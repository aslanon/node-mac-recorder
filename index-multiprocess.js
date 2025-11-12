/**
 * Multi-Process MacRecorder
 * Spawns each recorder in its own child process for true parallel recording
 */

const { EventEmitter } = require('events');
const { fork } = require('child_process');
const path = require('path');

class MacRecorderMultiProcess extends EventEmitter {
    constructor(options = {}) {
        super();

        this.worker = null;
        this.isRecording = false;
        this.outputPath = null;
        this.ready = false;
        this.pendingRequests = new Map();
        this.requestId = 0;

        // Auto-spawn worker
        this._spawnWorker();
    }

    _spawnWorker() {
        const workerPath = path.join(__dirname, 'recorder-worker.js');

        console.log(`🚀 Spawning recorder worker: ${workerPath}`);

        this.worker = fork(workerPath, [], {
            stdio: ['pipe', 'pipe', 'pipe', 'ipc'],
            env: { ...process.env }
        });

        this.worker.on('message', (msg) => this._handleWorkerMessage(msg));

        this.worker.on('error', (error) => {
            console.error('❌ Worker error:', error);
            this.emit('error', error);
        });

        this.worker.on('exit', (code, signal) => {
            console.log(`🛑 Worker exited: code=${code}, signal=${signal}`);
            this.ready = false;
            this.isRecording = false;

            // Reject all pending requests
            for (const [id, { reject }] of this.pendingRequests) {
                reject(new Error('Worker process exited'));
            }
            this.pendingRequests.clear();
        });

        this.worker.stdout.on('data', (data) => {
            console.log(`[Worker] ${data.toString().trim()}`);
        });

        this.worker.stderr.on('data', (data) => {
            console.error(`[Worker Error] ${data.toString().trim()}`);
        });
    }

    _handleWorkerMessage(msg) {
        // Handle ready message
        if (msg.type === 'ready') {
            this.ready = true;
            console.log('✅ Worker ready');
            return;
        }

        // Handle events
        if (msg.type === 'event') {
            this.emit(msg.event, msg.data);

            // Update local state based on events
            if (msg.event === 'recordingStarted') {
                this.isRecording = true;
            } else if (msg.event === 'stopped') {
                this.isRecording = false;
            }
            return;
        }

        // Handle errors
        if (msg.type === 'error') {
            console.error('❌ Worker error:', msg.message);
            this.emit('error', new Error(msg.message));
            return;
        }

        // Handle responses to specific requests
        if (msg.type.endsWith(':response')) {
            const requestType = msg.type.replace(':response', '');

            // Find matching pending request
            for (const [id, { type, resolve, reject }] of this.pendingRequests) {
                if (type === requestType) {
                    this.pendingRequests.delete(id);

                    if (msg.success === false) {
                        reject(new Error(msg.error || 'Request failed'));
                    } else {
                        resolve(msg.data);
                    }
                    break;
                }
            }
        }
    }

    _sendRequest(type, data = null, timeout = 30000) {
        return new Promise((resolve, reject) => {
            if (!this.worker) {
                return reject(new Error('Worker not initialized'));
            }

            if (!this.ready) {
                return reject(new Error('Worker not ready'));
            }

            const id = ++this.requestId;

            // Store pending request
            this.pendingRequests.set(id, { type, resolve, reject });

            // Set timeout
            const timeoutId = setTimeout(() => {
                if (this.pendingRequests.has(id)) {
                    this.pendingRequests.delete(id);
                    reject(new Error(`Request timeout: ${type}`));
                }
            }, timeout);

            // Send message to worker
            this.worker.send({ type, data, id });

            // Clear timeout on completion
            const originalResolve = resolve;
            const originalReject = reject;

            this.pendingRequests.set(id, {
                type,
                resolve: (value) => {
                    clearTimeout(timeoutId);
                    originalResolve(value);
                },
                reject: (error) => {
                    clearTimeout(timeoutId);
                    originalReject(error);
                }
            });
        });
    }

    async getWindows() {
        return this._sendRequest('getWindows');
    }

    async getDisplays() {
        const displays = await this._sendRequest('getDisplays');
        return displays.map((display, index) => ({
            id: display.id,
            name: display.name,
            width: display.width,
            height: display.height,
            x: display.x,
            y: display.y,
            isPrimary: display.isPrimary,
            resolution: `${display.width}x${display.height}`
        }));
    }

    async startRecording(outputPath, options = {}) {
        if (this.isRecording) {
            throw new Error('Recording already in progress');
        }

        if (!outputPath) {
            throw new Error('Output path is required');
        }

        this.outputPath = outputPath;

        const result = await this._sendRequest('startRecording', {
            outputPath,
            options
        }, 60000); // Longer timeout for recording start

        return result.outputPath;
    }

    async stopRecording() {
        if (!this.isRecording) {
            throw new Error('No recording in progress');
        }

        const result = await this._sendRequest('stopRecording', null, 10000);
        this.isRecording = false;

        return result;
    }

    async startCursorCapture(filepath, options = {}) {
        if (!this.ready) {
            throw new Error('Worker not ready');
        }

        const result = await this._sendRequest('startCursorCapture', {
            filepath,
            options
        });

        return result;
    }

    async stopCursorCapture() {
        const result = await this._sendRequest('stopCursorCapture');
        return result;
    }

    async getStatus() {
        return this._sendRequest('getStatus');
    }

    // Cleanup
    destroy() {
        if (this.worker) {
            this.worker.kill();
            this.worker = null;
        }

        this.ready = false;
        this.isRecording = false;
        this.pendingRequests.clear();
    }
}

module.exports = MacRecorderMultiProcess;

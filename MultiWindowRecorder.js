/**
 * MultiWindowRecorder - Creavit Desktop Integration
 * Manages multiple simultaneous window recordings
 */

const MacRecorder = require('./index-multiprocess');
const MacRecorderSync = require('./index'); // For cursor tracking
const path = require('path');
const { EventEmitter } = require('events');

class MultiWindowRecorder extends EventEmitter {
    constructor(options = {}) {
        super();

        this.recorders = [];
        this.windows = [];
        this.isRecording = false;
        this.outputFiles = [];
        this.cursorFiles = [];
        this.cameraFile = null; // Camera output file (from first recorder)
        this.audioFile = null; // Audio output file (from first recorder)
        this.cursorRecorder = null; // Separate recorder for cursor tracking
        this.timeUpdateInterval = null; // Timer for timeUpdate events
        this.metadata = {
            startTime: null,
            syncTimestamps: [],
            windowCount: 0
        };

        this.options = {
            frameRate: options.frameRate || 30,
            captureCursor: false, // Don't show system cursor in window recording
            preferScreenCaptureKit: options.preferScreenCaptureKit !== false,
            // Audio options
            enableMicrophone: options.enableMicrophone || false,
            microphoneDeviceId: options.microphoneDeviceId || null,
            captureSystemAudio: options.captureSystemAudio || false,
            // Camera options
            enableCamera: options.enableCamera || false,
            cameraDeviceId: options.cameraDeviceId || null,
            // Cursor tracking
            trackCursor: options.trackCursor !== false, // Default: true
            ...options
        };
    }

    /**
     * Add a window to be recorded
     * @param {Object} windowInfo - Window information from getWindows()
     * @returns {number} Index of the added window
     */
    async addWindow(windowInfo) {
        const recorder = new MacRecorder();

        const recorderInfo = {
            recorder,
            windowId: windowInfo.id,
            windowInfo: {
                id: windowInfo.id,
                appName: windowInfo.appName,
                title: windowInfo.title,
                width: windowInfo.width,
                height: windowInfo.height
            },
            outputPath: null,
            cursorFilePath: null,
            syncTimestamp: null,
            index: this.recorders.length
        };

        this.recorders.push(recorderInfo);
        this.windows.push(windowInfo);

        // Wait for worker to be ready
        await new Promise(r => setTimeout(r, 500));

        console.log(`✅ Window added: ${windowInfo.appName} (index: ${recorderInfo.index})`);

        return recorderInfo.index;
    }

    /**
     * Remove a window by index
     * @param {number} index - Window index
     */
    removeWindow(index) {
        if (index < 0 || index >= this.recorders.length) {
            throw new Error(`Invalid window index: ${index}`);
        }

        const recorderInfo = this.recorders[index];

        if (recorderInfo && recorderInfo.recorder) {
            recorderInfo.recorder.destroy();
            console.log(`🗑️ Window removed: ${recorderInfo.windowInfo.appName}`);
        }

        this.recorders.splice(index, 1);
        this.windows.splice(index, 1);

        // Update indices
        this.recorders.forEach((rec, i) => {
            rec.index = i;
        });
    }

    /**
     * Get current window count
     */
    getWindowCount() {
        return this.recorders.length;
    }

    /**
     * Start recording all windows
     * @param {string} outputDir - Output directory path
     * @param {Object} options - Recording options
     */
    async startRecording(outputDir, options = {}) {
        if (this.isRecording) {
            throw new Error('Recording already in progress');
        }

        if (this.recorders.length === 0) {
            throw new Error('No windows added. Call addWindow() first.');
        }

        const timestamp = Date.now();
        this.metadata.startTime = timestamp;
        this.metadata.windowCount = this.recorders.length;
        this.outputFiles = [];

        console.log(`🎬 Starting ${this.recorders.length} window recordings...`);
        console.log(`📁 Output directory: ${outputDir}`);

        // Start all recorders sequentially with 1s delay between each
        for (let i = 0; i < this.recorders.length; i++) {
            const recInfo = this.recorders[i];
            const appName = recInfo.windowInfo.appName.replace(/[^a-zA-Z0-9]/g, '_');
            const outputPath = path.join(outputDir, `temp_window_${i}_${appName}_${timestamp}.mov`);

            console.log(`\n▶️  Starting recorder ${i + 1}/${this.recorders.length}: ${recInfo.windowInfo.appName}`);

            const recordingOptions = {
                windowId: recInfo.windowId,
                frameRate: this.options.frameRate,
                captureCursor: this.options.captureCursor,
                preferScreenCaptureKit: this.options.preferScreenCaptureKit,
                // Use the MAIN timestamp for ALL files to keep them synchronized
                sessionTimestamp: timestamp,
                // Audio options - ONLY record audio on first window to avoid duplicates
                includeMicrophone: (i === 0 && this.options.enableMicrophone) || false,
                audioDeviceId: (i === 0 && this.options.microphoneDeviceId) || null,
                includeSystemAudio: (i === 0 && this.options.captureSystemAudio) || false,
                systemAudioDeviceId: null,
                // Camera options - record on first window only
                captureCamera: (i === 0 && this.options.enableCamera) || false,
                cameraDeviceId: (i === 0 && this.options.cameraDeviceId) || null,
                ...options
            };

            try {
                const startTimestamp = Date.now();

                // For first recorder, pre-calculate camera and audio paths
                // IMPORTANT: Use the MAIN timestamp, not startTimestamp, to match window files!
                if (i === 0) {
                    if (this.options.enableCamera) {
                        this.cameraFile = path.join(outputDir, `temp_camera_${timestamp}.mov`);
                        console.log(`   📷 Camera will be saved to: ${path.basename(this.cameraFile)}`);
                    }

                    if (this.options.enableMicrophone || this.options.captureSystemAudio) {
                        this.audioFile = path.join(outputDir, `temp_audio_${timestamp}.mov`);
                        console.log(`   🎵 Audio will be saved to: ${path.basename(this.audioFile)}`);
                    }
                }

                await recInfo.recorder.startRecording(outputPath, recordingOptions);

                recInfo.outputPath = outputPath;
                recInfo.syncTimestamp = startTimestamp;
                this.metadata.syncTimestamps.push(startTimestamp);
                this.outputFiles.push(outputPath);

                console.log(`   ✅ Recorder ${i + 1} started`);
                console.log(`   📄 Output: ${path.basename(outputPath)}`);

                // Start cursor tracking if enabled (only once for all windows)
                if (this.options.trackCursor && i === 0) {
                    const cursorPath = path.join(outputDir, `temp_cursor_${timestamp}.json`);

                    // Create cursor recorder on first use
                    if (!this.cursorRecorder) {
                        this.cursorRecorder = new MacRecorderSync();
                    }

                    // Track cursor globally (not window-relative for multi-window)
                    await this.cursorRecorder.startCursorCapture(cursorPath, {
                        windowRelative: false // Global coordinates for multi-window
                    });

                    // Store cursor file path for all windows
                    this.recorders.forEach(rec => {
                        rec.cursorFilePath = cursorPath;
                    });
                    this.cursorFiles.push(cursorPath);

                    console.log(`   🖱️  Cursor tracking started (global)`);
                    console.log(`   📄 Cursor file: ${path.basename(cursorPath)}`);
                }

                this.emit('recorderStarted', {
                    index: i,
                    windowInfo: recInfo.windowInfo,
                    outputPath: outputPath,
                    cursorFilePath: recInfo.cursorFilePath,
                    timestamp: startTimestamp
                });

                // Wait for ScreenCaptureKit initialization (except for last recorder)
                if (i < this.recorders.length - 1) {
                    console.log(`   ⏳ Waiting 1s for ScreenCaptureKit init...`);
                    await new Promise(r => setTimeout(r, 1000));
                }
            } catch (error) {
                console.error(`   ❌ Failed to start recorder ${i + 1}:`, error.message);

                // Stop all previously started recorders and cursor tracking
                for (let j = 0; j < i; j++) {
                    try {
                        await this.recorders[j].recorder.stopRecording();
                    } catch (stopError) {
                        console.error(`Failed to stop recorder ${j}:`, stopError.message);
                    }
                }

                // Stop cursor tracking if it was started
                if (this.options.trackCursor && this.cursorRecorder) {
                    try {
                        await this.cursorRecorder.stopCursorCapture();
                    } catch (cursorError) {
                        console.error(`Failed to stop cursor tracking:`, cursorError.message);
                    }
                }

                throw new Error(`Failed to start recorder ${i + 1}: ${error.message}`);
            }
        }

        this.isRecording = true;

        // Start timeUpdate timer (emit every second)
        this.timeUpdateInterval = setInterval(() => {
            if (this.isRecording && this.metadata.startTime) {
                const elapsed = Math.floor((Date.now() - this.metadata.startTime) / 1000);
                this.emit('timeUpdate', elapsed);
            }
        }, 1000);

        console.log(`\n✅ All ${this.recorders.length} recordings started successfully!`);
        console.log(`🔴 Multi-window recording in progress...`);

        this.emit('allStarted', {
            windowCount: this.recorders.length,
            outputFiles: this.outputFiles,
            metadata: this.metadata
        });

        return {
            windowCount: this.recorders.length,
            outputFiles: this.outputFiles,
            metadata: this.metadata
        };
    }

    /**
     * Stop all recordings
     */
    async stopRecording() {
        if (!this.isRecording) {
            throw new Error('No recording in progress');
        }

        console.log(`\n🛑 Stopping ${this.recorders.length} recordings...`);

        const stopTimestamp = Date.now();

        // Stop timeUpdate timer
        if (this.timeUpdateInterval) {
            clearInterval(this.timeUpdateInterval);
            this.timeUpdateInterval = null;
            console.log(`   ⏱️  Timer stopped`);
        }

        // Stop cursor tracking first (before stopping video recordings)
        if (this.options.trackCursor && this.cursorRecorder) {
            try {
                console.log(`   🖱️  Stopping cursor tracking...`);
                await this.cursorRecorder.stopCursorCapture();
                console.log(`   ✅ Cursor tracking stopped`);
            } catch (error) {
                console.error(`   ❌ Failed to stop cursor tracking:`, error.message);
            }
        }

        // Stop all recorders in parallel
        const stopPromises = this.recorders.map(async (recInfo, index) => {
            try {
                console.log(`   Stopping recorder ${index + 1}: ${recInfo.windowInfo.appName}...`);

                await recInfo.recorder.stopRecording();
                console.log(`   ✅ Recorder ${index + 1} stopped`);

                this.emit('recorderStopped', {
                    index,
                    windowInfo: recInfo.windowInfo,
                    outputPath: recInfo.outputPath,
                    cursorFilePath: recInfo.cursorFilePath
                });

                return {
                    index,
                    success: true,
                    outputPath: recInfo.outputPath,
                    cursorFilePath: recInfo.cursorFilePath
                };
            } catch (error) {
                console.error(`   ❌ Failed to stop recorder ${index + 1}:`, error.message);

                this.emit('recorderError', {
                    index,
                    error: error.message
                });

                return {
                    index,
                    success: false,
                    error: error.message
                };
            }
        });

        const results = await Promise.all(stopPromises);

        this.isRecording = false;

        // Get camera and audio paths from first recorder's status
        if (this.recorders.length > 0) {
            try {
                const firstRecorderStatus = this.recorders[0].recorder.getStatus();
                if (firstRecorderStatus.cameraOutputPath) {
                    this.cameraFile = firstRecorderStatus.cameraOutputPath;
                    console.log(`   📷 Camera file from recorder: ${path.basename(this.cameraFile)}`);
                }
                if (firstRecorderStatus.audioOutputPath) {
                    this.audioFile = firstRecorderStatus.audioOutputPath;
                    console.log(`   🎵 Audio file from recorder: ${path.basename(this.audioFile)}`);
                }
            } catch (error) {
                console.error(`   ⚠️  Could not get camera/audio paths from first recorder:`, error.message);
            }
        }

        // Calculate duration
        const duration = stopTimestamp - this.metadata.startTime;

        const result = {
            success: results.every(r => r.success),
            windowCount: this.recorders.length,
            outputFiles: this.outputFiles,
            cursorFiles: this.cursorFiles,
            cameraFile: this.cameraFile, // Camera output path (from first recorder)
            audioFile: this.audioFile,   // Audio output path (from first recorder)
            duration: duration,
            metadata: {
                ...this.metadata,
                stopTime: stopTimestamp,
                duration: duration,
                windows: this.recorders.map((recInfo, i) => ({
                    index: i,
                    windowInfo: recInfo.windowInfo,
                    outputPath: recInfo.outputPath,
                    cursorFilePath: recInfo.cursorFilePath,
                    syncTimestamp: recInfo.syncTimestamp,
                    syncOffset: recInfo.syncTimestamp - this.metadata.startTime
                }))
            }
        };

        console.log(`\n✅ All recordings stopped successfully!`);
        console.log(`📊 Duration: ${(duration / 1000).toFixed(2)}s`);
        console.log(`📁 Output files: ${this.outputFiles.length}`);
        if (this.options.trackCursor) {
            console.log(`🖱️  Cursor files: ${this.cursorFiles.length}`);
        }

        this.emit('allStopped', result);

        return result;
    }

    /**
     * Get recording status
     */
    getStatus() {
        return {
            isRecording: this.isRecording,
            windowCount: this.recorders.length,
            outputFiles: this.outputFiles,
            metadata: this.metadata,
            windows: this.recorders.map(rec => ({
                index: rec.index,
                windowInfo: rec.windowInfo,
                outputPath: rec.outputPath
            }))
        };
    }

    /**
     * Get metadata for CRVT file creation
     */
    getMetadataForCRVT() {
        return {
            version: '2.0',
            timestamp: this.metadata.startTime,
            duration: this.metadata.duration || 0,
            multiWindow: {
                enabled: true,
                windowCount: this.recorders.length,
                windows: this.recorders.map((recInfo, i) => ({
                    index: i,
                    windowId: recInfo.windowId,
                    appName: recInfo.windowInfo.appName,
                    title: recInfo.windowInfo.title,
                    outputPath: recInfo.outputPath, // Use outputPath for consistency with saveProjectToCrvt
                    cursorFilePath: recInfo.cursorFilePath,
                    syncTimestamp: recInfo.syncTimestamp,
                    syncOffset: recInfo.syncTimestamp - this.metadata.startTime,
                    layoutRow: i  // Each window on separate row
                }))
            },
            // Recording options
            options: {
                enableCamera: this.options.enableCamera,
                cameraDeviceId: this.options.cameraDeviceId,
                enableMicrophone: this.options.enableMicrophone,
                microphoneDeviceId: this.options.microphoneDeviceId,
                captureSystemAudio: this.options.captureSystemAudio,
                trackCursor: this.options.trackCursor
            }
        };
    }

    /**
     * Destroy all recorders and cleanup
     */
    destroy() {
        console.log('🧹 Cleaning up multi-window recorder...');

        // Stop timeUpdate timer
        if (this.timeUpdateInterval) {
            clearInterval(this.timeUpdateInterval);
            this.timeUpdateInterval = null;
        }

        this.recorders.forEach((recInfo, index) => {
            try {
                recInfo.recorder.destroy();
                console.log(`   ✓ Recorder ${index + 1} destroyed`);
            } catch (error) {
                console.error(`   ✗ Failed to destroy recorder ${index + 1}:`, error.message);
            }
        });

        // Destroy cursor recorder if exists
        if (this.cursorRecorder) {
            try {
                // MacRecorderSync uses cleanup() instead of destroy()
                if (typeof this.cursorRecorder.cleanup === 'function') {
                    this.cursorRecorder.cleanup();
                } else if (typeof this.cursorRecorder.destroy === 'function') {
                    this.cursorRecorder.destroy();
                }
                console.log(`   ✓ Cursor recorder destroyed`);
            } catch (error) {
                console.error(`   ✗ Failed to destroy cursor recorder:`, error.message);
            }
            this.cursorRecorder = null;
        }

        this.recorders = [];
        this.windows = [];
        this.outputFiles = [];
        this.cursorFiles = [];
        this.isRecording = false;

        console.log('✅ Multi-window recorder cleaned up');
    }
}

module.exports = MultiWindowRecorder;

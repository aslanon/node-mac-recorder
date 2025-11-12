/**
 * RecorderWorker - Child process worker for multi-session recording
 * Each MacRecorder instance spawns its own worker process
 * This allows multiple simultaneous recordings without native code changes
 */

const path = require('path');

// Load native binding directly
let nativeBinding;
try {
    nativeBinding = require('./build/Release/mac_recorder.node');
} catch (error) {
    try {
        nativeBinding = require('./build/Debug/mac_recorder.node');
    } catch (debugError) {
        process.send({
            type: 'error',
            message: 'Native module not found',
            error: error.message
        });
        process.exit(1);
    }
}

// Worker state
let isRecording = false;
let outputPath = null;
let recordingTimer = null;
let recordingStartTime = null;

// Cursor capture state
let cursorCaptureInterval = null;
let cursorCaptureFile = null;
let cursorCaptureStartTime = null;
let cursorCaptureFirstWrite = true;
let lastCapturedData = null;

// Message handler
process.on('message', async (msg) => {
    try {
        switch (msg.type) {
            case 'getWindows':
                handleGetWindows();
                break;
            case 'getDisplays':
                handleGetDisplays();
                break;
            case 'startRecording':
                await handleStartRecording(msg.data);
                break;
            case 'stopRecording':
                await handleStopRecording();
                break;
            case 'startCursorCapture':
                await handleStartCursorCapture(msg.data);
                break;
            case 'stopCursorCapture':
                await handleStopCursorCapture();
                break;
            case 'getStatus':
                handleGetStatus();
                break;
            case 'ping':
                process.send({ type: 'pong' });
                break;
            default:
                process.send({
                    type: 'error',
                    message: `Unknown message type: ${msg.type}`
                });
        }
    } catch (error) {
        process.send({
            type: 'error',
            message: error.message,
            stack: error.stack
        });
    }
});

function handleGetWindows() {
    try {
        const windows = nativeBinding.getWindows();
        process.send({
            type: 'getWindows:response',
            data: windows
        });
    } catch (error) {
        process.send({
            type: 'error',
            message: `Failed to get windows: ${error.message}`
        });
    }
}

function handleGetDisplays() {
    try {
        const displays = nativeBinding.getDisplays();
        process.send({
            type: 'getDisplays:response',
            data: displays
        });
    } catch (error) {
        process.send({
            type: 'error',
            message: `Failed to get displays: ${error.message}`
        });
    }
}

async function handleStartRecording(config) {
    if (isRecording) {
        process.send({
            type: 'error',
            message: 'Recording already in progress in this worker'
        });
        return;
    }

    try {
        const { outputPath: outPath, options } = config;
        outputPath = outPath;

        console.log(`📝 Worker ${process.pid}: Starting recording to ${outputPath}`);

        // Prepare recording options
        const recordingOptions = {
            includeMicrophone: options.includeMicrophone || false,
            includeSystemAudio: options.includeSystemAudio || false,
            captureCursor: options.captureCursor || false,
            displayId: options.displayId || null,
            windowId: options.windowId || null,
            audioDeviceId: options.audioDeviceId || null,
            systemAudioDeviceId: options.systemAudioDeviceId || null,
            captureCamera: options.captureCamera || false,
            cameraDeviceId: options.cameraDeviceId || null,
            // CRITICAL: Use provided sessionTimestamp from parent, or generate new one
            sessionTimestamp: options.sessionTimestamp || Date.now(),
            frameRate: options.frameRate || 60,
            quality: options.quality || 'high',
            preferScreenCaptureKit: options.preferScreenCaptureKit || false
        };

        // Start native recording
        const success = nativeBinding.startRecording(outputPath, recordingOptions);

        if (success) {
            isRecording = true;
            recordingStartTime = Date.now();

            // Start timer for timeUpdate events
            recordingTimer = setInterval(() => {
                const elapsed = Math.floor((Date.now() - recordingStartTime) / 1000);
                process.send({
                    type: 'event',
                    event: 'timeUpdate',
                    data: elapsed
                });
            }, 1000);

            // Poll for recording status
            const checkInterval = setInterval(() => {
                try {
                    const nativeStatus = nativeBinding.getRecordingStatus();
                    if (nativeStatus) {
                        clearInterval(checkInterval);
                        process.send({
                            type: 'event',
                            event: 'recordingStarted',
                            data: {
                                outputPath: outputPath,
                                timestamp: Date.now(),
                                options: recordingOptions
                            }
                        });
                    }
                } catch (error) {
                    clearInterval(checkInterval);
                }
            }, 50);

            // Timeout fallback
            setTimeout(() => {
                clearInterval(checkInterval);
            }, 5000);

            process.send({
                type: 'startRecording:response',
                success: true,
                data: { outputPath }
            });
        } else {
            throw new Error('Native recording failed to start');
        }
    } catch (error) {
        isRecording = false;
        process.send({
            type: 'startRecording:response',
            success: false,
            error: error.message
        });
    }
}

async function handleStopRecording() {
    if (!isRecording) {
        process.send({
            type: 'error',
            message: 'No recording in progress'
        });
        return;
    }

    try {
        // Stop timer
        if (recordingTimer) {
            clearInterval(recordingTimer);
            recordingTimer = null;
        }

        // Calculate elapsed time for stop limit
        const elapsedSeconds = recordingStartTime
            ? (Date.now() - recordingStartTime) / 1000
            : 0;

        // Stop native recording
        const success = nativeBinding.stopRecording(elapsedSeconds);

        isRecording = false;

        process.send({
            type: 'event',
            event: 'stopped',
            data: {
                code: success ? 0 : 1,
                outputPath: outputPath
            }
        });

        process.send({
            type: 'stopRecording:response',
            success: true,
            data: { outputPath }
        });

        // Small delay to ensure file is written
        setTimeout(() => {
            process.send({
                type: 'event',
                event: 'completed',
                data: outputPath
            });
        }, 1000);

    } catch (error) {
        process.send({
            type: 'stopRecording:response',
            success: false,
            error: error.message
        });
    }
}

function handleGetStatus() {
    try {
        const nativeStatus = nativeBinding.getRecordingStatus();
        process.send({
            type: 'getStatus:response',
            data: {
                isRecording: isRecording && nativeStatus,
                outputPath: outputPath,
                recordingTime: recordingStartTime
                    ? Math.floor((Date.now() - recordingStartTime) / 1000)
                    : 0
            }
        });
    } catch (error) {
        process.send({
            type: 'error',
            message: `Failed to get status: ${error.message}`
        });
    }
}

async function handleStartCursorCapture(config) {
    const fs = require('fs');

    if (cursorCaptureInterval) {
        process.send({
            type: 'error',
            message: 'Cursor capture already in progress'
        });
        return;
    }

    try {
        const { filepath, options = {} } = config;

        // Start cursor capture using native binding
        const success = nativeBinding.startCursorCapture(filepath, options);

        if (success) {
            cursorCaptureFile = filepath;
            cursorCaptureStartTime = Date.now();
            cursorCaptureFirstWrite = true;

            process.send({
                type: 'startCursorCapture:response',
                success: true,
                data: { filepath }
            });

            process.send({
                type: 'event',
                event: 'cursorCaptureStarted',
                data: { filepath }
            });
        } else {
            throw new Error('Native cursor capture failed to start');
        }
    } catch (error) {
        process.send({
            type: 'startCursorCapture:response',
            success: false,
            error: error.message
        });
    }
}

async function handleStopCursorCapture() {
    if (!cursorCaptureFile) {
        process.send({
            type: 'error',
            message: 'No cursor capture in progress'
        });
        return;
    }

    try {
        // Stop native cursor capture
        nativeBinding.stopCursorCapture();

        const filepath = cursorCaptureFile;
        cursorCaptureFile = null;
        cursorCaptureStartTime = null;
        cursorCaptureFirstWrite = true;
        lastCapturedData = null;

        if (cursorCaptureInterval) {
            clearInterval(cursorCaptureInterval);
            cursorCaptureInterval = null;
        }

        process.send({
            type: 'stopCursorCapture:response',
            success: true,
            data: { filepath }
        });

        process.send({
            type: 'event',
            event: 'cursorCaptureStopped',
            data: { filepath }
        });
    } catch (error) {
        process.send({
            type: 'stopCursorCapture:response',
            success: false,
            error: error.message
        });
    }
}

// Graceful shutdown
process.on('SIGTERM', () => {
    if (isRecording) {
        try {
            nativeBinding.stopRecording(0);
        } catch (error) {
            // Ignore cleanup errors
        }
    }
    process.exit(0);
});

process.on('SIGINT', () => {
    if (isRecording) {
        try {
            nativeBinding.stopRecording(0);
        } catch (error) {
            // Ignore cleanup errors
        }
    }
    process.exit(0);
});

// Signal ready
process.send({ type: 'ready' });

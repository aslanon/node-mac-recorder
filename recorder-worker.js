/**
 * RecorderWorker - Child process worker for multi-session recording
 * Each MacRecorder instance spawns its own worker process
 * This allows multiple simultaneous recordings without native code changes
 */

const path = require('path');

// Parent windows can disappear while a native callback is completing.
function sendToParent(message) {
    if (!process.connected) return;
    try { process.send(message, () => {}); } catch (_) {}
}
const { waitForNativeIdle } = require('./recorder_runtime_safety.cjs');

// Load native binding directly
let nativeBinding;
try {
    nativeBinding = require('./build/Release/mac_recorder.node');
} catch (error) {
    try {
        nativeBinding = require('./build/Debug/mac_recorder.node');
    } catch (debugError) {
        sendToParent({
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
let isPaused = false;
let pauseStartedAt = null;
let pausedDurationMs = 0;
let recordingStatusInterval = null;
let recordingStartTimeout = null;
let captureGeneration = 0;

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
            case 'pauseRecording':
                handlePauseRecording();
                break;
            case 'resumeRecording':
                handleResumeRecording();
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
                sendToParent({ type: 'pong' });
                break;
            default:
                sendToParent({
                    type: 'error',
                    message: `Unknown message type: ${msg.type}`
                });
        }
    } catch (error) {
        sendToParent({
            type: 'error',
            message: error.message,
            stack: error.stack
        });
    }
});

function handleGetWindows() {
    try {
        const windows = nativeBinding.getWindows();
        sendToParent({
            type: 'getWindows:response',
            data: windows
        });
    } catch (error) {
        sendToParent({
            type: 'error',
            message: `Failed to get windows: ${error.message}`
        });
    }
}

function handleGetDisplays() {
    try {
        const displays = nativeBinding.getDisplays();
        sendToParent({
            type: 'getDisplays:response',
            data: displays
        });
    } catch (error) {
        sendToParent({
            type: 'error',
            message: `Failed to get displays: ${error.message}`
        });
    }
}

function getPausedDurationMs(now = Date.now()) {
    return pausedDurationMs + (isPaused && pauseStartedAt ? Math.max(0, now - pauseStartedAt) : 0);
}

function getRecordingTimeSeconds(now = Date.now()) {
    if (!recordingStartTime) return 0;
    return Math.floor(Math.max(0, now - recordingStartTime - getPausedDurationMs(now)) / 1000);
}

async function handleStartRecording(config) {
    if (isRecording) {
        sendToParent({
            type: 'error',
            message: 'Recording already in progress in this worker'
        });
        return;
    }

    try {
        const { outputPath: outPath, options } = config;
        outputPath = outPath;
        isPaused = false;
        pauseStartedAt = null;
        pausedDurationMs = 0;
        ++captureGeneration;

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
                sendToParent({
                    type: 'event',
                    event: 'timeUpdate',
                    data: getRecordingTimeSeconds()
                });
            }, 1000);

            // Poll for recording status
            const checkInterval = recordingStatusInterval = setInterval(() => {
                if (!isRecording) { clearInterval(checkInterval); return; }
                try {
                    const nativeStatus = nativeBinding.getRecordingStatus();
                    if (nativeStatus) {
                        clearInterval(checkInterval);
                        sendToParent({
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
            recordingStartTimeout = setTimeout(() => {
                clearInterval(checkInterval);
            }, 5000);

            sendToParent({
                type: 'startRecording:response',
                success: true,
                data: { outputPath }
            });
        } else {
            throw new Error('Native recording failed to start');
        }
    } catch (error) {
        clearInterval(recordingTimer);
        clearInterval(recordingStatusInterval);
        clearTimeout(recordingStartTimeout);
        try {
            nativeBinding.stopRecording(0);
            await waitForNativeIdle(nativeBinding);
        } catch (cleanupError) {
            console.warn('Worker startup cleanup:', cleanupError.message);
        }
        isRecording = false;
        sendToParent({
            type: 'startRecording:response',
            success: false,
            error: error.message
        });
    }
}

function handlePauseRecording() {
    if (!isRecording) {
        sendToParent({ type: 'pauseRecording:response', success: false, error: 'No recording in progress' });
        return;
    }
    if (!isPaused) {
        if (typeof nativeBinding.pauseRecording !== 'function' || nativeBinding.pauseRecording() !== true) {
            sendToParent({ type: 'pauseRecording:response', success: false, error: 'Recording could not be paused' });
            return;
        }
        isPaused = true;
        pauseStartedAt = Date.now();
    }
    const status = buildStatus();
    sendToParent({ type: 'event', event: 'paused', data: status });
    sendToParent({ type: 'pauseRecording:response', success: true, data: status });
}

function handleResumeRecording() {
    if (!isRecording) {
        sendToParent({ type: 'resumeRecording:response', success: false, error: 'No recording in progress' });
        return;
    }
    if (isPaused) {
        if (typeof nativeBinding.resumeRecording !== 'function' || nativeBinding.resumeRecording() !== true) {
            sendToParent({ type: 'resumeRecording:response', success: false, error: 'Recording could not be resumed' });
            return;
        }
        const resumedAt = Date.now();
        pausedDurationMs += Math.max(0, resumedAt - pauseStartedAt);
        pauseStartedAt = null;
        isPaused = false;
    }
    const status = buildStatus();
    sendToParent({ type: 'event', event: 'resumed', data: status });
    sendToParent({ type: 'resumeRecording:response', success: true, data: status });
}

async function handleStopRecording() {
    if (!isRecording) {
        sendToParent({
            type: 'error',
            message: 'No recording in progress'
        });
        return;
    }

    try {
        clearInterval(recordingStatusInterval);
        clearTimeout(recordingStartTimeout);
        // Stop timer
        if (recordingTimer) {
            clearInterval(recordingTimer);
            recordingTimer = null;
        }

        // Calculate elapsed time for stop limit
        const elapsedSeconds = getRecordingTimeSeconds();
        const totalPausedSeconds = getPausedDurationMs() / 1000;

        // Stop native recording
        const success = nativeBinding.stopRecording(elapsedSeconds);
        await waitForNativeIdle(nativeBinding);

        isRecording = false;
        isPaused = false;
        pauseStartedAt = null;

        sendToParent({
            type: 'event',
            event: 'stopped',
            data: {
                code: success ? 0 : 1,
                outputPath: outputPath,
                recordingTime: elapsedSeconds,
                pausedDuration: totalPausedSeconds
            }
        });

        sendToParent({
            type: 'stopRecording:response',
            success: true,
            data: { outputPath, recordingTime: elapsedSeconds, pausedDuration: totalPausedSeconds }
        });

        const completedPath = outputPath;
        const completedGeneration = captureGeneration;
        setTimeout(() => {
            if (completedGeneration !== captureGeneration) return;
            sendToParent({
                type: 'event',
                event: 'completed',
                data: completedPath
            });
        }, 1000);

    } catch (error) {
        sendToParent({
            type: 'stopRecording:response',
            success: false,
            error: error.message
        });
    }
}

function buildStatus() {
    const nativeStatus = nativeBinding.getRecordingStatus();
    return {
        isRecording: isRecording && nativeStatus,
        isPaused,
        outputPath,
        recordingTime: getRecordingTimeSeconds(),
        pausedDuration: getPausedDurationMs() / 1000
    };
}

function handleGetStatus() {
    try {
        sendToParent({
            type: 'getStatus:response',
            data: buildStatus()
        });
    } catch (error) {
        sendToParent({
            type: 'error',
            message: `Failed to get status: ${error.message}`
        });
    }
}

async function handleStartCursorCapture(config) {
    const fs = require('fs');

    if (cursorCaptureInterval) {
        sendToParent({
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

            sendToParent({
                type: 'startCursorCapture:response',
                success: true,
                data: { filepath }
            });

            sendToParent({
                type: 'event',
                event: 'cursorCaptureStarted',
                data: { filepath }
            });
        } else {
            throw new Error('Native cursor capture failed to start');
        }
    } catch (error) {
        sendToParent({
            type: 'startCursorCapture:response',
            success: false,
            error: error.message
        });
    }
}

async function handleStopCursorCapture() {
    if (!cursorCaptureFile) {
        sendToParent({
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

        sendToParent({
            type: 'stopCursorCapture:response',
            success: true,
            data: { filepath }
        });

        sendToParent({
            type: 'event',
            event: 'cursorCaptureStopped',
            data: { filepath }
        });
    } catch (error) {
        sendToParent({
            type: 'stopCursorCapture:response',
            success: false,
            error: error.message
        });
    }
}

// Finalize writers before releasing the child process on parent cleanup.
let shuttingDown = false;
async function shutdown() {
    if (shuttingDown) return;
    shuttingDown = true;
    clearInterval(recordingTimer);
    clearInterval(recordingStatusInterval);
    clearTimeout(recordingStartTimeout);
    try {
        if (cursorCaptureFile) nativeBinding.stopCursorCapture();
        nativeBinding.stopRecording(0);
        await waitForNativeIdle(nativeBinding);
    } catch (error) {
        console.warn('Worker shutdown cleanup:', error.message);
    } finally {
        process.exit(0);
    }
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
process.on('disconnect', shutdown);

// Signal ready
sendToParent({ type: 'ready' });

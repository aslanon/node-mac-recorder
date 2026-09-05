const isBusy = (state) => !!(state && (
	state.isRecording || state.isStarting || state.isStopping || state.hasAuxiliaryRecording
));

async function waitForNativeIdle(binding, {
	timeoutMs = 30000, pollMs = 25, now = Date.now,
	sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
} = {}) {
	if (typeof binding.getRecordingLifecycleStatus !== "function") return;
	const started = now();
	while (isBusy(binding.getRecordingLifecycleStatus())) {
		if (now() - started >= timeoutMs) {
			const error = new Error("The previous recording is still finalizing. Please wait before starting again.");
			error.code = "RECORDER_STILL_FINALIZING";
			throw error;
		}
		await sleep(pollMs);
	}
}

function clearRecordingTimers(recorder) {
	clearInterval(recorder.recordingTimer);
	clearInterval(recorder.recordingStatusInterval);
	clearTimeout(recorder.recordingStartTimeout);
	recorder.recordingTimer = null;
	recorder.recordingStatusInterval = null;
	recorder.recordingStartTimeout = null;
	recorder._videoStartWatcherActive = false;
}

function installRecorderSafety(MacRecorder, binding, waitOptions) {
	const prototype = MacRecorder.prototype;
	prototype.getNativeLifecycleStatus = function () {
		return binding.getRecordingLifecycleStatus?.() || null;
	};
	for (const name of ["startRecording", "startIOSRecording"]) {
		const start = prototype[name];
		if (typeof start !== "function") continue;
		prototype[name] = function (...args) {
			if (this._startPromise) {
				return this._startMethod === name ? this._startPromise : Promise.reject(new Error("Recording is already starting"));
			}
			if (this.isRecording || this._stopPromise || isBusy(this.getNativeLifecycleStatus())) {
				return Promise.reject(new Error("Recording is already active or still finalizing"));
			}
			this._startMethod = name;
			this._captureGeneration = (this._captureGeneration || 0) + 1;
			this.videoStartTimestamp = 0;
			this._startPromise = Promise.resolve().then(() => start.apply(this, args)).catch(async (error) => {
				clearRecordingTimers(this);
				for (const stopTracking of ["stopCursorCapture", "stopKeyboardCapture"]) {
					try { await this[stopTracking]?.(); } catch (trackingError) {
						console.warn(`[Recorder] ${stopTracking} cleanup:`, trackingError.message);
					}
				}
				try {
					if (name === "startIOSRecording") binding.stopIOSDeviceRecording?.();
					else binding.stopRecording?.(0);
					await waitForNativeIdle(binding, waitOptions);
				} catch (cleanupError) {
					console.warn("[Recorder] Startup cleanup is still pending:", cleanupError.message);
				}
				this.isRecording = isBusy(this.getNativeLifecycleStatus());
				this.recordingMode = this.isRecording && name === "startIOSRecording" ? "iphone" : null;
				throw error;
			}).finally(() => {
				this._startPromise = null;
				this._startMethod = null;
			});
			return this._startPromise;
		};
	}

	const stop = prototype.stopRecording;
	prototype.stopRecording = function (...args) {
		if (this._stopPromise) return this._stopPromise;
		const pendingStart = this._startPromise;
		let stoppedMode = this.recordingMode;
		this._stopPromise = Promise.resolve().then(async () => {
			if (pendingStart) await pendingStart;
			stoppedMode = this.recordingMode;
			clearRecordingTimers(this);
			const result = await stop.apply(this, args);
			// ScreenCaptureKit's native stop returns before its writers finish.
			// Keep the JS promise pending until the native resources are reusable.
			await waitForNativeIdle(binding, waitOptions);
			return result;
		}).catch((error) => {
			clearRecordingTimers(this);
			this.isRecording = isBusy(this.getNativeLifecycleStatus());
			if (this.isRecording && stoppedMode === "iphone") this.recordingMode = "iphone";
			throw error;
		}).finally(() => {
			this._stopPromise = null;
		});
		return this._stopPromise;
	};
}

module.exports = installRecorderSafety;
module.exports.waitForNativeIdle = waitForNativeIdle;

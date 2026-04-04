const { EventEmitter } = require("events");
const path = require("path");
const fs = require("fs");
const cursorCapturePolling = require("./lib/cursorCapture/polling");

// Electron-safe native module loading
let electronSafeNativeBinding;

function loadElectronSafeModule() {
	try {
		// Try to load electron-safe build first
		electronSafeNativeBinding = require("./build/Release/mac_recorder_electron.node");
		console.log("✅ Loaded Electron-safe native module (Release)");
		return true;
	} catch (error) {
		try {
			electronSafeNativeBinding = require("./build/Debug/mac_recorder_electron.node");
			console.log("✅ Loaded Electron-safe native module (Debug)");
			return true;
		} catch (debugError) {
			console.error(
				"❌ Electron-safe native module not found. Run: npm run build:electron-safe"
			);
			console.error("Original error:", error.message);
			console.error("Debug error:", debugError.message);
			return false;
		}
	}
}

class ElectronSafeMacRecorder extends EventEmitter {
	constructor() {
		super();

		// Load the module safely
		if (!loadElectronSafeModule()) {
			throw new Error("Failed to load Electron-safe native module");
		}

		this.isRecording = false;
		this.outputPath = null;
		this.recordingTimer = null;
		this.recordingStartTime = null;

		this.cursorCaptureInterval = null;
		this.cursorCaptureFile = null;
		this.cursorCaptureStartTime = null;
		this.cursorCaptureFirstWrite = true;
		this.lastCapturedData = null;
		this.cursorDisplayInfo = null;
		this.recordingDisplayInfo = null;
		this.cursorCaptureSessionTimestamp = null;
		this.sessionTimestamp = null;
		this.syncTimestamp = null;

		this.options = {
			includeMicrophone: false,
			includeSystemAudio: false,
			quality: "high",
			frameRate: 60,
			captureArea: null,
			captureCursor: false,
			showClicks: false,
			displayId: null,
			windowId: null,
		};

		console.log("🔌 ElectronSafeMacRecorder initialized");
	}

	/**
	 * Set recording options safely
	 */
	setOptions(options = {}) {
		this.options = {
			...this.options,
			...options,
		};

		// Ensure boolean values
		this.options.includeMicrophone = options.includeMicrophone === true;
		this.options.includeSystemAudio = options.includeSystemAudio === true;
		this.options.captureCursor = options.captureCursor === true;

		console.log("⚙️ Options updated:", this.options);
	}

	/**
	 * Start recording with Electron-safe implementation
	 */
	async startRecording(outputPath, options = {}) {
		if (this.isRecording) {
			throw new Error("Recording is already in progress");
		}

		if (!outputPath) {
			throw new Error("Output path is required");
		}

		this.setOptions(options);

		const outputDir = path.dirname(outputPath);
		if (!fs.existsSync(outputDir)) {
			fs.mkdirSync(outputDir, { recursive: true });
		}

		this.outputPath = outputPath;

		console.log("🎬 Starting Electron-safe recording...");
		console.log("📁 Output path:", outputPath);
		console.log("⚙️ Options:", this.options);

		const startTimeout = setTimeout(() => {
			this.isRecording = false;
		}, 10000);

		let success = false;
		try {
			success = electronSafeNativeBinding.startRecording(
				outputPath,
				this.options,
			);
		} finally {
			clearTimeout(startTimeout);
		}

		if (!success) {
			console.error("❌ Failed to start Electron-safe recording");
			throw new Error("Failed to start recording - check permissions");
		}

		this.isRecording = true;
		this.recordingStartTime = Date.now();

		this.recordingTimer = setInterval(() => {
			const elapsed = Math.floor(
				(Date.now() - this.recordingStartTime) / 1000,
			);
			this.emit("timeUpdate", elapsed);
		}, 1000);

		const sessionTs =
			options.sessionTimestamp ||
			this.sessionTimestamp ||
			this.recordingStartTime;
		this.sessionTimestamp = sessionTs;
		const cursorFilePath = path.join(
			outputDir,
			`temp_cursor_${sessionTs}.json`,
		);

		let recordingDisplayInfo = null;
		try {
			const displays = await this.getDisplays();
			const did = this.options.displayId;
			let target = null;
			if (did != null && did !== undefined) {
				target = displays.find((d) => d.id === did);
			}
			if (!target) {
				target = displays.find((d) => d.isPrimary) || displays[0];
			}
			if (target) {
				recordingDisplayInfo = {
					displayId: target.id,
					x: target.x || 0,
					y: target.y || 0,
					width: target.width,
					height: target.height,
					logicalWidth: target.width,
					logicalHeight: target.height,
				};
			}
		} catch {
			recordingDisplayInfo = null;
		}
		this.recordingDisplayInfo = recordingDisplayInfo;

		const syncTimestamp = Date.now();
		this.syncTimestamp = syncTimestamp;

		try {
			await cursorCapturePolling.startCursorCapture(
				this,
				electronSafeNativeBinding,
				cursorFilePath,
				{
					videoRelative: !!recordingDisplayInfo,
					displayInfo: recordingDisplayInfo,
					recordingType: this.options.windowId
						? "window"
						: this.options.captureArea
							? "area"
							: "display",
					captureArea: this.options.captureArea || null,
					windowId: this.options.windowId || null,
					startTimestamp: syncTimestamp,
				},
			);
		} catch (cursorError) {
			console.warn(
				"⚠️ Cursor tracking failed to start:",
				cursorError.message,
			);
		}

		const startPayloadTs = this.syncTimestamp || this.recordingStartTime;
		const fileTimestampPayload = this.sessionTimestamp;

		setTimeout(() => {
			this.emit("recordingStarted", {
				outputPath: this.outputPath,
				timestamp: startPayloadTs,
				options: this.options,
				electronSafe: true,
				cursorOutputPath: cursorFilePath,
				sessionTimestamp: fileTimestampPayload,
				syncTimestamp: startPayloadTs,
				fileTimestamp: fileTimestampPayload,
			});
		}, 100);

		this.emit("started", this.outputPath);
		console.log("✅ Electron-safe recording started successfully");
		return this.outputPath;
	}

	/**
	 * Stop recording with Electron-safe implementation
	 */
	async stopRecording() {
		if (!this.isRecording) {
			throw new Error("No recording in progress");
		}

		try {
			console.log("🛑 Stopping Electron-safe recording...");

			if (this.cursorCaptureInterval) {
				try {
					await cursorCapturePolling.stopCursorCapture(this);
				} catch (cursorErr) {
					console.warn(
						"⚠️ Cursor capture stop:",
						cursorErr.message,
					);
				}
			}

			const stopTimeout = setTimeout(() => {
				this.isRecording = false;
				if (this.recordingTimer) {
					clearInterval(this.recordingTimer);
					this.recordingTimer = null;
				}
			}, 10000);

			const success = electronSafeNativeBinding.stopRecording();
			clearTimeout(stopTimeout);

			this.isRecording = false;
			if (this.recordingTimer) {
				clearInterval(this.recordingTimer);
				this.recordingTimer = null;
			}

			const result = {
				code: success ? 0 : 1,
				outputPath: this.outputPath,
				electronSafe: true,
			};

			this.emit("stopped", result);

			if (success) {
				setTimeout(() => {
					if (fs.existsSync(this.outputPath)) {
						this.emit("completed", this.outputPath);
						console.log("✅ Recording completed successfully");
					} else {
						console.warn("⚠️ Recording completed but file not found");
					}
				}, 1000);
			}

			return result;
		} catch (error) {
			console.error("❌ Exception during recording stop:", error);
			this.isRecording = false;
			if (this.recordingTimer) {
				clearInterval(this.recordingTimer);
				this.recordingTimer = null;
			}
			throw error;
		}
	}

	/**
	 * Get recording status with Electron-safe implementation
	 */
	getStatus() {
		try {
			const nativeStatus = electronSafeNativeBinding.getRecordingStatus();

			return {
				isRecording: this.isRecording && nativeStatus.isRecording,
				outputPath: this.outputPath,
				options: this.options,
				recordingTime: this.recordingStartTime
					? Math.floor((Date.now() - this.recordingStartTime) / 1000)
					: 0,
				electronSafe: true,
				nativeStatus: nativeStatus,
			};
		} catch (error) {
			console.error("❌ Exception getting status:", error);
			return {
				isRecording: this.isRecording,
				outputPath: this.outputPath,
				options: this.options,
				recordingTime: this.recordingStartTime
					? Math.floor((Date.now() - this.recordingStartTime) / 1000)
					: 0,
				electronSafe: true,
				error: error.message,
			};
		}
	}

	/**
	 * Get available displays with Electron-safe implementation
	 */
	async getDisplays() {
		try {
			const displays = electronSafeNativeBinding.getDisplays();
			console.log(`📺 Found ${displays.length} displays`);
			return displays;
		} catch (error) {
			console.error("❌ Exception getting displays:", error);
			return [];
		}
	}

	/**
	 * Get available windows with Electron-safe implementation
	 */
	async getWindows() {
		try {
			const windows = electronSafeNativeBinding.getWindows();
			console.log(`🪟 Found ${windows.length} windows`);
			return windows;
		} catch (error) {
			console.error("❌ Exception getting windows:", error);
			return [];
		}
	}

	/**
	 * Check permissions with Electron-safe implementation
	 */
	async checkPermissions() {
		try {
			const hasPermission = electronSafeNativeBinding.checkPermissions();

			return {
				screenRecording: hasPermission,
				accessibility: hasPermission,
				microphone: hasPermission,
				electronSafe: true,
			};
		} catch (error) {
			console.error("❌ Exception checking permissions:", error);
			return {
				screenRecording: false,
				accessibility: false,
				microphone: false,
				electronSafe: true,
				error: error.message,
			};
		}
	}

	/**
	 * Get cursor position with Electron-safe implementation
	 */
	getCursorPosition() {
		try {
			return electronSafeNativeBinding.getCursorPosition();
		} catch (error) {
			console.error("❌ Exception getting cursor position:", error);
			throw new Error("Failed to get cursor position: " + error.message);
		}
	}

	/**
	 * Get window thumbnail with Electron-safe implementation
	 */
	async getWindowThumbnail(windowId, options = {}) {
		try {
			const { maxWidth = 300, maxHeight = 200 } = options;
			const base64Image = electronSafeNativeBinding.getWindowThumbnail(
				windowId,
				maxWidth,
				maxHeight
			);

			if (base64Image) {
				return `data:image/png;base64,${base64Image}`;
			} else {
				throw new Error("Failed to capture window thumbnail");
			}
		} catch (error) {
			console.error("❌ Exception getting window thumbnail:", error);
			throw error;
		}
	}

	/**
	 * Get display thumbnail with Electron-safe implementation
	 */
	async getDisplayThumbnail(displayId, options = {}) {
		try {
			const { maxWidth = 300, maxHeight = 200 } = options;
			const base64Image = electronSafeNativeBinding.getDisplayThumbnail(
				displayId,
				maxWidth,
				maxHeight
			);

			if (base64Image) {
				return `data:image/png;base64,${base64Image}`;
			} else {
				throw new Error("Failed to capture display thumbnail");
			}
		} catch (error) {
			console.error("❌ Exception getting display thumbnail:", error);
			throw error;
		}
	}

	/**
	 * Get audio devices with Electron-safe implementation
	 */
	async getAudioDevices() {
		try {
			const devices = electronSafeNativeBinding.getAudioDevices();
			console.log(`🔊 Found ${devices.length} audio devices`);
			return devices;
		} catch (error) {
			console.error("❌ Exception getting audio devices:", error);
			return [];
		}
	}

	async startCursorCapture(intervalOrFilepath, options = {}) {
		if (!loadElectronSafeModule()) {
			throw new Error("Failed to load Electron-safe native module");
		}
		return cursorCapturePolling.startCursorCapture(
			this,
			electronSafeNativeBinding,
			intervalOrFilepath,
			options,
		);
	}

	async stopCursorCapture() {
		loadElectronSafeModule();
		if (!electronSafeNativeBinding) {
			return false;
		}
		return cursorCapturePolling.stopCursorCapture(this);
	}

	/**
	 * Get module information
	 */
	getModuleInfo() {
		return {
			version: require("./package.json").version,
			platform: process.platform,
			arch: process.arch,
			nodeVersion: process.version,
			nativeModule: "mac_recorder_electron.node",
			electronSafe: true,
			buildTime: new Date().toISOString(),
		};
	}
}

module.exports = ElectronSafeMacRecorder;

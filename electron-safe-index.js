const { EventEmitter } = require("events");
const path = require("path");
const fs = require("fs");

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

		// Update options
		this.setOptions(options);

		// Ensure output directory exists
		const outputDir = path.dirname(outputPath);
		if (!fs.existsSync(outputDir)) {
			fs.mkdirSync(outputDir, { recursive: true });
		}

		this.outputPath = outputPath;

		return new Promise((resolve, reject) => {
			try {
				console.log("🎬 Starting Electron-safe recording...");
				console.log("📁 Output path:", outputPath);
				console.log("⚙️ Options:", this.options);

				// Call native function with timeout protection
				const startTimeout = setTimeout(() => {
					this.isRecording = false;
					reject(new Error("Recording start timeout - Electron protection"));
				}, 10000); // 10 second timeout

				const success = electronSafeNativeBinding.startRecording(
					outputPath,
					this.options
				);
				clearTimeout(startTimeout);

				if (success) {
					this.isRecording = true;
					this.recordingStartTime = Date.now();

					// Start progress timer
					this.recordingTimer = setInterval(() => {
						const elapsed = Math.floor(
							(Date.now() - this.recordingStartTime) / 1000
						);
						this.emit("timeUpdate", elapsed);
					}, 1000);

					// Emit started event
					setTimeout(() => {
						this.emit("recordingStarted", {
							outputPath: this.outputPath,
							timestamp: this.recordingStartTime,
							options: this.options,
							electronSafe: true,
						});
					}, 100);

					this.emit("started", this.outputPath);
					console.log("✅ Electron-safe recording started successfully");
					resolve(this.outputPath);
				} else {
					console.error("❌ Failed to start Electron-safe recording");
					reject(new Error("Failed to start recording - check permissions"));
				}
			} catch (error) {
				console.error("❌ Exception during recording start:", error);
				this.isRecording = false;
				if (this.recordingTimer) {
					clearInterval(this.recordingTimer);
					this.recordingTimer = null;
				}
				reject(error);
			}
		});
	}

	/**
	 * Stop recording with Electron-safe implementation
	 */
	async stopRecording() {
		if (!this.isRecording) {
			throw new Error("No recording in progress");
		}

		return new Promise((resolve, reject) => {
			try {
				console.log("🛑 Stopping Electron-safe recording...");

				// Call native function with timeout protection
				const stopTimeout = setTimeout(() => {
					this.isRecording = false;
					if (this.recordingTimer) {
						clearInterval(this.recordingTimer);
						this.recordingTimer = null;
					}
					reject(new Error("Recording stop timeout - forced cleanup"));
				}, 10000); // 10 second timeout

				const success = electronSafeNativeBinding.stopRecording();
				clearTimeout(stopTimeout);

				// Always cleanup
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
					// Check if file exists
					setTimeout(() => {
						if (fs.existsSync(this.outputPath)) {
							this.emit("completed", this.outputPath);
							console.log("✅ Recording completed successfully");
						} else {
							console.warn("⚠️ Recording completed but file not found");
						}
					}, 1000);
				}

				resolve(result);
			} catch (error) {
				console.error("❌ Exception during recording stop:", error);

				// Force cleanup
				this.isRecording = false;
				if (this.recordingTimer) {
					clearInterval(this.recordingTimer);
					this.recordingTimer = null;
				}

				reject(error);
			}
		});
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

const { EventEmitter } = require("events");
const path = require("path");
const fs = require("fs");

// Native modülü yükle
let nativeBinding;
try {
	nativeBinding = require("./build/Release/mac_recorder.node");
} catch (error) {
	try {
		nativeBinding = require("./build/Debug/mac_recorder.node");
	} catch (debugError) {
		throw new Error(
			'Native module not found. Please run "npm run build" to compile the native module.\n' +
				"Original error: " +
				error.message
		);
	}
}

class MacRecorder extends EventEmitter {
	constructor() {
		super();
		this.isRecording = false;
		this.outputPath = null;
		this.recordingTimer = null;
		this.recordingStartTime = null;
		this.options = {
			includeMicrophone: false, // Default olarak mikrofon kapalı
			includeSystemAudio: true, // Default olarak sistem sesi açık
			quality: "medium",
			frameRate: 30,
			captureArea: null, // { x, y, width, height }
			captureCursor: false, // Default olarak cursor gizli
			showClicks: false,
			displayId: null, // Hangi ekranı kaydedeceği (null = ana ekran)
			windowId: null, // Hangi pencereyi kaydedeceği (null = tam ekran)
		};
	}

	/**
	 * macOS ses cihazlarını listeler
	 */
	async getAudioDevices() {
		return new Promise((resolve, reject) => {
			try {
				const devices = nativeBinding.getAudioDevices();
				const formattedDevices = devices.map((device) => ({
					name: typeof device === "string" ? device : device.name || device,
					id: typeof device === "object" ? device.id : device,
					type: typeof device === "object" ? device.type : "Audio Device",
				}));
				resolve(formattedDevices);
			} catch (error) {
				reject(error);
			}
		});
	}

	/**
	 * macOS ekranlarını listeler
	 */
	async getDisplays() {
		return new Promise((resolve, reject) => {
			try {
				const displays = nativeBinding.getDisplays();
				const formattedDisplays = displays.map((display, index) => ({
					id: index,
					name:
						typeof display === "string"
							? display
							: display.name || `Display ${index + 1}`,
					resolution:
						typeof display === "object"
							? `${display.width}x${display.height}`
							: "Unknown",
					width: typeof display === "object" ? display.width : null,
					height: typeof display === "object" ? display.height : null,
					x: typeof display === "object" ? display.x : 0,
					y: typeof display === "object" ? display.y : 0,
					isPrimary:
						typeof display === "object" ? display.isPrimary : index === 0,
				}));
				resolve(formattedDisplays);
			} catch (error) {
				reject(error);
			}
		});
	}

	/**
	 * macOS açık pencerelerini listeler
	 */
	async getWindows() {
		return new Promise((resolve, reject) => {
			try {
				const windows = nativeBinding.getWindows();
				resolve(windows);
			} catch (error) {
				reject(error);
			}
		});
	}

	/**
	 * Kayıt seçeneklerini ayarlar
	 */
	setOptions(options) {
		this.options = { ...this.options, ...options };
	}

	/**
	 * Ekran kaydını başlatır (macOS native AVFoundation kullanarak)
	 */
	async startRecording(outputPath, options = {}) {
		if (this.isRecording) {
			throw new Error("Recording is already in progress");
		}

		if (!outputPath) {
			throw new Error("Output path is required");
		}

		// Seçenekleri güncelle
		this.setOptions(options);

		// WindowId varsa captureArea'yı otomatik ayarla
		if (this.options.windowId && !this.options.captureArea) {
			try {
				const windows = await this.getWindows();
				const displays = await this.getDisplays();
				const targetWindow = windows.find(
					(w) => w.id === this.options.windowId
				);

				if (targetWindow) {
					// Pencere hangi display'de olduğunu bul
					let targetDisplayId = null;
					let adjustedX = targetWindow.x;
					let adjustedY = targetWindow.y;

					// Pencere hangi display'de?
					for (let i = 0; i < displays.length; i++) {
						const display = displays[i];
						const displayWidth = parseInt(display.resolution.split("x")[0]);
						const displayHeight = parseInt(display.resolution.split("x")[1]);

						// Pencere bu display sınırları içinde mi?
						if (
							targetWindow.x >= display.x &&
							targetWindow.x < display.x + displayWidth &&
							targetWindow.y >= display.y &&
							targetWindow.y < display.y + displayHeight
						) {
							targetDisplayId = i;
							// Koordinatları display'e göre normalize et
							adjustedX = targetWindow.x - display.x;
							adjustedY = targetWindow.y - display.y;
							break;
						}
					}

					// Eğer display bulunamadıysa ana display kullan
					if (targetDisplayId === null) {
						const mainDisplay = displays.find((d) => d.x === 0 && d.y === 0);
						if (mainDisplay) {
							targetDisplayId = displays.indexOf(mainDisplay);
							adjustedX = Math.max(
								0,
								Math.min(
									targetWindow.x,
									parseInt(mainDisplay.resolution.split("x")[0]) -
										targetWindow.width
								)
							);
							adjustedY = Math.max(
								0,
								Math.min(
									targetWindow.y,
									parseInt(mainDisplay.resolution.split("x")[1]) -
										targetWindow.height
								)
							);
						}
					}

					// DisplayId'yi ayarla
					if (targetDisplayId !== null) {
						this.options.displayId = targetDisplayId;
					}

					this.options.captureArea = {
						x: Math.max(0, adjustedX),
						y: Math.max(0, adjustedY),
						width: targetWindow.width,
						height: targetWindow.height,
					};

					console.log(
						`Window ${targetWindow.appName}: display=${targetDisplayId}, coords=${targetWindow.x},${targetWindow.y} -> ${adjustedX},${adjustedY}`
					);
				}
			} catch (error) {
				console.warn(
					"Pencere bilgisi alınamadı, tam ekran kaydedilecek:",
					error.message
				);
			}
		}

		// Çıkış dizinini oluştur
		const outputDir = path.dirname(outputPath);
		if (!fs.existsSync(outputDir)) {
			fs.mkdirSync(outputDir, { recursive: true });
		}

		this.outputPath = outputPath;

		return new Promise((resolve, reject) => {
			try {
				// Native kayıt başlat
				const recordingOptions = {
					includeMicrophone: this.options.includeMicrophone || false,
					includeSystemAudio: this.options.includeSystemAudio !== false, // Default true
					captureCursor: this.options.captureCursor || false,
					displayId: this.options.displayId || null, // null = ana ekran
					windowId: this.options.windowId || null, // null = tam ekran
				};

				// Manuel captureArea varsa onu kullan
				if (this.options.captureArea) {
					recordingOptions.captureArea = {
						x: this.options.captureArea.x,
						y: this.options.captureArea.y,
						width: this.options.captureArea.width,
						height: this.options.captureArea.height,
					};
				}

				const success = nativeBinding.startRecording(
					outputPath,
					recordingOptions
				);

				if (success) {
					this.isRecording = true;
					this.recordingStartTime = Date.now();

					// Timer başlat (progress tracking için)
					this.recordingTimer = setInterval(() => {
						const elapsed = Math.floor(
							(Date.now() - this.recordingStartTime) / 1000
						);
						this.emit("timeUpdate", elapsed);
					}, 1000);

					this.emit("started", this.outputPath);
					resolve(this.outputPath);
				} else {
					reject(
						new Error(
							"Failed to start recording. Check permissions and try again."
						)
					);
				}
			} catch (error) {
				reject(error);
			}
		});
	}

	/**
	 * Ekran kaydını durdurur
	 */
	async stopRecording() {
		if (!this.isRecording) {
			throw new Error("No recording in progress");
		}

		return new Promise((resolve, reject) => {
			try {
				const success = nativeBinding.stopRecording();

				// Timer durdur
				if (this.recordingTimer) {
					clearInterval(this.recordingTimer);
					this.recordingTimer = null;
				}

				this.isRecording = false;

				const result = {
					code: success ? 0 : 1,
					outputPath: this.outputPath,
				};

				this.emit("stopped", result);

				if (success) {
					// Dosyanın oluşturulmasını bekle
					setTimeout(() => {
						if (fs.existsSync(this.outputPath)) {
							this.emit("completed", this.outputPath);
						}
					}, 1000);
				}

				resolve(result);
			} catch (error) {
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
	 * Kayıt durumunu döndürür
	 */
	getStatus() {
		const nativeStatus = nativeBinding.getRecordingStatus();
		return {
			isRecording: this.isRecording && nativeStatus,
			outputPath: this.outputPath,
			options: this.options,
			recordingTime: this.recordingStartTime
				? Math.floor((Date.now() - this.recordingStartTime) / 1000)
				: 0,
		};
	}

	/**
	 * macOS'ta kayıt izinlerini kontrol eder
	 */
	async checkPermissions() {
		return new Promise((resolve) => {
			try {
				const hasPermission = nativeBinding.checkPermissions();
				resolve({
					screenRecording: hasPermission,
					accessibility: hasPermission,
					microphone: hasPermission, // Native modül ses izinlerini de kontrol ediyor
				});
			} catch (error) {
				resolve({
					screenRecording: false,
					accessibility: false,
					microphone: false,
					error: error.message,
				});
			}
		});
	}

	/**
	 * Pencere önizleme görüntüsü alır (Base64 PNG)
	 */
	async getWindowThumbnail(windowId, options = {}) {
		if (!windowId) {
			throw new Error("Window ID is required");
		}

		const { maxWidth = 300, maxHeight = 200 } = options;

		return new Promise((resolve, reject) => {
			try {
				const base64Image = nativeBinding.getWindowThumbnail(
					windowId,
					maxWidth,
					maxHeight
				);

				if (base64Image) {
					resolve(`data:image/png;base64,${base64Image}`);
				} else {
					reject(new Error("Failed to capture window thumbnail"));
				}
			} catch (error) {
				reject(error);
			}
		});
	}

	/**
	 * Ekran önizleme görüntüsü alır (Base64 PNG)
	 */
	async getDisplayThumbnail(displayId, options = {}) {
		if (displayId === null || displayId === undefined) {
			throw new Error("Display ID is required");
		}

		const { maxWidth = 300, maxHeight = 200 } = options;

		return new Promise((resolve, reject) => {
			try {
				const base64Image = nativeBinding.getDisplayThumbnail(
					displayId,
					maxWidth,
					maxHeight
				);

				if (base64Image) {
					resolve(`data:image/png;base64,${base64Image}`);
				} else {
					reject(new Error("Failed to capture display thumbnail"));
				}
			} catch (error) {
				reject(error);
			}
		});
	}

	/**
	 * Native modül bilgilerini döndürür
	 */
	getModuleInfo() {
		return {
			version: require("./package.json").version,
			platform: process.platform,
			arch: process.arch,
			nodeVersion: process.version,
			nativeModule: "mac_recorder.node",
		};
	}
}

module.exports = MacRecorder;

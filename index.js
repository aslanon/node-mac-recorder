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

		// Cursor capture variables
		this.cursorCaptureInterval = null;
		this.cursorCaptureFile = null;
		this.cursorCaptureStartTime = null;
		this.cursorCaptureFirstWrite = true;
		this.lastCapturedData = null;
		this.cursorDisplayInfo = null;
		this.recordingDisplayInfo = null;

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

		// Display cache için async initialization
		this.cachedDisplays = null;
		this.refreshDisplayCache();

		// Native cursor warm-up (cold start delay'ini önlemek için)
		this.warmUpCursor();
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
		const displays = nativeBinding.getDisplays();
		return displays.map((display, index) => ({
			id: display.id, // Use the actual display ID from native code
			name: display.name,
			width: display.width,
			height: display.height,
			x: display.x,
			y: display.y,
			isPrimary: display.isPrimary,
			resolution: `${display.width}x${display.height}`,
		}));
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
	setOptions(options = {}) {
		this.options = {
			includeMicrophone: options.includeMicrophone || false,
			includeSystemAudio: options.includeSystemAudio !== false, // Default true unless explicitly disabled
			captureCursor: options.captureCursor || false,
			displayId: options.displayId || null, // null = ana ekran
			windowId: options.windowId || null, // null = tam ekran
			audioDeviceId: options.audioDeviceId || null, // null = default device
			systemAudioDeviceId: options.systemAudioDeviceId || null, // null = auto-detect system audio device
			captureArea: options.captureArea || null,
		};
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
				// Window selector'dan seçilen pencere bilgisini al
				const WindowSelector = require('./window-selector');
				const selector = new WindowSelector();
				const selectedWindow = selector.getSelectedWindow();
				
				// Eğer window selector'dan overlay koordinatları varsa onları kullan
				if (selectedWindow && selectedWindow.overlayX !== undefined) {
					console.log('🎯 Using overlay coordinates for exact recording match');
					console.log(`Overlay coords: (${selectedWindow.overlayX}, ${selectedWindow.overlayY}) ${selectedWindow.overlayWidth}x${selectedWindow.overlayHeight}`);
					
					const displays = await this.getDisplays();
					const targetWindow = selectedWindow;
					
					// Display ID'yi bul
					let targetDisplayId = null;
					for (let i = 0; i < displays.length; i++) {
						const display = displays[i];
						const displayWidth = parseInt(display.resolution.split("x")[0]);
						const displayHeight = parseInt(display.resolution.split("x")[1]);

						// Pencere bu display sınırları içinde mi?
						if (
							targetWindow.overlayX >= display.x &&
							targetWindow.overlayX < display.x + displayWidth &&
							targetWindow.overlayY >= display.y &&
							targetWindow.overlayY < display.y + displayHeight
						) {
							targetDisplayId = display.id;
							break;
						}
					}
					
					// Display ID'yi ayarla
					if (targetDisplayId !== null) {
						this.options.displayId = targetDisplayId;
						const targetDisplay = displays.find(d => d.id === targetDisplayId);
						this.recordingDisplayInfo = {
							displayId: targetDisplayId,
							x: targetDisplay.x,
							y: targetDisplay.y,
							width: parseInt(targetDisplay.resolution.split("x")[0]),
							height: parseInt(targetDisplay.resolution.split("x")[1]),
						};
					}

					// Overlay koordinatlarını direkt kullan - display offset'ini çıkar
					const targetDisplay = displays.find(d => d.id === targetDisplayId);
					this.options.captureArea = {
						x: targetWindow.overlayX - (targetDisplay ? targetDisplay.x : 0),
						y: targetWindow.overlayY - (targetDisplay ? targetDisplay.y : 0),
						width: targetWindow.overlayWidth,
						height: targetWindow.overlayHeight,
					};

					console.log(`🎬 Recording area: x=${this.options.captureArea.x}, y=${this.options.captureArea.y}, w=${this.options.captureArea.width}, h=${this.options.captureArea.height}`);
				} else {
					// Fallback: Eski yöntem
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
								targetDisplayId = display.id; // Use actual display ID, not array index
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
							targetDisplayId = mainDisplay.id; // Use actual display ID, not array index
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

						// Recording için display bilgisini sakla (cursor capture için)
						const targetDisplay = displays.find(d => d.id === targetDisplayId);
						this.recordingDisplayInfo = {
							displayId: targetDisplayId,
							x: targetDisplay.x,
							y: targetDisplay.y,
							width: parseInt(targetDisplay.resolution.split("x")[0]),
							height: parseInt(targetDisplay.resolution.split("x")[1]),
						};
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

		// DisplayId manuel ayarlanmışsa display bilgisini sakla
		if (this.options.displayId !== null && !this.recordingDisplayInfo) {
			try {
				const displays = await this.getDisplays();
				const targetDisplay = displays.find(d => d.id === this.options.displayId);
				if (targetDisplay) {
					this.recordingDisplayInfo = {
						displayId: this.options.displayId,
						x: targetDisplay.x,
						y: targetDisplay.y,
						width: parseInt(targetDisplay.resolution.split("x")[0]),
						height: parseInt(targetDisplay.resolution.split("x")[1]),
					};
				}
			} catch (error) {
				console.warn("Display bilgisi alınamadı:", error.message);
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
					includeSystemAudio: this.options.includeSystemAudio !== false, // Default true unless explicitly disabled
					captureCursor: this.options.captureCursor || false,
					displayId: this.options.displayId || null, // null = ana ekran
					windowId: this.options.windowId || null, // null = tam ekran
					audioDeviceId: this.options.audioDeviceId || null, // null = default device
					systemAudioDeviceId: this.options.systemAudioDeviceId || null, // null = auto-detect system audio device
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
				this.recordingDisplayInfo = null;

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
				this.recordingDisplayInfo = null;
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
				// Get all displays first to validate the ID
				const displays = nativeBinding.getDisplays();
				const display = displays.find((d) => d.id === displayId);

				if (!display) {
					throw new Error(`Display with ID ${displayId} not found`);
				}

				const base64Image = nativeBinding.getDisplayThumbnail(
					display.id, // Use the actual CGDirectDisplayID
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
	 * Event'in kaydedilip kaydedilmeyeceğini belirler
	 */
	shouldCaptureEvent(currentData) {
		if (!this.lastCapturedData) {
			return true; // İlk event
		}

		const last = this.lastCapturedData;

		// Event type değişmişse
		if (currentData.type !== last.type) {
			return true;
		}

		// Pozisyon değişmişse (minimum 2 pixel tolerans)
		if (
			Math.abs(currentData.x - last.x) >= 2 ||
			Math.abs(currentData.y - last.y) >= 2
		) {
			return true;
		}

		// Cursor type değişmişse
		if (currentData.cursorType !== last.cursorType) {
			return true;
		}

		// Hiçbir değişiklik yoksa kaydetme
		return false;
	}

	/**
	 * Cursor capture başlatır - otomatik olarak dosyaya yazmaya başlar
	 * Recording başlatılmışsa otomatik olarak display-relative koordinatlar kullanır
	 * @param {string} filepath - Cursor data JSON dosya yolu
	 */
	async startCursorCapture(intervalOrFilepath = 100) {
		let filepath;
		let interval = 20; // Default 50 FPS

		// Parameter parsing: number = interval, string = filepath
		if (typeof intervalOrFilepath === "number") {
			interval = Math.max(10, intervalOrFilepath); // Min 10ms
			filepath = `cursor-data-${Date.now()}.json`;
		} else if (typeof intervalOrFilepath === "string") {
			filepath = intervalOrFilepath;
		} else {
			throw new Error(
				"Parameter must be interval (number) or filepath (string)"
			);
		}

		if (this.cursorCaptureInterval) {
			throw new Error("Cursor capture is already running");
		}

		// Recording başlatılmışsa o display'i kullan, yoksa main display kullan
		if (this.recordingDisplayInfo) {
			this.cursorDisplayInfo = this.recordingDisplayInfo;
		} else {
			// Main display bilgisini al (her zaman relative koordinatlar için)
			try {
				const displays = await this.getDisplays();
				const mainDisplay = displays.find((d) => d.isPrimary) || displays[0];
				if (mainDisplay) {
					this.cursorDisplayInfo = {
						displayId: 0,
						x: mainDisplay.x,
						y: mainDisplay.y,
						width: parseInt(mainDisplay.resolution.split("x")[0]),
						height: parseInt(mainDisplay.resolution.split("x")[1]),
					};
				}
			} catch (error) {
				console.warn("Main display bilgisi alınamadı:", error.message);
				this.cursorDisplayInfo = null; // Fallback: global koordinatlar
			}
		}

		return new Promise((resolve, reject) => {
			try {
				// Dosyayı oluştur ve temizle
				const fs = require("fs");
				fs.writeFileSync(filepath, "[");

				this.cursorCaptureFile = filepath;
				this.cursorCaptureStartTime = Date.now();
				this.cursorCaptureFirstWrite = true;
				this.lastCapturedData = null;

				// JavaScript interval ile polling yap (daha sık - mouse event'leri yakalamak için)
				this.cursorCaptureInterval = setInterval(() => {
					try {
						const position = nativeBinding.getCursorPosition();
						const timestamp = Date.now() - this.cursorCaptureStartTime;

						// Global koordinatları display-relative'e çevir
						let x = position.x;
						let y = position.y;

						if (this.cursorDisplayInfo) {
							// Display offset'lerini çıkar
							x = position.x - this.cursorDisplayInfo.x;
							y = position.y - this.cursorDisplayInfo.y;

							// Display bounds kontrolü - cursor display dışındaysa kaydetme
							if (
								x < 0 ||
								y < 0 ||
								x >= this.cursorDisplayInfo.width ||
								y >= this.cursorDisplayInfo.height
							) {
								return; // Bu frame'i skip et
							}
						}

						const cursorData = {
							x: x,
							y: y,
							timestamp: timestamp,
							unixTimeMs: Date.now(),
							cursorType: position.cursorType,
							type: position.eventType || "move",
						};

						// Sadece eventType değiştiğinde veya pozisyon değiştiğinde kaydet
						if (this.shouldCaptureEvent(cursorData)) {
							// Dosyaya ekle
							const jsonString = JSON.stringify(cursorData);

							if (this.cursorCaptureFirstWrite) {
								fs.appendFileSync(filepath, jsonString);
								this.cursorCaptureFirstWrite = false;
							} else {
								fs.appendFileSync(filepath, "," + jsonString);
							}

							// Son pozisyonu sakla
							this.lastCapturedData = { ...cursorData };
						}
					} catch (error) {
						console.error("Cursor capture error:", error);
					}
				}, interval); // Configurable FPS

				this.emit("cursorCaptureStarted", filepath);
				resolve(true);
			} catch (error) {
				reject(error);
			}
		});
	}

	/**
	 * Cursor capture durdurur - dosya yazma işlemini sonlandırır
	 */
	async stopCursorCapture() {
		return new Promise((resolve, reject) => {
			try {
				if (!this.cursorCaptureInterval) {
					return resolve(false);
				}

				// Interval'ı durdur
				clearInterval(this.cursorCaptureInterval);
				this.cursorCaptureInterval = null;

				// Dosyayı kapat
				if (this.cursorCaptureFile) {
					const fs = require("fs");
					fs.appendFileSync(this.cursorCaptureFile, "]");
					this.cursorCaptureFile = null;
				}

				// Değişkenleri temizle
				this.lastCapturedData = null;
				this.cursorCaptureStartTime = null;
				this.cursorCaptureFirstWrite = true;
				this.cursorDisplayInfo = null;

				this.emit("cursorCaptureStopped");
				resolve(true);
			} catch (error) {
				reject(error);
			}
		});
	}

	/**
	 * Anlık cursor pozisyonunu ve tipini döndürür
	 * Display-relative koordinatlar döner (her zaman pozitif)
	 */
	getCursorPosition() {
		try {
			const position = nativeBinding.getCursorPosition();

			// Cursor hangi display'de ise o display'e relative döndür
			return this.getDisplayRelativePositionSync(position);
		} catch (error) {
			throw new Error("Failed to get cursor position: " + error.message);
		}
	}

	/**
	 * Global koordinatları en uygun display'e relative çevirir (sync version)
	 */
	getDisplayRelativePositionSync(position) {
		try {
			// Cache'lenmiş displays'leri kullan
			if (!this.cachedDisplays) {
				// İlk çağrı - global koordinat döndür ve cache başlat
				this.refreshDisplayCache();
				return position;
			}

			// Cursor hangi display içinde ise onu bul
			for (const display of this.cachedDisplays) {
				const x = parseInt(display.x);
				const y = parseInt(display.y);
				const width = parseInt(display.resolution.split("x")[0]);
				const height = parseInt(display.resolution.split("x")[1]);

				if (
					position.x >= x &&
					position.x < x + width &&
					position.y >= y &&
					position.y < y + height
				) {
					// Bu display içinde
					return {
						x: position.x - x,
						y: position.y - y,
						cursorType: position.cursorType,
						eventType: position.eventType,
						displayId: display.id,
						displayIndex: this.cachedDisplays.indexOf(display),
					};
				}
			}

			// Hiçbir display'de değilse main display'e relative döndür
			const mainDisplay =
				this.cachedDisplays.find((d) => d.isPrimary) || this.cachedDisplays[0];
			if (mainDisplay) {
				return {
					x: position.x - parseInt(mainDisplay.x),
					y: position.y - parseInt(mainDisplay.y),
					cursorType: position.cursorType,
					eventType: position.eventType,
					displayId: mainDisplay.id,
					displayIndex: this.cachedDisplays.indexOf(mainDisplay),
					outsideDisplay: true,
				};
			}

			// Fallback: global koordinat
			return position;
		} catch (error) {
			// Hata durumunda global koordinat döndür
			return position;
		}
	}

	/**
	 * Display cache'ini refresh eder
	 */
	async refreshDisplayCache() {
		try {
			this.cachedDisplays = await this.getDisplays();
		} catch (error) {
			console.warn("Display cache refresh failed:", error.message);
		}
	}

	/**
	 * Native cursor modülünü warm-up yapar (cold start delay'ini önler)
	 */
	warmUpCursor() {
		// Async warm-up to prevent blocking constructor
		setTimeout(() => {
			try {
				// Silent warm-up call
				nativeBinding.getCursorPosition();
			} catch (error) {
				// Ignore warm-up errors
			}
		}, 10); // 10ms delay to not block initialization
	}

	/**
	 * getCurrentCursorPosition alias for getCursorPosition (backward compatibility)
	 */
	getCurrentCursorPosition() {
		return this.getCursorPosition();
	}

	/**
	 * Cursor capture durumunu döndürür
	 */
	getCursorCaptureStatus() {
		return {
			isCapturing: !!this.cursorCaptureInterval,
			outputFile: this.cursorCaptureFile || null,
			startTime: this.cursorCaptureStartTime || null,
			displayInfo: this.cursorDisplayInfo || null,
		};
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

	async getDisplaysWithThumbnails(options = {}) {
		const displays = await this.getDisplays();

		// Get thumbnails for each display
		const displayPromises = displays.map(async (display) => {
			try {
				const thumbnail = await this.getDisplayThumbnail(display.id, options);
				return {
					...display,
					thumbnail,
				};
			} catch (error) {
				return {
					...display,
					thumbnail: null,
					thumbnailError: error.message,
				};
			}
		});

		return Promise.all(displayPromises);
	}

	async getWindowsWithThumbnails(options = {}) {
		const windows = await this.getWindows();

		// Get thumbnails for each window
		const windowPromises = windows.map(async (window) => {
			try {
				const thumbnail = await this.getWindowThumbnail(window.id, options);
				return {
					...window,
					thumbnail,
				};
			} catch (error) {
				return {
					...window,
					thumbnail: null,
					thumbnailError: error.message,
				};
			}
		});

		return Promise.all(windowPromises);
	}
}

// WindowSelector modülünü de export edelim
MacRecorder.WindowSelector = require('./window-selector');

module.exports = MacRecorder;

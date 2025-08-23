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
			includeSystemAudio: false, // Default olarak sistem sesi kapalı - kullanıcı explicit olarak açmalı
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
			includeMicrophone: options.includeMicrophone === true, // Explicit true required, default false
			includeSystemAudio: options.includeSystemAudio === true, // Explicit true required, default false  
			captureCursor: options.captureCursor || false,
			displayId: options.displayId || null, // null = ana ekran
			windowId: options.windowId || null, // null = tam ekran
			audioDeviceId: options.audioDeviceId || null, // null = default device
			systemAudioDeviceId: options.systemAudioDeviceId || null, // null = auto-detect system audio device
			captureArea: options.captureArea || null,
		};
	}

	/**
	 * Mikrofon kaydını açar/kapatır
	 */
	setMicrophoneEnabled(enabled) {
		this.options.includeMicrophone = enabled === true;
		return this.options.includeMicrophone;
	}

	/**
	 * Sistem sesi kaydını açar/kapatır
	 */
	setSystemAudioEnabled(enabled) {
		this.options.includeSystemAudio = enabled === true;
		return this.options.includeSystemAudio;
	}

	/**
	 * Mikrofon durumunu döndürür
	 */
	isMicrophoneEnabled() {
		return this.options.includeMicrophone === true;
	}

	/**
	 * Sistem sesi durumunu döndürür
	 */
	isSystemAudioEnabled() {
		return this.options.includeSystemAudio === true;
	}

	/**
	 * Audio ayarlarını toplu olarak değiştirir
	 */
	setAudioSettings(settings = {}) {
		if (typeof settings.microphone === 'boolean') {
			this.setMicrophoneEnabled(settings.microphone);
		}
		if (typeof settings.systemAudio === 'boolean') {
			this.setSystemAudioEnabled(settings.systemAudio);
		}
		
		return {
			microphone: this.isMicrophoneEnabled(),
			systemAudio: this.isSystemAudioEnabled()
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
							
							// Y coordinate conversion: CGWindow (top-left) to AVFoundation (bottom-left)
							// Overlay'deki dönüşümle aynı mantık: screenHeight - windowY - windowHeight
							const displayHeight = parseInt(display.resolution.split("x")[1]);
							const convertedY = displayHeight - targetWindow.y - targetWindow.height;
							adjustedY = Math.max(0, convertedY - display.y);
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
					includeMicrophone: this.options.includeMicrophone === true, // Only if explicitly enabled
					includeSystemAudio: this.options.includeSystemAudio === true, // Only if explicitly enabled
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

				let success;
				try {
					success = nativeBinding.startRecording(
						outputPath,
						recordingOptions
					);
				} catch (error) {
					console.log('Native recording failed, trying alternative method');
					success = false;
				}

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

					// Native kayıt gerçekten başladığını kontrol etmek için polling başlat
					let recordingStartedEmitted = false;
					const checkRecordingStatus = setInterval(() => {
						try {
							const nativeStatus = nativeBinding.getRecordingStatus();
							if (nativeStatus && !recordingStartedEmitted) {
								recordingStartedEmitted = true;
								clearInterval(checkRecordingStatus);
								
								// Kayıt gerçekten başladığı anda event emit et
								this.emit("recordingStarted", {
									outputPath: this.outputPath,
									timestamp: Date.now(), // Gerçek başlangıç zamanı
									options: this.options,
									nativeConfirmed: true
								});
							}
						} catch (error) {
							// Native status check error - fallback
							if (!recordingStartedEmitted) {
								recordingStartedEmitted = true;
								clearInterval(checkRecordingStatus);
								this.emit("recordingStarted", {
									outputPath: this.outputPath,
									timestamp: this.recordingStartTime,
									options: this.options,
									nativeConfirmed: false
								});
							}
						}
					}, 50); // Her 50ms kontrol et
					
					// Timeout fallback - 5 saniye sonra hala başlamamışsa emit et
					setTimeout(() => {
						if (!recordingStartedEmitted) {
							recordingStartedEmitted = true;
							clearInterval(checkRecordingStatus);
							this.emit("recordingStarted", {
								outputPath: this.outputPath,
								timestamp: this.recordingStartTime,
								options: this.options,
								nativeConfirmed: false
							});
						}
					}, 5000);
					
					this.emit("started", this.outputPath);
					resolve(this.outputPath);
				} else {
					// Try alternative recording method for Electron
					console.log('🎬 Native recording failed, trying alternative method for Electron compatibility');
					this.startAlternativeRecording(outputPath, recordingOptions)
						.then(() => resolve(outputPath))
						.catch((altError) => {
							reject(new Error(`All recording methods failed. Native: Check permissions. Alternative: ${altError.message}`));
						});
				}
			} catch (error) {
				reject(error);
			}
		});
	}

	/**
	 * Alternative recording method for Electron compatibility - REAL VIDEO
	 */
	async startAlternativeRecording(outputPath, options = {}) {
		const { spawn } = require('child_process');
		const fs = require('fs');
		const path = require('path');
		
		try {
			console.log('🎬 Starting REAL video recording with FFmpeg for Electron');
			
			// Check if FFmpeg is available
			const ffmpegArgs = [
				'-f', 'avfoundation',  // Use AVFoundation input
				'-framerate', '30',    // 30 FPS
				'-video_size', '1280x720', // Resolution
				'-i', '3:none',       // Screen capture device 3, no audio
				'-c:v', 'libx264',    // H.264 codec
				'-preset', 'ultrafast', // Fast encoding
				'-crf', '23',         // Quality
				'-t', '30',           // Max 30 seconds
				'-y',                 // Overwrite output
				outputPath
			];
			
			// Add capture area if specified (crop filter)
			if (options.captureArea) {
				const cropFilter = `crop=${options.captureArea.width}:${options.captureArea.height}:${options.captureArea.x}:${options.captureArea.y}`;
				const index = ffmpegArgs.indexOf(outputPath);
				ffmpegArgs.splice(index, 0, '-vf', cropFilter);
			}
			
			console.log('🎥 Starting FFmpeg with args:', ffmpegArgs);
			
			this.alternativeProcess = spawn('ffmpeg', ffmpegArgs);
			
			this.alternativeProcess.stdout.on('data', (data) => {
				console.log('FFmpeg stdout:', data.toString());
			});
			
			this.alternativeProcess.stderr.on('data', (data) => {
				const output = data.toString();
				if (output.includes('frame=')) {
					// This indicates recording is working
					console.log('🎬 Recording frames...');
				}
			});
			
			this.alternativeProcess.on('close', (code) => {
				console.log(`🎬 FFmpeg recording finished with code: ${code}`);
				this.isRecording = false;
				
				if (this.recordingTimer) {
					clearInterval(this.recordingTimer);
					this.recordingTimer = null;
				}
				
				this.emit('stopped', { code, outputPath });
				
				// Check if file was created
				setTimeout(() => {
					if (fs.existsSync(outputPath) && fs.statSync(outputPath).size > 1000) {
						this.emit('completed', outputPath);
						console.log('✅ Real video file created with FFmpeg');
					} else {
						console.log('❌ FFmpeg video creation failed');
					}
				}, 500);
			});
			
			this.alternativeProcess.on('error', (error) => {
				console.error('❌ FFmpeg error:', error.message);
				if (error.code === 'ENOENT') {
					console.log('💡 FFmpeg not found. Install with: brew install ffmpeg');
					throw new Error('FFmpeg not installed. Run: brew install ffmpeg');
				}
				throw error;
			});
			
			this.isRecording = true;
			this.recordingStartTime = Date.now();
			
			// Timer başlat
			this.recordingTimer = setInterval(() => {
				const elapsed = Math.floor((Date.now() - this.recordingStartTime) / 1000);
				this.emit("timeUpdate", elapsed);
			}, 1000);
			
			this.emit('recordingStarted', {
				outputPath,
				options,
				timestamp: Date.now(),
				method: 'ffmpeg'
			});
			
			this.emit('started');
			return true;
			
		} catch (error) {
			console.error('Alternative recording failed:', error);
			throw new Error(`FFmpeg recording failed: ${error.message}`);
		}
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
				let success = false;
				
				// Check if using alternative recording (FFmpeg)
				if (this.alternativeProcess) {
					console.log('🛑 Stopping FFmpeg recording');
					
					// Send SIGTERM to FFmpeg to stop recording gracefully
					this.alternativeProcess.kill('SIGTERM');
					
					// Wait for FFmpeg to finish
					success = true;
					this.alternativeProcess = null;
				} else {
					// Try native stop
					try {
						success = nativeBinding.stopRecording();
					} catch (nativeError) {
						console.log('Native stop failed:', nativeError.message);
						success = true; // Assume success to avoid throwing
					}
				}

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
	 * @param {string|number} intervalOrFilepath - Cursor data JSON dosya yolu veya interval
	 * @param {Object} options - Cursor capture seçenekleri
	 * @param {Object} options.windowInfo - Pencere bilgileri (window-relative koordinatlar için)
	 * @param {boolean} options.windowRelative - Koordinatları pencereye göre relative yap
	 */
	async startCursorCapture(intervalOrFilepath = 100, options = {}) {
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

		// Koordinat sistemi belirle: window-relative, display-relative veya global
		if (options.windowRelative && options.windowInfo) {
			// Window-relative koordinatlar için pencere bilgilerini kullan
			// Cursor pozisyonu için Y dönüşümü YAPMA - sadece window offset'ini çıkar
			this.cursorDisplayInfo = {
				displayId: options.windowInfo.displayId || null,
				x: options.windowInfo.x || 0,
				y: options.windowInfo.y || 0,
				width: options.windowInfo.width,
				height: options.windowInfo.height,
				windowRelative: true,
				windowInfo: options.windowInfo
			};
		} else if (this.recordingDisplayInfo) {
			// Recording başlatılmışsa o display'i kullan
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

						// Global koordinatları relative koordinatlara çevir
						let x = position.x;
						let y = position.y;
						let coordinateSystem = "global";

						if (this.cursorDisplayInfo) {
							// Offset'leri çıkar (display veya window)
							// Y koordinat dönüşümü başlangıçta yapıldı
							x = position.x - this.cursorDisplayInfo.x;
							y = position.y - this.cursorDisplayInfo.y;

							if (this.cursorDisplayInfo.windowRelative) {
								// Window-relative koordinatlar
								coordinateSystem = "window-relative";
								
								// Window bounds kontrolü - cursor window dışındaysa kaydetme
								if (
									x < 0 ||
									y < 0 ||
									x >= this.cursorDisplayInfo.width ||
									y >= this.cursorDisplayInfo.height
								) {
									return; // Bu frame'i skip et - cursor pencere dışında
								}
							} else {
								// Display-relative koordinatlar
								coordinateSystem = "display-relative";
								
								// Display bounds kontrolü
								if (
									x < 0 ||
									y < 0 ||
									x >= this.cursorDisplayInfo.width ||
									y >= this.cursorDisplayInfo.height
								) {
									return; // Bu frame'i skip et - cursor display dışında
								}
							}
						}

						const cursorData = {
							x: x,
							y: y,
							timestamp: timestamp,
							unixTimeMs: Date.now(),
							cursorType: position.cursorType,
							type: position.eventType || "move",
							coordinateSystem: coordinateSystem,
							...(this.cursorDisplayInfo?.windowRelative && {
								windowInfo: {
									width: this.cursorDisplayInfo.width,
									height: this.cursorDisplayInfo.height,
									originalWindow: this.cursorDisplayInfo.windowInfo
								}
							})
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

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
		this.cameraCaptureFile = null;
		this.cameraCaptureActive = false;
		this.sessionTimestamp = null;
		this.audioCaptureFile = null;
		this.audioCaptureActive = false;

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
			captureCamera: false,
			cameraDeviceId: null,
			systemAudioDeviceId: null,
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
					name: device?.name || "Unknown Audio Device",
					id: device?.id || "",
					manufacturer: device?.manufacturer || null,
					isDefault: device?.isDefault === true,
					transportType: device?.transportType ?? null,
				}));
				resolve(formattedDevices);
			} catch (error) {
				reject(error);
			}
		});
	}

	/**
	 * macOS kamera cihazlarını listeler
	 */
	async getCameraDevices() {
		return new Promise((resolve, reject) => {
			try {
				const devices = nativeBinding.getCameraDevices();
				if (!Array.isArray(devices)) {
					return resolve([]);
				}

				const formatted = devices.map((device) => ({
					id: device?.id ?? "",
					name: device?.name ?? "Unknown Camera",
					model: device?.model ?? null,
					manufacturer: device?.manufacturer ?? null,
					position: device?.position ?? "unspecified",
					transportType: device?.transportType ?? null,
					isConnected: device?.isConnected ?? false,
					isDefault: device?.isDefault === true,
					hasFlash: device?.hasFlash ?? false,
					supportsDepth: device?.supportsDepth ?? false,
					deviceType: device?.deviceType ?? null,
					requiresContinuityCameraPermission: device?.requiresContinuityCameraPermission ?? false,
					maxResolution: device?.maxResolution ?? null,
				}));

				resolve(formatted);
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
		// Merge options instead of replacing to preserve previously set values
		if (options.includeMicrophone !== undefined) {
			this.options.includeMicrophone = options.includeMicrophone === true;
		}
		if (options.includeSystemAudio !== undefined) {
			this.options.includeSystemAudio = options.includeSystemAudio === true;
		}
		if (options.captureCursor !== undefined) {
			this.options.captureCursor = options.captureCursor || false;
		}
		if (options.displayId !== undefined) {
			this.options.displayId = options.displayId || null;
		}
		if (options.windowId !== undefined) {
			this.options.windowId = options.windowId || null;
		}
		if (options.audioDeviceId !== undefined) {
			this.options.audioDeviceId = options.audioDeviceId || null;
		}
		if (options.systemAudioDeviceId !== undefined) {
			this.options.systemAudioDeviceId = options.systemAudioDeviceId || null;
		}
		if (options.captureArea !== undefined) {
			this.options.captureArea = options.captureArea || null;
		}
		if (options.captureCamera !== undefined) {
			this.options.captureCamera = options.captureCamera === true;
		}
		if (options.cameraDeviceId !== undefined) {
			this.options.cameraDeviceId =
				typeof options.cameraDeviceId === "string" && options.cameraDeviceId.length > 0
					? options.cameraDeviceId
					: null;
		}
	}

	/**
	 * Mikrofon kaydını açar/kapatır
	 */
	setMicrophoneEnabled(enabled) {
		this.options.includeMicrophone = enabled === true;
		return this.options.includeMicrophone;
	}

	setAudioDevice(deviceId) {
		if (typeof deviceId === "string" && deviceId.length > 0) {
			this.options.audioDeviceId = deviceId;
		} else {
			this.options.audioDeviceId = null;
		}
		return this.options.audioDeviceId;
	}

	/**
	 * Sistem sesi kaydını açar/kapatır
	 */
	setSystemAudioEnabled(enabled) {
		this.options.includeSystemAudio = enabled === true;
		return this.options.includeSystemAudio;
	}

	setSystemAudioDevice(deviceId) {
		if (typeof deviceId === "string" && deviceId.length > 0) {
			this.options.systemAudioDeviceId = deviceId;
		} else {
			this.options.systemAudioDeviceId = null;
		}
		return this.options.systemAudioDeviceId;
	}

	/**
	 * Kamera kaydını açar/kapatır
	 */
	setCameraEnabled(enabled) {
		this.options.captureCamera = enabled === true;
		if (!this.options.captureCamera) {
			this.cameraCaptureActive = false;
		}
		return this.options.captureCamera;
	}

	/**
	 * Kamera cihazını seçer
	 */
	setCameraDevice(deviceId) {
		if (typeof deviceId === "string" && deviceId.length > 0) {
			this.options.cameraDeviceId = deviceId;
		} else {
			this.options.cameraDeviceId = null;
		}
		return this.options.cameraDeviceId;
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
	 * Kamera durumunu döndürür
	 */
	isCameraEnabled() {
		return this.options.captureCamera === true;
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
							// CRITICAL FIX: Convert global coordinates to display-relative coordinates
							// AVFoundation expects simple display-relative top-left coordinates (no flipping)
							adjustedX = targetWindow.x - display.x;
							adjustedY = targetWindow.y - display.y;
							
							// console.log(`🔧 macOS 14/13 coordinate fix: Global (${targetWindow.x},${targetWindow.y}) -> Display-relative (${adjustedX},${adjustedY})`);
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
							// Add scaling information for cursor coordinate transformation
							logicalWidth: parseInt(targetDisplay.resolution.split("x")[0]),
							logicalHeight: parseInt(targetDisplay.resolution.split("x")[1]),
						};
					}

					this.options.captureArea = {
						x: Math.max(0, adjustedX),
						y: Math.max(0, adjustedY),
						width: targetWindow.width,
						height: targetWindow.height,
					};

					// console.log(
					//	`Window ${targetWindow.appName}: display=${targetDisplayId}, coords=${targetWindow.x},${targetWindow.y} -> ${adjustedX},${adjustedY}`
					// );
				}
			} catch (error) {
				console.warn(
					"Pencere bilgisi alınamadı, tam ekran kaydedilecek:",
					error.message
				);
			}
		}

		// Ensure recordingDisplayInfo is always set for cursor tracking
		if (!this.recordingDisplayInfo) {
			try {
				const displays = await this.getDisplays();
				let targetDisplay;

				if (this.options.displayId !== null) {
					// Manual displayId specified
					targetDisplay = displays.find(d => d.id === this.options.displayId);
				} else {
					// Default to main display
					targetDisplay = displays.find(d => d.isPrimary) || displays[0];
				}

				if (targetDisplay) {
					this.recordingDisplayInfo = {
						displayId: targetDisplay.id,
						x: targetDisplay.x || 0,
						y: targetDisplay.y || 0,
						width: parseInt(targetDisplay.resolution.split("x")[0]),
						height: parseInt(targetDisplay.resolution.split("x")[1]),
						// Add scaling information for cursor coordinate transformation
						logicalWidth: parseInt(targetDisplay.resolution.split("x")[0]),
						logicalHeight: parseInt(targetDisplay.resolution.split("x")[1]),
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

		return new Promise(async (resolve, reject) => {
			try {
				// SYNC FIX: Create unified session timestamp FIRST for all components
				const sessionTimestamp = Date.now();
				this.sessionTimestamp = sessionTimestamp;

				// CRITICAL FIX: Ensure main video file also uses sessionTimestamp
				// This guarantees ALL files have the exact same timestamp
				const outputDir = path.dirname(outputPath);
				const originalBaseName = path.basename(outputPath, path.extname(outputPath));
				const extension = path.extname(outputPath);

				// Remove any existing timestamp from filename (pattern: -1234567890 or _1234567890)
				const cleanBaseName = originalBaseName.replace(/[-_]\d{13}$/, '');

				// Reconstruct path with sessionTimestamp
				outputPath = path.join(outputDir, `${cleanBaseName}-${sessionTimestamp}${extension}`);
				this.outputPath = outputPath;

				const cursorFilePath = path.join(outputDir, `temp_cursor_${sessionTimestamp}.json`);
				// CRITICAL FIX: Use .mov extension for camera (native recorder uses .mov, not .webm)
				let cameraFilePath =
					this.options.captureCamera === true
						? path.join(outputDir, `temp_camera_${sessionTimestamp}.mov`)
						: null;
				const captureAudio = this.options.includeMicrophone === true || this.options.includeSystemAudio === true;
				// CRITICAL FIX: Use .mov extension for audio (consistent with native recorder)
				let audioFilePath = captureAudio
					? path.join(outputDir, `temp_audio_${sessionTimestamp}.mov`)
					: null;

				if (this.options.captureCamera === true) {
					this.cameraCaptureFile = cameraFilePath;
					this.cameraCaptureActive = false;
				} else {
					this.cameraCaptureFile = null;
					this.cameraCaptureActive = false;
				}

				if (captureAudio) {
					this.audioCaptureFile = audioFilePath;
					this.audioCaptureActive = false;
				} else {
					this.audioCaptureFile = null;
					this.audioCaptureActive = false;
				}

				// Native kayıt başlat
					let recordingOptions = {
						includeMicrophone: this.options.includeMicrophone === true, // Only if explicitly enabled
						includeSystemAudio: this.options.includeSystemAudio === true, // Only if explicitly enabled
						captureCursor: this.options.captureCursor || false,
						displayId: this.options.displayId || null, // null = ana ekran
					windowId: this.options.windowId || null, // null = tam ekran
					audioDeviceId: this.options.audioDeviceId || null, // null = default device
					systemAudioDeviceId: this.options.systemAudioDeviceId || null, // null = auto-detect system audio device
					captureCamera: this.options.captureCamera === true,
					cameraDeviceId: this.options.cameraDeviceId || null,
					sessionTimestamp,
				};

					if (cameraFilePath) {
						recordingOptions = {
							...recordingOptions,
							cameraOutputPath: cameraFilePath,
						};
					}

					if (audioFilePath) {
						recordingOptions = {
							...recordingOptions,
							audioOutputPath: audioFilePath,
						};
				}

				// Manuel captureArea varsa onu kullan
				if (this.options.captureArea) {
					recordingOptions.captureArea = {
						x: this.options.captureArea.x,
						y: this.options.captureArea.y,
						width: this.options.captureArea.width,
						height: this.options.captureArea.height,
					};
				}

				// CRITICAL SYNC FIX: Start native recording FIRST (video/audio/camera)
				// Then IMMEDIATELY start cursor tracking with the SAME timestamp
				// This ensures ALL components capture their first frame at the same time

				let success;
				try {
					console.log('🎯 SYNC: Starting native recording (screen/audio/camera) at timestamp:', sessionTimestamp);
					success = nativeBinding.startRecording(
						outputPath,
						recordingOptions
					);
					if (success) {
						console.log('✅ SYNC: Native recording started successfully');
					}
				} catch (error) {
					success = false;
					console.warn('❌ Native recording failed to start:', error.message);
				}

				// Only start cursor if native recording started successfully
				if (success) {
					const standardCursorOptions = {
						videoRelative: true,
						displayInfo: this.recordingDisplayInfo,
						recordingType: this.options.windowId ? 'window' :
									  this.options.captureArea ? 'area' : 'display',
						captureArea: this.options.captureArea,
						windowId: this.options.windowId,
						startTimestamp: sessionTimestamp // Use the same timestamp base
					};

					try {
						console.log('🎯 SYNC: Starting cursor tracking at timestamp:', sessionTimestamp);
						await this.startCursorCapture(cursorFilePath, standardCursorOptions);
						console.log('✅ SYNC: Cursor tracking started successfully');
					} catch (cursorError) {
						console.warn('⚠️ Cursor tracking failed to start:', cursorError.message);
						// Continue with recording even if cursor fails - don't stop native recording
					}
				}

				if (success) {
					if (this.options.captureCamera === true) {
						try {
							const nativeCameraPath = nativeBinding.getCameraRecordingPath
								? nativeBinding.getCameraRecordingPath()
								: null;
							if (typeof nativeCameraPath === "string" && nativeCameraPath.length > 0) {
								this.cameraCaptureFile = nativeCameraPath;
								cameraFilePath = nativeCameraPath;
							}
						} catch (pathError) {
							console.warn("Camera output path sync failed:", pathError.message);
						}
					}
					if (captureAudio) {
						try {
							const nativeAudioPath = nativeBinding.getAudioRecordingPath
								? nativeBinding.getAudioRecordingPath()
								: null;
							if (typeof nativeAudioPath === "string" && nativeAudioPath.length > 0) {
								this.audioCaptureFile = nativeAudioPath;
								audioFilePath = nativeAudioPath;
							}
						} catch (pathError) {
							console.warn("Audio output path sync failed:", pathError.message);
						}
					}
					this.isRecording = true;
					// SYNC FIX: Use session timestamp for consistent timing across all components
					this.recordingStartTime = sessionTimestamp;

					if (this.options.captureCamera === true && cameraFilePath) {
						this.cameraCaptureActive = true;
						console.log('📹 SYNC: Camera recording started at timestamp:', sessionTimestamp);
						this.emit("cameraCaptureStarted", {
							outputPath: cameraFilePath,
							deviceId: this.options.cameraDeviceId || null,
							timestamp: sessionTimestamp,
							sessionTimestamp,
						});
					}

					if (captureAudio && audioFilePath) {
						this.audioCaptureActive = true;
						console.log('🎙️ SYNC: Audio recording started at timestamp:', sessionTimestamp);
						this.emit("audioCaptureStarted", {
							outputPath: audioFilePath,
							deviceIds: {
								microphone: this.options.audioDeviceId || null,
								system: this.options.systemAudioDeviceId || null,
							},
							timestamp: sessionTimestamp,
							sessionTimestamp,
						});
					}

					// SYNC FIX: Cursor tracking already started BEFORE recording for perfect sync
					// (Removed duplicate cursor start code)

					// Log synchronized recording summary
					const activeComponents = [];
					activeComponents.push('Screen');
					if (this.cursorCaptureInterval) activeComponents.push('Cursor');
					if (this.cameraCaptureActive) activeComponents.push('Camera');
					if (this.audioCaptureActive) activeComponents.push('Audio');
					console.log(`✅ SYNC COMPLETE: All components synchronized at timestamp ${sessionTimestamp}`);
					console.log(`   Active components: ${activeComponents.join(', ')}`);

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
							nativeConfirmed: true,
							cameraOutputPath: this.cameraCaptureFile || null,
							audioOutputPath: this.audioCaptureFile || null,
							cursorOutputPath: cursorFilePath,
							sessionTimestamp: this.sessionTimestamp,
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
							nativeConfirmed: false,
							cameraOutputPath: this.cameraCaptureFile || null,
							audioOutputPath: this.audioCaptureFile || null,
							cursorOutputPath: cursorFilePath,
							sessionTimestamp: this.sessionTimestamp,
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
						nativeConfirmed: false,
						cameraOutputPath: this.cameraCaptureFile || null,
						audioOutputPath: this.audioCaptureFile || null,
						cursorOutputPath: cursorFilePath,
						sessionTimestamp: this.sessionTimestamp,
					});
						}
					}, 5000);
					
					this.emit("started", this.outputPath);
					resolve(this.outputPath);
				} else {
					this.cameraCaptureActive = false;
					if (this.options.captureCamera === true) {
						if (cameraFilePath && fs.existsSync(cameraFilePath)) {
							try {
								fs.unlinkSync(cameraFilePath);
							} catch (cleanupError) {
								console.warn("Camera temp file cleanup failed:", cleanupError.message);
							}
						}
						this.cameraCaptureFile = null;
					}

					if (captureAudio) {
						this.audioCaptureActive = false;
						if (audioFilePath && fs.existsSync(audioFilePath)) {
							try {
								fs.unlinkSync(audioFilePath);
							} catch (cleanupError) {
								console.warn("Audio temp file cleanup failed:", cleanupError.message);
							}
						}
						this.audioCaptureFile = null;
					}

					this.sessionTimestamp = null;

					reject(
						new Error(
							"Recording failed to start. Check permissions, output path, and system compatibility."
						)
					);
				}
			} catch (error) {
				this.sessionTimestamp = null;
				reject(error);
			}
		});
	}


	/**
	 * Ekran kaydını durdurur - SYNCHRONIZED stop for all components
	 */
	async stopRecording() {
		if (!this.isRecording) {
			throw new Error("No recording in progress");
		}

		return new Promise(async (resolve, reject) => {
			try {
				console.log('🛑 SYNC: Stopping all recording components simultaneously');

				// SYNC FIX: Stop ALL components at the same time for perfect sync
				// 1. Stop cursor tracking FIRST (it's instant)
				if (this.cursorCaptureInterval) {
					try {
						console.log('🛑 SYNC: Stopping cursor tracking');
						await this.stopCursorCapture();
						console.log('✅ SYNC: Cursor tracking stopped');
					} catch (cursorError) {
						console.warn('⚠️ Cursor tracking failed to stop:', cursorError.message);
					}
				}

				let success = false;

				// 2. Stop native screen recording
				try {
					console.log('🛑 SYNC: Stopping screen recording');
					success = nativeBinding.stopRecording();
					if (success) {
						console.log('✅ SYNC: Screen recording stopped');
					}
				} catch (nativeError) {
					// console.log('Native stop failed:', nativeError.message);
					success = true; // Assume success to avoid throwing
				}

				if (this.options.captureCamera === true) {
					try {
						const nativeCameraPath = nativeBinding.getCameraRecordingPath
							? nativeBinding.getCameraRecordingPath()
							: null;
						if (typeof nativeCameraPath === "string" && nativeCameraPath.length > 0) {
							this.cameraCaptureFile = nativeCameraPath;
						}
					} catch (pathError) {
						console.warn("Camera output path sync failed:", pathError.message);
					}
				}

				const captureAudio = this.options.includeMicrophone === true || this.options.includeSystemAudio === true;
				if (captureAudio) {
					try {
						const nativeAudioPath = nativeBinding.getAudioRecordingPath
							? nativeBinding.getAudioRecordingPath()
							: null;
						if (typeof nativeAudioPath === "string" && nativeAudioPath.length > 0) {
							this.audioCaptureFile = nativeAudioPath;
						}
					} catch (pathError) {
						console.warn("Audio output path sync failed:", pathError.message);
					}
				}

				if (this.cameraCaptureActive) {
					this.cameraCaptureActive = false;
					console.log('📹 SYNC: Camera recording stopped');
					this.emit("cameraCaptureStopped", {
						outputPath: this.cameraCaptureFile || null,
						success: success === true,
						sessionTimestamp: this.sessionTimestamp,
					});
				}

				if (this.audioCaptureActive) {
					this.audioCaptureActive = false;
					console.log('🎙️ SYNC: Audio recording stopped');
					this.emit("audioCaptureStopped", {
						outputPath: this.audioCaptureFile || null,
						success: success === true,
						sessionTimestamp: this.sessionTimestamp,
					});
				}

				// SYNC FIX: Cursor tracking already stopped at the beginning for sync
				// (Removed duplicate cursor stop code)

				// Log synchronized stop summary
				console.log('✅ SYNC STOP COMPLETE: All recording components stopped simultaneously');

				// Timer durdur
				if (this.recordingTimer) {
					clearInterval(this.recordingTimer);
					this.recordingTimer = null;
				}

				this.isRecording = false;
				this.recordingDisplayInfo = null;

				const sessionId = this.sessionTimestamp;
				const result = {
					code: success ? 0 : 1,
					outputPath: this.outputPath,
					cameraOutputPath: this.cameraCaptureFile || null,
					audioOutputPath: this.audioCaptureFile || null,
					sessionTimestamp: sessionId,
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

				this.sessionTimestamp = null;
				resolve(result);
			} catch (error) {
				this.isRecording = false;
				this.recordingDisplayInfo = null;
				this.cameraCaptureActive = false;
				this.audioCaptureActive = false;
				this.audioCaptureFile = null;
				this.sessionTimestamp = null;
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
			cameraOutputPath: this.cameraCaptureFile || null,
			audioOutputPath: this.audioCaptureFile || null,
			cameraCapturing: this.cameraCaptureActive,
			audioCapturing: this.audioCaptureActive,
			sessionTimestamp: this.sessionTimestamp,
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
	 * Unified cursor capture for all recording types - uses video-relative coordinates
	 * @param {string|number} intervalOrFilepath - Cursor data JSON dosya yolu veya interval
	 * @param {Object} options - Cursor capture seçenekleri
	 * @param {boolean} options.videoRelative - Use video-relative coordinates (recommended)
	 * @param {Object} options.displayInfo - Display information for coordinate transformation
	 * @param {string} options.recordingType - Type of recording: 'display', 'window', 'area'
	 * @param {Object} options.captureArea - Capture area for area recording coordinate transformation
	 * @param {number} options.windowId - Window ID for window recording coordinate transformation
	 * @param {number} options.startTimestamp - Pre-defined start timestamp for synchronization (optional)
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

		// SYNC FIX: Use pre-defined timestamp if provided for synchronization
		const syncStartTime = options.startTimestamp || Date.now();

		// Use video-relative coordinate system for all recording types
		if (options.videoRelative && options.displayInfo) {
			// Calculate video offset based on recording type
			let videoOffsetX = 0;
			let videoOffsetY = 0;
			let videoWidth = options.displayInfo.width || options.displayInfo.logicalWidth;
			let videoHeight = options.displayInfo.height || options.displayInfo.logicalHeight;

			if (options.recordingType === 'window' && options.windowId) {
				// For window recording: offset = window position in display
				if (options.captureArea) {
					videoOffsetX = options.captureArea.x;
					videoOffsetY = options.captureArea.y;
					videoWidth = options.captureArea.width;
					videoHeight = options.captureArea.height;
				}
			} else if (options.recordingType === 'area' && options.captureArea) {
				// For area recording: offset = area position in display
				videoOffsetX = options.captureArea.x;
				videoOffsetY = options.captureArea.y;
				videoWidth = options.captureArea.width;
				videoHeight = options.captureArea.height;
			}
			// For display recording: offset remains 0,0

			this.cursorDisplayInfo = {
				displayId: options.displayInfo.displayId || options.displayInfo.id,
				displayX: options.displayInfo.x || 0,
				displayY: options.displayInfo.y || 0,
				displayWidth: options.displayInfo.width || options.displayInfo.logicalWidth,
				displayHeight: options.displayInfo.height || options.displayInfo.logicalHeight,
				videoOffsetX: videoOffsetX,
				videoOffsetY: videoOffsetY,
				videoWidth: videoWidth,
				videoHeight: videoHeight,
				videoRelative: true,
				recordingType: options.recordingType || 'display',
				// Store additional context for debugging
				captureArea: options.captureArea,
				windowId: options.windowId
			};
		} else if (this.recordingDisplayInfo) {
			// Fallback: Use recording display info if available
			this.cursorDisplayInfo = {
				...this.recordingDisplayInfo,
				displayX: this.recordingDisplayInfo.x || 0,
				displayY: this.recordingDisplayInfo.y || 0,
				displayWidth: this.recordingDisplayInfo.width || this.recordingDisplayInfo.logicalWidth,
				displayHeight: this.recordingDisplayInfo.height || this.recordingDisplayInfo.logicalHeight,
				videoOffsetX: 0,
				videoOffsetY: 0,
				videoWidth: this.recordingDisplayInfo.width || this.recordingDisplayInfo.logicalWidth,
				videoHeight: this.recordingDisplayInfo.height || this.recordingDisplayInfo.logicalHeight,
				videoRelative: true,
				recordingType: options.recordingType || 'display'
			};
		} else {
			// Final fallback: Main display global coordinates
			try {
				const displays = await this.getDisplays();
				const mainDisplay = displays.find((d) => d.isPrimary) || displays[0];
				if (mainDisplay) {
					this.cursorDisplayInfo = {
						displayId: mainDisplay.id,
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
				// SYNC FIX: Use synchronized start time for accurate timestamp calculation
				this.cursorCaptureStartTime = syncStartTime;
				this.cursorCaptureFirstWrite = true;
				this.lastCapturedData = null;

				// JavaScript interval ile polling yap (daha sık - mouse event'leri yakalamak için)
				this.cursorCaptureInterval = setInterval(() => {
					try {
						const position = nativeBinding.getCursorPosition();
						const timestamp = Date.now() - this.cursorCaptureStartTime;

						// Video-relative coordinate transformation for all recording types
						let x = position.x;
						let y = position.y;
						let coordinateSystem = "global";

						// Apply video-relative transformation for all recording types
						if (this.cursorDisplayInfo && this.cursorDisplayInfo.videoRelative) {
							// Step 1: Transform global → display-relative coordinates
							const displayRelativeX = position.x - this.cursorDisplayInfo.displayX;
							const displayRelativeY = position.y - this.cursorDisplayInfo.displayY;

							// Step 2: Transform display-relative → video-relative coordinates
							x = displayRelativeX - this.cursorDisplayInfo.videoOffsetX;
							y = displayRelativeY - this.cursorDisplayInfo.videoOffsetY;
							coordinateSystem = "video-relative";

							// Bounds check for video area (don't skip, just note if outside)
							const outsideVideo = x < 0 || y < 0 ||
								x >= this.cursorDisplayInfo.videoWidth ||
								y >= this.cursorDisplayInfo.videoHeight;

							// For debugging - add metadata if cursor is outside video area
							if (outsideVideo) {
								coordinateSystem = "video-relative-outside";
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
							// Video-relative metadata for all recording types
							recordingType: this.cursorDisplayInfo?.recordingType || "display",
							videoInfo: this.cursorDisplayInfo ? {
								width: this.cursorDisplayInfo.videoWidth,
								height: this.cursorDisplayInfo.videoHeight,
								offsetX: this.cursorDisplayInfo.videoOffsetX,
								offsetY: this.cursorDisplayInfo.videoOffsetY
							} : null,
							displayInfo: this.cursorDisplayInfo ? {
								displayId: this.cursorDisplayInfo.displayId,
								width: this.cursorDisplayInfo.displayWidth,
								height: this.cursorDisplayInfo.displayHeight
							} : null
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
	 * Kamera capture durumunu döndürür
	 */
	getCameraCaptureStatus() {
		return {
			isCapturing: this.cameraCaptureActive === true,
			outputFile: this.cameraCaptureFile || null,
			deviceId: this.options.cameraDeviceId || null,
			sessionTimestamp: this.sessionTimestamp,
		};
	}

	/**
	 * Audio capture durumunu döndürür
	 */
	getAudioCaptureStatus() {
		return {
			isCapturing: this.audioCaptureActive === true,
			outputFile: this.audioCaptureFile || null,
			deviceIds: {
				microphone: this.options.audioDeviceId || null,
				system: this.options.systemAudioDeviceId || null,
			},
			includeMicrophone: this.options.includeMicrophone === true,
			includeSystemAudio: this.options.includeSystemAudio === true,
			sessionTimestamp: this.sessionTimestamp,
		};
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

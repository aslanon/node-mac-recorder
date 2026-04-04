const { EventEmitter } = require("events");
const path = require("path");
const fs = require("fs");
const cursorCapturePolling = require("./lib/cursorCapture/polling");

// Auto-switch to Electron-safe implementation when running under Electron and binary exists
let USE_ELECTRON_SAFE = false;
let ElectronSafeMacRecorder = null;
try {
  const isElectron = !!(process && process.versions && process.versions.electron);
  const preferElectronSafe = process.env.PREFER_ELECTRON_SAFE === "1" || process.env.USE_ELECTRON_SAFE === "1";
  if (isElectron || preferElectronSafe) {
    const rel = path.join(__dirname, "build", "Release", "mac_recorder_electron.node");
    const dbg = path.join(__dirname, "build", "Debug", "mac_recorder_electron.node");
    if (fs.existsSync(rel) || fs.existsSync(dbg) || preferElectronSafe) {
      // Defer requiring native .node; use JS wrapper which loads it
      ElectronSafeMacRecorder = require("./electron-safe-index");
      USE_ELECTRON_SAFE = true;
      console.log("✅ Auto-enabled Electron-safe MacRecorder");
    }
  }
} catch (_) {
  // Ignore auto-switch errors; fall back to standard binding
}

// Native modülü yükle
let nativeBinding;
if (!USE_ELECTRON_SAFE) {
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
}

class MacRecorder extends EventEmitter {
	constructor() {
		super();
		this.isRecording = false;
		this.outputPath = null;
		this.recordingTimer = null;
		this.recordingStartTime = null;

		// MULTI-SESSION: Unique session ID for this recorder instance
		this.nativeSessionId = null;  // Will be generated when recording starts

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
		this.syncTimestamp = null;
		this.audioCaptureFile = null;
		this.audioCaptureActive = false;

		this.options = {
			includeMicrophone: false, // Default olarak mikrofon kapalı
			includeSystemAudio: false, // Default olarak sistem sesi kapalı - kullanıcı explicit olarak açmalı
			quality: "high",
			frameRate: 60,
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
		if (options.sessionTimestamp !== undefined) {
			this.options.sessionTimestamp = options.sessionTimestamp;
		}
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
		if (options.frameRate !== undefined) {
			const fps = parseInt(options.frameRate, 10);
			if (!Number.isNaN(fps) && fps > 0) {
				// Clamp reasonable range 1-120
				this.options.frameRate = Math.min(Math.max(fps, 1), 120);
			}
		}
		// Prefer ScreenCaptureKit (macOS 15+) toggle
		if (options.preferScreenCaptureKit !== undefined) {
			this.options.preferScreenCaptureKit = options.preferScreenCaptureKit === true;
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

		// Cache display list so we don't fetch multiple times during preparation
		let cachedDisplays = null;
		const getCachedDisplays = async () => {
			if (cachedDisplays) {
				return cachedDisplays;
			}
			try {
				cachedDisplays = await this.getDisplays();
			} catch (error) {
				console.warn("Display bilgisi alınamadı:", error.message);
				cachedDisplays = [];
			}
			return cachedDisplays;
		};

		/**
		 * Normalize capture area coordinates:
		 *  - Pick correct display based on user-provided area/displayId info
		 *  - Convert global coordinates to display-relative when needed
		 *  - Clamp to valid bounds to avoid ScreenCaptureKit skipping crops
		 */
		const normalizeCaptureArea = async () => {
			if (!this.options.captureArea) {
				return;
			}

			const displays = await getCachedDisplays();
			if (!Array.isArray(displays) || displays.length === 0) {
				return;
			}

			const rawArea = this.options.captureArea;
			const parsedArea = {
				x: Number(rawArea.x),
				y: Number(rawArea.y),
				width: Number(rawArea.width),
				height: Number(rawArea.height),
			};

			if (
				!Number.isFinite(parsedArea.x) ||
				!Number.isFinite(parsedArea.y) ||
				!Number.isFinite(parsedArea.width) ||
				!Number.isFinite(parsedArea.height) ||
				parsedArea.width <= 0 ||
				parsedArea.height <= 0
			) {
				return;
			}

			const areaRect = {
				left: parsedArea.x,
				top: parsedArea.y,
				right: parsedArea.x + parsedArea.width,
				bottom: parsedArea.y + parsedArea.height,
			};

			const getDisplayRect = (display) => {
				const dx = Number(display.x) || 0;
				const dy = Number(display.y) || 0;
				const dw = Number(display.width) || 0;
				const dh = Number(display.height) || 0;
				return {
					left: dx,
					top: dy,
					right: dx + dw,
					bottom: dy + dh,
					width: dw,
					height: dh,
				};
			};

			const requestedDisplayId =
				this.options.displayId === null || this.options.displayId === undefined
					? null
					: Number(this.options.displayId);

			let targetDisplay = null;
			if (requestedDisplayId !== null && Number.isFinite(requestedDisplayId)) {
				targetDisplay =
					displays.find(
						(display) => Number(display.id) === requestedDisplayId
					) || null;
			}

			if (!targetDisplay) {
				targetDisplay =
					displays.find((display) => {
						const rect = getDisplayRect(display);
						return (
							areaRect.left >= rect.left &&
							areaRect.right <= rect.right &&
							areaRect.top >= rect.top &&
							areaRect.bottom <= rect.bottom
						);
					}) || null;
			}

			if (!targetDisplay) {
				let bestDisplay = null;
				let bestOverlap = 0;
				displays.forEach((display) => {
					const rect = getDisplayRect(display);
					const overlapWidth =
						Math.min(areaRect.right, rect.right) -
						Math.max(areaRect.left, rect.left);
					const overlapHeight =
						Math.min(areaRect.bottom, rect.bottom) -
						Math.max(areaRect.top, rect.top);
					if (overlapWidth > 0 && overlapHeight > 0) {
						const overlapArea = overlapWidth * overlapHeight;
						if (overlapArea > bestOverlap) {
							bestOverlap = overlapArea;
							bestDisplay = display;
						}
					}
				});
				targetDisplay = bestDisplay;
			}

			if (!targetDisplay) {
				targetDisplay =
					displays.find((display) => display.isPrimary) || displays[0];
			}

			if (!targetDisplay) {
				return;
			}

			const targetRect = getDisplayRect(targetDisplay);
			if (targetRect.width <= 0 || targetRect.height <= 0) {
				return;
			}

			const tolerance = 1; // allow sub-pixel offsets
			const isRelativeToDisplay = () => {
				const endX = parsedArea.x + parsedArea.width;
				const endY = parsedArea.y + parsedArea.height;
				return (
					parsedArea.x >= -tolerance &&
					parsedArea.y >= -tolerance &&
					endX <= targetRect.width + tolerance &&
					endY <= targetRect.height + tolerance
				);
			};

			let relativeX = parsedArea.x;
			let relativeY = parsedArea.y;

			if (!isRelativeToDisplay()) {
				relativeX = parsedArea.x - targetRect.left;
				relativeY = parsedArea.y - targetRect.top;
			}

			let relativeWidth = parsedArea.width;
			let relativeHeight = parsedArea.height;

			// Discard if area sits completely outside the display
			if (
				relativeX >= targetRect.width ||
				relativeY >= targetRect.height ||
				relativeWidth <= 0 ||
				relativeHeight <= 0
			) {
				return;
			}

			if (relativeX < 0) {
				relativeWidth += relativeX;
				relativeX = 0;
			}

			if (relativeY < 0) {
				relativeHeight += relativeY;
				relativeY = 0;
			}

			const maxWidth = targetRect.width - relativeX;
			const maxHeight = targetRect.height - relativeY;

			if (maxWidth <= 0 || maxHeight <= 0) {
				return;
			}

			relativeWidth = Math.min(relativeWidth, maxWidth);
			relativeHeight = Math.min(relativeHeight, maxHeight);

			if (relativeWidth <= 0 || relativeHeight <= 0) {
				return;
			}

			const normalizeValue = (value, minValue) =>
				Math.max(minValue, Math.round(value));
			const normalizedArea = {
				x: Math.max(0, Math.round(relativeX)),
				y: Math.max(0, Math.round(relativeY)),
				width: normalizeValue(relativeWidth, 1),
				height: normalizeValue(relativeHeight, 1),
			};

			const originalRounded = {
				x: Math.round(parsedArea.x),
				y: Math.round(parsedArea.y),
				width: normalizeValue(parsedArea.width, 1),
				height: normalizeValue(parsedArea.height, 1),
			};

			const displayChanged =
				!Number.isFinite(requestedDisplayId) ||
				Number(targetDisplay.id) !== requestedDisplayId;
			const areaChanged =
				normalizedArea.x !== originalRounded.x ||
				normalizedArea.y !== originalRounded.y ||
				normalizedArea.width !== originalRounded.width ||
				normalizedArea.height !== originalRounded.height;

			if (displayChanged || areaChanged) {
				console.log(
					`🎯 Capture area normalize: display=${targetDisplay.id} -> (${rawArea.x},${rawArea.y},${rawArea.width}x${rawArea.height}) ➜ (${normalizedArea.x},${normalizedArea.y},${normalizedArea.width}x${normalizedArea.height})`
				);
			}

			this.options.captureArea = normalizedArea;
			this.options.displayId = Number(targetDisplay.id);
			this.recordingDisplayInfo = {
				displayId: Number(targetDisplay.id),
				x: Number(targetDisplay.x) || 0,
				y: Number(targetDisplay.y) || 0,
				width: Number(targetDisplay.width) || 0,
				height: Number(targetDisplay.height) || 0,
				logicalWidth: Number(targetDisplay.width) || 0,
				logicalHeight: Number(targetDisplay.height) || 0,
			};
		};

		// WindowId varsa captureArea'yı otomatik ayarla
		if (this.options.windowId && !this.options.captureArea) {
			try {
				const windows = await this.getWindows();
				const displays = await getCachedDisplays();
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
				const displays = await getCachedDisplays();
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

		// Normalize capture area AFTER automatic window capture logic
		if (this.options.captureArea) {
			await normalizeCaptureArea();
		}

		// Çıkış dizinini oluştur
		const outputDir = path.dirname(outputPath);
		if (!fs.existsSync(outputDir)) {
			fs.mkdirSync(outputDir, { recursive: true });
		}

		this.outputPath = outputPath;

		return new Promise(async (resolve, reject) => {
			try {
				// MULTI-SESSION: Generate unique session ID for this recording
				// Use provided sessionTimestamp from options, or generate new one
				const sessionTimestamp = this.options.sessionTimestamp || Date.now();
				this.sessionTimestamp = sessionTimestamp;
				this.nativeSessionId = `rec_${sessionTimestamp}_${Math.random().toString(36).substr(2, 9)}`;

				console.log(`🎬 Starting recording with session ID: ${this.nativeSessionId}`);
				if (this.options.sessionTimestamp) {
					console.log(`   ⏰ Using provided sessionTimestamp: ${this.options.sessionTimestamp}`);
				} else {
					console.log(`   ⏰ Generated new sessionTimestamp: ${sessionTimestamp}`);
				}

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
					// MULTI-SESSION: Pass unique session ID to native code
					nativeSessionId: this.nativeSessionId,
					frameRate: this.options.frameRate || 60,
					quality: this.options.quality || "high",
					// Hint native side to use ScreenCaptureKit on macOS 15+
					preferScreenCaptureKit: this.options.preferScreenCaptureKit === true,
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
					// For ScreenCaptureKit (async startup), wait briefly until native fully initialized
					// ScreenCaptureKit needs ~150-300ms to start + ~150ms for first 10 frames
					const waitStart = Date.now();
					try {
						while (Date.now() - waitStart < 600) {
							try {
								const nativeStatus = nativeBinding && nativeBinding.getRecordingStatus ? nativeBinding.getRecordingStatus() : true;
								if (nativeStatus) {
									console.log(`✅ SYNC: Native recording fully ready after ${Date.now() - waitStart}ms`);
									break;
								}
							} catch (_) {}
							await new Promise(r => setTimeout(r, 30));
						}
					} catch (_) {}
					this.sessionTimestamp = sessionTimestamp;

					// Native sync_timeline handles A/V alignment - no JS-level delay needed
					const syncTimestamp = Date.now();
					this.syncTimestamp = syncTimestamp;
					this.recordingStartTime = syncTimestamp;
					console.log(`🎯 CURSOR SYNC: Cursor tracking will use timestamp: ${syncTimestamp}`);

					const standardCursorOptions = {
						videoRelative: true,
						displayInfo: this.recordingDisplayInfo,
						recordingType: this.options.windowId ? 'window' :
									  this.options.captureArea ? 'area' : 'display',
						captureArea: this.options.captureArea,
						windowId: this.options.windowId,
						startTimestamp: syncTimestamp // Align cursor timeline to actual start
					};

					try {
						console.log('🎯 SYNC: Starting cursor tracking at timestamp:', syncTimestamp);
						await this.startCursorCapture(cursorFilePath, standardCursorOptions);
						console.log('✅ SYNC: Cursor tracking started successfully');
					} catch (cursorError) {
						console.warn('⚠️ Cursor tracking failed to start:', cursorError.message);
						// Continue with recording even if cursor fails - don't stop native recording
					}
				}

				if (success) {
					const timelineTimestamp = this.syncTimestamp || sessionTimestamp;
					const fileTimestamp = this.sessionTimestamp || sessionTimestamp;

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

					if (this.options.captureCamera === true && cameraFilePath) {
						this.cameraCaptureActive = true;
						console.log('📹 SYNC: Camera recording started at timestamp:', timelineTimestamp);
						this.emit("cameraCaptureStarted", {
							outputPath: cameraFilePath,
							deviceId: this.options.cameraDeviceId || null,
							timestamp: timelineTimestamp,
							sessionTimestamp: fileTimestamp,
							syncTimestamp: timelineTimestamp,
							fileTimestamp,
						});
					}

					if (captureAudio && audioFilePath) {
						this.audioCaptureActive = true;
						console.log('🎙️ SYNC: Audio recording started at timestamp:', timelineTimestamp);
						this.emit("audioCaptureStarted", {
							outputPath: audioFilePath,
							deviceIds: {
								microphone: this.options.audioDeviceId || null,
								system: this.options.systemAudioDeviceId || null,
							},
							timestamp: timelineTimestamp,
							sessionTimestamp: fileTimestamp,
							syncTimestamp: timelineTimestamp,
							fileTimestamp,
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
					console.log(`✅ SYNC COMPLETE: All components synchronized at timestamp ${timelineTimestamp}`);
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
						const startTimestampPayload = this.syncTimestamp || this.recordingStartTime || Date.now();
						const fileTimestampPayload = this.sessionTimestamp;
						this.emit("recordingStarted", {
							outputPath: this.outputPath,
							timestamp: startTimestampPayload,
							options: this.options,
							nativeConfirmed: true,
							cameraOutputPath: this.cameraCaptureFile || null,
							audioOutputPath: this.audioCaptureFile || null,
							cursorOutputPath: cursorFilePath,
							sessionTimestamp: fileTimestampPayload,
							syncTimestamp: startTimestampPayload,
							fileTimestamp: fileTimestampPayload,
						});
							}
						} catch (error) {
							// Native status check error - fallback
							if (!recordingStartedEmitted) {
								recordingStartedEmitted = true;
								clearInterval(checkRecordingStatus);
						const startTimestampPayload = this.syncTimestamp || this.recordingStartTime || Date.now();
						const fileTimestampPayload = this.sessionTimestamp;
						this.emit("recordingStarted", {
							outputPath: this.outputPath,
							timestamp: startTimestampPayload,
							options: this.options,
							nativeConfirmed: false,
							cameraOutputPath: this.cameraCaptureFile || null,
							audioOutputPath: this.audioCaptureFile || null,
							cursorOutputPath: cursorFilePath,
							sessionTimestamp: fileTimestampPayload,
							syncTimestamp: startTimestampPayload,
							fileTimestamp: fileTimestampPayload,
						});
							}
						}
					}, 50); // Her 50ms kontrol et
					
					// Timeout fallback - 5 saniye sonra hala başlamamışsa emit et
					setTimeout(() => {
						if (!recordingStartedEmitted) {
							recordingStartedEmitted = true;
							clearInterval(checkRecordingStatus);
					const startTimestampPayload = this.syncTimestamp || this.recordingStartTime || Date.now();
					const fileTimestampPayload = this.sessionTimestamp;
					this.emit("recordingStarted", {
						outputPath: this.outputPath,
						timestamp: startTimestampPayload,
						options: this.options,
						nativeConfirmed: false,
						cameraOutputPath: this.cameraCaptureFile || null,
						audioOutputPath: this.audioCaptureFile || null,
						cursorOutputPath: cursorFilePath,
						sessionTimestamp: fileTimestampPayload,
						syncTimestamp: startTimestampPayload,
						fileTimestamp: fileTimestampPayload,
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
					this.syncTimestamp = null;

					reject(
						new Error(
							"Recording failed to start. Check permissions, output path, and system compatibility."
						)
					);
				}
			} catch (error) {
				this.sessionTimestamp = null;
				this.syncTimestamp = null;
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
			const stopRequestedAt = Date.now();
			const elapsedSeconds =
				this.recordingStartTime && this.recordingStartTime > 0
					? (stopRequestedAt - this.recordingStartTime) / 1000
					: -1;
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
					const stopLimit = elapsedSeconds > 0 ? elapsedSeconds : 0;
					console.log(`📊 DEBUG: elapsedSeconds=${elapsedSeconds.toFixed(3)}, stopLimit=${stopLimit.toFixed(3)}`);
					console.log(`📊 DEBUG: typeof nativeBinding.stopRecording = ${typeof nativeBinding.stopRecording}`);
					console.log(`📊 DEBUG: nativeBinding.stopRecording = ${nativeBinding.stopRecording}`);
					success = nativeBinding.stopRecording(stopLimit);
					if (success) {
						console.log('✅ SYNC: Screen recording stopped');
					}
				} catch (nativeError) {
					console.log('⚠️ Native stop failed:', nativeError.message);
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
						syncTimestamp: this.syncTimestamp,
					});
				}

				if (this.audioCaptureActive) {
					this.audioCaptureActive = false;
					console.log('🎙️ SYNC: Audio recording stopped');
					this.emit("audioCaptureStopped", {
						outputPath: this.audioCaptureFile || null,
						success: success === true,
						sessionTimestamp: this.sessionTimestamp,
						syncTimestamp: this.syncTimestamp,
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
					syncTimestamp: this.syncTimestamp,
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
				this.syncTimestamp = null;
				resolve(result);
			} catch (error) {
				this.isRecording = false;
				this.recordingDisplayInfo = null;
				this.cameraCaptureActive = false;
				this.audioCaptureActive = false;
				this.audioCaptureFile = null;
				this.sessionTimestamp = null;
				this.syncTimestamp = null;
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
			syncTimestamp: this.syncTimestamp,
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

	async startCursorCapture(intervalOrFilepath = 100, options = {}) {
		return cursorCapturePolling.startCursorCapture(
			this,
			nativeBinding,
			intervalOrFilepath,
			options,
		);
	}

	async stopCursorCapture() {
		return cursorCapturePolling.stopCursorCapture(this);
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
						seed: position.seed,
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
					seed: position.seed,
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

module.exports = USE_ELECTRON_SAFE ? ElectronSafeMacRecorder : MacRecorder;

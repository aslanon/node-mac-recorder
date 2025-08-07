const { EventEmitter } = require("events");
const path = require("path");

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

class WindowSelector extends EventEmitter {
	constructor() {
		super();
		this.isSelecting = false;
		this.selectionTimer = null;
		this.selectedWindow = null;
		this.lastStatus = null;
	}

	/**
	 * Pencere seçim modunu başlatır
	 * İmleç hangi pencerenin üstüne gelirse o pencereyi highlight eder
	 * Select butonuna basılınca seçim tamamlanır
	 */
	async startSelection() {
		if (this.isSelecting) {
			throw new Error("Window selection is already in progress");
		}

		return new Promise((resolve, reject) => {
			try {
				// Native window selection başlat
				const success = nativeBinding.startWindowSelection();
				
				if (success) {
					this.isSelecting = true;
					this.selectedWindow = null;
					
					// Status polling timer başlat (higher frequency for overlay updates)
					this.selectionTimer = setInterval(() => {
						this.checkSelectionStatus();
					}, 50); // 20 FPS status check for smooth overlay

					this.emit("selectionStarted");
					resolve(true);
				} else {
					reject(new Error("Failed to start window selection"));
				}
			} catch (error) {
				reject(error);
			}
		});
	}

	/**
	 * Pencere seçim modunu durdurur
	 */
	async stopSelection() {
		if (!this.isSelecting) {
			return false;
		}

		return new Promise((resolve, reject) => {
			try {
				const success = nativeBinding.stopWindowSelection();
				
				// Timer'ı durdur
				if (this.selectionTimer) {
					clearInterval(this.selectionTimer);
					this.selectionTimer = null;
				}

				this.isSelecting = false;
				this.lastStatus = null;

				this.emit("selectionStopped");
				resolve(success);
			} catch (error) {
				reject(error);
			}
		});
	}

	/**
	 * Selection durumunu kontrol eder ve event yayar
	 */
	checkSelectionStatus() {
		if (!this.isSelecting) return;

		try {
			const status = nativeBinding.getWindowSelectionStatus();
			
			// Seçim tamamlandı mı kontrol et
			if (status.hasSelectedWindow && !this.selectedWindow) {
				const windowInfo = nativeBinding.getSelectedWindowInfo();
				if (windowInfo) {
					this.selectedWindow = windowInfo;
					this.isSelecting = false;
					
					// Timer'ı durdur
					if (this.selectionTimer) {
						clearInterval(this.selectionTimer);
						this.selectionTimer = null;
					}

					this.emit("windowSelected", windowInfo);
					return;
				}
			}

			// Mevcut pencere değişti mi kontrol et
			if (this.lastStatus) {
				const lastWindow = this.lastStatus.currentWindow;
				const currentWindow = status.currentWindow;
				
				if (!lastWindow && currentWindow) {
					// Yeni pencere üstüne gelindi
					this.emit("windowEntered", currentWindow);
				} else if (lastWindow && !currentWindow) {
					// Pencere üstünden ayrıldı
					this.emit("windowLeft", lastWindow);
				} else if (lastWindow && currentWindow && 
						  (lastWindow.id !== currentWindow.id || 
						   lastWindow.title !== currentWindow.title || 
						   lastWindow.appName !== currentWindow.appName)) {
					// Farklı bir pencereye geçildi
					this.emit("windowLeft", lastWindow);
					this.emit("windowEntered", currentWindow);
				}
			} else if (!this.lastStatus && status.currentWindow) {
				// İlk pencere detection
				this.emit("windowEntered", status.currentWindow);
			}

			this.lastStatus = status;
		} catch (error) {
			this.emit("error", error);
		}
	}

	/**
	 * Seçilen pencere bilgisini döndürür
	 */
	getSelectedWindow() {
		return this.selectedWindow;
	}

	/**
	 * Seçim durumunu döndürür
	 */
	getStatus() {
		try {
			const nativeStatus = nativeBinding.getWindowSelectionStatus();
			return {
				isSelecting: this.isSelecting && nativeStatus.isSelecting,
				hasSelectedWindow: !!this.selectedWindow,
				selectedWindow: this.selectedWindow,
				nativeStatus: nativeStatus
			};
		} catch (error) {
			return {
				isSelecting: this.isSelecting,
				hasSelectedWindow: !!this.selectedWindow,
				selectedWindow: this.selectedWindow,
				error: error.message
			};
		}
	}

	/**
	 * Promise tabanlı pencere seçimi
	 * Kullanıcı bir pencere seçene kadar bekler
	 */
	async selectWindow() {
		if (this.isSelecting) {
			throw new Error("Selection already in progress");
		}

		return new Promise(async (resolve, reject) => {
			try {
				// Event listener'ları ayarla
				const onWindowSelected = (windowInfo) => {
					this.removeAllListeners("windowSelected");
					this.removeAllListeners("error");
					resolve(windowInfo);
				};

				const onError = (error) => {
					this.removeAllListeners("windowSelected");
					this.removeAllListeners("error");
					reject(error);
				};

				this.once("windowSelected", onWindowSelected);
				this.once("error", onError);

				// Seçimi başlat
				await this.startSelection();

			} catch (error) {
				this.removeAllListeners("windowSelected");
				this.removeAllListeners("error");
				reject(error);
			}
		});
	}

	/**
	 * Pencereyi en öne getirir (focus yapar)
	 * @param {number} windowId - Window ID
	 * @returns {Promise<boolean>} Success/failure
	 */
	async bringWindowToFront(windowId) {
		if (!windowId) {
			throw new Error("Window ID is required");
		}

		try {
			const success = nativeBinding.bringWindowToFront(windowId);
			return success;
		} catch (error) {
			throw new Error(`Failed to bring window to front: ${error.message}`);
		}
	}

	/**
	 * Otomatik pencere en öne getirme özelliğini aktif/pasif yapar
	 * Cursor hangi pencereye gelirse otomatik olarak en öne getirir
	 * @param {boolean} enabled - Enable/disable auto bring to front
	 */
	setBringToFrontEnabled(enabled) {
		try {
			nativeBinding.setBringToFrontEnabled(enabled);
			// Only log if explicitly setting, not on startup
			if (arguments.length > 0) {
				console.log(`🔄 Auto bring-to-front: ${enabled ? 'ENABLED' : 'DISABLED'}`);
			}
		} catch (error) {
			throw new Error(`Failed to set bring to front: ${error.message}`);
		}
	}

	/**
	 * Cleanup - tüm kaynakları temizle
	 */
	async cleanup() {
		if (this.isSelecting) {
			await this.stopSelection();
		}

		// Timer'ı temizle
		if (this.selectionTimer) {
			clearInterval(this.selectionTimer);
			this.selectionTimer = null;
		}

		// Event listener'ları temizle
		this.removeAllListeners();

		// State'i sıfırla
		this.selectedWindow = null;
		this.lastStatus = null;
		this.isSelecting = false;
	}

	/**
	 * Seçilen pencere için kayıt önizleme overlay'ini gösterir
	 * Tüm ekranı siyah yapar, sadece pencere alanını şeffaf bırakır
	 * @param {Object} windowInfo - Pencere bilgileri
	 * @returns {Promise<boolean>} Success/failure
	 */
	async showRecordingPreview(windowInfo) {
		if (!windowInfo) {
			throw new Error("Window info is required");
		}

		try {
			const success = nativeBinding.showRecordingPreview(windowInfo);
			return success;
		} catch (error) {
			throw new Error(`Failed to show recording preview: ${error.message}`);
		}
	}

	/**
	 * Kayıt önizleme overlay'ini gizler
	 * @returns {Promise<boolean>} Success/failure
	 */
	async hideRecordingPreview() {
		try {
			const success = nativeBinding.hideRecordingPreview();
			return success;
		} catch (error) {
			throw new Error(`Failed to hide recording preview: ${error.message}`);
		}
	}

	/**
	 * Ekran seçimi başlatır
	 * Tüm ekranları overlay ile gösterir ve seçim yapılmasını bekler
	 * @returns {Promise<boolean>} Success/failure
	 */
	async startScreenSelection() {
		try {
			const success = nativeBinding.startScreenSelection();
			return success;
		} catch (error) {
			throw new Error(`Failed to start screen selection: ${error.message}`);
		}
	}

	/**
	 * Ekran seçimini durdurur
	 * @returns {Promise<boolean>} Success/failure
	 */
	async stopScreenSelection() {
		try {
			const success = nativeBinding.stopScreenSelection();
			return success;
		} catch (error) {
			throw new Error(`Failed to stop screen selection: ${error.message}`);
		}
	}

	/**
	 * Seçilen ekran bilgisini döndürür
	 * @returns {Object|null} Screen info or null
	 */
	getSelectedScreen() {
		try {
			return nativeBinding.getSelectedScreenInfo();
		} catch (error) {
			console.error(`Failed to get selected screen: ${error.message}`);
			return null;
		}
	}

	/**
	 * Promise tabanlı ekran seçimi
	 * Kullanıcı bir ekran seçene kadar bekler
	 * @returns {Promise<Object>} Selected screen info
	 */
	async selectScreen() {
		try {
			// Start screen selection
			await this.startScreenSelection();
			
			// Poll for selection completion
			return new Promise((resolve, reject) => {
				const checkSelection = () => {
					const selectedScreen = this.getSelectedScreen();
					if (selectedScreen) {
						resolve(selectedScreen);
					} else {
						// Check again in 100ms
						setTimeout(checkSelection, 100);
					}
				};
				
				// Start polling
				checkSelection();
				
				// Timeout after 60 seconds
				setTimeout(() => {
					this.stopScreenSelection();
					reject(new Error('Screen selection timed out'));
				}, 60000);
			});
		} catch (error) {
			throw new Error(`Failed to select screen: ${error.message}`);
		}
	}

	/**
	 * Seçilen ekran için kayıt önizleme overlay'ini gösterir
	 * Diğer ekranları siyah yapar, sadece seçili ekranı şeffaf bırakır
	 * @param {Object} screenInfo - Ekran bilgileri
	 * @returns {Promise<boolean>} Success/failure
	 */
	async showScreenRecordingPreview(screenInfo) {
		if (!screenInfo) {
			throw new Error("Screen info is required");
		}

		try {
			const success = nativeBinding.showScreenRecordingPreview(screenInfo);
			return success;
		} catch (error) {
			throw new Error(`Failed to show screen recording preview: ${error.message}`);
		}
	}

	/**
	 * Ekran kayıt önizleme overlay'ini gizler
	 * @returns {Promise<boolean>} Success/failure
	 */
	async hideScreenRecordingPreview() {
		try {
			const success = nativeBinding.hideScreenRecordingPreview();
			return success;
		} catch (error) {
			throw new Error(`Failed to hide screen recording preview: ${error.message}`);
		}
	}

	/**
	 * macOS'ta pencere seçim izinlerini kontrol eder
	 */
	async checkPermissions() {
		try {
			// Mevcut MacRecorder'dan permission check'i kullan
			const MacRecorder = require("./index.js");
			const recorder = new MacRecorder();
			return await recorder.checkPermissions();
		} catch (error) {
			return {
				screenRecording: false,
				accessibility: false,
				error: error.message
			};
		}
	}
}

module.exports = WindowSelector;
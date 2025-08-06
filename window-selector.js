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
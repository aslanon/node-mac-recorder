const { EventEmitter } = require("events");
const path = require("path");

// Native modülü yükle
let nativeBinding;
try {
    if (process.platform === "darwin" && process.arch === "arm64") {
        nativeBinding = require("./prebuilds/darwin-arm64/node.napi.node");
    } else {
        nativeBinding = require("./build/Release/mac_recorder.node");
    }
} catch (error) {
    try {
        nativeBinding = require("./build/Release/mac_recorder.node");
    } catch (_) {
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

class ElectronWindowSelector extends EventEmitter {
    constructor() {
        super();
        this.isSelecting = false;
        this.isScreenSelecting = false;
        this.selectedWindow = null;
        this.selectedScreen = null;
        this.selectionTimer = null;
        this.lastStatus = null;
        
        // Electron detection
        this.isElectron = !!(process.versions && process.versions.electron) || 
                         !!(process.env.ELECTRON_VERSION) ||
                         !!(process.env.ELECTRON_RUN_AS_NODE);
        
        console.log(`🔍 ElectronWindowSelector: ${this.isElectron ? 'Electron' : 'Node.js'} environment detected`);
    }

    /**
     * Pencere seçim modunu başlatır - Electron'da overlay ile
     * @returns {Promise<Object>} Seçilen pencere bilgisi
     */
    async selectWindow() {
        if (this.isSelecting) {
            throw new Error("Window selection is already in progress");
        }

        return new Promise((resolve, reject) => {
            try {
                // Event listener'ları ayarla
                const onWindowSelected = (windowInfo) => {
                    this.removeAllListeners("windowSelected");
                    this.removeAllListeners("error");
                    this.removeAllListeners("selectionCancelled");
                    resolve(windowInfo);
                };

                const onError = (error) => {
                    this.removeAllListeners("windowSelected");
                    this.removeAllListeners("error");
                    this.removeAllListeners("selectionCancelled");
                    reject(error);
                };

                const onCancelled = () => {
                    this.removeAllListeners("windowSelected");
                    this.removeAllListeners("error");
                    this.removeAllListeners("selectionCancelled");
                    reject(new Error("Window selection was cancelled"));
                };

                this.once("windowSelected", onWindowSelected);
                this.once("error", onError);
                this.once("selectionCancelled", onCancelled);

                // Native window selection başlat (overlay ile)
                this.startWindowSelectionWithOverlay();

            } catch (error) {
                this.removeAllListeners("windowSelected");
                this.removeAllListeners("error");
                this.removeAllListeners("selectionCancelled");
                reject(error);
            }
        });
    }

    /**
     * Ekran seçim modunu başlatır - Electron'da overlay ile
     * @returns {Promise<Object>} Seçilen ekran bilgisi
     */
    async selectScreen() {
        if (this.isScreenSelecting) {
            throw new Error("Screen selection is already in progress");
        }

        return new Promise((resolve, reject) => {
            try {
                // Event listener'ları ayarla
                const onScreenSelected = (screenInfo) => {
                    this.removeAllListeners("screenSelected");
                    this.removeAllListeners("error");
                    this.removeAllListeners("selectionCancelled");
                    resolve(screenInfo);
                };

                const onError = (error) => {
                    this.removeAllListeners("screenSelected");
                    this.removeAllListeners("error");
                    this.removeAllListeners("selectionCancelled");
                    reject(error);
                };

                const onCancelled = () => {
                    this.removeAllListeners("screenSelected");
                    this.removeAllListeners("error");
                    this.removeAllListeners("selectionCancelled");
                    reject(new Error("Screen selection was cancelled"));
                };

                this.once("screenSelected", onScreenSelected);
                this.once("error", onError);
                this.once("selectionCancelled", onCancelled);

                // Native screen selection başlat (overlay ile)
                this.startScreenSelectionWithOverlay();

            } catch (error) {
                this.removeAllListeners("screenSelected");
                this.removeAllListeners("error");
                this.removeAllListeners("selectionCancelled");
                reject(error);
            }
        });
    }

    /**
     * Native window selection'ı overlay ile başlatır
     */
    async startWindowSelectionWithOverlay() {
        try {
            // Native binding'den window selection başlat
            const success = await this.callNativeWindowSelection();
            
            if (success) {
                this.isSelecting = true;
                this.selectedWindow = null;

                // Polling timer başlat (overlay update'leri için)
                this.selectionTimer = setInterval(() => {
                    this.checkWindowSelectionStatus();
                }, 50); // 20 FPS

                this.emit("selectionStarted");
                console.log("✅ Window selection overlay started");
            } else {
                throw new Error("Failed to start window selection overlay");
            }
        } catch (error) {
            console.error("❌ Window selection failed:", error.message);
            this.emit("error", error);
        }
    }

    /**
     * Native screen selection'ı overlay ile başlatır
     */
    async startScreenSelectionWithOverlay() {
        try {
            // Native binding'den screen selection başlat
            const success = await this.callNativeScreenSelection();
            
            if (success) {
                this.isScreenSelecting = true;
                this.selectedScreen = null;

                // Polling timer başlat (overlay update'leri için)
                this.selectionTimer = setInterval(() => {
                    this.checkScreenSelectionStatus();
                }, 50); // 20 FPS

                this.emit("screenSelectionStarted");
                console.log("✅ Screen selection overlay started");
            } else {
                throw new Error("Failed to start screen selection overlay");
            }
        } catch (error) {
            console.error("❌ Screen selection failed:", error.message);
            this.emit("error", error);
        }
    }

    /**
     * Native window selection API'yi çağırır - Electron-compatible
     */
    async callNativeWindowSelection() {
        try {
            // Electron'da bile overlay'lerin çalışması için environment variable'ı geçici olarak kaldır
            const originalElectronVersion = process.env.ELECTRON_VERSION;
            const originalElectronRunAs = process.env.ELECTRON_RUN_AS_NODE;
            
            // Geçici olarak Electron environment variable'larını kaldır
            delete process.env.ELECTRON_VERSION;
            delete process.env.ELECTRON_RUN_AS_NODE;
            
            try {
                // Native function çağır
                const result = nativeBinding.startWindowSelection();
                return result;
            } finally {
                // Environment variable'ları geri yükle
                if (originalElectronVersion) {
                    process.env.ELECTRON_VERSION = originalElectronVersion;
                }
                if (originalElectronRunAs) {
                    process.env.ELECTRON_RUN_AS_NODE = originalElectronRunAs;
                }
            }
        } catch (error) {
            console.error("Native window selection failed:", error.message);
            return false;
        }
    }

    /**
     * Native screen selection API'yi çağırır - Electron-compatible
     */
    async callNativeScreenSelection() {
        try {
            // Electron'da bile overlay'lerin çalışması için environment variable'ı geçici olarak kaldır
            const originalElectronVersion = process.env.ELECTRON_VERSION;
            const originalElectronRunAs = process.env.ELECTRON_RUN_AS_NODE;
            
            // Geçici olarak Electron environment variable'larını kaldır
            delete process.env.ELECTRON_VERSION;
            delete process.env.ELECTRON_RUN_AS_NODE;
            
            try {
                // Native function çağır
                const result = nativeBinding.startScreenSelection();
                return result;
            } finally {
                // Environment variable'ları geri yükle
                if (originalElectronVersion) {
                    process.env.ELECTRON_VERSION = originalElectronVersion;
                }
                if (originalElectronRunAs) {
                    process.env.ELECTRON_RUN_AS_NODE = originalElectronRunAs;
                }
            }
        } catch (error) {
            console.error("Native screen selection failed:", error.message);
            return false;
        }
    }

    /**
     * Window selection durumunu kontrol eder
     */
    checkWindowSelectionStatus() {
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

                    console.log("🎯 Window selected:", windowInfo.title || windowInfo.appName);
                    this.emit("windowSelected", windowInfo);
                    return;
                }
            }

            // Mouse movement events için mevcut pencere değişikliklerini kontrol et
            if (this.lastStatus) {
                const lastWindow = this.lastStatus.currentWindow;
                const currentWindow = status.currentWindow;

                if (!lastWindow && currentWindow) {
                    // Yeni pencere üstüne gelindi
                    this.emit("windowEntered", currentWindow);
                } else if (lastWindow && !currentWindow) {
                    // Pencere üstünden ayrıldı
                    this.emit("windowLeft", lastWindow);
                } else if (
                    lastWindow &&
                    currentWindow &&
                    (lastWindow.id !== currentWindow.id ||
                        lastWindow.title !== currentWindow.title ||
                        lastWindow.appName !== currentWindow.appName)
                ) {
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
            console.error("Window selection status check error:", error.message);
            this.emit("error", error);
        }
    }

    /**
     * Screen selection durumunu kontrol eder
     */
    checkScreenSelectionStatus() {
        if (!this.isScreenSelecting) return;

        try {
            const selectedScreen = nativeBinding.getSelectedScreenInfo();
            
            if (selectedScreen && !this.selectedScreen) {
                this.selectedScreen = selectedScreen;
                this.isScreenSelecting = false;

                // Timer'ı durdur
                if (this.selectionTimer) {
                    clearInterval(this.selectionTimer);
                    this.selectionTimer = null;
                }

                console.log("🖥️ Screen selected:", selectedScreen);
                this.emit("screenSelected", selectedScreen);
            }
        } catch (error) {
            console.error("Screen selection status check error:", error.message);
            this.emit("error", error);
        }
    }

    /**
     * Window selection'ı durdurur
     */
    async stopWindowSelection() {
        if (!this.isSelecting) {
            return false;
        }

        try {
            // Environment variable'ları geçici kaldır
            const originalElectronVersion = process.env.ELECTRON_VERSION;
            const originalElectronRunAs = process.env.ELECTRON_RUN_AS_NODE;
            
            delete process.env.ELECTRON_VERSION;
            delete process.env.ELECTRON_RUN_AS_NODE;
            
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
                console.log("🛑 Window selection stopped");
                return success;
            } finally {
                // Environment variable'ları geri yükle
                if (originalElectronVersion) {
                    process.env.ELECTRON_VERSION = originalElectronVersion;
                }
                if (originalElectronRunAs) {
                    process.env.ELECTRON_RUN_AS_NODE = originalElectronRunAs;
                }
            }
        } catch (error) {
            console.error("Stop window selection error:", error.message);
            return false;
        }
    }

    /**
     * Screen selection'ı durdurur
     */
    async stopScreenSelection() {
        if (!this.isScreenSelecting) {
            return false;
        }

        try {
            // Environment variable'ları geçici kaldır
            const originalElectronVersion = process.env.ELECTRON_VERSION;
            const originalElectronRunAs = process.env.ELECTRON_RUN_AS_NODE;
            
            delete process.env.ELECTRON_VERSION;
            delete process.env.ELECTRON_RUN_AS_NODE;
            
            try {
                const success = nativeBinding.stopScreenSelection();

                // Timer'ı durdur
                if (this.selectionTimer) {
                    clearInterval(this.selectionTimer);
                    this.selectionTimer = null;
                }

                this.isScreenSelecting = false;

                this.emit("screenSelectionStopped");
                console.log("🛑 Screen selection stopped");
                return success;
            } finally {
                // Environment variable'ları geri yükle
                if (originalElectronVersion) {
                    process.env.ELECTRON_VERSION = originalElectronVersion;
                }
                if (originalElectronRunAs) {
                    process.env.ELECTRON_RUN_AS_NODE = originalElectronRunAs;
                }
            }
        } catch (error) {
            console.error("Stop screen selection error:", error.message);
            return false;
        }
    }

    /**
     * Recording preview gösterir
     * @param {Object} windowInfo - Pencere bilgisi
     */
    async showRecordingPreview(windowInfo) {
        if (!windowInfo) {
            throw new Error("Window info is required");
        }

        try {
            // Environment variable'ları geçici kaldır
            const originalElectronVersion = process.env.ELECTRON_VERSION;
            const originalElectronRunAs = process.env.ELECTRON_RUN_AS_NODE;
            
            delete process.env.ELECTRON_VERSION;
            delete process.env.ELECTRON_RUN_AS_NODE;
            
            try {
                const success = nativeBinding.showRecordingPreview(windowInfo);
                console.log("🎬 Recording preview shown");
                return success;
            } finally {
                // Environment variable'ları geri yükle
                if (originalElectronVersion) {
                    process.env.ELECTRON_VERSION = originalElectronVersion;
                }
                if (originalElectronRunAs) {
                    process.env.ELECTRON_RUN_AS_NODE = originalElectronRunAs;
                }
            }
        } catch (error) {
            console.error("Show recording preview error:", error.message);
            throw error;
        }
    }

    /**
     * Recording preview'ı gizler
     */
    async hideRecordingPreview() {
        try {
            // Environment variable'ları geçici kaldır
            const originalElectronVersion = process.env.ELECTRON_VERSION;
            const originalElectronRunAs = process.env.ELECTRON_RUN_AS_NODE;
            
            delete process.env.ELECTRON_VERSION;
            delete process.env.ELECTRON_RUN_AS_NODE;
            
            try {
                const success = nativeBinding.hideRecordingPreview();
                console.log("🎬 Recording preview hidden");
                return success;
            } finally {
                // Environment variable'ları geri yükle
                if (originalElectronVersion) {
                    process.env.ELECTRON_VERSION = originalElectronVersion;
                }
                if (originalElectronRunAs) {
                    process.env.ELECTRON_RUN_AS_NODE = originalElectronRunAs;
                }
            }
        } catch (error) {
            console.error("Hide recording preview error:", error.message);
            throw error;
        }
    }

    /**
     * Screen recording preview gösterir
     * @param {Object} screenInfo - Ekran bilgisi
     */
    async showScreenRecordingPreview(screenInfo) {
        if (!screenInfo) {
            throw new Error("Screen info is required");
        }

        try {
            // Environment variable'ları geçici kaldır
            const originalElectronVersion = process.env.ELECTRON_VERSION;
            const originalElectronRunAs = process.env.ELECTRON_RUN_AS_NODE;
            
            delete process.env.ELECTRON_VERSION;
            delete process.env.ELECTRON_RUN_AS_NODE;
            
            try {
                const success = nativeBinding.showScreenRecordingPreview(screenInfo);
                console.log("🖥️ Screen recording preview shown");
                return success;
            } finally {
                // Environment variable'ları geri yükle
                if (originalElectronVersion) {
                    process.env.ELECTRON_VERSION = originalElectronVersion;
                }
                if (originalElectronRunAs) {
                    process.env.ELECTRON_RUN_AS_NODE = originalElectronRunAs;
                }
            }
        } catch (error) {
            console.error("Show screen recording preview error:", error.message);
            throw error;
        }
    }

    /**
     * Screen recording preview'ı gizler
     */
    async hideScreenRecordingPreview() {
        try {
            // Environment variable'ları geçici kaldır
            const originalElectronVersion = process.env.ELECTRON_VERSION;
            const originalElectronRunAs = process.env.ELECTRON_RUN_AS_NODE;
            
            delete process.env.ELECTRON_VERSION;
            delete process.env.ELECTRON_RUN_AS_NODE;
            
            try {
                const success = nativeBinding.hideScreenRecordingPreview();
                console.log("🖥️ Screen recording preview hidden");
                return success;
            } finally {
                // Environment variable'ları geri yükle
                if (originalElectronVersion) {
                    process.env.ELECTRON_VERSION = originalElectronVersion;
                }
                if (originalElectronRunAs) {
                    process.env.ELECTRON_RUN_AS_NODE = originalElectronRunAs;
                }
            }
        } catch (error) {
            console.error("Hide screen recording preview error:", error.message);
            throw error;
        }
    }

    /**
     * Mevcut durumu döndürür
     */
    getStatus() {
        return {
            isSelecting: this.isSelecting,
            isScreenSelecting: this.isScreenSelecting,
            hasSelectedWindow: !!this.selectedWindow,
            hasSelectedScreen: !!this.selectedScreen,
            selectedWindow: this.selectedWindow,
            selectedScreen: this.selectedScreen,
            isElectron: this.isElectron
        };
    }

    /**
     * Seçilen pencere bilgisini döndürür
     */
    getSelectedWindow() {
        return this.selectedWindow;
    }

    /**
     * Seçilen ekran bilgisini döndürür
     */
    getSelectedScreen() {
        return this.selectedScreen;
    }

    /**
     * Tüm kaynakları temizler
     */
    async cleanup() {
        try {
            // Selection'ları durdur
            if (this.isSelecting) {
                await this.stopWindowSelection();
            }
            
            if (this.isScreenSelecting) {
                await this.stopScreenSelection();
            }

            // Timer'ları temizle
            if (this.selectionTimer) {
                clearInterval(this.selectionTimer);
                this.selectionTimer = null;
            }

            // Preview'ları gizle
            try {
                await this.hideRecordingPreview();
                await this.hideScreenRecordingPreview();
            } catch (error) {
                // Preview errors are not critical
                console.warn("Preview cleanup warning:", error.message);
            }

            // Event listener'ları temizle
            this.removeAllListeners();

            // State'i sıfırla
            this.selectedWindow = null;
            this.selectedScreen = null;
            this.lastStatus = null;
            this.isSelecting = false;
            this.isScreenSelecting = false;

            console.log("🧹 ElectronWindowSelector cleaned up");
        } catch (error) {
            console.error("Cleanup error:", error.message);
        }
    }

    /**
     * İzinleri kontrol eder
     */
    async checkPermissions() {
        try {
            const MacRecorder = require("./index.js");
            const recorder = new MacRecorder();
            return await recorder.checkPermissions();
        } catch (error) {
            return {
                screenRecording: false,
                accessibility: false,
                error: error.message,
            };
        }
    }
}

module.exports = ElectronWindowSelector;
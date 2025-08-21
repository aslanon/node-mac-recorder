# Electron Integration Guide

Bu döküman `node-mac-recorder` paketinin Electron uygulamaları ile güvenli entegrasyonunu açıklar.

## 🔧 Sorun Çözümü

**Problem**: ScreenCaptureKit'e geçtikten sonra Electron uygulamalarında native NSWindow overlay'lar crash'e sebep oluyordu.

**Çözüm**: `ElectronWindowSelector` sınıfı otomatik olarak Electron ortamını tespit eder ve güvenli mod kullanır.

## 📋 Electron Güvenli Mod Özellikleri

### 🔍 Otomatik Tespit
```javascript
// Otomatik olarak tespit edilen environment variable'lar:
- process.versions.electron
- process.env.ELECTRON_VERSION  
- process.env.ELECTRON_RUN_AS_NODE
```

### 🚫 Native Overlay'lar Devre Dışı
Electron modunda aşağıdaki native işlevler güvenli modda çalışır:
- ✅ Window listing (güvenli)
- ❌ Native NSWindow overlays (devre dışı)
- ❌ Native recording preview overlays (devre dışı)

## 🎯 API Kullanımı

### Temel Kurulum
```javascript
const ElectronWindowSelector = require('node-mac-recorder/electron-window-selector');

const selector = new ElectronWindowSelector();
console.log(`Environment: ${selector.isElectron ? 'Electron' : 'Node.js'}`);
```

### Real-Time Window Detection (Electron Mode)
```javascript
// 1. Mevcut pencere listesini al
const windows = await selector.getAvailableWindows();
console.log(`Found ${windows.length} windows`);

// 2. Real-time mouse tracking başlat
const nativeBinding = require('./build/Release/mac_recorder.node');
const trackingInterval = setInterval(() => {
    const status = nativeBinding.getWindowSelectionStatus();
    
    if (status && status.currentWindow) {
        const window = status.currentWindow;
        console.log(`Window under cursor: ${window.appName} - "${window.title}"`);
        console.log(`Position: (${window.x}, ${window.y}) Size: ${window.width}x${window.height}`);
        
        if (window.screenId !== undefined) {
            console.log(`Screen: ${window.screenId} (${window.screenWidth}x${window.screenHeight})`);
        }
        
        // Electron UI'da bu window'u real-time highlight et
        highlightWindowInElectronUI(window);
    }
}, 100); // 100ms polling for smooth tracking

// 3. Pencere seçimi tamamlandığında
function selectWindow(windowInfo) {
    clearInterval(trackingInterval);
    console.log('Window selected:', windowInfo);
    
    // Recording başlat
    startRecordingWithWindow(windowInfo);
}
```

### Screen/Display Seçimi (Electron Mode)  
```javascript
// 1. Mevcut display listesini al
const displays = await selector.getAvailableDisplays();
console.log(`Found ${displays.length} displays`);

// 2. Screen seçim başlat (Electron mode'da otomatik main screen)
const nativeBinding = require('./build/Release/mac_recorder.node');
const screenResult = nativeBinding.startScreenSelection();

if (screenResult) {
    // Screen seçim bilgisini al
    const selectedScreen = nativeBinding.getSelectedScreenInfo();
    
    if (selectedScreen) {
        console.log('Screen selected:', selectedScreen);
        console.log(`Resolution: ${selectedScreen.width}x${selectedScreen.height}`);
        console.log(`Position: (${selectedScreen.x}, ${selectedScreen.y})`);
        
        // Screen recording başlat
        startScreenRecording(selectedScreen);
    }
}

// 3. Manuel screen seçimi (UI ile)
function selectScreen(screenInfo) {
    console.log('Screen manually selected:', screenInfo);
    
    // Recording başlat
    startScreenRecordingWithScreen(screenInfo);
}
```

## 🎨 Electron UI Implementation Önerisi

### 1. Window Picker UI Component

```html
<!-- Electron Renderer Process -->
<div class="window-picker">
    <h3>Select Window to Record</h3>
    <div class="window-grid">
        <!-- Her window için thumbnail ve bilgi -->
        <div v-for="window in availableWindows" 
             :key="window.id" 
             class="window-card"
             :class="{ selected: selectedWindow?.id === window.id }"
             @click="selectWindow(window)">
            
            <div class="window-thumbnail">
                <!-- Thumbnail görseli buraya -->
                <img :src="window.thumbnail" v-if="window.thumbnail" />
                <div class="window-placeholder" v-else>
                    {{ window.appName?.charAt(0) || '?' }}
                </div>
            </div>
            
            <div class="window-info">
                <div class="app-name">{{ window.appName || 'Unknown App' }}</div>
                <div class="window-title">{{ window.title || 'Untitled' }}</div>
                <div class="window-size">{{ window.width }}×{{ window.height }}</div>
            </div>
        </div>
    </div>
</div>
```

### 2. Real-Time Window Tracking (Renderer Process)
```javascript
// renderer.js
const { ipcRenderer } = require('electron');

let windowSelector = null;
let trackingInterval = null;
let currentHighlightedWindow = null;

async function initializeWindowPicker() {
    // Main process'ten window selector'ı başlat
    const result = await ipcRenderer.invoke('init-window-selector');
    
    if (result.success) {
        // Mevcut windows'ları al
        const windows = await ipcRenderer.invoke('get-available-windows');
        displayWindowsInUI(windows);
        
        // Real-time tracking başlat
        startRealTimeTracking();
    }
}

function startRealTimeTracking() {
    trackingInterval = setInterval(async () => {
        try {
            // Main process'ten mouse altındaki pencere bilgisini al
            const currentWindow = await ipcRenderer.invoke('get-current-window-under-cursor');
            
            if (currentWindow && currentWindow.id !== currentHighlightedWindow?.id) {
                // Yeni pencere tespit edildi
                highlightWindowInUI(currentWindow);
                currentHighlightedWindow = currentWindow;
                
                // UI'da bilgileri güncelle
                updateCurrentWindowInfo(currentWindow);
            } else if (!currentWindow && currentHighlightedWindow) {
                // Mouse hiçbir pencere üstünde değil
                clearWindowHighlight();
                currentHighlightedWindow = null;
                clearCurrentWindowInfo();
            }
        } catch (error) {
            console.warn('Window tracking error:', error.message);
        }
    }, 100); // 100ms smooth tracking
}

function highlightWindowInUI(window) {
    // Tüm window card'ları normal hale getir
    document.querySelectorAll('.window-card').forEach(card => {
        card.classList.remove('hover-detected');
    });
    
    // Eşleşen window card'ı highlight et
    const matchingCard = document.querySelector(`[data-window-id="${window.id}"]`);
    if (matchingCard) {
        matchingCard.classList.add('hover-detected');
    }
}

function clearWindowHighlight() {
    document.querySelectorAll('.window-card').forEach(card => {
        card.classList.remove('hover-detected');
    });
}

function updateCurrentWindowInfo(window) {
    const infoDiv = document.getElementById('current-window-info');
    if (infoDiv) {
        infoDiv.innerHTML = `
            <h4>Window Under Cursor</h4>
            <p><strong>App:</strong> ${window.appName}</p>
            <p><strong>Title:</strong> ${window.title}</p>
            <p><strong>Size:</strong> ${window.width}×${window.height}</p>
            <p><strong>Position:</strong> (${window.x}, ${window.y})</p>
            ${window.screenId !== undefined ? 
                `<p><strong>Screen:</strong> ${window.screenId} (${window.screenWidth}×${window.screenHeight})</p>` : 
                ''}
        `;
        infoDiv.classList.add('visible');
    }
}

function clearCurrentWindowInfo() {
    const infoDiv = document.getElementById('current-window-info');
    if (infoDiv) {
        infoDiv.classList.remove('visible');
    }
}

function displayWindowsInUI(windows) {
    const windowGrid = document.querySelector('.window-grid');
    windowGrid.innerHTML = '';
    
    windows.forEach(window => {
        const windowCard = createWindowCard(window);
        windowGrid.appendChild(windowCard);
    });
}

function createWindowCard(window) {
    const card = document.createElement('div');
    card.className = 'window-card';
    card.setAttribute('data-window-id', window.id);
    card.innerHTML = `
        <div class="window-thumbnail">
            <div class="window-placeholder">${window.appName?.charAt(0) || '?'}</div>
        </div>
        <div class="window-info">
            <div class="app-name">${window.appName || 'Unknown App'}</div>
            <div class="window-title">${window.title || 'Untitled'}</div>
            <div class="window-size">${window.width}×${window.height}</div>
        </div>
    `;
    
    card.addEventListener('click', () => selectWindow(window));
    return card;
}

function selectWindow(window) {
    // Tracking'i durdur
    if (trackingInterval) {
        clearInterval(trackingInterval);
        trackingInterval = null;
    }
    
    // UI'da seçimi görsel olarak göster
    document.querySelectorAll('.window-card').forEach(card => {
        card.classList.remove('selected', 'hover-detected');
    });
    event.target.closest('.window-card').classList.add('selected');
    
    // Main process'e seçimi bildir
    ipcRenderer.invoke('window-selected', window);
}

// Cleanup function
window.addEventListener('beforeunload', () => {
    if (trackingInterval) {
        clearInterval(trackingInterval);
    }
});
```

### 3. Enhanced Main Process Handler
```javascript
// main.js
const { ipcMain } = require('electron');
const ElectronWindowSelector = require('node-mac-recorder/electron-window-selector');

let windowSelector = null;
let nativeBinding = null;

ipcMain.handle('init-window-selector', async () => {
    try {
        windowSelector = new ElectronWindowSelector();
        
        // Native binding'i yükle (real-time tracking için)
        try {
            nativeBinding = require('./build/Release/mac_recorder.node');
        } catch (error) {
            console.warn('Native binding yüklenemedi:', error.message);
        }
        
        return { success: true };
    } catch (error) {
        return { success: false, error: error.message };
    }
});

ipcMain.handle('get-available-windows', async () => {
    if (!windowSelector) return [];
    return await windowSelector.getAvailableWindows();
});

ipcMain.handle('get-available-displays', async () => {
    if (!windowSelector) return [];
    return await windowSelector.getAvailableDisplays();
});

// Real-time window tracking için yeni handler
ipcMain.handle('get-current-window-under-cursor', async () => {
    if (!nativeBinding) return null;
    
    try {
        const status = nativeBinding.getWindowSelectionStatus();
        return status?.currentWindow || null;
    } catch (error) {
        console.warn('Window status alınamadı:', error.message);
        return null;
    }
});

ipcMain.handle('window-selected', async (event, windowInfo) => {
    console.log('Window selected in Electron UI:', windowInfo);
    console.log(`  - App: ${windowInfo.appName}`);
    console.log(`  - Title: ${windowInfo.title}`);
    console.log(`  - Size: ${windowInfo.width}×${windowInfo.height}`);
    console.log(`  - Position: (${windowInfo.x}, ${windowInfo.y})`);
    
    if (windowInfo.screenId !== undefined) {
        console.log(`  - Screen: ${windowInfo.screenId} (${windowInfo.screenWidth}×${windowInfo.screenHeight})`);
    }
    
    // Recording başlatılabilir
    const MacRecorder = require('node-mac-recorder');
    const recorder = new MacRecorder();
    
    try {
        // Window recording başlat
        await recorder.startRecording('./output.mov', {
            windowId: windowInfo.id,
            // Screen coordination
            x: windowInfo.x,
            y: windowInfo.y, 
            width: windowInfo.width,
            height: windowInfo.height,
            // Diğer options
            fps: 30,
            audioEnabled: true
        });
        
        return { 
            success: true, 
            message: 'Recording started successfully',
            windowInfo: windowInfo
        };
    } catch (error) {
        return { 
            success: false, 
            error: error.message 
        };
    }
});

// Screen recording handler
ipcMain.handle('screen-selected', async (event, screenInfo) => {
    console.log('Screen selected in Electron UI:', screenInfo);
    
    const MacRecorder = require('node-mac-recorder');
    const recorder = new MacRecorder();
    
    try {
        // Screen recording başlat
        await recorder.startRecording('./screen-output.mov', {
            // Screen mode
            screenId: screenInfo.id,
            x: screenInfo.x,
            y: screenInfo.y,
            width: screenInfo.width,
            height: screenInfo.height,
            fps: 30,
            audioEnabled: true
        });
        
        return { 
            success: true, 
            message: 'Screen recording started',
            screenInfo: screenInfo
        };
    } catch (error) {
        return { 
            success: false, 
            error: error.message 
        };
    }
});

// Recording control handlers
ipcMain.handle('stop-recording', async () => {
    // Aktif recorder instance'ı durdur
    // Bu implementation'a recorder management eklenmeli
    return { success: true, message: 'Recording stopped' };
});
```

## 🎬 Recording Preview (Electron Mode)

Electron modunda native preview'lar çalışmaz. Bunun yerine Electron UI'da preview gösterin:

```javascript
// Recording preview'ı Electron UI'da göster
function showRecordingPreview(windowInfo) {
    // Electron window'da overlay div oluştur
    const overlay = document.createElement('div');
    overlay.className = 'recording-preview-overlay';
    overlay.style.cssText = `
        position: fixed;
        top: 0;
        left: 0;
        right: 0;
        bottom: 0;
        background: rgba(0, 0, 0, 0.5);
        z-index: 9999;
        display: flex;
        align-items: center;
        justify-content: center;
    `;
    
    overlay.innerHTML = `
        <div class="preview-info">
            <h3>Recording Preview</h3>
            <p>Recording: ${windowInfo.appName} - ${windowInfo.title}</p>
            <p>Area: ${windowInfo.width}×${windowInfo.height}</p>
            <button id="start-recording">Start Recording</button>
            <button id="cancel-preview">Cancel</button>
        </div>
    `;
    
    document.body.appendChild(overlay);
}
```

## 🎨 Enhanced CSS Styling (Real-Time Tracking)
```css
.window-picker {
    padding: 20px;
    max-height: 500px;
    overflow-y: auto;
    position: relative;
}

.window-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
    gap: 15px;
    margin-top: 15px;
}

.window-card {
    border: 2px solid #e1e1e1;
    border-radius: 8px;
    padding: 10px;
    cursor: pointer;
    transition: all 0.2s;
    position: relative;
}

.window-card:hover {
    border-color: #007acc;
    background-color: #f0f8ff;
}

.window-card.selected {
    border-color: #007acc;
    background-color: #e6f3ff;
}

/* Real-time hover detection styling */
.window-card.hover-detected {
    border-color: #ff6b35 !important;
    background-color: #fff3f0 !important;
    box-shadow: 0 4px 12px rgba(255, 107, 53, 0.3);
    transform: translateY(-2px);
}

.window-card.hover-detected::before {
    content: "🎯 CURSOR HERE";
    position: absolute;
    top: -10px;
    right: 5px;
    background: #ff6b35;
    color: white;
    padding: 2px 6px;
    border-radius: 4px;
    font-size: 10px;
    font-weight: bold;
}

.window-thumbnail {
    height: 80px;
    background: #f5f5f5;
    border-radius: 4px;
    display: flex;
    align-items: center;
    justify-content: center;
    margin-bottom: 8px;
}

.window-placeholder {
    font-size: 24px;
    font-weight: bold;
    color: #666;
}

.window-info {
    text-align: center;
}

.app-name {
    font-weight: bold;
    color: #333;
    margin-bottom: 2px;
}

.window-title {
    color: #666;
    font-size: 12px;
    margin-bottom: 2px;
}

.window-size {
    color: #999;
    font-size: 11px;
}

/* Real-time info panel */
#current-window-info {
    position: fixed;
    top: 20px;
    right: 20px;
    background: rgba(0, 0, 0, 0.9);
    color: white;
    padding: 15px;
    border-radius: 8px;
    min-width: 250px;
    opacity: 0;
    transform: translateX(300px);
    transition: all 0.3s ease;
    z-index: 1000;
    font-family: 'Monaco', monospace;
    font-size: 12px;
}

#current-window-info.visible {
    opacity: 1;
    transform: translateX(0);
}

#current-window-info h4 {
    margin: 0 0 10px 0;
    color: #ff6b35;
    font-size: 14px;
}

#current-window-info p {
    margin: 4px 0;
    line-height: 1.4;
}

#current-window-info strong {
    color: #fff;
}

/* Animation for smooth transitions */
.window-card {
    will-change: transform, box-shadow, border-color;
}

@keyframes pulseHover {
    0% { transform: scale(1) translateY(-2px); }
    50% { transform: scale(1.02) translateY(-3px); }
    100% { transform: scale(1) translateY(-2px); }
}

.window-card.hover-detected {
    animation: pulseHover 2s infinite;
}

/* Status indicator */
.tracking-status {
    position: absolute;
    top: 10px;
    left: 20px;
    background: #4CAF50;
    color: white;
    padding: 5px 10px;
    border-radius: 15px;
    font-size: 12px;
    font-weight: bold;
}

.tracking-status::before {
    content: "🔴 ";
    animation: blink 1s infinite;
}

@keyframes blink {
    0%, 50% { opacity: 1; }
    51%, 100% { opacity: 0; }
}
```

## ✨ Yeni Real-Time Tracking Özellikleri

### 🎯 Anlık Window Tespit
- **100ms polling** ile smooth mouse tracking
- Mouse hangi pencere üstüne giderse **otomatik highlight**
- **Screen detection** - pencere hangi ekranda, otomatik tespit
- **Koordinat bilgisi** - x, y, width, height gerçek zamanlı

### 🔥 UI Features
- `hover-detected` class ile anlık görsel feedback
- Real-time info panel (sağ üst köşe)
- Pulse animation effect
- "🎯 CURSOR HERE" indicator

### 🖥️ Multi-Screen Support
- Pencere hangi screen'de otomatik tespit
- Screen koordinatları ve boyutları dahil
- Cross-screen window tracking

## ⚠️ Önemli Notlar

### 🔧 Teknik Gereksinimler
1. **Native Module**: Real-time tracking için native binding gerekli
2. **macOS Permissions**: Screen Recording ve Accessibility izinleri
3. **Electron Environment**: `ELECTRON_VERSION` env variable otomatik tespit
4. **Performance**: 100ms polling interval (ayarlanabilir)

### 🛠️ Implementation Notes
1. **IPC Communication**: Main ↔ Renderer process real-time data exchange
2. **Memory Management**: Interval cleanup önemli
3. **Error Handling**: Native binding yoksa graceful fallback
4. **UI Responsiveness**: CSS transitions ile smooth UX

### 🚨 Troubleshooting
- **Native binding yüklenemezse**: `npm run build` ile tekrar derle
- **Permission hatası**: System Preferences → Security & Privacy
- **Tracking çalışmıyorsa**: `ELECTRON_VERSION` environment variable kontrol et
- **UI update yavaşsa**: Polling interval'ı artır (100ms → 200ms)

## 🚀 Sonraki Adımlar

### Phase 1: Core Enhancement
1. ✅ **Real-time window tracking** - TAMAMLANDI
2. ✅ **Screen detection accuracy** - TAMAMLANDI  
3. ✅ **Electron compatibility** - TAMAMLANDI
4. 🔄 Thumbnail generation implementasyonu

### Phase 2: Advanced Features  
5. 📋 Window list real-time updates
6. 🖥️ Multiple display UI enhancement
7. 📹 Recording progress indicator
8. ✂️ Custom recording area selection
9. 🎨 Window preview thumbnails

### Phase 3: Performance & UX
10. ⚡ Performance optimization
11. 🎭 Advanced animations
12. 📱 Responsive design improvements
13. 🔧 Settings panel

## 📞 Test Komutları

```bash
# Fixed overlay functionality test
node test-overlay-fix.js

# Electron mode test  
ELECTRON_VERSION=25.0.0 node test-overlay-fix.js

# Build native module
npm run build

# Full integration test
node test-electron-window-selector.js
```

## 🎉 Sonuç

Bu güncellenmiş implementasyon ile:

✅ **Mouse tracking** gerçek zamanlı çalışıyor
✅ **Window detection** hassas ve hızlı
✅ **Screen coordination** doğru hesaplanıyor  
✅ **Electron integration** sorunsuz çalışıyor
✅ **Multi-display support** tam uyumlu
✅ **Real-time UI feedback** kullanıcı dostu

Electron uygulamanızda artık native overlay benzeri deneyim sunabilir, kullanıcı mouse'u hareket ettirdikçe hangi pencere üstünde olduğunu görebilir ve tek tıkla recording başlatabilirsiniz!
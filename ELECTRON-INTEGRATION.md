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

### Pencere Seçimi (Electron Safe Mode)
```javascript
// 1. Mevcut pencere listesini al
const windows = await selector.getAvailableWindows();
console.log(`Found ${windows.length} windows`);

// 2. Pencere seçim başlat (otomatik mode - demo amaçlı)
const selectedWindow = await selector.selectWindow();

// 3. Event listener ile dinle
selector.on('windowSelected', (windowInfo) => {
    console.log('Selected:', windowInfo.title, windowInfo.appName);
    
    // Electron UI'da bu window'u highlight et
    showWindowInElectronUI(windowInfo);
});
```

### Display Seçimi (Electron Safe Mode)  
```javascript
// 1. Mevcut display listesini al
const displays = await selector.getAvailableDisplays();
console.log(`Found ${displays.length} displays`);

// 2. Display seçim başlat (otomatik mode - demo amaçlı)
const selectedDisplay = await selector.selectScreen();

// 3. Event listener ile dinle
selector.on('screenSelected', (screenInfo) => {
    console.log('Selected Display:', screenInfo.name, screenInfo.resolution);
    
    // Electron UI'da bu display'i highlight et
    showDisplayInElectronUI(screenInfo);
});
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

### 2. Renderer Process Logic
```javascript
// renderer.js
const { ipcRenderer } = require('electron');

let windowSelector = null;

async function initializeWindowPicker() {
    // Main process'ten window selector'ı başlat
    const result = await ipcRenderer.invoke('init-window-selector');
    
    if (result.success) {
        // Mevcut windows'ları al
        const windows = await ipcRenderer.invoke('get-available-windows');
        displayWindowsInUI(windows);
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
    // UI'da seçimi görsel olarak göster
    document.querySelectorAll('.window-card').forEach(card => 
        card.classList.remove('selected')
    );
    event.target.closest('.window-card').classList.add('selected');
    
    // Main process'e seçimi bildir
    ipcRenderer.invoke('window-selected', window);
}
```

### 3. Main Process Handler
```javascript
// main.js
const { ipcMain } = require('electron');
const ElectronWindowSelector = require('node-mac-recorder/electron-window-selector');

let windowSelector = null;

ipcMain.handle('init-window-selector', async () => {
    try {
        windowSelector = new ElectronWindowSelector();
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

ipcMain.handle('window-selected', async (event, windowInfo) => {
    console.log('Window selected in Electron UI:', windowInfo);
    
    // Recording başlatılabilir
    const MacRecorder = require('node-mac-recorder');
    const recorder = new MacRecorder();
    
    // Window recording başlat
    await recorder.startRecording('./output.mov', {
        windowId: windowInfo.id,
        // ... diğer options
    });
    
    return { success: true };
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

## 🔧 CSS Styling
```css
.window-picker {
    padding: 20px;
    max-height: 500px;
    overflow-y: auto;
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
}

.window-card:hover {
    border-color: #007acc;
    background-color: #f0f8ff;
}

.window-card.selected {
    border-color: #007acc;
    background-color: #e6f3ff;
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
```

## ⚠️ Önemli Notlar

1. **Native Overlays**: Electron modunda native NSWindow overlays devre dışıdır
2. **Auto Selection**: Şu an demo amaçlı otomatik seçim yapıyor, gerçek uygulamada UI ile seçim yapılmalı
3. **Permission Check**: `checkPermissions()` tüm modlarda çalışır
4. **Event Handling**: Electron'da event'ler IPC ile main ve renderer process arasında taşınmalı

## 🚀 Sonraki Adımlar

1. Thumbnail generation implementasyonu
2. Real-time window list updates
3. Multiple display support UI
4. Recording progress indicator
5. Custom recording area selection

## 📞 Test Komutları

```bash
# Electron mode test
ELECTRON_VERSION=25.0.0 node test-electron-window-selector.js

# Node.js mode test  
node test-electron-window-selector.js
```

Bu implementasyon sayesinde Electron uygulamaları crash olmadan pencere seçimi yapabilir ve recording işlevlerini güvenli şekilde kullanabilir.
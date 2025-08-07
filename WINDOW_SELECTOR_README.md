# Window Selector

**macOS Window Selection Tool with Real-time Visual Overlay**

Bu modül, macOS'ta sistem imleci ile pencere seçimi yapabilmenizi sağlayan güçlü bir araçtır. İmleç hangi pencerenin üstüne gelirse, o pencereyi mavi kapsayıcı ile highlight eder ve merkeze yerleştirilen "Select Window" butonu ile seçim yapabilirsiniz.

## ✨ Özellikler

- **Real-time Window Detection**: İmleç hangi pencereye gelirse otomatik olarak tespit eder
- **Visual Overlay**: Seçilebilir pencereleri mavi transparant kapsayıcı ile highlight eder
- **Interactive Selection**: Merkeze yerleştirilen "Select Window" butonu ile kolay seçim
- **Multi-display Support**: Çoklu ekran kurulumlarında çalışır
- **Detailed Window Info**: Pencere pozisyonu, boyutu ve hangi ekranda olduğunu döndürür
- **Event-driven API**: Pencere hover, seçim ve hata durumları için event'ler
- **Window Focus Control**: Detect edilen pencereyi otomatik olarak en öne getirir
- **Auto Bring-to-Front**: Cursor hangi pencereye gelirse otomatik focus yapar
- **Recording Preview Overlay**: Kayıt alanını görselleştiren tam ekran overlay sistemi
- **Screen Selection**: Tam ekran overlay ile ekran seçimi (menu bar dahil)
- **Screen Recording Preview**: Seçilen ekran için kayıt önizleme sistemi
- **Permission Management**: macOS izin kontrolü ve yönetimi

## 🚀 Kurulum

```bash
# Ana proje dizininde
npm install

# Native modülü build edin
npm run build
```

## 📋 Sistem Gereksinimleri

- **macOS 10.15+** (Catalina veya üzeri)
- **Node.js 14+**
- **Xcode Command Line Tools**
- **System Permissions**:
  - Screen Recording permission
  - Accessibility permission

## 🔐 İzinler

İlk kullanımda macOS aşağıdaki izinleri isteyecektir:

1. **System Preferences > Security & Privacy > Privacy > Screen Recording**
   - Terminal veya kullandığınız IDE'yi (VSCode, WebStorm, vb.) etkinleştirin

2. **System Preferences > Security & Privacy > Privacy > Accessibility**
   - Terminal veya kullandığınız IDE'yi etkinleştirin

## 🎯 Temel Kullanım

### Basit Pencere Seçimi

```javascript
const WindowSelector = require('./window-selector');

async function selectWindow() {
    const selector = new WindowSelector();
    
    try {
        console.log('Bir pencere seçin...');
        const selectedWindow = await selector.selectWindow();
        
        console.log('Seçilen pencere:', {
            title: selectedWindow.title,
            app: selectedWindow.appName,
            position: `(${selectedWindow.x}, ${selectedWindow.y})`,
            size: `${selectedWindow.width}x${selectedWindow.height}`,
            screen: selectedWindow.screenId
        });
        
        return selectedWindow;
        
    } catch (error) {
        console.error('Hata:', error.message);
    } finally {
        await selector.cleanup();
    }
}

selectWindow();
```

### Manuel Kontrol

```javascript
const WindowSelector = require('./window-selector');

async function manualSelection() {
    const selector = new WindowSelector();
    
    // Event listener'lar
    selector.on('windowEntered', (window) => {
        console.log(`Pencere üstünde: ${window.title} (${window.appName})`);
    });
    
    selector.on('windowSelected', (window) => {
        console.log(`Seçildi: ${window.title}`);
    });
    
    // Seçimi başlat
    await selector.startSelection();
    
    // Kullanıcı seçim yapana kadar bekle
    // Seçim tamamlandığında 'windowSelected' event'i tetiklenir
    
    // Seçimi durdurmak için:
    // await selector.stopSelection();
}
```

## 📚 API Reference

### WindowSelector Class

#### Constructor
```javascript
const selector = new WindowSelector();
```

#### Methods

##### `async selectWindow()`
Promise tabanlı pencere seçimi. Kullanıcı bir pencere seçene kadar bekler.

**Returns:** `Promise<WindowInfo>`

```javascript
const window = await selector.selectWindow();
```

##### `async startSelection()`
Pencere seçim modunu başlatır.

**Returns:** `Promise<boolean>`

##### `async stopSelection()`
Pencere seçim modunu durdurur.

**Returns:** `Promise<boolean>`

##### `getSelectedWindow()`
Son seçilen pencere bilgisini döndürür.

**Returns:** `WindowInfo | null`

##### `getStatus()`
Seçici durumunu döndürür.

**Returns:** `SelectionStatus`

##### `async checkPermissions()`
macOS izinlerini kontrol eder.

**Returns:** `Promise<PermissionStatus>`

##### `async bringWindowToFront(windowId)`
Belirtilen pencereyi en öne getirir (focus yapar).

**Parameters:**
- `windowId` (number) - Window ID

**Returns:** `Promise<boolean>` - Başarı/başarısızlık

```javascript
const success = await selector.bringWindowToFront(windowInfo.id);
```

##### `setBringToFrontEnabled(enabled)`
Otomatik pencere en öne getirme özelliğini aktif/pasif yapar.

**Parameters:**
- `enabled` (boolean) - Enable/disable

```javascript
selector.setBringToFrontEnabled(true);  // Auto mode ON
selector.setBringToFrontEnabled(false); // Auto mode OFF
```

##### `async showRecordingPreview(windowInfo)`
Seçilen pencere için kayıt önizleme overlay'ini gösterir. Tüm ekranı siyah yapar, sadece pencere alanını şeffaf bırakır.

**Parameters:**
- `windowInfo` (WindowInfo) - Pencere bilgileri

**Returns:** `Promise<boolean>` - Başarı/başarısızlık

```javascript
const success = await selector.showRecordingPreview(selectedWindow);
```

##### `async hideRecordingPreview()`
Kayıt önizleme overlay'ini gizler.

**Returns:** `Promise<boolean>` - Başarı/başarısızlık

```javascript
const success = await selector.hideRecordingPreview();
```

##### `async startScreenSelection()`
Ekran seçim modunu başlatır. Tüm ekranları overlay ile gösterir.

**Returns:** `Promise<boolean>` - Başarı/başarısızlık

```javascript
const success = await selector.startScreenSelection();
```

##### `async stopScreenSelection()`
Ekran seçim modunu durdurur.

**Returns:** `Promise<boolean>` - Başarı/başarısızlık

```javascript
const success = await selector.stopScreenSelection();
```

##### `getSelectedScreen()`
Son seçilen ekran bilgisini döndürür.

**Returns:** `ScreenInfo | null`

```javascript
const screenInfo = selector.getSelectedScreen();
```

##### `async selectScreen()`
Promise tabanlı ekran seçimi. Kullanıcı bir ekran seçene kadar bekler.

**Returns:** `Promise<ScreenInfo>`

```javascript
const selectedScreen = await selector.selectScreen();
```

##### `async showScreenRecordingPreview(screenInfo)`
Seçilen ekran için kayıt önizleme overlay'ini gösterir. Diğer ekranları siyah yapar, sadece seçili ekranı şeffaf bırakır.

**Parameters:**
- `screenInfo` (ScreenInfo) - Ekran bilgileri

**Returns:** `Promise<boolean>` - Başarı/başarısızlık

```javascript
const success = await selector.showScreenRecordingPreview(selectedScreen);
```

##### `async hideScreenRecordingPreview()`
Ekran kayıt önizleme overlay'ini gizler.

**Returns:** `Promise<boolean>` - Başarı/başarısızlık

```javascript
const success = await selector.hideScreenRecordingPreview();
```

##### `async cleanup()`
Tüm kaynakları temizler ve seçimi durdurur.

#### Events

##### `selectionStarted`
Seçim modu başladığında tetiklenir.

```javascript
selector.on('selectionStarted', () => {
    console.log('Seçim başladı');
});
```

##### `windowEntered`
İmleç bir pencereye geldiğinde tetiklenir.

```javascript
selector.on('windowEntered', (windowInfo) => {
    console.log(`Pencere: ${windowInfo.title}`);
});
```

##### `windowLeft`
İmleç bir pencereden ayrıldığında tetiklenir.

```javascript
selector.on('windowLeft', (windowInfo) => {
    console.log(`Ayrıldı: ${windowInfo.title}`);
});
```

##### `windowSelected`
Bir pencere seçildiğinde tetiklenir.

```javascript
selector.on('windowSelected', (windowInfo) => {
    console.log('Seçilen pencere:', windowInfo);
});
```

##### `selectionStopped`
Seçim modu durduğunda tetiklenir.

##### `error`
Bir hata oluştuğunda tetiklenir.

```javascript
selector.on('error', (error) => {
    console.error('Hata:', error.message);
});
```

## 📊 Data Types

### WindowInfo
```javascript
{
    id: number,           // Pencere ID'si
    title: string,        // Pencere başlığı
    appName: string,      // Uygulama adı
    x: number,           // Global X pozisyonu
    y: number,           // Global Y pozisyonu
    width: number,       // Pencere genişliği
    height: number,      // Pencere yüksekliği
    screenId: number,    // Hangi ekranda olduğu
    screenX: number,     // Ekranın X pozisyonu
    screenY: number,     // Ekranın Y pozisyonu
    screenWidth: number, // Ekran genişliği
    screenHeight: number // Ekran yüksekliği
}
```

### SelectionStatus
```javascript
{
    isSelecting: boolean,      // Seçim modunda mı?
    hasSelectedWindow: boolean, // Seçilmiş pencere var mı?
    selectedWindow: WindowInfo | null,
    nativeStatus: object       // Native durum bilgisi
}
```

### PermissionStatus
```javascript
{
    screenRecording: boolean,  // Ekran kaydı izni
    accessibility: boolean,    // Erişilebilirlik izni
    microphone: boolean       // Mikrofon izni
}
```

### ScreenInfo
```javascript
{
    id: number,          // Ekran ID'si (0, 1, 2, ...)
    name: string,        // Ekran adı ("Display 1", "Display 2", ...)
    x: number,          // Global X pozisyonu
    y: number,          // Global Y pozisyonu
    width: number,      // Ekran genişliği
    height: number,     // Ekran yüksekliği
    resolution: string, // Çözünürlük string'i ("1920x1080")
    isPrimary: boolean  // Ana ekran mı?
}
```

## 🎮 Test Etme

### Test Dosyasını Çalıştır
```bash
# Interaktif test
node window-selector-test.js

# API test modu
node window-selector-test.js --api-test
```

### Örnekleri Çalıştır
```bash
# Basit örnek
node examples/window-selector-example.js

# Gelişmiş örnek (event'lerle)
node examples/window-selector-example.js --advanced

# Çoklu seçim
node examples/window-selector-example.js --multiple

# Detaylı analiz
node examples/window-selector-example.js --analysis

# Yardım
node examples/window-selector-example.js --help
```

## ⚡ Nasıl Çalışır?

### Pencere Seçim Süreci
1. **Window Detection**: macOS `CGWindowListCopyWindowInfo` API'si ile açık pencereleri tespit eder
2. **Cursor Tracking**: Real-time olarak imleç pozisyonunu takip eder
3. **Overlay Rendering**: NSWindow ile transparant overlay penceresi oluşturur
4. **Hit Testing**: İmlecin hangi pencere üstünde olduğunu hesaplar
5. **Visual Feedback**: Pencereyi highlight eden mavi kapsayıcı çizer
6. **User Interaction**: Merkeze yerleştirilen button ile seçim yapar
7. **Data Collection**: Seçilen pencerenin tüm bilgilerini toplar

### Kayıt Önizleme Sistemi (Pencere)
1. **Full Screen Overlay**: Tüm ekranı kaplayan siyah transparan katman oluşturur
2. **Window Cutout**: Seçilen pencere alanını şeffaf hale getirir (cut-out effect)
3. **Coordinate Conversion**: CGWindow koordinatlarını NSView koordinatlarına dönüştürür  
4. **Multi-Display Support**: Çoklu ekran kurulumlarında doğru pozisyonlama yapar
5. **Non-Interactive**: Mouse events'leri geçirir, kullanıcı etkileşimini engellemeZ
6. **Clean Management**: Programatik açma/kapama kontrolü sağlar

### Ekran Seçim Sistemi
1. **Multi-Screen Detection**: NSScreen.screens ile tüm ekranları tespit eder
2. **Full Screen Coverage**: Her ekran için tam kaplama overlay oluşturur (menu bar dahil)
3. **Interactive Overlays**: Her ekranda merkezi "Select Screen" butonu
4. **Screen Information Display**: Ekran adı ve çözünürlük bilgilerini gösterir
5. **Automatic Assignment**: Her overlay'i kendi ekranına otomatik atar
6. **Selection Feedback**: Seçim yapıldığında anında geri bildirim

### Ekran Kayıt Önizleme Sistemi
1. **Multi-Screen Management**: Birden fazla ekranı aynı anda yönetir
2. **Selective Darkening**: Sadece seçilmeyen ekranları siyah overlay ile kaplar
3. **Recording Area Highlight**: Seçilen ekran tamamen şeffaf kalır
4. **Screen-Specific Overlays**: Her ekran için ayrı overlay penceresi
5. **Coordinate Independence**: Her ekranın kendi koordinat sistemini kullanır

## 🔧 Troubleshooting

### Build Hataları
```bash
# Xcode Command Line Tools'u yükle
xcode-select --install

# Node-gyp'i yeniden build et
npm run clean
npm run build
```

### İzin Hataları
1. **System Preferences > Security & Privacy > Privacy** bölümüne git
2. **Screen Recording** ve **Accessibility** sekmelerinde Terminal'i etkinleştir
3. Uygulamayı yeniden başlat

### Runtime Hataları
```javascript
// İzinleri kontrol et
const permissions = await selector.checkPermissions();
if (!permissions.screenRecording) {
    console.log('Screen recording permission required');
}
```

## 🌟 Gelişmiş Örnekler

### Auto Bring-to-Front (DEFAULT - Otomatik Focus)
```javascript
const WindowSelector = require('./window-selector');

async function autoBringToFront() {
    const selector = new WindowSelector();
    
    // Auto bring-to-front varsayılan olarak AÇIK
    // (Kapatmak için: selector.setBringToFrontEnabled(false))
    
    selector.on('windowEntered', (window) => {
        console.log(`🔝 Auto-focused: ${window.appName} - "${window.title}"`);
    });
    
    await selector.startSelection();
    console.log('🖱️ Move cursor over windows - they will come to front automatically!');
    console.log('💡 Only the specific window focuses, not all windows of the app');
}
```

### Manuel Window Focus
```javascript
const WindowSelector = require('./window-selector');

async function manualFocus() {
    const selector = new WindowSelector();
    
    selector.on('windowEntered', async (window) => {
        console.log(`Found: ${window.appName} - "${window.title}"`);
        
        // Manuel olarak pencereyi en öne getir
        const success = await selector.bringWindowToFront(window.id);
        if (success) {
            console.log('✅ Window brought to front!');
        }
    });
    
    await selector.startSelection();
}
```

### Ekran Seçimi ile Kayıt
```javascript
const WindowSelector = require('./window-selector');
const MacRecorder = require('./index');

async function recordScreenWithPreview() {
    const selector = new WindowSelector();
    const recorder = new MacRecorder();
    
    try {
        // Ekran seç
        const screen = await selector.selectScreen();
        console.log(`Selected: ${screen.name} (${screen.resolution})`);
        
        // Kayıt önizlemesi göster (diğer ekranlar siyah, seçili ekran şeffaf)
        await selector.showScreenRecordingPreview(screen);
        console.log('🎬 Screen recording preview shown');
        
        // 3 saniye bekle
        await new Promise(resolve => setTimeout(resolve, 3000));
        
        // Ekran kaydını başlat
        const outputPath = `./recordings/screen-${screen.id}-${Date.now()}.mov`;
        await recorder.startRecording(outputPath, {
            displayId: screen.id,
            captureCursor: true,
            includeMicrophone: true
        });
        
        console.log('🔴 Screen recording started...');
        
        // 10 saniye kaydet
        setTimeout(async () => {
            await recorder.stopRecording();
            
            // Önizleme overlay'ini gizle
            await selector.hideScreenRecordingPreview();
            console.log(`✅ Recording saved: ${outputPath}`);
        }, 10000);
        
    } finally {
        await selector.cleanup();
    }
}
```

### Kayıt Önizleme ile Pencere Kaydı
```javascript
const WindowSelector = require('./window-selector');
const MacRecorder = require('./index');

async function recordWithPreview() {
    const selector = new WindowSelector();
    const recorder = new MacRecorder();
    
    try {
        // Pencere seç
        const window = await selector.selectWindow();
        console.log(`Selected: ${window.title}`);
        
        // Kayıt önizlemesi göster (siyah overlay + şeffaf pencere alanı)
        await selector.showRecordingPreview(window);
        console.log('🎬 Recording preview shown - you can see exact recording area');
        
        // 3 saniye bekle (kullanıcı görebilsin)
        await new Promise(resolve => setTimeout(resolve, 3000));
        
        // Kaydı başlat
        const outputPath = `./recordings/${window.appName}-${Date.now()}.mov`;
        await recorder.startRecording(outputPath, {
            windowId: window.id,
            captureCursor: true,
            includeMicrophone: true
        });
        
        console.log('🔴 Recording started...');
        
        // 10 saniye kaydet
        setTimeout(async () => {
            await recorder.stopRecording();
            
            // Önizleme overlay'ini gizle
            await selector.hideRecordingPreview();
            console.log(`✅ Recording saved: ${outputPath}`);
        }, 10000);
        
    } finally {
        await selector.cleanup();
    }
}
```

### Basit Ekran Seçimi
```javascript
const WindowSelector = require('./window-selector');

async function selectScreen() {
    const selector = new WindowSelector();
    
    try {
        console.log('Bir ekran seçin...');
        const selectedScreen = await selector.selectScreen();
        
        console.log('Seçilen ekran:', {
            name: selectedScreen.name,
            resolution: selectedScreen.resolution,
            position: `(${selectedScreen.x}, ${selectedScreen.y})`,
            isPrimary: selectedScreen.isPrimary
        });
        
        return selectedScreen;
        
    } catch (error) {
        console.error('Hata:', error.message);
    } finally {
        await selector.cleanup();
    }
}
```

### Manuel Ekran Kontrolü
```javascript
const WindowSelector = require('./window-selector');

async function manualScreenSelection() {
    const selector = new WindowSelector();
    
    try {
        // Ekran seçimini başlat
        await selector.startScreenSelection();
        console.log('🖥️ Screen overlays shown - click Select Screen button');
        
        // Polling ile seçim bekle
        const checkSelection = () => {
            const selected = selector.getSelectedScreen();
            if (selected) {
                console.log(`✅ Screen selected: ${selected.name}`);
                return selected;
            }
            setTimeout(checkSelection, 100);
        };
        
        checkSelection();
        
    } catch (error) {
        console.error('Hata:', error.message);
    }
}
```

### Otomatik Pencere Kaydı (Basit)
```javascript
const WindowSelector = require('./window-selector');
const MacRecorder = require('./index');

async function recordSelectedWindow() {
    const selector = new WindowSelector();
    const recorder = new MacRecorder();
    
    try {
        // Pencere seç
        const window = await selector.selectWindow();
        console.log(`Recording: ${window.title}`);
        
        // Seçilen pencereyi kaydet
        const outputPath = `./recordings/${window.appName}-${Date.now()}.mov`;
        await recorder.startRecording(outputPath, {
            windowId: window.id,
            captureCursor: true,
            includeMicrophone: true
        });
        
        // 10 saniye kaydet
        setTimeout(async () => {
            await recorder.stopRecording();
            console.log(`Recording saved: ${outputPath}`);
        }, 10000);
        
    } finally {
        await selector.cleanup();
    }
}
```

### Pencere Monitoring
```javascript
const WindowSelector = require('./window-selector');

async function monitorWindowChanges() {
    const selector = new WindowSelector();
    const visitedWindows = new Set();
    
    selector.on('windowEntered', (window) => {
        const key = `${window.appName}-${window.title}`;
        if (!visitedWindows.has(key)) {
            visitedWindows.add(key);
            console.log(`Yeni pencere keşfedildi: ${window.title} (${window.appName})`);
        }
    });
    
    await selector.startSelection();
    
    // İptal etmek için Ctrl+C
    process.on('SIGINT', async () => {
        console.log(`\nToplam keşfedilen pencere: ${visitedWindows.size}`);
        await selector.cleanup();
        process.exit(0);
    });
}
```

## 📄 Lisans

Bu modül ana projenin lisansı altındadır.

## 🤝 Katkıda Bulunma

1. Fork edin
2. Feature branch oluşturun (`git checkout -b feature/amazing-feature`)
3. Commit edin (`git commit -m 'Add amazing feature'`)
4. Push edin (`git push origin feature/amazing-feature`)
5. Pull Request açın

## ⭐ Özellik İstekleri

### Pencere Seçimi
- [ ] Pencere gruplandırma
- [ ] Hotkey desteği  
- [ ] Pencere filtreleme
- [ ] Çoklu seçim modu
- [ ] Screenshot alma
- [ ] Window history

### Ekran Seçimi
- [x] Tam ekran overlay (menu bar dahil) ✅
- [x] Multi-display desteği ✅
- [x] Kayıt önizleme sistemi ✅
- [ ] Hotkey desteği
- [ ] Çoklu ekran seçimi
- [ ] Ekran thumbnail'ları

---

**Not**: Bu modül sadece macOS'ta çalışır ve sistem izinleri gerektirir.
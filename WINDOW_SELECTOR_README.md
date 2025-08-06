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

1. **Window Detection**: macOS `CGWindowListCopyWindowInfo` API'si ile açık pencereleri tespit eder
2. **Cursor Tracking**: Real-time olarak imleç pozisyonunu takip eder
3. **Overlay Rendering**: NSWindow ile transparant overlay penceresi oluşturur
4. **Hit Testing**: İmlecin hangi pencere üstünde olduğunu hesaplar
5. **Visual Feedback**: Pencereyi highlight eden mavi kapsayıcı çizer
6. **User Interaction**: Merkeze yerleştirilen button ile seçim yapar
7. **Data Collection**: Seçilen pencerenin tüm bilgilerini toplar

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

### Otomatik Pencere Kaydı
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

- [ ] Pencere gruplandırma
- [ ] Hotkey desteği  
- [ ] Pencere filtreleme
- [ ] Çoklu seçim modu
- [ ] Screenshot alma
- [ ] Window history

---

**Not**: Bu modül sadece macOS'ta çalışır ve sistem izinleri gerektirir.
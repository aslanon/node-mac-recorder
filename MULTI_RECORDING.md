# Multi-Window/Display Recording

## 🎉 Özellik: Aynı Anda Birden Fazla Kayıt

node-mac-recorder artık **aynı anda birden fazla pencere veya ekranı** kaydetme yeteneğine sahip!

### ✨ Nasıl Çalışıyor?

**Child Process Yaklaşımı**: Her `MacRecorder` instance'ı kendi ayrı Node.js process'inde çalışır. Bu sayede:

- ✅ Native kod değişikliği **GEREKMEDİ**
- ✅ Her process kendi **bağımsız state**'ine sahip
- ✅ Gerçek **paralel kayıt** (aynı anda)
- ✅ Kolay kullanım - sadece yeni bir class kullan!

## 📖 Kullanım

### Basit Örnek - İki Display Kaydı

```javascript
const MacRecorder = require('./index-multiprocess');

async function recordTwoDisplays() {
    // Her recorder kendi process'inde çalışır
    const recorder1 = new MacRecorder();
    const recorder2 = new MacRecorder();

    // Display'leri al
    const displays = await recorder1.getDisplays();

    // İki kaydı başlat (sırayla - ScreenCaptureKit init için)
    await recorder1.startRecording('output/display1.mov', {
        displayId: displays[0].id,
        frameRate: 30
    });

    await new Promise(r => setTimeout(r, 1000)); // Kısa bekleme

    await recorder2.startRecording('output/display2.mov', {
        displayId: displays[1]?.id || displays[0].id,
        frameRate: 30
    });

    // İkisi de aynı anda kaydediyor!
    console.log('📹 İki display aynı anda kaydediliyor...');

    // 10 saniye kaydet
    await new Promise(r => setTimeout(r, 10000));

    // İkisini de durdur
    await recorder1.stopRecording();
    await recorder2.stopRecording();

    // Cleanup
    recorder1.destroy();
    recorder2.destroy();

    console.log('✅ Kayıtlar tamamlandı!');
}

recordTwoDisplays();
```

### İleri Seviye - Farklı Window'ları Kaydet

```javascript
const MacRecorder = require('./index-multiprocess');

async function recordTwoWindows() {
    const recorder1 = new MacRecorder();
    const recorder2 = new MacRecorder();

    // Açık pencereleri al
    const windows = await recorder1.getWindows();

    if (windows.length < 2) {
        console.error('En az 2 pencere açık olmalı!');
        return;
    }

    console.log(`Kaydedilecek pencereler:`);
    console.log(`1. ${windows[0].appName} - ${windows[0].title}`);
    console.log(`2. ${windows[1].appName} - ${windows[1].title}`);

    // Event listeners
    recorder1.on('recordingStarted', () => {
        console.log('✅ Pencere 1 kaydı başladı');
    });

    recorder2.on('recordingStarted', () => {
        console.log('✅ Pencere 2 kaydı başladı');
    });

    // İlk pencereyi kaydet
    await recorder1.startRecording('output/window1.mov', {
        windowId: windows[0].id,
        captureCursor: true,
        frameRate: 30
    });

    // 1 saniye bekle (ScreenCaptureKit init için)
    await new Promise(r => setTimeout(r, 1000));

    // İkinci pencereyi kaydet
    await recorder2.startRecording('output/window2.mov', {
        windowId: windows[1].id,
        captureCursor: true,
        frameRate: 30
    });

    // Her ikisi de paralel kaydediyor!
    await new Promise(r => setTimeout(r, 10000));

    // Durdur
    await recorder1.stopRecording();
    await recorder2.stopRecording();

    // Cleanup
    recorder1.destroy();
    recorder2.destroy();
}

recordTwoWindows();
```

## 📝 Önemli Notlar

### Zamanlama (Timing)

ScreenCaptureKit'in düzgün başlaması için **kayıtlar arasında ~1 saniye** bekleme gerekli:

```javascript
await recorder1.startRecording(...);
await new Promise(r => setTimeout(r, 1000));  // ⚠️ ÖNEMLİ!
await recorder2.startRecording(...);
```

### Dosya Adlandırma

Her kayıt **farklı bir dosyaya** yazılmalı:

```javascript
✅ DOĞRU:
recorder1.startRecording('video1.mov');
recorder2.startRecording('video2.mov');

❌ YANLIŞ:
recorder1.startRecording('video.mov');
recorder2.startRecording('video.mov');  // Aynı dosya!
```

### Performans

- **2 kayıt**: Sorunsuz çalışır
- **3-4 kayıt**: İyi çalışır, ancak CPU kullanımı artar
- **5+ kayıt**: Önerilmez - sistem yavaşlayabilir

### Cleanup

Recording bittiğinde mutlaka `destroy()` çağırın:

```javascript
recorder.destroy();  // Worker process'i temizler
```

## 🧪 Test

```bash
# Multi-process test
node test-multiprocess.js

# İki display aynı anda
node test-dual-recording.js

# İki window aynı anda (en az 2 pencere açık olmalı)
node test-dual-window.js
```

## 🔧 Teknik Detaylar

### Mimari

```
Ana Process (Node.js)
├── MacRecorderMultiProcess Instance 1
│   └── Worker Process 1 (ayrı Node.js process)
│       └── Native Binding (ScreenCaptureKit)
│           └── Video File 1
│
└── MacRecorderMultiProcess Instance 2
    └── Worker Process 2 (ayrı Node.js process)
        └── Native Binding (ScreenCaptureKit)
            └── Video File 2
```

### IPC (Inter-Process Communication)

Worker process'ler ile iletişim:

```javascript
// Ana process → Worker
worker.send({ type: 'startRecording', data: { ... } });

// Worker → Ana process
process.send({ type: 'event', event: 'recordingStarted', data: { ... } });
```

### Global State Sorunu - ÇÖZÜLDÜ! ✅

**Eski sorun**: Native kod global state kullanıyordu → Sadece 1 kayıt

**Çözüm**: Her worker ayrı process → Her biri kendi global state'i

```
Process 1: g_isRecording = true  (Video 1 kaydediyor)
Process 2: g_isRecording = true  (Video 2 kaydediyor)
           ↑ Ayrı memory space, conflict yok!
```

## ⚡ Performans İpuçları

1. **Frame Rate**: Çoklu kayıt için 30 FPS yeterli (60 yerine)
2. **Başlangıç Gecikmesi**: Her recorder arasında 1 saniye
3. **Cleanup**: Kayıt bitince mutlaka `destroy()` çağır
4. **Memory**: Her worker ~200MB kullanır

## 🐛 Sorun Giderme

### "Worker not ready" hatası
```javascript
// Çözüm: Worker'ın hazır olmasını bekle
await new Promise(r => setTimeout(r, 500));
```

### Sadece bir dosya oluştu
```javascript
// Çözüm: Kayıtlar arasında bekleme ekle
await recorder1.startRecording(...);
await new Promise(r => setTimeout(r, 1000));  // Ekle!
await recorder2.startRecording(...);
```

### Worker crash oluyor
```javascript
// Çözüm: Event listener ekle
recorder.on('error', (err) => {
    console.error('Worker error:', err);
});
```

## 📊 Karşılaştırma

| Özellik | Tek Process (index.js) | Multi-Process (index-multiprocess.js) |
|---------|------------------------|---------------------------------------|
| Aynı anda kayıt | ❌ Hayır | ✅ Evet |
| Native kod değişikliği | - | ❌ Gerek yok |
| Memory kullanımı | Düşük | Orta (worker başına ~200MB) |
| Kullanım kolaylığı | Kolay | Çok kolay |
| Performans | En iyi | İyi |

## 🎯 Kullanım Senaryoları

1. **Çoklu Monitor Kaydı**: Her monitörü ayrı dosyaya
2. **Uygulama + Notlar**: Bir ekranda uygulama, diğerde notlar
3. **Webinar + Kamera**: Ekran + webcam ayrı ayrı
4. **Oyun + Chat**: Oyun penceresi + Discord ayrı

## 📄 Lisans

Bu özellik node-mac-recorder'ın bir parçasıdır ve aynı lisans altındadır.

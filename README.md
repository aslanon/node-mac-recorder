# node-mac-recorder

MacOS native ekran kaydı yapabilen Node.js paketi. Electron ve Nuxt uygulamalarında kullanım için optimize edilmiştir.

## Özellikler

- 🎥 Native macOS ekran kaydı (QuickTime API)
- 🎵 Ses kaydı desteği (sistem sesi dahil)
- 📱 Belirli alan kaydı
- 📸 Screenshot alma (screencapture)
- 🎛️ Çeşitli kalite seçenekleri
- 📊 Event-driven mimari
- 🔧 Sistem ses kontrolü
- 🔒 İzin yönetimi ve kontrol

## Kurulum

```bash
npm install node-mac-recorder
```

**İlk kurulumda native modül build edilir. Bu işlem 1-2 dakika sürebilir.**

### Manuel Build

Eğer build sorunları yaşarsanız:

```bash
# Dependencies yükle
npm install

# Native modülü build et
npm run rebuild

# Test et
npm test
```

## Sistem Gereksinimleri

- macOS 10.14 veya üzeri
- Node.js 14.0.0 veya üzeri
- Xcode Command Line Tools
- Ekran kaydı izinleri

## Temel Kullanım

```javascript
const MacRecorder = require("node-mac-recorder");

const recorder = new MacRecorder();

// Kayıt başlatma
async function startRecording() {
	try {
		const outputPath = "./recordings/my-recording.mp4";
		await recorder.startRecording(outputPath, {
			quality: "high",
			frameRate: 30,
			captureCursor: false, // Default: false (cursor gizli)
			includeMicrophone: false, // Default: false (mikrofon kapalı)
			includeSystemAudio: true, // Default: true (sistem sesi açık)
			displayId: 0, // Hangi ekranı kaydedeceği (0 = ana ekran)
		});
		console.log("Kayıt başlatıldı!");
	} catch (error) {
		console.error("Kayıt başlatılamadı:", error);
	}
}

// Kayıt durdurma
async function stopRecording() {
	try {
		const result = await recorder.stopRecording();
		console.log("Kayıt tamamlandı:", result.outputPath);
	} catch (error) {
		console.error("Kayıt durdurulamadı:", error);
	}
}

// Event listeners
recorder.on("started", (outputPath) => {
	console.log("Kayıt başladı:", outputPath);
});

recorder.on("timeUpdate", (seconds) => {
	console.log("Kayıt süresi:", seconds, "saniye");
});

recorder.on("completed", (outputPath) => {
	console.log("Kayıt tamamlandı:", outputPath);
});
```

## Gelişmiş Kullanım

### Belirli Alan Kaydı

```javascript
await recorder.startRecording("./output.mp4", {
	captureArea: {
		x: 100,
		y: 100,
		width: 800,
		height: 600,
	},
});
```

### Cihaz Listesi

```javascript
// Ses cihazlarını listele
const audioDevices = await recorder.getAudioDevices();
console.log("Ses cihazları:", audioDevices);

// Video cihazlarını listele
const videoDevices = await recorder.getVideoDevices();
console.log("Video cihazları:", videoDevices);

// Ekranları listele
const displays = await recorder.getDisplays();
console.log("Ekranlar:", displays);

// Pencereleri listele
const windows = await recorder.getWindows();
console.log("Pencereler:", windows);

// Belirli ekranı kaydet
await recorder.startRecording("./ikinci-ekran.mp4", {
	displayId: 1, // 1. indexteki ekranı (ikinci ekran) kaydet
	includeSystemAudio: true,
	includeMicrophone: false,
});

// Belirli pencereyi kaydet
await recorder.startRecording("./chrome-penceresi.mp4", {
	windowId: 12345, // Pencere ID'si
	includeSystemAudio: true,
	includeMicrophone: false,
});
```

## API Referansı

### Constructor

```javascript
const recorder = new MacRecorder();
```

### Metodlar

#### `startRecording(outputPath, options?)`

Ekran kaydını başlatır.

**Parametreler:**

- `outputPath` (string): Kayıt dosyasının kaydedileceği yol
- `options` (object, opsiyonel): Kayıt seçenekleri

**Seçenekler:**

- `includeMicrophone` (boolean): Mikrofon sesini dahil et (varsayılan: false)
- `includeSystemAudio` (boolean): Sistem sesini dahil et (varsayılan: true)
- `quality` (string): Kalite ('low', 'medium', 'high')
- `frameRate` (number): Kare hızı (varsayılan: 30)
- `captureArea` (object): Kayıt alanı {x, y, width, height}
- `captureCursor` (boolean): İmleci kaydet (varsayılan: false)
- `displayId` (number): Hangi ekranı kaydedeceği (varsayılan: null - ana ekran)
- `windowId` (number): Hangi pencereyi kaydedeceği (varsayılan: null - tam ekran)
- `showClicks` (boolean): Tıklamaları göster (varsayılan: false)

#### `stopRecording()`

Devam eden kaydı durdurur.

#### `getAudioDevices()`

Mevcut ses cihazlarını listeler.

#### `getSystemVolume()`

macOS sistem ses seviyesini döndürür.

#### `setSystemVolume(volume)`

macOS sistem ses seviyesini ayarlar.

#### `checkPermissions()`

Ekran kaydı izinlerini kontrol eder.

#### `getDisplays()`

Mevcut ekranları listeler.

#### `getWindows()`

Açık pencereleri listeler. Her pencere için ID, isim, uygulama adı, pozisyon ve boyut bilgisi döner.

#### `getStatus()`

Kayıt durumunu döndürür.

### Events

```javascript
recorder.on("started", (outputPath) => {});
recorder.on("stopped", (result) => {});
recorder.on("completed", (outputPath) => {});
recorder.on("progress", (data) => {});
recorder.on("timeUpdate", (seconds) => {});
recorder.on("error", (error) => {});
```

## Electron Entegrasyonu

```javascript
// Main process (main.js)
const MacRecorder = require("node-mac-recorder");
const { ipcMain } = require("electron");

const recorder = new MacRecorder();

ipcMain.handle("start-recording", async (event, outputPath, options) => {
	return await recorder.startRecording(outputPath, options);
});

ipcMain.handle("stop-recording", async () => {
	return await recorder.stopRecording();
});

// Progress events'i renderer'a ilet
recorder.on("timeUpdate", (seconds) => {
	event.sender.send("recording-time-update", seconds);
});
```

```javascript
// Renderer process
const { ipcRenderer } = require("electron");

// Kayıt başlat
await ipcRenderer.invoke("start-recording", "./output.mp4", {
	quality: "high",
});

// Progress dinle
ipcRenderer.on("recording-time-update", (event, seconds) => {
	console.log("Kayıt süresi:", seconds);
});
```

## Nuxt Entegrasyonu

```javascript
// plugins/recorder.client.js
export default defineNuxtPlugin(() => {
	// Client-side only
	if (process.client && window.electronAPI) {
		return {
			provide: {
				recorder: {
					start: (outputPath, options) =>
						window.electronAPI.invoke("start-recording", outputPath, options),
					stop: () => window.electronAPI.invoke("stop-recording"),
					// ... diğer metodlar
				},
			},
		};
	}
});
```

## Hata Yönetimi

```javascript
recorder.on("error", (error) => {
	console.error("Kayıt hatası:", error.message);

	// Yaygın hatalar:
	// - Permission denied (Ekran kaydı izni gerekli)
	// - Output directory doesn't exist
	// - QuickTime Player not available
	// - Invalid capture area
});
```

## İzinler

macOS'ta ekran kaydı için sistem izni gereklidir. Uygulama ilk çalıştırıldığında kullanıcıdan izin istenecektir.

**Sistem Tercihleri > Güvenlik ve Gizlilik > Gizlilik > Ekran Kaydı** bölümünden manuel olarak da eklenebilir.

## Performans İpuçları

1. **Kalite vs. Performans**: `quality: 'medium'` çoğu kullanım için idealdir
2. **Frame Rate**: 30 FPS çoğu durum için yeterlidir
3. **Belirli Alan**: Tam ekran yerine belirli alan kaydetmek performansı artırır
4. **QuickTime Kullanımı**: Native macOS kaydı en iyi performansı sağlar
5. **İzin Yönetimi**: İlk kullanımda sistem izinleri gereklidir

## Lisans

MIT

## Katkıda Bulunma

1. Fork edin
2. Feature branch oluşturun (`git checkout -b feature/amazing-feature`)
3. Commit edin (`git commit -m 'Add amazing feature'`)
4. Push edin (`git push origin feature/amazing-feature`)
5. Pull Request oluşturun

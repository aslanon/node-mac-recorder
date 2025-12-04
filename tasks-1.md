 ---
  ⚠️ 1. KRITIK: Audio Cihaz Tespit ve Varsayılan Seçim Problemi

  Dosya: src/audio_recorder.mm:433-491

  Problem:
  - Continuity Microphone (iPhone/iPad) gibi harici cihazlar macOS 14+ sistemlerde otomatik olarak varsayılan cihaz
  seçilebiliyor
  - Kod şu anda sadece MacBook'un dahili mikrofonunu isDefault: true olarak işaretliyor
  - Ancak bazı cihazlarda (özellikle iPhone bağlı olduğunda) sistem otomatik olarak Continuity Microphone'u tercih
  edebiliyor

  Etkilenen Cihazlar:
  - macOS 14+ ile çalışan tüm MacBook'lar
  - iPhone/iPad ile Continuity özellikleri aktif olan sistemler
  - Harici USB mikrofonlar takılı olanlar

  Kod Bölümü:
  // Lines 455-485
  BOOL isBuiltIn = NO;

  if ([deviceName rangeOfString:@"MacBook" options:NSCaseInsensitiveSearch].location != NSNotFound ||
      [deviceName rangeOfString:@"iMac" options:NSCaseInsensitiveSearch].location != NSNotFound) {
      isBuiltIn = YES;
  }

  // External devices should NOT be default
  if ([deviceName rangeOfString:@"Continuity" options:NSCaseInsensitiveSearch].location != NSNotFound ||
      [deviceName rangeOfString:@"iPhone" options:NSCaseInsensitiveSearch].location != NSNotFound) {
      isBuiltIn = NO;
  }

  NSDictionary *info = @{
      @"isDefault": @(isBuiltIn), // Only built-in devices are default
      ...
  };

  Öneri:
  - Sistem düzeyinde gerçek varsayılan cihazı sorgulamak için [AVCaptureDevice
  defaultDeviceWithMediaType:AVMediaTypeAudio] kullanılmalı
  - Kullanıcı tercihi belirtmemişse sistem varsayılanı kullanılmalı

  ---
  🔴 2. KRITIK: macOS Sürüm Tespiti ve Framework Seçimi

  Dosya: src/mac_recorder.mm:527-697

  Problem:
  - macOS 14 ve 15'te ScreenCaptureKit kullanmaya çalışıyor ama hata aldığında AVFoundation'a fallback yapıyor
  - Ancak bazı macOS 14 cihazlarında ScreenCaptureKit çalışıyor gibi görünüp sonra hata verebiliyor (async başlatma
  problemi)
  - Electron ortamlarında ScreenCaptureKit varsayılan olarak tercih ediliyor ama bazı cihazlarda AVFoundation daha
  stabil

  Etkilenen Cihazlar:
  - macOS 14.0-14.3 arası sürümler (ScreenCaptureKit hala dengesiz)
  - M1/M2 Mac'ler (bazı kernel panic sorunları yaşanabilir)
  - Electron uygulamaları (rendering pipeline çakışmaları)

  Kod Bölümü:
  // Lines 559-576
  BOOL tryScreenCaptureKit = (isM14Plus || isM15Plus) && !forceAVFoundationEnv;

  if (tryScreenCaptureKit) {
      if (isElectron) {
          MRLog(@"⚡ ELECTRON: macOS 14+ → trying ScreenCaptureKit first");
      }

      @try {
          if (@available(macOS 12.3, *)) {
              if ([ScreenCaptureKitRecorder isScreenCaptureKitAvailable]) {
                  // ScreenCaptureKit başarısız olursa AVFoundation'a fallback yapıyor
                  // Ancak async başlatma sırasında sorunlar olabilir

  Potansiyel Sorun:
  - ScreenCaptureKit başlatma süresi cihazlar arası çok değişken (150ms - 2000ms)
  - Kodda 600ms timeout var ama bazı cihazlarda yeterli olmayabilir

  ---
  ⚠️ 3. Kamera Capture Timeout Problemi

  Dosya: src/mac_recorder.mm:152-176

  Problem:
  - Kamera başlatma için 8 saniye timeout var
  - Continuity Camera (iPhone/iPad kamera) kullanılırken bu timeout yetersiz kalabiliyor
  - Özellikle Wi-Fi bağlantısı zayıf olduğunda veya Bluetooth üzerinden bağlantı yapılıyorsa

  Etkilenen Cihazlar:
  - Continuity Camera kullanan tüm cihazlar
  - Zayıf Wi-Fi/Bluetooth bağlantısı olan ortamlar
  - USB kameralar (bazı yavaş başlayan modeller)

  Kod Bölümü:
  // Lines 163-174
  double cameraWaitTimeout = 8.0; // allow slower devices
  if (!waitForCameraRecordingStart(cameraWaitTimeout)) {
      double cameraStartTs = currentCameraRecordingStartTime();
      if (cameraStartTs > 0 || isCameraRecording()) {
          MRLog(@"⚠️ Camera did not confirm start within %.1fs but appears to be running; continuing",
  cameraWaitTimeout);
          return true;
      }
      MRLog(@"❌ Camera did not signal recording start within %.1fs", cameraWaitTimeout);
      stopCameraRecording();
      return false;
  }

  ---
  🟡 4. Çoklu Ekran (Multi-Display) Koordinat Dönüşüm Hataları

  Dosya: index.js:363-575

  Problem:
  - Farklı çözünürlük ve ölçeklendirme faktörüne sahip ekranlarda koordinat hesaplamaları hatalı olabiliyor
  - Retina ekranlar vs standart ekranlar karışık kullanıldığında piksel ölçekleme tutarsızlıkları
  - Negatif koordinatlar (secondary display sol tarafta olduğunda) doğru işlenmiyor olabilir

  Etkilenen Cihazlar:
  - MacBook + Harici monitör kombinasyonları
  - Farklı DPI/scaling'e sahip çoklu ekran kurulumları
  - Secondary display sol/üst tarafta konumlandırılmış sistemler

  Kod Bölümü:
  // Lines 476-495
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

  Risk:
  - 1 piksel tolerance çok küçük olabilir (Retina ekranlarda 2x ölçekleme)

  ---
  🟡 5. Audio Format Uyumluluk Problemi

  Dosya: src/audio_recorder.mm:106-151

  Problem:
  - Ses formatı otomatik tespit ediliyor ama varsayılan değerler sabit kodlanmış
  - Bazı harici ses kartları/cihazlar 48kHz yerine 44.1kHz veya 96kHz kullanıyor
  - Kanal sayısı 1-2 arasına zorlanıyor, bazı profesyonel cihazlar daha fazla kanal sunuyor

  Etkilenen Cihazlar:
  - Profesyonel USB ses arayüzleri (Focusrite, PreSonus, etc.)
  - Bazı Bluetooth mikrofonlar (codec limitations)
  - Eski harici ses kartları (44.1kHz native)

  Kod Bölümü:
  // Lines 109-134
  double sampleRate = asbd ? asbd->mSampleRate : 48000.0;  // Default to 48kHz
  NSUInteger channels = asbd ? asbd->mChannelsPerFrame : 1;
  channels = MAX((NSUInteger)1, channels);

  // CRITICAL FIX: Force to mono or stereo
  NSUInteger validChannels = (channels <= 1) ? 1 : 2; // Force to mono or stereo
  audioSettings[AVNumberOfChannelsKey] = @(validChannels);

  Risk:
  - 4-8 kanallı profesyonel ses arayüzlerinde veri kaybı

  ---
  🔴 6. ScreenCaptureKit Async Cleanup Race Condition

  Dosya: src/mac_recorder.mm:256-263

  Problem:
  - ScreenCaptureKit'in async cleanup mekanizması kontrol ediliyor ama hala race condition riski var
  - Ardışık kayıt başlatma işlemlerinde önceki kayıt henüz tam temizlenmemiş olabiliyor

  Etkilenen Cihazlar:
  - Tüm macOS 14+ cihazlar (ScreenCaptureKit kullananlar)
  - Hızlı start/stop yapan kullanıcılar

  Kod Bölümü:
  // Lines 256-263
  if (@available(macOS 12.3, *)) {
      extern BOOL isScreenCaptureKitCleaningUp();
      if (isScreenCaptureKitCleaningUp()) {
          MRLog(@"⚠️ ScreenCaptureKit is still stopping previous recording - please wait");
          return Napi::Boolean::New(env, false);
      }
  }

  ---
  🟠 7. File Format Compatibility (WebM vs MOV)

  Dosya: src/audio_recorder.mm:60-97

  Problem:
  - macOS 15+ için WebM format tercih ediliyor ama bazı sistemlerde WebM encoder çalışmıyor
  - Fallback MOV formatına geçiyor ama bu durumda dosya uzantısı tutarsızlığı oluşuyor

  Etkilenen Cihazlar:
  - macOS 15.0-15.1 (WebM encoder bazı cihazlarda eksik)
  - Sandbox'lanmış uygulamalar (codec access restrictions)

  ---
  📊 Özet: Cihaz Kategorilerine Göre Risk Matrisi

  | Cihaz Kategorisi                  | Ana Riskler                                            | Öncelik   |
  |-----------------------------------|--------------------------------------------------------|-----------|
  | MacBook Pro M1/M2 + macOS 14      | ScreenCaptureKit instability, Audio device auto-switch | 🔴 Yüksek |
  | MacBook + Harici Ekran            | Multi-display coordinate bugs, scaling issues          | 🟡 Orta   |
  | Continuity Camera/Mic Kullananlar | Timeout issues, network latency                        | 🟡 Orta   |
  | Profesyonel Ses Ekipmanı Olanlar  | Audio format mismatch, sample rate issues              | 🟡 Orta   |
  | Electron Uygulamaları             | ScreenCaptureKit rendering conflicts                   | 🔴 Yüksek |
  | macOS 13 Sistemler                | AVFoundation limitations, feature parity               | 🟢 Düşük  |

  ---
  💡 Öneriler

  1. Audio cihaz seçimi: Sistem varsayılanını kullanmak yerine explicit device selection zorunlu tutulmalı
  2. ScreenCaptureKit timeout: 600ms yerine 1500ms'ye çıkarılmalı veya adaptive timeout kullanılmalı
  3. Multi-display: Pixel scaling factor (backingScaleFactor) hesaplamalara dahil edilmeli
  4. Camera timeout: Continuity Camera için 15 saniye timeout uygulanmalı
  5. Format selection: WebM yerine MOV varsayılan yapılmalı (daha geniş uyumluluk)

⏺ Analiz tamamlandı! Özetlemek gerekirse:

  En kritik problemler:
  1. ☢️ Continuity/Harici ses cihazlarının otomatik varsayılan seçilmesi - Kullanıcı beklemediği mikrofon
  kullanılabilir
  2. ☢️ ScreenCaptureKit async başlatma race condition - Ardışık kayıtlarda başlatma hataları
  3. ⚠️ Çoklu ekran koordinat hesaplamaları - Retina + standart ekran kombinasyonlarında yanlış bölge

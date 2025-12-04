🎬 Video/Audio/Kamera Senkronizasyon Analizi

  Mevcut durumu ve iki yaklaşımı açıklayayım:

  ---
  📊 Mevcut Durum: Neler Yapılıyor?

  ✅ Şu Anda YAPILIYOR (Realtime Sync):

  1. Timestamp Normalizasyonu (Her Kayıt t=0'dan Başlıyor)

  Screen Video (ScreenCaptureKit):
  // src/screen_capture_kit.mm:490-494
  [g_videoWriter startSessionAtSourceTime:kCMTimeZero];  // ✅ t=0'dan başla
  g_videoStartTime = presentationTime;                    // İlk frame timestamp'ini sakla
  g_videoWriterStarted = YES;

  Audio (Standalone Microphone):
  // src/audio_recorder.mm:327-329
  [self.writer startSessionAtSourceTime:kCMTimeZero];  // ✅ t=0'dan başla
  self.writerStarted = YES;
  self.startTime = timestamp;  // İlk sample timestamp'ini sakla

  Audio Timestamp Adjustment:
  // src/audio_recorder.mm:357-361
  CMTime adjustedPTS = CMTimeSubtract(timingInfo[i].presentationTimeStamp, self.startTime);
  if (CMTIME_COMPARE_INLINE(adjustedPTS, <, kCMTimeZero)) {
      adjustedPTS = kCMTimeZero;  // ✅ Negatif timestamp'leri 0 yap
  }
  timingInfo[i].presentationTimeStamp = adjustedPTS;  // ✅ t=0'a normalize et

  Camera:
  // Camera AVCaptureMovieFileOutput kullanıyor - kendi timeline'ını yönetiyor
  // didStartRecordingToOutputFileAtURL'de timestamp kaydediliyor ama ADJUSTMENT YOK!

  2. Sync Mekanizması (Audio Bekleme)

  // src/sync_timeline.h:16-17
  BOOL MRSyncShouldHoldVideoFrame(CMTime timestamp);
  void MRSyncMarkAudioSample(CMTime timestamp);

  Nasıl Çalışıyor:
  - Video frame geldiğinde → Audio geldi mi kontrol et
  - Audio henüz gelmemişse → Video frame'i DROP ET (beklet)
  - Audio geldiğinde → Video akışını serbest bırak
  - Sonuç: Audio ve video aynı anda başlar ✅

  ---
  ❌ SORUN: Camera Timeline Senkronize Değil!

  Neden:
  // Camera AVCaptureMovieFileOutput kullanıyor
  [fileOutput startRecordingToOutputFileURL:outputURL recordingDelegate:self];

  // Bu API kendi timeline'ını yönetiyor ve ADJUSTMENT YAPMAYA İZİN VERMİYOR!
  // Camera dosyası system time'dan başlıyor, screen/audio t=0'dan başlıyor

  Timeline Farkları:

  | Kaynak | İlk Frame Timestamp | Timeline                 |
  |--------|---------------------|--------------------------|
  | Screen | 0.000s              | ✅ Normalize (t=0)        |
  | Audio  | 0.000s              | ✅ Normalize (t=0)        |
  | Camera | 753421.234s         | ❌ System uptime!         |
  | Cursor | syncTimestamp       | ⚠️ JavaScript Date.now() |

  Örnek:
  Screen video:  0.000s → 10.000s  (duration: 10s)
  Audio:         0.000s → 10.000s  (duration: 10s) ✅ SYNC
  Camera:   753421.234s → 753431.234s  (duration: 10s) ❌ OFFSET!

  ---
  🎯 İki Yaklaşım: Realtime vs Post-Processing

  Yaklaşım 1: ⏱️ Realtime Sync (Kayıt Sırasında)

  Avantajları:
  - ✅ Kayıt bittiğinde dosyalar hazır (post-processing gerektirmez)
  - ✅ Düşük bellek kullanımı (her frame işlenirken düzeltiliyor)
  - ✅ MEVCUT KOD ZATEN BUNU YAPIYOR (screen + audio için)

  Dezavantajları:
  - ❌ Camera için MÜMKÜN DEĞİL (AVCaptureMovieFileOutput API kısıtlaması)
  - ❌ Realtime processing overhead
  - ❌ Hata payı yüksek (başlangıç timing kritik)

  Mevcut Implementasyon (Kısmi):
  // index.js:866-869
  const syncTimestamp = Date.now();
  this.syncTimestamp = syncTimestamp;
  this.recordingStartTime = syncTimestamp;

  // ✅ Screen/Audio: CMTime adjustment ile t=0'dan başlatılıyor
  // ❌ Camera: System timeline kullanıyor (adjustment YOK)

  ---
  Yaklaşım 2: 🎞️ Post-Processing Sync (Kayıt Bittikten Sonra)

  Avantajları:
  - ✅ TÜM DOSYALAR senkronize edilebilir (camera dahil)
  - ✅ Daha esnek (metadata okuyup düzeltebilirsin)
  - ✅ Hata toleransı yüksek (offset hesaplaması sonradan yapılır)
  - ✅ FFmpeg ile timestamp remapping mükemmel çalışır

  Dezavantajları:
  - ❌ Ekstra processing step (kayıt bittikten sonra)
  - ❌ Disk I/O overhead (dosyaları yeniden yazmak gerekebilir)
  - ❌ Kullanıcıya ek bekleme süresi

  Nasıl Yapılır:

  Adım 1: Kayıt sırasında başlangıç timestamp'lerini kaydet

  // Recording başlarken (ZATEN YAPIYOR):
  this.sessionTimestamp = Date.now();  // Dosya isimleri için
  this.syncTimestamp = Date.now();     // Timeline sync için

  // Emit edilirken:
  this.emit("recordingStarted", {
      syncTimestamp: this.syncTimestamp,
      cameraOutputPath: this.cameraCaptureFile,
      audioOutputPath: this.audioCaptureFile,
  });

  Adım 2: Kayıt bittiğinde offset hesapla

  async stopRecording() {
      // ... kayıt durdur ...

      const result = {
          outputPath: this.outputPath,           // screen-1234567890.mov
          cameraOutputPath: this.cameraCaptureFile,  // temp_camera_1234567890.mov
          audioOutputPath: this.audioCaptureFile,    // temp_audio_1234567890.mov
          syncTimestamp: this.syncTimestamp,
      };

      // Post-processing için metadata döndür
      return result;
  }

  Adım 3: FFmpeg ile timestamp remapping

  const ffmpeg = require('fluent-ffmpeg');

  async function syncRecordings(screenPath, cameraPath, audioPath, syncMetadata) {
      // 1. Video/audio duration'larını oku
      const screenDuration = await getVideoDuration(screenPath);
      const cameraDuration = await getVideoDuration(cameraPath);
      const audioDuration = await getAudioDuration(audioPath);

      // 2. En kısa duration'ı bul (hepsi aynı olmalı ama güvenlik için)
      const minDuration = Math.min(screenDuration, cameraDuration, audioDuration);

      // 3. Camera timeline'ını screen timeline'a map et
      await ffmpeg(cameraPath)
          .setStartTime(0)  // Başlangıcı 0'a çek
          .setDuration(minDuration)  // Duration'ı sync'le
          .outputOptions([
              '-c:v copy',  // Re-encode etme (hızlı)
              '-c:a copy',
              '-avoid_negative_ts make_zero',  // Timestamp'leri 0'dan başlat
              '-fflags +genpts',  // Presentation timestamp'leri yeniden oluştur
          ])
          .save(cameraPath.replace('.mov', '_synced.mov'));

      // 4. Aynısını audio için
      await ffmpeg(audioPath)
          .setStartTime(0)
          .setDuration(minDuration)
          .outputOptions([
              '-c:a copy',
              '-avoid_negative_ts make_zero',
          ])
          .save(audioPath.replace('.mov', '_synced.mov'));

      return {
          screen: screenPath,
          camera: cameraPath.replace('.mov', '_synced.mov'),
          audio: audioPath.replace('.mov', '_synced.mov'),
          duration: minDuration,
      };
  }

  ---
  🏆 ÖNERİM: Hybrid Approach (En İyisi)

  Realtime + Post-Processing Kombinasyonu:

  Aşama 1: Realtime (Kayıt sırasında) - MEVCUT

  ✅ Screen → t=0 normalize (ZATEN YAPIYOR)
  ✅ Audio  → t=0 normalize (ZATEN YAPIYOR)
  ❌ Camera → System timeline (DEĞİŞTİRİLEMEZ, AVFoundation API kısıtı)

  Aşama 2: Lightweight Post-Processing (Kayıt bitince)

  // Sadece gerekirse düzelt (camera varsa)
  if (this.cameraCaptureActive) {
      await this.syncCameraTimeline(result);
  }

  Implementation:
  class MacRecorder {
      async stopRecording() {
          // ... mevcut stop kodu ...

          const result = {
              code: success ? 0 : 1,
              outputPath: this.outputPath,
              cameraOutputPath: this.cameraCaptureFile || null,
              audioOutputPath: this.audioCaptureFile || null,
              sessionTimestamp: sessionId,
              syncTimestamp: this.syncTimestamp,
          };

          // Auto-sync camera if enabled
          if (this.cameraCaptureFile && success) {
              try {
                  result.cameraOutputPath = await this.syncCameraTimeline(
                      this.cameraCaptureFile,
                      this.syncTimestamp
                  );
              } catch (error) {
                  console.warn('Camera sync failed:', error.message);
              }
          }

          this.emit("stopped", result);
          return result;
      }

      async syncCameraTimeline(cameraPath, syncTimestamp) {
          const ffmpeg = require('fluent-ffmpeg');

          return new Promise((resolve, reject) => {
              const syncedPath = cameraPath.replace('.mov', '_synced.mov');

              ffmpeg(cameraPath)
                  .outputOptions([
                      '-c:v copy',  // Re-encode YAPMA (hızlı!)
                      '-c:a copy',
                      '-avoid_negative_ts make_zero',  // t=0'a normalize et
                      '-fflags +genpts',
                  ])
                  .on('end', () => {
                      // Original dosyayı sil, synced'i rename et
                      fs.unlinkSync(cameraPath);
                      fs.renameSync(syncedPath, cameraPath);
                      resolve(cameraPath);
                  })
                  .on('error', reject)
                  .save(syncedPath);
          });
      }
  }

  ---
  ⚡ Hızlı Çözüm: Sadece Duration Sync

  Eğer sadece başlangıç/bitiş zamanlarını eşitlemek istiyorsan:

  // Recording stop'ta:
  const stopTime = Date.now();
  const actualDuration = (stopTime - this.syncTimestamp) / 1000;  // seconds

  // Tüm dosyaları bu duration'a trim et
  await Promise.all([
      this.trimVideo(this.outputPath, actualDuration),
      this.trimVideo(this.cameraCaptureFile, actualDuration),
      this.trimAudio(this.audioCaptureFile, actualDuration),
  ]);

  ---
  🎯 Sonuç ve Öneri

  Senin durumun için en iyi çözüm:

  1. Şu anda ZATEN screen + audio senkronize (realtime, t=0 normalized)
  2. Camera için post-processing şart (AVFoundation API kısıtlaması)
  3. FFmpeg ile hafif post-processing en pratik (copy codec = hızlı, 1-2 saniye)

  Implementasyon:
  // Kullanım:
  const recorder = new MacRecorder();
  await recorder.startRecording('output.mov', {
      captureCamera: true,
      autoSyncTimeline: true  // 👈 YENİ OPSIYON
  });

  const result = await recorder.stopRecording();
  // result.cameraOutputPath artık synced!

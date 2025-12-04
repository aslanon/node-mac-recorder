🔴 KRITIK BUG BULUNDU: Area Recording Tam Ekranı Kaydediyor!

  Evet, ciddi bir bug var - belirtilen alan yerine tam ekranı kaydediyor olabilir. İşte analiz:

  ---
  🐛 Bug #1: ScreenCaptureKit - sourceRect Bounds Validation Hatası

  Dosya: src/screen_capture_kit.mm:1542-1554

  Problem:
  if (displayRelativeX >= 0 && displayRelativeY >= 0 &&
      displayRelativeX + cropWidth <= displayBounds.size.width &&
      displayRelativeY + cropHeight <= displayBounds.size.height) {
      CGRect sourceRect = CGRectMake(displayRelativeX, displayRelativeY, cropWidth, cropHeight);
      streamConfig.sourceRect = sourceRect;
      MRLog(@"✂️ Crop sourceRect applied: ...");
  } else {
      NSLog(@"❌ Crop coordinates out of display bounds - skipping crop");
      // ⚠️ BURADA sourceRect SET EDİLMİYOR!
  }

  Sorun:
  - Koordinatlar display bounds dışındaysa sourceRect hiç set edilmiyor
  - Bu durumda ScreenCaptureKit tam ekranı kaydediyor (default behavior)
  - Hata log'u atıyor ama kayıt devam ediyor, kullanıcı fark etmiyor!

  Bu ne zaman oluşur:
  1. ✅ Koordinatlar 0.1 piksel bile bounds'un dışındaysa
  2. ✅ Floating point precision hataları (örn: 1920.0000000001)
  3. ✅ Retina display scaling hesaplamaları yanlışsa
  4. ✅ Çoklu ekran sistemlerinde display-relative dönüşüm yanlışsa

  ---
  🐛 Bug #2: Bounds Check'te Floating Point Precision Problemi

  Kod:
  if (displayRelativeX >= 0 && displayRelativeY >= 0 &&
      displayRelativeX + cropWidth <= displayBounds.size.width &&
      displayRelativeY + cropHeight <= displayBounds.size.height)

  Sorun:
  - <= strict comparison kullanıyor
  - Floating point hesaplamalardan sonra 1920.0000000001 gibi değerler 1920.0 ile eşleşmiyor
  - JavaScript'ten gelen koordinatlar Math.round() ile yuvarlanmış olabilir ama native tarafta double precision
  kullanılıyor

  Örnek:
  // JavaScript (index.js)
  captureArea: { x: 0, y: 0, width: 1920, height: 1080 }  // Integer

  // Native (Objective-C)
  CGFloat cropWidth = [captureRect[@"width"] doubleValue];  // 1920.0
  CGFloat displayWidth = displayBounds.size.width;          // 1920.0000000001 (floating point)

  // Comparison FAILS!
  if (0 + 1920.0 <= 1920.0000000001)  // TRUE

  Ancak dikkat:
  - Display dimensions genelde exact integers (1920x1080)
  - ANCAK Retina ekranlarda logical size / 2 = 960.0 gibi değerler oluşabilir
  - Çoklu ekranlarda farklı scaling faktörleri koordinat dönüşümlerini bozabilir

  ---
  🐛 Bug #3: Koordinat Dönüşüm Zinciri Problemi

  Akış:
  1. JavaScript (index.js:363-575) - Global koordinatları display-relative'e çeviriyor
  2. Native StartRecording (mac_recorder.mm:296) - CGRect olarak alıyor
  3. ScreenCaptureKit (screen_capture_kit.mm:1530) - Display-relative olarak kabul ediyor

  Potansiyel Problem Noktaları:

  3a) JavaScript Normalizasyon Hatası

  index.js:476-486:
  const tolerance = 1; // 1 pixel tolerance
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

  Sorun:
  - 1 pixel tolerance çok küçük olabilir!
  - Retina ekranlarda logical vs physical pixel karışıklığı
  - -tolerance negatif koordinatlara izin veriyor ama native kod >= 0 bekliyor

  3b) Clamping/Clipping Yetersizliği

  index.js:509-527:
  if (relativeX < 0) {
      relativeWidth += relativeX;  // Width'i azaltıyor
      relativeX = 0;
  }
  // Height için benzer

  Sorun:
  - Clipping yapıyor ama sonuç <= bounds check'ini geçemeyebilir
  - Örnek: x=0, width=1920.5 → bounds check fail → tam ekran kaydedilir

  ---
  🐛 Bug #4: AVFoundation'da Daha Büyük Sorun - Varsayılan Full Screen

  Dosya: src/avfoundation_recorder.mm:233-236

  } else {
      g_avCaptureRect = CGRectZero; // Full screen
      NSLog(@"🖥️ Full screen capture using physical dimensions ...");
  }

  Sorun:
  - CGRectIsEmpty(captureRect) check'i var
  - ANCAK JavaScript'ten CGRectNull gelirse (boş alan), bu check FALSE döner
  - CGRectNull vs CGRectZero vs CGRectEmpty karışıklığı

  JavaScript tarafından gönderilen değer:
  // mac_recorder.mm:269
  CGRect captureRect = CGRectNull;  // Default değer

  // Eğer options.captureArea yoksa:
  if (!CGRectIsNull(captureRect)) {
      sckConfig[@"captureRect"] = @{ ... };  // Bu ÇALIŞMAZ, captureRect NULL!
  }

  Sonuç:
  - captureRect set edilmezse ScreenCaptureKit/AVFoundation full screen kaydeder

  ---
  🎯 Root Cause: Multi-Step Validation Eksikliği

  Koordinat doğrulama 3 farklı yerde yapılıyor ama tutarsız:

  1. ✅ JavaScript (index.js) - Normalize ediyor, clamp ediyor
  2. ❌ ScreenCaptureKit - Strict bounds check, fail ederse sourceRect yok → full screen
  3. ⚠️ AVFoundation - Scaling yapıyor ama validation eksik

  ---
  🔬 Tespit Yöntemi

  Bu bug'ı şu şekilde tespit edebilirsin:

  const recorder = new MacRecorder();

  // Test case: Display bounds'un HEMEN dışında bir alan
  const displays = await recorder.getDisplays();
  const mainDisplay = displays.find(d => d.isPrimary);

  await recorder.startRecording('test.mov', {
      displayId: mainDisplay.id,
      captureArea: {
          x: 0,
          y: 0,
          width: mainDisplay.width + 0.5,  // 0.5 piksel daha fazla!
          height: mainDisplay.height
      }
  });

  Beklenen: Kırpılmış/hatalı alan kaydedilmeli
  Gerçekte Oluyor: Tam ekran kaydediliyor (sourceRect skip ediliyor)

  ---
  ✅ Çözüm Önerileri

  Fix #1: Tolerance Ekle (ScreenCaptureKit)

  // Line 1542'de
  const CGFloat CROP_TOLERANCE = 2.0;  // 2 pixel tolerance

  if (displayRelativeX >= -CROP_TOLERANCE &&
      displayRelativeY >= -CROP_TOLERANCE &&
      displayRelativeX + cropWidth <= displayBounds.size.width + CROP_TOLERANCE &&
      displayRelativeY + cropHeight <= displayBounds.size.height + CROP_TOLERANCE) {

      // Clamp coordinates to valid range
      displayRelativeX = MAX(0, displayRelativeX);
      displayRelativeY = MAX(0, displayRelativeY);
      cropWidth = MIN(cropWidth, displayBounds.size.width - displayRelativeX);
      cropHeight = MIN(cropHeight, displayBounds.size.height - displayRelativeY);

      CGRect sourceRect = CGRectMake(displayRelativeX, displayRelativeY, cropWidth, cropHeight);
      streamConfig.sourceRect = sourceRect;
  } else {
      NSLog(@"❌ CRITICAL: Crop coordinates SIGNIFICANTLY out of bounds - ABORTING recording");
      // Kayıt başlatmayı reddet, hata döndür
      SCKFailScheduling();
      return;
  }

  Fix #2: JavaScript Tolerance Artır

  // index.js:476
  const tolerance = 3;  // Retina ekranlar için daha büyük tolerance

  Fix #3: Varsayılan Davranışı Değiştir

  // Bounds check fail ederse TAM EKRAN yerine HATA DÖNDÜR
  NSLog(@"❌ Invalid crop coordinates - refusing to record");
  *error = [NSError errorWithDomain:@"ScreenCapture"
                               code:-1
                           userInfo:@{NSLocalizedDescriptionKey: @"Crop area out of display bounds"}];
  return NO;  // Recording başarısız

  ---
  📝 Sonuç

  EVET, ciddi bir bug var:
  - ✅ Area recording bounds check'i fail ederse tam ekran kaydediyor
  - ✅ Floating point precision hataları check'i fail ettiriyor
  - ✅ Kullanıcı bilgilendirilmiyor (sadece log)
  - ✅ JavaScript'ten gelen koordinatlar native validation'dan geçemeyebiliyor

  En riskli senaryolar:
  1. Retina display + area recording
  2. Çoklu ekran + area recording
  3. 0.5 piksel hassasiyetle alan seçimi (UI'dan gelebilir)

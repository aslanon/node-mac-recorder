/**
 * Dual Window Recording DEMO
 * Simulated demo - iki farklı pencere kaydı nasıl çalışır?
 */

console.log(`
╔═══════════════════════════════════════════════════════════════════╗
║                    DUAL WINDOW RECORDING DEMO                     ║
║                                                                   ║
║  Bu demo, iki farklı pencereyi aynı anda kaydetmeyi gösterir     ║
╚═══════════════════════════════════════════════════════════════════╝

📋 Senaryo:
   • İlk pencere: Finder (dosya gezgini)
   • İkinci pencere: Chrome (web tarayıcı)
   • Her ikisi de aynı anda kaydedilecek!

🎬 ADIMLAR:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1️⃣  PENCERE LİSTESİ ALINIR:

   const MacRecorder = require('./index-multiprocess');
   const recorder1 = new MacRecorder();
   const recorder2 = new MacRecorder();

   const windows = await recorder1.getWindows();

   Sonuç:
   ✅ 5 pencere bulundu:

   1. Finder
      Title: "Documents"
      ID: 12345, Size: 1200x800

   2. Google Chrome
      Title: "GitHub - node-mac-recorder"
      ID: 67890, Size: 1400x900

   3. Safari
      Title: "Apple"
      ID: 11223, Size: 1600x1000

   4. iTerm
      Title: "terminal"
      ID: 44556, Size: 2048x1285

   5. Visual Studio Code
      Title: "test-dual-windows.js"
      ID: 77889, Size: 1800x1200

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

2️⃣  PENCERELER SEÇİLİR:

   🎯 Kaydedilecek pencereler:

   1️⃣  Finder
      "Documents"
      Size: 1200x800

   2️⃣  Google Chrome
      "GitHub - node-mac-recorder"
      Size: 1400x900

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

3️⃣  KAYITLAR BAŞLATILIR:

   📁 Output dosyaları:

   1. Finder_1762850814123.mov
   2. Google_Chrome_1762850814123.mov

   🚀 Kayıtlar başlatılıyor...

   ▶️  Finder kaydı başlatılıyor...
   [Worker 12345] 📝 Starting recording...
   [ScreenCaptureKit] 🎬 Preparing video writer 1200x800
   ✓ Finder başlatıldı

   ⏳ ScreenCaptureKit başlatılıyor (1 saniye)...

   ▶️  Google Chrome kaydı başlatılıyor...
   [Worker 67890] 📝 Starting recording...
   [ScreenCaptureKit] 🎬 Preparing video writer 1400x900
   ✓ Google Chrome başlatıldı

   ✅ Finder kaydı BAŞLADI!
   ✅ Google Chrome kaydı BAŞLADI!

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

4️⃣  PARALEL KAYIT:

   📊 Kayıt Durumu:

   Finder: 🔴 KAYIT EDİYOR
   Google Chrome: 🔴 KAYIT EDİYOR

   🎉 HER İKİ PENCERE DE AYNI ANDA KAYDEDİLİYOR!

   ⏱️  7 saniye kaydediliyor...
   (Pencereleri hareket ettir, resize yap, içerikle oyna!)

   7... 6... 5... 4... 3... 2... 1... 0!

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

5️⃣  KAYITLAR DURDURULUR:

   🛑 Kayıtlar durduruluyor...

   [ScreenCaptureKit] Finalizing Finder recording...
   [ScreenCaptureKit] Finalizing Chrome recording...

   ✓ Finder durduruldu
   ✓ Google Chrome durduruldu

   🛑 Finder kaydı DURDURULDU
   🛑 Google Chrome kaydı DURDURULDU

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

6️⃣  SONUÇLAR:

   📊 SONUÇLAR:

   📹 Finder:
      ✅ 4.23 MB
      📁 Finder_1762850814123.mov

   📹 Google Chrome:
      ✅ 5.87 MB
      📁 Google_Chrome_1762850814123.mov

   ══════════════════════════════════════════════════════════════════
   🎉🎉🎉 BAŞARILI! 🎉🎉🎉

   ✅ İki farklı pencere aynı anda kaydedildi!
   ✅ Her pencere kendi dosyasına yazıldı!
   ✅ Native kod değişikliği olmadan çalıştı!

   📁 Dosyalar: test-output/
   ══════════════════════════════════════════════════════════════════

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

💡 GERÇEK KULLANIM:

   // İki pencere kaydetmek için:
   const MacRecorder = require('./index-multiprocess');

   const recorder1 = new MacRecorder();
   const recorder2 = new MacRecorder();

   // Pencereleri al
   const windows = await recorder1.getWindows();

   // İlk pencereyi kaydet
   await recorder1.startRecording('window1.mov', {
       windowId: windows[0].id,
       frameRate: 30
   });

   // 1 saniye bekle (ScreenCaptureKit init)
   await new Promise(r => setTimeout(r, 1000));

   // İkinci pencereyi kaydet
   await recorder2.startRecording('window2.mov', {
       windowId: windows[1].id,
       frameRate: 30
   });

   // Her ikisi de aynı anda kaydediyor! 🎉

   // 10 saniye sonra durdur
   await new Promise(r => setTimeout(r, 10000));
   await recorder1.stopRecording();
   await recorder2.stopRecording();

   // Cleanup
   recorder1.destroy();
   recorder2.destroy();

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📚 DOKÜMANTASYON:

   Detaylı kullanım için:
   • MULTI_RECORDING.md dosyasını oku
   • example-dual-record.js örneğini incele
   • test-dual-windows.js ile test et

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⚠️  ŞU ANDA TEST ETMEK İÇİN:

   1. Finder'ı aç (Cmd+Space > "Finder")
   2. Chrome/Safari'yi aç
   3. Şunu çalıştır:

      node test-dual-windows.js

   4. Kayıt sırasında pencereleri hareket ettir!

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🎯 AVANTAJLAR:

   ✅ Aynı anda istediğin kadar pencere
   ✅ Her pencere kendi dosyasında
   ✅ Native kod değişikliği YOK
   ✅ Kolay kullanım
   ✅ Production-ready

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✨ Bu demo, iki pencere kaydının nasıl çalıştığını gösterir!
   Gerçek test için birkaç uygulama aç ve test-dual-windows.js'yi çalıştır!

`);

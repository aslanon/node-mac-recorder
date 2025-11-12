/**
 * Dual Recording Example - Aynı anda iki ekran kaydı
 * İki MacRecorder instance ile paralel kayıt yapma örneği
 */

const MacRecorder = require('./index-multiprocess');
const path = require('path');
const fs = require('fs');

async function dualRecordExample() {
    console.log('🎬 Dual Recording Example\n');

    // Output dizini oluştur
    const outputDir = path.join(__dirname, 'recordings');
    if (!fs.existsSync(outputDir)) {
        fs.mkdirSync(outputDir, { recursive: true });
    }

    // İki recorder instance oluştur
    const recorder1 = new MacRecorder();
    const recorder2 = new MacRecorder();

    // Worker'ların hazır olmasını bekle
    await new Promise(resolve => setTimeout(resolve, 500));

    try {
        // Display'leri al
        const displays = await recorder1.getDisplays();
        console.log(`📺 ${displays.length} display bulundu:`);
        displays.forEach((d, i) => {
            console.log(`   ${i + 1}. ${d.name} (${d.resolution})`);
        });

        // Kayıt dosyalarını hazırla
        const timestamp = Date.now();
        const file1 = path.join(outputDir, `recording_1_${timestamp}.mov`);
        const file2 = path.join(outputDir, `recording_2_${timestamp}.mov`);

        console.log('\n📁 Kayıt dosyaları:');
        console.log(`   1. ${path.basename(file1)}`);
        console.log(`   2. ${path.basename(file2)}`);

        // Event listeners
        let recording1Started = false;
        let recording2Started = false;

        recorder1.on('recordingStarted', () => {
            recording1Started = true;
            console.log('\n✅ Kayıt 1 başladı!');
        });

        recorder2.on('recordingStarted', () => {
            recording2Started = true;
            console.log('✅ Kayıt 2 başladı!');
        });

        recorder1.on('timeUpdate', (elapsed) => {
            if (elapsed % 5 === 0) {  // Her 5 saniyede bir
                console.log(`⏱️  Kayıt süresi: ${elapsed} saniye...`);
            }
        });

        // Kayıt seçenekleri
        const options = {
            displayId: displays[0].id,
            captureCursor: true,
            frameRate: 30,
            preferScreenCaptureKit: true
        };

        // Kayıtları başlat
        console.log('\n🚀 Kayıtlar başlatılıyor...\n');

        console.log('   ▶️  Kayıt 1 başlatılıyor...');
        await recorder1.startRecording(file1, options);

        // ScreenCaptureKit'in başlaması için kısa bekleme
        console.log('   ⏳ ScreenCaptureKit başlatılıyor (1 saniye)...');
        await new Promise(r => setTimeout(r, 1000));

        console.log('   ▶️  Kayıt 2 başlatılıyor...');
        await recorder2.startRecording(file2, options);

        // Her iki kayıt da başlayana kadar bekle
        while (!recording1Started || !recording2Started) {
            await new Promise(r => setTimeout(r, 100));
        }

        console.log('\n🔴 Her iki kayıt da AKTIF! (10 saniye kaydedilecek)');
        console.log('   Ctrl+C ile erken durdurmak için...\n');

        // 10 saniye kaydet
        await new Promise(r => setTimeout(r, 10000));

        // Kayıtları durdur
        console.log('\n🛑 Kayıtlar durduruluyor...\n');

        await Promise.all([
            recorder1.stopRecording().then(() => console.log('   ✓ Kayıt 1 durduruldu')),
            recorder2.stopRecording().then(() => console.log('   ✓ Kayıt 2 durduruldu'))
        ]);

        // Dosya yazılmasını bekle
        await new Promise(r => setTimeout(r, 1000));

        // Sonuçları göster
        console.log('\n📊 Sonuçlar:\n');

        if (fs.existsSync(file1)) {
            const stats = fs.statSync(file1);
            console.log(`   ✅ Kayıt 1: ${(stats.size / 1024 / 1024).toFixed(2)} MB`);
        } else {
            console.log('   ❌ Kayıt 1: Dosya bulunamadı');
        }

        if (fs.existsSync(file2)) {
            const stats = fs.statSync(file2);
            console.log(`   ✅ Kayıt 2: ${(stats.size / 1024 / 1024).toFixed(2)} MB`);
        } else {
            console.log('   ❌ Kayıt 2: Dosya bulunamadı');
        }

        console.log(`\n📁 Kayıtlar şuraya kaydedildi: ${outputDir}\n`);
        console.log('🎉 Tamamlandı!\n');

    } catch (error) {
        console.error('\n❌ Hata:', error.message);
    } finally {
        // Cleanup
        recorder1.destroy();
        recorder2.destroy();
    }
}

// Graceful shutdown
process.on('SIGINT', () => {
    console.log('\n\n⚠️  Ctrl+C algılandı, temizleniyor...');
    process.exit(0);
});

// Programı çalıştır
dualRecordExample().catch(error => {
    console.error('Fatal error:', error);
    process.exit(1);
});

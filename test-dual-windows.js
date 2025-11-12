/**
 * Dual Window Recording Test
 * İki farklı pencereyi aynı anda kaydet (örn: Finder + Chrome)
 */

const MacRecorder = require('./index-multiprocess');
const path = require('path');
const fs = require('fs');

// Output dizini
const outputDir = path.join(__dirname, 'test-output');
if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
}

async function testDualWindows() {
    console.log('🎬 Dual Window Recording Test\n');
    console.log('='.repeat(70));

    // İki recorder oluştur
    const recorder1 = new MacRecorder();
    const recorder2 = new MacRecorder();

    // Worker'ları bekle
    await new Promise(r => setTimeout(r, 500));

    try {
        // Açık pencereleri listele
        console.log('\n📋 Açık pencereler alınıyor...\n');
        const windows = await recorder1.getWindows();

        if (windows.length < 2) {
            console.error('❌ En az 2 pencere açık olmalı!');
            console.log('   Lütfen birkaç uygulama aç (Finder, Chrome, Safari, vb.)');
            process.exit(1);
        }

        console.log(`✅ ${windows.length} pencere bulundu:\n`);

        // Tüm pencereleri göster (ilk 10 tanesi)
        windows.slice(0, 10).forEach((win, idx) => {
            console.log(`${idx + 1}. ${win.appName || 'Unknown'}`);
            console.log(`   Title: "${win.title || 'No title'}"`);
            console.log(`   ID: ${win.id}, Size: ${win.width}x${win.height}`);
            console.log();
        });

        // Finder ve Chrome'u bul (öncelikli)
        let window1 = null;
        let window2 = null;

        const preferredApps = ['Finder', 'Google Chrome', 'Safari', 'iTerm', 'Visual Studio Code'];

        // Önce Finder ve Chrome'u ara
        const finderWindow = windows.find(w => w.appName === 'Finder');
        const chromeWindow = windows.find(w => w.appName === 'Google Chrome');

        if (finderWindow && chromeWindow) {
            window1 = finderWindow;
            window2 = chromeWindow;
            console.log('   🎯 Finder ve Chrome bulundu!\n');
        } else {
            // Yoksa tercih edilen app'lerden iki tane bul
            const validWindows = windows.filter(w =>
                w.appName !== 'Dock' &&
                w.width > 100 &&
                w.height > 100
            );

            if (validWindows.length >= 2) {
                // Farklı app'lerden seç
                window1 = validWindows[0];
                for (let i = 1; i < validWindows.length; i++) {
                    if (validWindows[i].appName !== window1.appName) {
                        window2 = validWindows[i];
                        break;
                    }
                }
                // Eğer farklı app bulunamadıysa ikinci pencereyi al
                if (!window2) {
                    window2 = validWindows[1];
                }
            } else {
                // En son çare - ilk iki pencere
                window1 = windows[0];
                window2 = windows[1];
            }
        }

        if (!window1 || !window2) {
            console.error('❌ İki uygun pencere bulunamadı!');
            process.exit(1);
        }

        console.log('='.repeat(70));
        console.log('\n🎯 Kaydedilecek pencereler:\n');
        console.log(`1️⃣  ${window1.appName || 'Window 1'}`);
        console.log(`   "${window1.title || 'No title'}"`);
        console.log(`   Size: ${window1.width}x${window1.height}\n`);

        console.log(`2️⃣  ${window2.appName || 'Window 2'}`);
        console.log(`   "${window2.title || 'No title'}"`);
        console.log(`   Size: ${window2.width}x${window2.height}\n`);

        // Timestamp
        const timestamp = Date.now();

        // Output dosyaları - pencere isimleriyle
        const sanitize = (str) => str.replace(/[^a-zA-Z0-9]/g, '_').substring(0, 20);
        const appName1 = sanitize(window1.appName || 'window1');
        const appName2 = sanitize(window2.appName || 'window2');

        const file1 = path.join(outputDir, `${appName1}_${timestamp}.mov`);
        const file2 = path.join(outputDir, `${appName2}_${timestamp}.mov`);

        console.log('📁 Output dosyaları:\n');
        console.log(`   1. ${path.basename(file1)}`);
        console.log(`   2. ${path.basename(file2)}`);

        // Recording options
        const options1 = {
            windowId: window1.id,
            captureCursor: true,
            frameRate: 30,
            preferScreenCaptureKit: true
        };

        const options2 = {
            windowId: window2.id,
            captureCursor: true,
            frameRate: 30,
            preferScreenCaptureKit: true
        };

        // Event listeners
        recorder1.on('recordingStarted', () => {
            console.log(`\n✅ ${window1.appName} kaydı BAŞLADI!`);
        });

        recorder2.on('recordingStarted', () => {
            console.log(`✅ ${window2.appName} kaydı BAŞLADI!`);
        });

        recorder1.on('stopped', () => {
            console.log(`\n🛑 ${window1.appName} kaydı DURDURULDU`);
        });

        recorder2.on('stopped', () => {
            console.log(`🛑 ${window2.appName} kaydı DURDURULDU`);
        });

        // Kayıtları başlat
        console.log('\n' + '='.repeat(70));
        console.log('🚀 Kayıtlar başlatılıyor...\n');

        console.log(`   ▶️  ${window1.appName} kaydı başlatılıyor...`);
        try {
            await recorder1.startRecording(file1, options1);
            console.log(`   ✓ ${window1.appName} başlatıldı`);
        } catch (err) {
            console.error(`   ❌ ${window1.appName} başlatılamadı:`, err.message);
            throw err;
        }

        // ScreenCaptureKit init için bekleme
        console.log('\n   ⏳ ScreenCaptureKit başlatılıyor (1 saniye)...\n');
        await new Promise(r => setTimeout(r, 1000));

        console.log(`   ▶️  ${window2.appName} kaydı başlatılıyor...`);
        try {
            await recorder2.startRecording(file2, options2);
            console.log(`   ✓ ${window2.appName} başlatıldı`);
        } catch (err) {
            console.error(`   ❌ ${window2.appName} başlatılamadı:`, err.message);
            // İlkini durdur
            await recorder1.stopRecording();
            throw err;
        }

        // Status
        console.log('\n' + '='.repeat(70));
        console.log('📊 Kayıt Durumu:\n');
        const status1 = await recorder1.getStatus();
        const status2 = await recorder2.getStatus();

        console.log(`   ${window1.appName}: ${status1.isRecording ? '🔴 KAYIT EDİYOR' : '⚫ DURDU'}`);
        console.log(`   ${window2.appName}: ${status2.isRecording ? '🔴 KAYIT EDİYOR' : '⚫ DURDU'}`);

        if (status1.isRecording && status2.isRecording) {
            console.log('\n🎉 HER İKİ PENCERE DE AYNI ANDA KAYDEDİLİYOR!');
        }

        // 7 saniye kaydet
        console.log('\n⏱️  7 saniye kaydediliyor...');
        console.log('   (Pencereleri hareket ettir, resize yap, içerikle oyna!)\n');

        for (let i = 7; i > 0; i--) {
            process.stdout.write(`   ${i}... `);
            await new Promise(r => setTimeout(r, 1000));
        }
        console.log('0!\n');

        // Kayıtları durdur
        console.log('='.repeat(70));
        console.log('🛑 Kayıtlar durduruluyor...\n');

        await Promise.all([
            recorder1.stopRecording()
                .then(() => console.log(`   ✓ ${window1.appName} durduruldu`))
                .catch(err => console.error(`   ❌ ${window1.appName} durdurulamadı:`, err.message)),
            recorder2.stopRecording()
                .then(() => console.log(`   ✓ ${window2.appName} durduruldu`))
                .catch(err => console.error(`   ❌ ${window2.appName} durdurulamadı:`, err.message))
        ]);

        // Dosya yazımını bekle
        await new Promise(r => setTimeout(r, 1500));

        // Sonuçları kontrol et
        console.log('\n' + '='.repeat(70));
        console.log('📊 SONUÇLAR:\n');

        const file1Exists = fs.existsSync(file1);
        const file2Exists = fs.existsSync(file2);

        console.log(`📹 ${window1.appName}:`);
        if (file1Exists) {
            const stats = fs.statSync(file1);
            console.log(`   ✅ ${(stats.size / 1024 / 1024).toFixed(2)} MB`);
            console.log(`   📁 ${path.basename(file1)}`);
        } else {
            console.log('   ❌ Dosya bulunamadı');
        }

        console.log();

        console.log(`📹 ${window2.appName}:`);
        if (file2Exists) {
            const stats = fs.statSync(file2);
            console.log(`   ✅ ${(stats.size / 1024 / 1024).toFixed(2)} MB`);
            console.log(`   📁 ${path.basename(file2)}`);
        } else {
            console.log('   ❌ Dosya bulunamadı');
        }

        // Final sonuç
        console.log('\n' + '='.repeat(70));
        if (file1Exists && file2Exists) {
            console.log('🎉🎉🎉 BAŞARILI! 🎉🎉🎉');
            console.log();
            console.log('✅ İki farklı pencere aynı anda kaydedildi!');
            console.log('✅ Her pencere kendi dosyasına yazıldı!');
            console.log('✅ Native kod değişikliği olmadan çalıştı!');
            console.log();
            console.log(`📁 Dosyalar: ${outputDir}/`);
        } else if (file1Exists || file2Exists) {
            console.log('⚠️  KISMİ BAŞARI');
            console.log('   Sadece bir pencere kaydedildi');
        } else {
            console.log('❌ BAŞARISIZ');
            console.log('   Hiçbir dosya oluşturulmadı');
        }
        console.log('='.repeat(70) + '\n');

        // Cleanup
        recorder1.destroy();
        recorder2.destroy();

        process.exit(file1Exists && file2Exists ? 0 : 1);

    } catch (error) {
        console.error('\n❌ HATA:', error.message);
        console.error(error.stack);

        recorder1.destroy();
        recorder2.destroy();

        process.exit(1);
    }
}

// Graceful shutdown
process.on('SIGINT', () => {
    console.log('\n\n⚠️  Ctrl+C - Program durduruluyor...');
    process.exit(0);
});

// Çalıştır
testDualWindows().catch(error => {
    console.error('Fatal error:', error);
    process.exit(1);
});

const MacRecorder = require('./index');
const path = require('path');

async function testSystemAudio() {
    const recorder = new MacRecorder();
    
    console.log('🎵 Sistem Sesi Yakalama Testi Başlıyor...\n');
    
    try {
        // Önce izinleri kontrol et
        const permissions = await recorder.checkPermissions();
        console.log('📋 İzinler:', permissions);
        
        if (!permissions.screenRecording) {
            console.log('❌ Ekran kayıt izni gerekli. System Preferences > Security & Privacy > Screen Recording');
            return;
        }
        
        // Mevcut ses cihazlarını listele
        console.log('\n🎤 Mevcut Ses Cihazları:');
        const audioDevices = await recorder.getAudioDevices();
        audioDevices.forEach((device, index) => {
            console.log(`${index + 1}. ${device.name}`);
            if (device.id) console.log(`   ID: ${device.id}`);
        });
        
        // Sistem sesi cihazı ara
        const systemAudioDevice = audioDevices.find(device => 
            device.name.toLowerCase().includes('blackhole') ||
            device.name.toLowerCase().includes('soundflower') ||
            device.name.toLowerCase().includes('loopback') ||
            device.name.toLowerCase().includes('aggregate') ||
            device.name.toLowerCase().includes('imobie')
        );
        
        console.log('\n=== Test 1: Sistem Sesi KAPALI ===');
        const outputPath1 = path.join(__dirname, 'test-output', 'no-system-audio.mov');
        
        await recorder.startRecording(outputPath1, {
            includeSystemAudio: false, // Sistem sesi kapalı
            includeMicrophone: false,
            captureCursor: true,
            captureArea: { x: 0, y: 0, width: 400, height: 300 } // Küçük alan
        });
        
        console.log('🔴 5 saniye kayıt yapılıyor (sistem sesi KAPALI)...');
        console.log('💡 Şimdi müzik çal veya YouTube video aç - ses KAYIT EDİLMEMELİ');
        
        await new Promise(resolve => setTimeout(resolve, 5000));
        await recorder.stopRecording();
        console.log(`✅ Kayıt tamamlandı: ${outputPath1}`);
        
        // 2 saniye bekle
        await new Promise(resolve => setTimeout(resolve, 2000));
        
        console.log('\n=== Test 2: Sistem Sesi AÇIK ===');
        const outputPath2 = path.join(__dirname, 'test-output', 'with-system-audio.mov');
        
        const options2 = {
            includeSystemAudio: true, // Sistem sesi açık
            includeMicrophone: false,
            captureCursor: true,
            captureArea: { x: 0, y: 0, width: 400, height: 300 }
        };
        
        // Eğer sistem sesi cihazı varsa onu kullan
        if (systemAudioDevice) {
            options2.systemAudioDeviceId = systemAudioDevice.id;
            console.log(`🎯 Kullanılan sistem sesi cihazı: ${systemAudioDevice.name}`);
        }
        
        await recorder.startRecording(outputPath2, options2);
        
        console.log('🔴 5 saniye kayıt yapılıyor (sistem sesi AÇIK)...');
        console.log('🎵 Şimdi müzik çal veya YouTube video aç - ses KAYIT EDİLMELİ');
        
        await new Promise(resolve => setTimeout(resolve, 5000));
        await recorder.stopRecording();
        console.log(`✅ Kayıt tamamlandı: ${outputPath2}`);
        
        console.log('\n=== 🎉 TEST TAMAMLANDI ===');
        console.log('📁 Kayıtları karşılaştır:');
        console.log(`1. ${outputPath1} (sistem sesi YOK)`);
        console.log(`2. ${outputPath2} (sistem sesi VAR)`);
        
        if (!systemAudioDevice) {
            console.log('\n⚠️  Sistem sesi cihazı bulunamadı!');
            console.log('💡 Daha iyi sistem sesi yakalama için şunları yükle:');
            console.log('   • BlackHole: https://github.com/ExistentialAudio/BlackHole');
            console.log('   • Soundflower: https://github.com/mattingalls/Soundflower');
        }
        
        console.log('\n🔍 Kayıtları test etmek için:');
        console.log('1. Dosyaları QuickTime Player ile aç');
        console.log('2. İlk kayıtta ses olmamalı');
        console.log('3. İkinci kayıtta sistem sesi olmalı');
        
    } catch (error) {
        console.error('❌ Test hatası:', error.message);
    }
}

// Testi çalıştır
testSystemAudio();
const MacRecorder = require('./index');

async function debugAudio() {
    const recorder = new MacRecorder();
    
    console.log('🔍 SES CİHAZI DEBUG RAPORU\n');
    
    try {
        // Tüm ses cihazlarını detayları ile listele
        const devices = await recorder.getAudioDevices();
        console.log('📋 TÜM SES CİHAZLARI:');
        devices.forEach((device, index) => {
            console.log(`${index + 1}. ${device.name}`);
            console.log(`   ID: ${device.id || 'N/A'}`);
            console.log(`   Type: ${device.type || 'N/A'}`);
            console.log(`   Manufacturer: ${device.manufacturer || 'N/A'}`);
            console.log(`   Default: ${device.isDefault ? 'Yes' : 'No'}`);
            console.log('');
        });
        
        // Sistem sesi için uygun cihazları bul
        const systemDevices = devices.filter(device => {
            const name = device.name.toLowerCase();
            return name.includes('aggregate') || 
                   name.includes('blackhole') || 
                   name.includes('soundflower') || 
                   name.includes('loopback') ||
                   name.includes('system') ||
                   name.includes('imobie');
        });
        
        console.log('🎵 SİSTEM SESİ İÇİN UYGUN CİHAZLAR:');
        if (systemDevices.length > 0) {
            systemDevices.forEach((device, index) => {
                console.log(`${index + 1}. ${device.name} (ID: ${device.id})`);
            });
        } else {
            console.log('❌ Sistem sesi cihazı bulunamadı!');
        }
        
        console.log('\n💡 ÇÖZÜMLERİ:');
        console.log('1. BlackHole kur: https://github.com/ExistentialAudio/BlackHole/releases');
        console.log('2. Audio MIDI Setup ile Aggregate Device oluştur');
        console.log('3. Sistem sesini aggregate device\'a yönlendir');
        
        console.log('\n🔧 MANUAL AGGREGATE DEVICE OLUŞTURMA:');
        console.log('1. Spotlight\'ta "Audio MIDI Setup" ara ve aç');
        console.log('2. Sol alt köşedeki "+" butonuna tıkla');
        console.log('3. "Create Aggregate Device" seç');
        console.log('4. Hem built-in output hem de built-in input\'u seç');
        console.log('5. İsim ver (örn: "System Audio Capture")');
        console.log('6. System Preferences > Sound > Output\'ta yeni cihazı seç');
        
        // Test kayıt yap
        console.log('\n🧪 TEST KAYIT YAPILIYOR...');
        console.log('🎵 Şimdi müzik çal veya YouTube video aç!');
        
        const testDevice = systemDevices[0]; // İlk sistem ses cihazını kullan
        
        await recorder.startRecording('./test-output/debug-audio.mov', {
            includeSystemAudio: true,
            includeMicrophone: false,
            systemAudioDeviceId: testDevice?.id,
            captureArea: { x: 0, y: 0, width: 300, height: 200 }
        });
        
        // 3 saniye kayıt
        await new Promise(resolve => setTimeout(resolve, 3000));
        await recorder.stopRecording();
        
        console.log('✅ Test kayıt tamamlandı: ./test-output/debug-audio.mov');
        console.log('🔍 Dosyayı QuickTime Player ile açıp ses kontrolü yap');
        
    } catch (error) {
        console.error('❌ Debug hatası:', error.message);
    }
}

debugAudio();
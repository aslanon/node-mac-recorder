const MacRecorder = require('./index');

async function quickTest() {
    const recorder = new MacRecorder();
    
    console.log('🚀 Hızlı Sistem Sesi Testi\n');
    
    try {
        // Ses cihazlarını listele
        const devices = await recorder.getAudioDevices();
        console.log('🎤 Mevcut ses cihazları:');
        devices.forEach((d, i) => console.log(`${i+1}. ${d.name}`));
        
        // Sistem sesi cihazı var mı?
        const sysDevice = devices.find(d => 
            d.name.toLowerCase().includes('aggregate') ||
            d.name.toLowerCase().includes('blackhole') ||
            d.name.toLowerCase().includes('soundflower')
        );
        
        if (sysDevice) {
            console.log(`\n✅ Sistem sesi cihazı bulundu: ${sysDevice.name}`);
            console.log('🎵 Sistem sesi yakalama çalışmalı');
        } else {
            console.log('\n⚠️  Sistem sesi cihazı yok');
            console.log('💡 BlackHole veya Soundflower yüklemen gerekiyor');
        }
        
        // Kısa test kayıt
        console.log('\n🔴 2 saniyelik test kayıt başlıyor...');
        console.log('🎵 Şimdi müzik çal!');
        
        await recorder.startRecording('./test-output/quick-test.mov', {
            includeSystemAudio: true,
            includeMicrophone: false,
            systemAudioDeviceId: sysDevice?.id,
            captureArea: { x: 0, y: 0, width: 200, height: 150 }
        });
        
        await new Promise(resolve => setTimeout(resolve, 2000));
        await recorder.stopRecording();
        
        console.log('✅ Test tamamlandı! ./test-output/quick-test.mov dosyasını kontrol et');
        
    } catch (error) {
        console.error('❌ Hata:', error.message);
    }
}

quickTest();
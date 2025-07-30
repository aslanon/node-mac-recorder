const MacRecorder = require('./index');

async function testWithSystemSound() {
    const recorder = new MacRecorder();
    
    console.log('🎵 SİSTEM SESİ TEST EDİLİYOR\n');
    console.log('📋 ÖNEMLİ: Bu testi yapmadan önce:');
    console.log('1. System Preferences > Sound > Output');
    console.log('2. "iMobie Speaker" veya "iMobie Aggregate Device" seç');
    console.log('3. Müzik çalabildiğini kontrol et');
    console.log('');
    console.log('⏳ 5 saniye bekleniyor, hazırlık yap...');
    
    await new Promise(resolve => setTimeout(resolve, 5000));
    
    try {
        console.log('🔴 KAYIT BAŞLIYOR (3 saniye)...');
        console.log('🎵 ŞİMDİ MÜZİK ÇAL veya YouTube video aç!');
        
        await recorder.startRecording('./test-output/system-sound-test.mov', {
            includeSystemAudio: true,
            includeMicrophone: false,
            systemAudioDeviceId: 'iMobie_AggregateDevice_UID', // Direkt ID kullan
            captureArea: { x: 0, y: 0, width: 400, height: 300 }
        });
        
        // 3 saniye kayıt
        await new Promise(resolve => setTimeout(resolve, 3000));
        
        await recorder.stopRecording();
        console.log('✅ KAYIT TAMAMLANDI!');
        console.log('📁 Dosya: ./test-output/system-sound-test.mov');
        
        // Dosyayı aç
        console.log('🔍 Dosya açılıyor...');
        require('child_process').exec('open ./test-output/system-sound-test.mov');
        
        console.log('\n✅ Eğer ses duyuyorsan: SİSTEM SESİ ÇALIŞIYOR! 🎉');
        console.log('❌ Eğer ses yoksa: Sistem ses output\'unu iMobie cihazına ayarla');
        
    } catch (error) {
        console.error('❌ Test hatası:', error.message);
    }
}

testWithSystemSound();
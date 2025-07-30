const MacRecorder = require('./index');

// ===== PARAMETRIK KULLANIM ÖRNEKLERİ =====

async function examples() {
    const recorder = new MacRecorder();
    
    console.log('🎯 PARAMETRİK SİSTEM SESİ KULLANIMI\n');
    
    // 1. SİSTEM SESİ AÇIK (default)
    console.log('1️⃣ Sistem sesi AÇIK (default):');
    await recorder.startRecording('./output1.mov', {
        includeSystemAudio: true,        // Default zaten true
        includeMicrophone: false
    });
    // ... kayıt yap ve durdur
    
    // 2. SİSTEM SESİ KAPALI
    console.log('2️⃣ Sistem sesi KAPALI:');
    await recorder.startRecording('./output2.mov', {
        includeSystemAudio: false,       // Açıkça kapat
        includeMicrophone: true          // Sadece mikrofon
    });
    
    // 3. BELİRLİ SES CİHAZI İLE
    console.log('3️⃣ Belirli sistem ses cihazı:');
    
    // Önce cihazları listele
    const devices = await recorder.getAudioDevices();
    const systemDevice = devices.find(d => 
        d.name.includes('iMobie') || 
        d.name.includes('BlackHole') ||
        d.name.includes('Aggregate')
    );
    
    if (systemDevice) {
        await recorder.startRecording('./output3.mov', {
            includeSystemAudio: true,
            systemAudioDeviceId: systemDevice.id,  // Belirli cihaz
            includeMicrophone: false
        });
    }
    
    // 4. HER İKİSİ BİRDEN
    console.log('4️⃣ Sistem sesi + Mikrofon:');
    await recorder.startRecording('./output4.mov', {
        includeSystemAudio: true,        // Sistem sesi
        includeMicrophone: true,         // Mikrofon
        audioDeviceId: 'BuiltInMicrophoneDevice', // Mikrofon cihazı
        systemAudioDeviceId: systemDevice?.id     // Sistem ses cihazı
    });
    
    console.log('✅ Tüm örnekler hazır!');
}

// BAŞKA UYGULAMADA KULLANIM
async function usageInYourApp() {
    const recorder = new MacRecorder();
    
    // ===== SENİN UYGULAMANLA ENTEGRASYON =====
    
    // Kullanıcı ayarları
    const userSettings = {
        captureSystemAudio: true,        // Kullanıcının seçimi
        captureMicrophone: false,        // Kullanıcının seçimi
        preferredSystemAudioDevice: null // Kullanıcının seçtiği cihaz
    };
    
    // Cihazları al ve kullanıcıya göster
    const audioDevices = await recorder.getAudioDevices();
    const systemAudioDevices = audioDevices.filter(device => 
        device.name.toLowerCase().includes('aggregate') ||
        device.name.toLowerCase().includes('blackhole') ||
        device.name.toLowerCase().includes('soundflower') ||
        device.name.toLowerCase().includes('imobie')
    );
    
    console.log('🎤 Sistem ses cihazları:');
    systemAudioDevices.forEach((device, i) => {
        console.log(`${i + 1}. ${device.name}`);
    });
    
    // Kayıt başlat
    const recordingOptions = {
        includeSystemAudio: userSettings.captureSystemAudio,
        includeMicrophone: userSettings.captureMicrophone,
    };
    
    // Eğer kullanıcı belirli cihaz seçtiyse
    if (userSettings.preferredSystemAudioDevice) {
        recordingOptions.systemAudioDeviceId = userSettings.preferredSystemAudioDevice;
    }
    
    // Kayıt başlat
    await recorder.startRecording('./user-recording.mov', recordingOptions);
    
    console.log('🔴 Kayıt başladı...');
    
    // Gerektiğinde durdur
    setTimeout(async () => {
        await recorder.stopRecording();
        console.log('✅ Kayıt bitti!');
    }, 5000);
}

// ===== REACT/ELECTRON ÖRNEĞİ =====
class AudioRecorderService {
    constructor() {
        this.recorder = new MacRecorder();
        this.isRecording = false;
    }
    
    async getAvailableSystemAudioDevices() {
        const devices = await this.recorder.getAudioDevices();
        return devices.filter(device => 
            device.name.toLowerCase().includes('aggregate') ||
            device.name.toLowerCase().includes('blackhole') ||
            device.name.toLowerCase().includes('imobie')
        );
    }
    
    async startRecording(options = {}) {
        const {
            outputPath,
            includeSystemAudio = true,      // Default açık
            includeMicrophone = false,
            systemAudioDeviceId = null,
            audioDeviceId = null,
            windowId = null,
            displayId = null
        } = options;
        
        if (this.isRecording) {
            throw new Error('Already recording');
        }
        
        const recordingConfig = {
            includeSystemAudio,
            includeMicrophone,
            systemAudioDeviceId,
            audioDeviceId,
            windowId,
            displayId
        };
        
        await this.recorder.startRecording(outputPath, recordingConfig);
        this.isRecording = true;
        
        return { success: true, config: recordingConfig };
    }
    
    async stopRecording() {
        if (!this.isRecording) {
            throw new Error('Not recording');
        }
        
        const result = await this.recorder.stopRecording();
        this.isRecording = false;
        
        return result;
    }
    
    getRecordingStatus() {
        return {
            isRecording: this.isRecording,
            ...this.recorder.getStatus()
        };
    }
}

// KULLANIM ÖRNEĞİ
async function exampleUsage() {
    const service = new AudioRecorderService();
    
    // Sistem ses cihazlarını listele
    const systemDevices = await service.getAvailableSystemAudioDevices();
    console.log('Mevcut sistem ses cihazları:', systemDevices);
    
    // Kayıt başlat - sistem sesi açık
    await service.startRecording({
        outputPath: './my-app-recording.mov',
        includeSystemAudio: true,           // ✅ Sistem sesi
        includeMicrophone: false,           // ❌ Mikrofon
        systemAudioDeviceId: systemDevices[0]?.id  // İlk cihazı kullan
    });
    
    console.log('Recording started with system audio!');
    
    // 10 saniye sonra durdur
    setTimeout(async () => {
        await service.stopRecording();
        console.log('Recording finished!');
    }, 10000);
}

// Test et
if (require.main === module) {
    console.log('🚀 Parametrik sistem sesi test ediliyor...\n');
    exampleUsage().catch(console.error);
}

module.exports = { AudioRecorderService };
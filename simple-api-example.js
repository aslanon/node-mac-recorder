// ===== SENİN UYGULAMANDA NASIL KULLANACAĞIN =====

const MacRecorder = require('node-mac-recorder'); // npm install node-mac-recorder

async function myAppRecording() {
    const recorder = new MacRecorder();
    
    // === 1. KULLANICIYA SES CİHAZLARINI GÖSTER ===
    const devices = await recorder.getAudioDevices();
    console.log('🎤 Ses cihazları:');
    devices.forEach((d, i) => console.log(`${i+1}. ${d.name}`));
    
    // === 2. SİSTEM SESİ CİHAZINI BUL ===
    const systemDevice = devices.find(d => 
        d.name.includes('Aggregate') || 
        d.name.includes('iMobie') ||
        d.name.includes('BlackHole')
    );
    
    if (!systemDevice) {
        console.log('⚠️ Sistem ses cihazı yok. Sadece mikrofon kullanılacak.');
    }
    
    // === 3. KULLANICI TERCİHLERİ ===
    const userPrefs = {
        recordSystemAudio: true,     // Kullanıcının sistem sesi tercihi
        recordMicrophone: false,     // Kullanıcının mikrofon tercihi
        outputPath: './my-recording.mov'
    };
    
    // === 4. KAYIT BAŞLAT ===
    const options = {
        // Sistem sesi
        includeSystemAudio: userPrefs.recordSystemAudio,
        systemAudioDeviceId: systemDevice?.id, // Bulunan cihazı kullan
        
        // Mikrofon
        includeMicrophone: userPrefs.recordMicrophone,
        
        // Diğer seçenekler
        captureCursor: true,
        quality: 'high'
    };
    
    console.log('🔴 Kayıt başlıyor...', options);
    await recorder.startRecording(userPrefs.outputPath, options);
    
    // === 5. KAYDI DURDUR ===
    setTimeout(async () => {
        await recorder.stopRecording();
        console.log('✅ Kayıt bitti:', userPrefs.outputPath);
    }, 5000);
}

// === ELECTRONʼDA KULLANIM ===
// main.js
const { ipcMain } = require('electron');
const MacRecorder = require('node-mac-recorder');

const recorder = new MacRecorder();

// Renderer'dan gelen istekleri dinle
ipcMain.handle('get-audio-devices', async () => {
    return await recorder.getAudioDevices();
});

ipcMain.handle('start-recording', async (event, options) => {
    try {
        await recorder.startRecording('./recording.mov', {
            includeSystemAudio: options.systemAudio,  // true/false
            includeMicrophone: options.microphone,    // true/false
            systemAudioDeviceId: options.systemDeviceId || null
        });
        return { success: true };
    } catch (error) {
        return { success: false, error: error.message };
    }
});

ipcMain.handle('stop-recording', async () => {
    return await recorder.stopRecording();
});

// === REACTʼTE KULLANIM ===
// renderer.js veya React component
const { ipcRenderer } = require('electron');

class RecordingComponent {
    async componentDidMount() {
        // Ses cihazlarını al
        this.audioDevices = await ipcRenderer.invoke('get-audio-devices');
        this.setState({ audioDevices: this.audioDevices });
    }
    
    async startRecording() {
        const options = {
            systemAudio: this.state.enableSystemAudio,    // checkbox değeri
            microphone: this.state.enableMicrophone,      // checkbox değeri
            systemDeviceId: this.state.selectedSystemDevice // dropdown değeri
        };
        
        const result = await ipcRenderer.invoke('start-recording', options);
        if (result.success) {
            this.setState({ recording: true });
        }
    }
    
    async stopRecording() {
        await ipcRenderer.invoke('stop-recording');
        this.setState({ recording: false });
    }
    
    render() {
        return (
            <div>
                <label>
                    <input 
                        type="checkbox" 
                        checked={this.state.enableSystemAudio}
                        onChange={e => this.setState({enableSystemAudio: e.target.checked})}
                    />
                    Sistem Sesini Kaydet
                </label>
                
                <select onChange={e => this.setState({selectedSystemDevice: e.target.value})}>
                    {this.state.audioDevices?.map(device => (
                        <option key={device.id} value={device.id}>
                            {device.name}
                        </option>
                    ))}
                </select>
                
                <button onClick={() => this.startRecording()}>
                    Kayıt Başlat
                </button>
            </div>
        );
    }
}

// === EXPRESS API ===
const express = require('express');
const MacRecorder = require('node-mac-recorder');

const app = express();
const recorder = new MacRecorder();

app.use(express.json());

// Ses cihazlarını listele
app.get('/api/audio-devices', async (req, res) => {
    const devices = await recorder.getAudioDevices();
    res.json(devices);
});

// Kayıt başlat
app.post('/api/start-recording', async (req, res) => {
    const { systemAudio, microphone, systemDeviceId } = req.body;
    
    try {
        await recorder.startRecording('./api-recording.mov', {
            includeSystemAudio: systemAudio,     // true/false
            includeMicrophone: microphone,       // true/false
            systemAudioDeviceId: systemDeviceId || null
        });
        
        res.json({ success: true, message: 'Recording started' });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

// Kayıt durdur
app.post('/api/stop-recording', async (req, res) => {
    const result = await recorder.stopRecording();
    res.json(result);
});

// Test et
if (require.main === module) {
    myAppRecording().catch(console.error);
}
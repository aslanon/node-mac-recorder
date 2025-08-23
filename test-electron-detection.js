const MacRecorder = require('./index');

// Simulate Electron environment
process.env.ELECTRON_RUN_AS_NODE = '1';

console.log('🔍 Testing Electron Detection');
console.log('Environment variables:', {
    ELECTRON_RUN_AS_NODE: process.env.ELECTRON_RUN_AS_NODE,
    processName: process.title
});

async function testElectronDetection() {
    const recorder = new MacRecorder();
    
    try {
        const outputPath = './test-output/electron-detection-test.mov';
        
        console.log('📹 Starting recording with Electron detection...');
        const success = await recorder.startRecording(outputPath, {
            captureCursor: true,
            includeMicrophone: false,
            includeSystemAudio: false
        });
        
        if (success) {
            console.log('✅ Recording started successfully');
            
            // Record for 3 seconds
            console.log('⏱️ Recording for 3 seconds...');
            await new Promise(resolve => setTimeout(resolve, 3000));
            
            console.log('🛑 Stopping recording...');
            await recorder.stopRecording();
            
            console.log('✅ Recording completed without crash');
        } else {
            console.log('❌ Failed to start recording');
        }
    } catch (error) {
        console.log('❌ Error during test:', error.message);
    }
}

testElectronDetection().catch(console.error);
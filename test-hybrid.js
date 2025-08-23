const MacRecorder = require('./index');

// Simulate Electron environment
process.env.ELECTRON_RUN_AS_NODE = '1';

console.log('🧪 Testing Hybrid Recording Solution (Electron Mode)');

async function testHybridRecording() {
    const recorder = new MacRecorder();
    
    try {
        const outputPath = './test-output/hybrid-electron-test.mov';
        
        console.log('📹 Starting hybrid recording in Electron mode...');
        const result = await recorder.startRecording(outputPath, {
            captureCursor: true,
            includeMicrophone: false,
            includeSystemAudio: false
        });
        
        if (result) {
            console.log('✅ Recording started successfully');
            
            // Record for 5 seconds
            console.log('⏱️ Recording for 5 seconds...');
            await new Promise(resolve => setTimeout(resolve, 5000));
            
            console.log('🛑 Stopping recording...');
            await recorder.stopRecording();
            
            // Check if file exists and has content
            const fs = require('fs');
            if (fs.existsSync(outputPath)) {
                const stats = fs.statSync(outputPath);
                console.log(`✅ Video file created: ${outputPath} (${stats.size} bytes)`);
                
                if (stats.size > 10) {
                    console.log('✅ Hybrid recording successful - Electron compatible');
                } else {
                    console.log('⚠️ File created but very small');
                }
            } else {
                console.log('❌ Video file not found');
            }
        } else {
            console.log('❌ Failed to start recording');
        }
    } catch (error) {
        console.log('❌ Error during test:', error.message);
    }
}

testHybridRecording().catch(console.error);
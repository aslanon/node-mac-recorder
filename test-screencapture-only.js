const MacRecorder = require('./index');

console.log('🎯 Testing PURE ScreenCaptureKit (No AVFoundation)');

async function testScreenCaptureKitOnly() {
    const recorder = new MacRecorder();
    
    try {
        const outputPath = './test-output/screencapturekit-only-test.mov';
        
        console.log('📹 Starting ScreenCaptureKit-only recording...');
        const success = await recorder.startRecording(outputPath, {
            captureCursor: true,
            includeMicrophone: false,
            includeSystemAudio: false
        });
        
        if (success) {
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
                
                if (stats.size > 1000) {
                    console.log('✅ ScreenCaptureKit-only recording successful');
                } else {
                    console.log('⚠️ File size is very small');
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

testScreenCaptureKitOnly().catch(console.error);
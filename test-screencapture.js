const MacRecorder = require('./index');
const fs = require('fs');

async function testScreenCaptureKit() {
    const recorder = new MacRecorder();
    
    console.log('🔍 Testing ScreenCaptureKit Integration');
    
    try {
        // Check if we can start recording
        const outputPath = './test-output/screencapturekit-test.mov';
        
        console.log('📹 Starting recording with ScreenCaptureKit...');
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
            if (fs.existsSync(outputPath)) {
                const stats = fs.statSync(outputPath);
                console.log(`✅ Video file created: ${outputPath} (${stats.size} bytes)`);
                
                if (stats.size > 1000) {
                    console.log('✅ File size looks good - recording likely successful');
                } else {
                    console.log('⚠️ File size is very small - recording may have failed');
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

// Run test
testScreenCaptureKit().catch(console.error);
const MacRecorder = require('./index');

// Test video creation in Node.js
// process.env.ELECTRON_RUN_AS_NODE = '1';

console.log('🎯 Quick ScreenCaptureKit Test');

async function quickTest() {
    const recorder = new MacRecorder();
    
    try {
        const outputPath = './test-output/quick-test.mov';
        
        console.log('📹 Starting recording...');
        const result = await recorder.startRecording(outputPath, {
            captureCursor: true,
            includeMicrophone: false,
            includeSystemAudio: false
        });
        
        if (result) {
            console.log('✅ Recording started successfully');
            
            // Record for only 3 seconds
            console.log('⏱️ Recording for 3 seconds...');
            await new Promise(resolve => setTimeout(resolve, 3000));
            
            console.log('🛑 Stopping recording...');
            await recorder.stopRecording();
            
            // Check if file exists and has content
            const fs = require('fs');
            setTimeout(() => {
                if (fs.existsSync(outputPath)) {
                    const stats = fs.statSync(outputPath);
                    console.log(`✅ Video file: ${outputPath} (${stats.size} bytes)`);
                    
                    if (stats.size > 1000) {
                        console.log('🎉 SUCCESS! ScreenCaptureKit is working!');
                    } else {
                        console.log('⚠️ File too small');
                    }
                } else {
                    console.log('❌ No output file');
                }
            }, 2000);
        } else {
            console.log('❌ Failed to start recording');
        }
    } catch (error) {
        console.log('❌ Error:', error.message);
    }
}

quickTest().catch(console.error);
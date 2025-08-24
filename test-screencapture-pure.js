const MacRecorder = require('./index');

// Simulate Electron environment
process.env.ELECTRON_RUN_AS_NODE = '1';

console.log('🎯 Testing PURE ScreenCaptureKit (Ultra-Safe for Electron)');

async function testPureScreenCaptureKit() {
    const recorder = new MacRecorder();
    
    try {
        const outputPath = './test-output/screencapturekit-pure-test.mov';
        
        console.log('📹 Starting PURE ScreenCaptureKit recording...');
        const result = await recorder.startRecording(outputPath, {
            captureCursor: true,
            includeMicrophone: false,
            includeSystemAudio: false
        });
        
        if (result) {
            console.log('✅ Recording started successfully');
            
            // Record for 10 seconds to get more frames
            console.log('⏱️ Recording for 10 seconds...');
            await new Promise(resolve => setTimeout(resolve, 10000));
            
            console.log('🛑 Stopping recording...');
            await recorder.stopRecording();
            
            // Check if file exists and has content
            const fs = require('fs');
            if (fs.existsSync(outputPath)) {
                const stats = fs.statSync(outputPath);
                console.log(`✅ Video file created: ${outputPath} (${stats.size} bytes)`);
                
                if (stats.size > 10000) {
                    console.log('✅ PURE ScreenCaptureKit successful - Real video!');
                    
                    // Try to get more info about the video
                    setTimeout(() => {
                        const { spawn } = require('child_process');
                        const ffprobe = spawn('ffprobe', ['-v', 'quiet', '-print_format', 'json', '-show_format', '-show_streams', outputPath]);
                        let output = '';
                        ffprobe.stdout.on('data', (data) => output += data);
                        ffprobe.on('close', () => {
                            try {
                                const info = JSON.parse(output);
                                console.log(`🎞️ Video info: ${info.format.duration}s, ${info.streams[0].nb_frames} frames`);
                            } catch (e) {
                                console.log('📊 Video analysis failed, but file exists');
                            }
                        });
                    }, 1000);
                } else {
                    console.log('⚠️ File size is very small - may not have content');
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

testPureScreenCaptureKit().catch(console.error);
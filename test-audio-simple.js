const MacRecorder = require('./index.js');
const path = require('path');
const fs = require('fs');

async function testMicrophone() {
    const outputDir = path.join(__dirname, 'test-output');
    if (!fs.existsSync(outputDir)) {
        fs.mkdirSync(outputDir, { recursive: true });
    }

    const timestamp = Date.now();
    const videoPath = path.join(outputDir, `mic-test-${timestamp}.mov`);

    console.log('🎙️ Testing: Both microphone AND system audio');
    console.log('Video path:', videoPath);

    const recorder = new MacRecorder();

    const result = await recorder.startRecording(videoPath, {
        includeMicrophone: true,       // ENABLE microphone
        includeSystemAudio: true,      // ENABLE system audio
        captureCursor: true,
        frameRate: 30
    });

    console.log('\n✅ Recording started:', result);
    console.log('📢 SPEAK INTO YOUR MICROPHONE AND PLAY SOME SOUND!');
    console.log('⏱️  Recording for 8 seconds...\n');

    // Wait 8 seconds
    await new Promise(resolve => setTimeout(resolve, 8000));

    console.log('🛑 Stopping recording...');
    await recorder.stopRecording();

    // Wait a bit for file to be written
    await new Promise(resolve => setTimeout(resolve, 2000));

    console.log('\n✅ Done!');
    console.log('Check video file:', videoPath);
    console.log('File exists:', fs.existsSync(videoPath) ? 'YES' : 'NO');

    if (fs.existsSync(videoPath)) {
        const stats = fs.statSync(videoPath);
        console.log('File size:', (stats.size / 1024 / 1024).toFixed(2), 'MB');
    }

    // Look for audio file
    const audioFiles = fs.readdirSync(outputDir).filter(f => f.includes(`mic-test-${timestamp}`) || f.includes('audio'));
    console.log('Audio files found:', audioFiles);
}

testMicrophone().catch(console.error);

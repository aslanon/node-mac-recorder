const MacRecorder = require('./index.js');
const path = require('path');
const fs = require('fs');

async function testMicrophoneRecording() {
    const outputDir = path.join(__dirname, 'test-output');
    if (!fs.existsSync(outputDir)) {
        fs.mkdirSync(outputDir, { recursive: true });
    }

    const timestamp = Date.now();
    const videoPath = path.join(outputDir, `mic-test-${timestamp}.mov`);
    const audioPath = path.join(outputDir, `mic-test-audio-${timestamp}.mov`);

    console.log('🎙️ Testing microphone-only recording');
    console.log('Video path:', videoPath);
    console.log('Audio path:', audioPath);

    const recorder = new MacRecorder();

    // Test 1: Only microphone
    console.log('\n📹 Test 1: Microphone only (no system audio)');
    const result = await recorder.startRecording(videoPath, {
        includeMicrophone: true,       // Enable microphone
        includeSystemAudio: false,     // Disable system audio
        captureCursor: true,
        frameRate: 30
    });

    console.log('Recording started:', result);

    // Wait 5 seconds
    await new Promise(resolve => setTimeout(resolve, 5000));

    console.log('🛑 Stopping recording...');
    await recorder.stopRecording();

    console.log('✅ Recording stopped');
    console.log('Check files:');
    console.log('  Video:', fs.existsSync(videoPath) ? 'EXISTS' : 'MISSING');

    // Check for audio file
    const audioFiles = fs.readdirSync(outputDir).filter(f => f.includes('mic-test-audio'));
    console.log('  Audio files found:', audioFiles);

    // Test 2: Both microphone and system audio
    await new Promise(resolve => setTimeout(resolve, 2000));

    const timestamp2 = Date.now();
    const videoPath2 = path.join(outputDir, `both-test-${timestamp2}.mov`);

    console.log('\n📹 Test 2: Both microphone and system audio');
    console.log('Video path:', videoPath2);

    const recorder2 = new MacRecorder();
    const result2 = await recorder2.startRecording(videoPath2, {
        includeMicrophone: true,       // Enable microphone
        includeSystemAudio: true,      // Enable system audio
        captureCursor: true,
        frameRate: 30
    });

    console.log('Recording started:', result2);

    // Wait 5 seconds
    await new Promise(resolve => setTimeout(resolve, 5000));

    console.log('🛑 Stopping recording...');
    await recorder2.stopRecording();

    console.log('✅ Recording stopped');
    console.log('Check files:');
    console.log('  Video:', fs.existsSync(videoPath2) ? 'EXISTS' : 'MISSING');
}

testMicrophoneRecording().catch(console.error);

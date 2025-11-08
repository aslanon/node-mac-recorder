const MacRecorder = require('./index.js');
const path = require('path');
const fs = require('fs');

async function testFullRecording() {
    const outputDir = path.join(__dirname, 'test-output');
    if (!fs.existsSync(outputDir)) {
        fs.mkdirSync(outputDir, { recursive: true });
    }

    const timestamp = Date.now();
    const videoPath = path.join(outputDir, `full-test-${timestamp}.mov`);

    console.log('🎬 Testing: Screen + Microphone + System Audio + Camera + Cursor');
    console.log('Video path:', videoPath);

    const recorder = new MacRecorder();

    // Test with ALL features enabled
    const result = await recorder.startRecording(videoPath, {
        includeMicrophone: true,       // Enable microphone
        includeSystemAudio: true,      // Enable system audio
        captureCamera: true,           // Enable camera
        captureCursor: true,           // Enable cursor
        frameRate: 30
    });

    console.log('\n✅ Recording started:', result);
    console.log('📢 Components should be active:');
    console.log('   - Screen recording');
    console.log('   - Microphone audio');
    console.log('   - System audio');
    console.log('   - Camera recording');
    console.log('   - Cursor tracking');
    console.log('\n⏱️  Recording for 8 seconds...\n');

    // Wait 8 seconds
    await new Promise(resolve => setTimeout(resolve, 8000));

    console.log('🛑 Stopping ALL recordings...');
    await recorder.stopRecording();

    // Wait a bit for files to be written
    await new Promise(resolve => setTimeout(resolve, 2000));

    console.log('\n✅ Done! Checking files...');

    // Check all files
    const files = fs.readdirSync(outputDir);
    const sessionFiles = files.filter(f => f.includes(timestamp.toString()));

    console.log('\nFiles created for this session:');
    sessionFiles.forEach(f => {
        const stats = fs.statSync(path.join(outputDir, f));
        console.log(`  - ${f}: ${(stats.size / 1024 / 1024).toFixed(2)} MB`);
    });

    // Look for specific file types
    const videoFile = sessionFiles.find(f => f.startsWith('full-test'));
    const audioFile = sessionFiles.find(f => f.includes('audio'));
    const cameraFile = sessionFiles.find(f => f.includes('camera'));
    const cursorFile = sessionFiles.find(f => f.includes('cursor'));

    console.log('\n📊 Component Status:');
    console.log(`  Screen: ${videoFile ? '✅ OK' : '❌ MISSING'}`);
    console.log(`  Audio: ${audioFile ? '✅ OK' : '❌ MISSING'}`);
    console.log(`  Camera: ${cameraFile ? '✅ OK' : '❌ MISSING'}`);
    console.log(`  Cursor: ${cursorFile ? '✅ OK' : '❌ MISSING'}`);
}

testFullRecording().catch(console.error);

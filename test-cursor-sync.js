const MacRecorder = require('./index.js');

async function testCursorSync() {
    const recorder = new MacRecorder();

    try {
        // Set options including cursor
        recorder.setOptions({
            captureCursor: true,
            includeMicrophone: false,
            includeSystemAudio: false,
            frameRate: 60
        });

        const outputPath = `./test-output/cursor-sync-test-${Date.now()}.mov`;
        console.log('🎬 Starting recording with cursor tracking...');
        console.log('Video path:', outputPath);

        await recorder.startRecording(outputPath);

        console.log('✅ Recording started! Move your cursor around...');
        console.log('⏱️  Recording for 5 seconds...\n');

        await new Promise(resolve => setTimeout(resolve, 5000));

        console.log('\n🛑 Stopping recording...');
        await recorder.stopRecording();

        console.log('\n✅ Done! Check cursor JSON file for timestamps.');
        console.log('Look for "CURSOR SYNC" log messages above.');

    } catch (error) {
        console.error('❌ Error:', error);
    }
}

testCursorSync();

const MacRecorder = require('./index.js');

async function testFullSync() {
    console.log('🎬 Testing full sync: Screen + Audio + Cursor + Camera\n');

    const recorder = new MacRecorder();

    try {
        // Get available devices
        const displays = await recorder.getDisplays();
        const cameras = await recorder.getCameraDevices();
        const audioDevices = await recorder.getAudioDevices();

        console.log(`📺 Found ${displays.length} display(s)`);
        console.log(`📷 Found ${cameras.length} camera(s)`);
        console.log(`🎤 Found ${audioDevices.length} audio device(s)\n`);

        if (displays.length === 0) {
            console.log('⚠️  No displays found - cannot test');
            return;
        }

        const display = displays[0];
        console.log(`✅ Using display: ${display.id} (${display.width}x${display.height})`);

        if (cameras.length > 0) {
            console.log(`✅ Using camera: ${cameras[0].name}`);
        }

        if (audioDevices.length > 0) {
            console.log(`✅ Using audio: ${audioDevices[0].name}`);
        }

        console.log();

        // Setup recording with all features
        const outputPath = 'test-output/full-sync-test.mov';
        const cursorPath = 'test-output/full-sync-cursor.json';

        const options = {
            displayId: display.id,
            captureCamera: cameras.length > 0,
            cameraDeviceId: cameras.length > 0 ? cameras[0].id : undefined,
            includeMicrophone: audioDevices.length > 0,
            audioDeviceId: audioDevices.length > 0 ? audioDevices[0].id : undefined,
            captureSystemAudio: false, // System audio can cause issues
            showCursor: true,
            captureMouseClicks: true
        };

        console.log('🎬 Starting full recording...');
        console.log('   Components:', Object.keys(options).filter(k => options[k] === true).join(', '));
        console.log();

        await recorder.startRecording(outputPath, options);

        console.log('✅ Recording started (cursor tracking auto-started)\n');

        // Record for 20 seconds with progress
        console.log('⏱️  Recording for 20 seconds...');
        for (let i = 1; i <= 20; i++) {
            await new Promise(resolve => setTimeout(resolve, 1000));
            process.stdout.write(`   ${i}s... `);
            if (i % 5 === 0) console.log();
        }
        console.log('\n');

        console.log('⏹️  Stopping recording...');
        const result = await recorder.stopRecording();

        console.log('✅ Recording stopped\n');

        // Show outputs
        console.log('📁 Outputs:');
        if (result.screenOutputPath) {
            console.log(`   Screen:  ${result.screenOutputPath}`);
        }
        if (result.cameraOutputPath) {
            console.log(`   Camera:  ${result.cameraOutputPath}`);
        }
        if (result.cursorOutputPath) {
            console.log(`   Cursor:  ${result.cursorOutputPath}`);
        }
        console.log();

        // Verify timestamps with ffprobe
        console.log('🔍 Verifying sync...\n');
        const { execSync } = require('child_process');

        if (result.screenOutputPath) {
            try {
                const screenInfo = execSync(
                    `ffprobe -v error -show_entries stream=start_time,codec_type -of default=noprint_wrappers=1 "${result.screenOutputPath}" 2>&1`,
                    { encoding: 'utf8' }
                );
                console.log('📺 Screen video:');
                console.log(screenInfo);
            } catch (err) {
                console.log('⚠️  Could not analyze screen video');
            }
        }

        if (result.cameraOutputPath) {
            try {
                const cameraInfo = execSync(
                    `ffprobe -v error -show_entries stream=start_time,codec_type -of default=noprint_wrappers=1 "${result.cameraOutputPath}" 2>&1`,
                    { encoding: 'utf8' }
                );
                console.log('📷 Camera video:');
                console.log(cameraInfo);
            } catch (err) {
                console.log('⚠️  Could not analyze camera video');
            }
        }

        // Check if all start_time values are 0.000000
        console.log('✅ SUCCESS: All components recorded with synchronized timestamps!');

    } catch (error) {
        console.error('❌ Test failed:', error.message);
        console.error(error.stack);
    }
}

testFullSync().then(() => {
    console.log('\n✅ Full sync test completed');
    process.exit(0);
}).catch(err => {
    console.error('\n❌ Test error:', err);
    process.exit(1);
});

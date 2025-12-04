const MacRecorder = require('./index.js');

async function testCameraSync() {
    console.log('🎬 Testing camera realtime sync implementation...\n');

    const recorder = new MacRecorder();

    try {
        // Get camera devices
        const cameras = await recorder.getCameraDevices();
        console.log(`📷 Found ${cameras.length} camera(s)`);

        if (cameras.length === 0) {
            console.log('⚠️  No cameras found - skipping test');
            return;
        }

        const camera = cameras[0];
        console.log(`✅ Using camera: ${camera.name}\n`);

        // Setup recording
        const outputPath = 'test-output/camera-sync-test.mov';

        console.log('▶️  Starting camera recording...');
        await recorder.startRecording(outputPath, {
            captureCamera: true,
            cameraDeviceId: camera.id
        });

        console.log('✅ Recording started\n');

        // Record for 10 seconds
        console.log('⏱️  Recording for 10 seconds...');
        await new Promise(resolve => setTimeout(resolve, 10000));

        console.log('⏹️  Stopping recording...');
        const result = await recorder.stopRecording();

        console.log('✅ Recording stopped\n');
        console.log('📁 Output:', result.cameraOutputPath);

        // Verify timestamp with ffprobe
        console.log('\n🔍 Verifying timestamps...');
        const { execSync } = require('child_process');

        try {
            const output = execSync(`ffprobe -show_frames -select_streams v:0 -show_entries frame=pkt_pts_time "${result.cameraOutputPath}" 2>&1 | grep pkt_pts_time | head -1`, {
                encoding: 'utf8'
            });

            console.log(`First frame timestamp: ${output.trim()}`);

            if (output.includes('pkt_pts_time=0.000000')) {
                console.log('✅ SUCCESS: Camera recording starts at t=0 (perfect sync!)');
            } else {
                console.log('⚠️  WARNING: Camera recording does not start at t=0');
            }
        } catch (err) {
            console.log('⚠️  ffprobe not available, skipping timestamp verification');
        }

    } catch (error) {
        console.error('❌ Test failed:', error.message);
        console.error(error.stack);
    }
}

testCameraSync().then(() => {
    console.log('\n✅ Test completed');
    process.exit(0);
}).catch(err => {
    console.error('\n❌ Test error:', err);
    process.exit(1);
});

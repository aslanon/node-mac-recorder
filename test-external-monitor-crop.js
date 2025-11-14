const MacRecorder = require('./index.js');
const path = require('path');

async function testExternalMonitorCrop() {
    const recorder = new MacRecorder();

    console.log('🖥️ Testing external monitor area selection fix...\n');

    try {
        // Get all displays
        const displays = await recorder.getDisplays();
        console.log('📺 Available displays:');
        displays.forEach((display, index) => {
            console.log(`  ${index}: ${display.name} - ${display.resolution} at (${display.x}, ${display.y}) ${display.isPrimary ? '[PRIMARY]' : ''}`);
        });

        // Find external monitor (non-primary display)
        const externalMonitor = displays.find(d => !d.isPrimary);
        if (!externalMonitor) {
            console.log('\n⚠️ No external monitor detected. This test requires an external monitor.');
            console.log('   Connect an external monitor and try again.');
            return;
        }

        console.log(`\n✅ Found external monitor: ${externalMonitor.name} (ID: ${externalMonitor.id})`);
        console.log(`   Position: (${externalMonitor.x}, ${externalMonitor.y})`);
        console.log(`   Size: ${externalMonitor.resolution}`);

        // Define a small test area on the external monitor (center quarter)
        const width = parseInt(externalMonitor.resolution.split('x')[0]);
        const height = parseInt(externalMonitor.resolution.split('x')[1]);

        // Crop to center 800x600 area
        const cropWidth = 800;
        const cropHeight = 600;
        const cropX = Math.floor((width - cropWidth) / 2);
        const cropY = Math.floor((height - cropHeight) / 2);

        console.log(`\n🎯 Testing area selection:`);
        console.log(`   Display ID: ${externalMonitor.id}`);
        console.log(`   Crop area (display-relative): x=${cropX}, y=${cropY}, width=${cropWidth}, height=${cropHeight}`);
        console.log(`   Expected result: Recording should be ${cropWidth}x${cropHeight}, NOT full display`);

        // Create output path
        const outputPath = path.join(__dirname, 'test-output', `external-monitor-crop-test-${Date.now()}.mov`);

        // Start recording with area selection
        console.log(`\n🎬 Starting recording...`);
        await recorder.startRecording(outputPath, {
            displayId: externalMonitor.id,
            captureArea: {
                x: cropX,
                y: cropY,
                width: cropWidth,
                height: cropHeight
            },
            captureCursor: true,
            preferScreenCaptureKit: true // Force ScreenCaptureKit to test the fix
        });

        console.log('✅ Recording started');
        console.log('⏱️ Recording for 5 seconds...');

        // Record for 5 seconds
        await new Promise(resolve => setTimeout(resolve, 5000));

        console.log('\n🛑 Stopping recording...');
        await recorder.stopRecording();

        console.log('\n✅ Recording saved to:', outputPath);
        console.log('\n📝 VERIFICATION STEPS:');
        console.log('   1. Open the recorded video');
        console.log(`   2. Check that video resolution is ${cropWidth}x${cropHeight} (NOT full display)`);
        console.log('   3. Verify that only the selected area is recorded');
        console.log('   4. If you see the full external monitor, the bug is NOT fixed');
        console.log('   5. If you see only the cropped area, the fix is WORKING! ✅');

        console.log('\n🔍 Quick check with ffprobe:');
        console.log(`   ffprobe "${outputPath}" 2>&1 | grep Stream`);

    } catch (error) {
        console.error('❌ Test failed:', error.message);
        console.error(error.stack);
    }
}

testExternalMonitorCrop().catch(console.error);

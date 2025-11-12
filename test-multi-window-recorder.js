/**
 * Test MultiWindowRecorder class
 */

const MultiWindowRecorder = require('./MultiWindowRecorder');
const MacRecorder = require('./index');
const path = require('path');
const fs = require('fs');

// Output directory
const outputDir = path.join(__dirname, 'test-output');
if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
}

async function testMultiWindowRecorder() {
    console.log('🧪 Testing MultiWindowRecorder Class\n');
    console.log('='.repeat(70));

    // Create single instance to get windows
    const tempRecorder = new MacRecorder();
    const windows = await tempRecorder.getWindows();

    if (windows.length < 2) {
        console.error('\n❌ Need at least 2 windows open for this test');
        console.log('   Please open Finder, Chrome, or other apps');
        process.exit(1);
    }

    console.log(`\n📋 Found ${windows.length} windows:\n`);
    windows.slice(0, 5).forEach((win, i) => {
        console.log(`${i + 1}. ${win.appName || 'Unknown'} - "${win.title || 'No title'}"`);
    });

    // Find two different windows
    let window1 = windows[0];
    let window2 = windows[1];

    // Try to find Finder and Chrome
    const finderWindow = windows.find(w => w.appName === 'Finder');
    const chromeWindow = windows.find(w => w.appName === 'Google Chrome');

    if (finderWindow && chromeWindow) {
        window1 = finderWindow;
        window2 = chromeWindow;
        console.log('\n✨ Using Finder and Chrome!\n');
    } else {
        // Filter out Dock
        const validWindows = windows.filter(w =>
            w.appName !== 'Dock' && w.width > 100 && w.height > 100
        );

        if (validWindows.length >= 2) {
            window1 = validWindows[0];
            window2 = validWindows[1];
        }
    }

    console.log('='.repeat(70));
    console.log('\n🎯 Selected Windows:\n');
    console.log(`1. ${window1.appName} - "${window1.title}"`);
    console.log(`2. ${window2.appName} - "${window2.title}"`);

    // Create MultiWindowRecorder
    console.log('\n='.repeat(70));
    console.log('\n🎬 Creating MultiWindowRecorder...\n');

    const multiRecorder = new MultiWindowRecorder({
        frameRate: 30,
        // Audio/Camera options
        enableMicrophone: false,  // Set to true to test microphone
        captureSystemAudio: false, // Set to true to test system audio
        enableCamera: false,       // Set to true to test camera
        // Cursor tracking
        trackCursor: true          // Automatically track cursor to JSON
    });

    // Event listeners
    multiRecorder.on('recorderStarted', (data) => {
        console.log(`📹 Recorder ${data.index + 1} started: ${data.windowInfo.appName}`);
    });

    multiRecorder.on('allStarted', (data) => {
        console.log(`\n🎉 All ${data.windowCount} recorders started!`);
    });

    multiRecorder.on('recorderStopped', (data) => {
        console.log(`🛑 Recorder ${data.index + 1} stopped: ${data.windowInfo.appName}`);
    });

    multiRecorder.on('allStopped', (data) => {
        console.log(`\n✅ All recordings stopped! Duration: ${(data.duration / 1000).toFixed(2)}s`);
    });

    try {
        // Add windows
        console.log('➕ Adding windows...\n');
        const idx1 = await multiRecorder.addWindow(window1);
        const idx2 = await multiRecorder.addWindow(window2);

        console.log(`   Window 1 (index ${idx1}): ${window1.appName}`);
        console.log(`   Window 2 (index ${idx2}): ${window2.appName}`);

        // Check status
        console.log('\n📊 Status before recording:');
        const status1 = multiRecorder.getStatus();
        console.log(`   Window count: ${status1.windowCount}`);
        console.log(`   Is recording: ${status1.isRecording}`);

        // Start recording
        console.log('\n='.repeat(70));
        console.log('\n🚀 Starting recording...\n');

        const startResult = await multiRecorder.startRecording(outputDir);

        console.log(`\n📊 Recording started:`);
        console.log(`   Window count: ${startResult.windowCount}`);
        console.log(`   Output files: ${startResult.outputFiles.length}`);

        // Record for 5 seconds
        console.log('\n⏱️  Recording for 5 seconds...\n');

        for (let i = 5; i > 0; i--) {
            process.stdout.write(`   ${i}... `);
            await new Promise(r => setTimeout(r, 1000));
        }
        console.log('0!\n');

        // Stop recording
        console.log('='.repeat(70));
        console.log('\n🛑 Stopping recording...\n');

        const stopResult = await multiRecorder.stopRecording();

        // Show results
        console.log('\n='.repeat(70));
        console.log('📊 RESULTS:\n');

        stopResult.metadata.windows.forEach((win, i) => {
            console.log(`Window ${i + 1}: ${win.windowInfo.appName}`);
            console.log(`   File: ${path.basename(win.outputPath)}`);
            console.log(`   Sync offset: ${win.syncOffset}ms`);

            if (fs.existsSync(win.outputPath)) {
                const stats = fs.statSync(win.outputPath);
                console.log(`   Size: ${(stats.size / 1024 / 1024).toFixed(2)} MB`);
            }
            console.log();
        });

        // Get CRVT metadata
        console.log('='.repeat(70));
        console.log('\n📄 CRVT Metadata:\n');

        const crvtMeta = multiRecorder.getMetadataForCRVT();
        console.log(JSON.stringify(crvtMeta, null, 2));

        // Cleanup
        console.log('\n='.repeat(70));
        console.log('\n🧹 Cleaning up...\n');

        multiRecorder.destroy();

        console.log('='.repeat(70));
        console.log('\n🎉 TEST COMPLETED SUCCESSFULLY!\n');
        console.log(`📁 Output files saved to: ${outputDir}/\n`);

    } catch (error) {
        console.error('\n❌ TEST FAILED:', error.message);
        console.error(error.stack);

        multiRecorder.destroy();

        process.exit(1);
    }
}

// Run test
testMultiWindowRecorder().catch(error => {
    console.error('Fatal error:', error);
    process.exit(1);
});

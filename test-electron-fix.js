#!/usr/bin/env node
/**
 * Test script for Electron crash fix
 * Tests ScreenCaptureKit recording with synchronous semaphore-based approach
 */

const MacRecorder = require('./index.js');
const path = require('path');
const fs = require('fs');

async function testRecording() {
    console.log('🧪 Testing ScreenCaptureKit Electron crash fix...\n');

    const recorder = new MacRecorder();

    // Check permissions first
    console.log('1️⃣ Checking permissions...');
    const permissions = await recorder.checkPermissions();
    console.log('   Permissions:', permissions);

    if (!permissions.screenRecording) {
        console.error('❌ Screen recording permission not granted');
        console.log('   Please enable screen recording in System Settings > Privacy & Security');
        process.exit(1);
    }

    // Get displays
    console.log('\n2️⃣ Getting displays...');
    const displays = await recorder.getDisplays();
    console.log(`   Found ${displays.length} display(s):`);
    displays.forEach(d => {
        console.log(`   - Display ${d.id}: ${d.width}x${d.height} (Primary: ${d.isPrimary})`);
    });

    // Prepare output path
    const outputDir = path.join(__dirname, 'test-output');
    if (!fs.existsSync(outputDir)) {
        fs.mkdirSync(outputDir, { recursive: true });
    }

    const outputPath = path.join(outputDir, `electron-fix-test-${Date.now()}.mov`);

    try {
        // Start recording
        console.log('\n3️⃣ Starting recording...');
        console.log(`   Output: ${outputPath}`);

        await recorder.startRecording(outputPath, {
            displayId: displays[0].id,
            captureCursor: true,
            includeMicrophone: false,
            includeSystemAudio: false
        });

        console.log('✅ Recording started successfully!');
        console.log('   Recording for 3 seconds...\n');

        // Record for 3 seconds
        await new Promise(resolve => setTimeout(resolve, 3000));

        // Stop recording
        console.log('4️⃣ Stopping recording...');
        const result = await recorder.stopRecording();
        console.log('✅ Recording stopped successfully!');
        console.log('   Result:', result);

        // Check output file
        if (fs.existsSync(outputPath)) {
            const stats = fs.statSync(outputPath);
            console.log(`\n✅ Output file created: ${outputPath}`);
            console.log(`   File size: ${(stats.size / 1024).toFixed(2)} KB`);
        } else {
            console.log('\n⚠️ Output file not found (may still be finalizing)');
        }

        console.log('\n🎉 Test completed successfully! No crashes detected.');
        console.log('   The Electron crash fix appears to be working.\n');

    } catch (error) {
        console.error('\n❌ Test failed:', error.message);
        console.error('   Stack:', error.stack);
        process.exit(1);
    }
}

// Run test
testRecording().catch(error => {
    console.error('Fatal error:', error);
    process.exit(1);
});

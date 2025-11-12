const MacRecorder = require('./index');
const path = require('path');
const fs = require('fs');

// Test output dizini
const outputDir = path.join(__dirname, 'test-output');
if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
}

async function testDualRecording() {
    console.log('🎬 Dual Recording Test (Same Display, Two Files)\n');

    // İki ayrı recorder instance oluştur
    const recorder1 = new MacRecorder();
    const recorder2 = new MacRecorder();

    try {
        // Display'leri listele
        console.log('📋 Fetching available displays...');
        const displays = await recorder1.getDisplays();

        console.log(`\n✅ ${displays.length} display(s) found:\n`);
        displays.forEach((display, idx) => {
            console.log(`${idx + 1}. ${display.name}`);
            console.log(`   ID: ${display.id}, Resolution: ${display.resolution}`);
            console.log(`   Primary: ${display.isPrimary}`);
        });

        const mainDisplay = displays.find(d => d.isPrimary) || displays[0];

        console.log(`\n🎯 Will record main display twice simultaneously:`);
        console.log(`   Display: ${mainDisplay.name} (${mainDisplay.resolution})`);

        // Timestamp oluştur
        const timestamp = Date.now();

        // Output paths
        const outputPath1 = path.join(outputDir, `temp_screen_${timestamp}.mov`);
        const outputPath2 = path.join(outputDir, `temp_screen_1_${timestamp}.mov`);

        console.log(`\n📁 Output files:`);
        console.log(`   File 1: ${outputPath1}`);
        console.log(`   File 2: ${outputPath2}`);

        // Recording options
        const options = {
            displayId: mainDisplay.id,
            captureCursor: true,
            frameRate: 30,
            preferScreenCaptureKit: true
        };

        // Event listeners
        recorder1.on('recordingStarted', (info) => {
            console.log('✅ Recorder 1 started:', path.basename(info.outputPath));
        });

        recorder2.on('recordingStarted', (info) => {
            console.log('✅ Recorder 2 started:', path.basename(info.outputPath));
        });

        // Kayıtları başlat
        console.log('\n🚀 Starting recordings...\n');

        let recorder1Started = false;
        let recorder2Started = false;

        try {
            console.log('▶️  Starting Recorder 1...');
            await recorder1.startRecording(outputPath1, options);
            recorder1Started = true;
            console.log('   ✓ Recorder 1 started successfully');
        } catch (error) {
            console.error('   ❌ Recorder 1 failed:', error.message);
        }

        // Kısa bir bekleme
        await new Promise(resolve => setTimeout(resolve, 200));

        try {
            console.log('▶️  Starting Recorder 2...');
            await recorder2.startRecording(outputPath2, options);
            recorder2Started = true;
            console.log('   ✓ Recorder 2 started successfully');
        } catch (error) {
            console.error('   ❌ Recorder 2 failed:', error.message);
            console.log('   ℹ️  Expected behavior: Native module uses global state');
            console.log('      Only ONE recording can be active at a time');
        }

        // Status kontrol
        console.log('\n📊 Recording status:');
        console.log(`   Recorder 1: ${recorder1.isRecording ? '🔴 RECORDING' : '⚫ STOPPED'}`);
        console.log(`   Recorder 2: ${recorder2.isRecording ? '🔴 RECORDING' : '⚫ STOPPED'}`);

        // 3 saniye kaydet
        if (recorder1Started || recorder2Started) {
            console.log('\n⏱️  Recording for 3 seconds...\n');
            await new Promise(resolve => setTimeout(resolve, 3000));
        }

        // Kayıtları durdur
        console.log('🛑 Stopping recordings...\n');

        if (recorder1.isRecording) {
            try {
                console.log('   Stopping Recorder 1...');
                await recorder1.stopRecording();
                console.log('   ✓ Recorder 1 stopped');
            } catch (error) {
                console.error('   ❌ Error stopping Recorder 1:', error.message);
            }
        }

        if (recorder2.isRecording) {
            try {
                console.log('   Stopping Recorder 2...');
                await recorder2.stopRecording();
                console.log('   ✓ Recorder 2 stopped');
            } catch (error) {
                console.error('   ❌ Error stopping Recorder 2:', error.message);
            }
        }

        // Biraz bekle dosyaların yazılması için
        await new Promise(resolve => setTimeout(resolve, 500));

        // Dosyaları kontrol et
        console.log('\n📊 Checking output files:\n');

        const file1Exists = fs.existsSync(outputPath1);
        const file2Exists = fs.existsSync(outputPath2);

        console.log(`   File 1: ${file1Exists ? '✅ EXISTS' : '❌ NOT FOUND'}`);
        if (file1Exists) {
            const stats1 = fs.statSync(outputPath1);
            console.log(`           Size: ${(stats1.size / 1024 / 1024).toFixed(2)} MB`);
        }

        console.log(`   File 2: ${file2Exists ? '✅ EXISTS' : '❌ NOT FOUND'}`);
        if (file2Exists) {
            const stats2 = fs.statSync(outputPath2);
            console.log(`           Size: ${(stats2.size / 1024 / 1024).toFixed(2)} MB`);
        }

        // Sonuç ve analiz
        console.log('\n' + '='.repeat(70));
        console.log('📋 TEST RESULTS & ANALYSIS');
        console.log('='.repeat(70));

        if (file1Exists && file2Exists) {
            console.log('✅ SURPRISE: Both recordings were created!');
            console.log('   This suggests the implementation might support multiple recordings');
        } else if (file1Exists) {
            console.log('⚠️  EXPECTED RESULT: Only ONE recording created');
            console.log('\n💡 REASON:');
            console.log('   - Native module (screen_capture_kit.mm) uses GLOBAL state variables:');
            console.log('     • g_isRecording (global recording flag)');
            console.log('     • g_stream (single SCStream instance)');
            console.log('     • g_videoWriter (single AVAssetWriter)');
            console.log('     • g_outputPath (single output path)');
            console.log('\n   - When recorder2.startRecording() is called:');
            console.log('     1. Checks: g_isRecording = true (set by recorder1)');
            console.log('     2. Rejects with "Recording is already in progress"');
            console.log('\n🔧 TO ENABLE DUAL RECORDING:');
            console.log('   Need to refactor native code to support multiple streams:');
            console.log('   • Replace global variables with instance-based state');
            console.log('   • Use Map<sessionId, RecordingState>');
            console.log('   • Support multiple SCStream instances simultaneously');
        } else {
            console.log('❌ FAILED: No recordings were created');
        }

        console.log('='.repeat(70) + '\n');

    } catch (error) {
        console.error('\n❌ Test failed:', error.message);
        console.error(error.stack);
        process.exit(1);
    }
}

// Run test
testDualRecording().catch(error => {
    console.error('Fatal error:', error);
    process.exit(1);
});

const MacRecorder = require('./index-multiprocess');
const path = require('path');
const fs = require('fs');

// Test output dizini
const outputDir = path.join(__dirname, 'test-output');
if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
}

async function testMultiProcessRecording() {
    console.log('🎬 Multi-Process Dual Recording Test\n');
    console.log('='.repeat(70));

    // İki ayrı recorder instance oluştur (her biri kendi process'inde)
    const recorder1 = new MacRecorder();
    const recorder2 = new MacRecorder();

    // Wait for workers to be ready
    await new Promise(resolve => setTimeout(resolve, 500));

    try {
        // Display'leri listele
        console.log('\n📋 Fetching displays...');
        const displays = await recorder1.getDisplays();

        console.log(`✅ Found ${displays.length} display(s):\n`);
        displays.forEach((display, idx) => {
            console.log(`${idx + 1}. ${display.name} - ${display.resolution}`);
        });

        const mainDisplay = displays.find(d => d.isPrimary) || displays[0];

        // Timestamp oluştur
        const timestamp = Date.now();

        // Output paths - farklı dosyalar
        const outputPath1 = path.join(outputDir, `temp_screen_${timestamp}.mov`);
        const outputPath2 = path.join(outputDir, `temp_screen_1_${timestamp}.mov`);

        console.log(`\n📁 Output files:`);
        console.log(`   File 1: ${path.basename(outputPath1)}`);
        console.log(`   File 2: ${path.basename(outputPath2)}`);

        // Recording options
        const options = {
            displayId: mainDisplay.id,
            captureCursor: true,
            frameRate: 30,
            preferScreenCaptureKit: true
        };

        // Event listeners
        recorder1.on('recordingStarted', (info) => {
            console.log('✅ Recorder 1 STARTED');
        });

        recorder2.on('recordingStarted', (info) => {
            console.log('✅ Recorder 2 STARTED');
        });

        recorder1.on('stopped', () => {
            console.log('🛑 Recorder 1 STOPPED');
        });

        recorder2.on('stopped', () => {
            console.log('🛑 Recorder 2 STOPPED');
        });

        // Kayıtları başlat - SIRAYLA (ScreenCaptureKit initialization için)
        console.log('\n🚀 Starting recordings...\n');

        console.log('   Starting Recorder 1...');
        try {
            await recorder1.startRecording(outputPath1, options);
            console.log('   ✓ Recorder 1 started');
        } catch (err) {
            console.error('   ❌ Recorder 1 failed:', err.message);
        }

        // Kısa gecikme - ScreenCaptureKit'in tam başlaması için
        await new Promise(r => setTimeout(r, 1000));

        console.log('   Starting Recorder 2...');
        try {
            await recorder2.startRecording(outputPath2, options);
            console.log('   ✓ Recorder 2 started');
        } catch (err) {
            console.error('   ❌ Recorder 2 failed:', err.message);
        }

        // Status kontrol
        console.log('\n📊 Recording status:');
        const status1 = await recorder1.getStatus();
        const status2 = await recorder2.getStatus();

        console.log(`   Recorder 1: ${status1.isRecording ? '🔴 RECORDING' : '⚫ STOPPED'}`);
        console.log(`   Recorder 2: ${status2.isRecording ? '🔴 RECORDING' : '⚫ STOPPED'}`);

        // 5 saniye kaydet
        console.log('\n⏱️  Recording for 5 seconds...\n');
        await new Promise(resolve => setTimeout(resolve, 5000));

        // Kayıtları durdur - PARALEL!
        console.log('🛑 Stopping BOTH recordings...\n');

        const stopPromises = [
            recorder1.stopRecording()
                .then(() => console.log('   ✓ Recorder 1 stopped'))
                .catch(err => console.error('   ❌ Recorder 1 stop failed:', err.message)),
            recorder2.stopRecording()
                .then(() => console.log('   ✓ Recorder 2 stopped'))
                .catch(err => console.error('   ❌ Recorder 2 stop failed:', err.message))
        ];

        await Promise.all(stopPromises);

        // Biraz bekle dosyaların yazılması için
        await new Promise(resolve => setTimeout(resolve, 1000));

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

        // Sonuç
        console.log('\n' + '='.repeat(70));
        if (file1Exists && file2Exists) {
            console.log('🎉 SUCCESS: PARALLEL RECORDING WORKS!');
            console.log('   Both recordings completed simultaneously');
            console.log('   No native code changes needed!');
        } else if (file1Exists || file2Exists) {
            console.log('⚠️  PARTIAL: Only one recording created');
        } else {
            console.log('❌ FAILED: No recordings were created');
        }
        console.log('='.repeat(70) + '\n');

        // Cleanup workers
        recorder1.destroy();
        recorder2.destroy();

        process.exit(file1Exists && file2Exists ? 0 : 1);

    } catch (error) {
        console.error('\n❌ Test failed:', error.message);
        console.error(error.stack);

        recorder1.destroy();
        recorder2.destroy();

        process.exit(1);
    }
}

// Run test
testMultiProcessRecording().catch(error => {
    console.error('Fatal error:', error);
    process.exit(1);
});

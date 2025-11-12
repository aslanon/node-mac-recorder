const MacRecorder = require('./index');
const path = require('path');
const fs = require('fs');

// Test output dizini
const outputDir = path.join(__dirname, 'test-output');
if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
}

async function testDualWindowRecording() {
    console.log('🎬 Dual Window Recording Test\n');

    // İki ayrı recorder instance oluştur
    const recorder1 = new MacRecorder();
    const recorder2 = new MacRecorder();

    try {
        // Açık pencereleri listele
        console.log('📋 Fetching available windows...');
        const windows = await recorder1.getWindows();

        if (windows.length < 2) {
            console.error('❌ En az 2 açık pencere gerekli. Şu anda sadece', windows.length, 'pencere açık.');
            process.exit(1);
        }

        console.log(`\n✅ ${windows.length} açık pencere bulundu:\n`);
        windows.slice(0, 5).forEach((win, idx) => {
            console.log(`${idx + 1}. ${win.appName} - "${win.title}"`);
            console.log(`   ID: ${win.id}, Size: ${win.width}x${win.height}`);
        });

        // İlk iki pencereyi seç
        const window1 = windows[0];
        const window2 = windows[1];

        console.log(`\n🎯 Recording windows:`);
        console.log(`   Window 1: ${window1.appName} - "${window1.title}"`);
        console.log(`   Window 2: ${window2.appName} - "${window2.title}"`);

        // Timestamp oluştur
        const timestamp = Date.now();

        // Output paths
        const outputPath1 = path.join(outputDir, `temp_screen_${timestamp}.mov`);
        const outputPath2 = path.join(outputDir, `temp_screen_1_${timestamp}.mov`);

        console.log(`\n📁 Output files:`);
        console.log(`   File 1: ${outputPath1}`);
        console.log(`   File 2: ${outputPath2}`);

        // Recording options
        const options1 = {
            windowId: window1.id,
            captureCursor: true,
            frameRate: 30,
            preferScreenCaptureKit: true
        };

        const options2 = {
            windowId: window2.id,
            captureCursor: true,
            frameRate: 30,
            preferScreenCaptureKit: true
        };

        // Event listeners
        recorder1.on('recordingStarted', (info) => {
            console.log('✅ Recorder 1 started:', info.outputPath);
        });

        recorder2.on('recordingStarted', (info) => {
            console.log('✅ Recorder 2 started:', info.outputPath);
        });

        recorder1.on('stopped', () => {
            console.log('🛑 Recorder 1 stopped');
        });

        recorder2.on('stopped', () => {
            console.log('🛑 Recorder 2 stopped');
        });

        // Kayıtları başlat
        console.log('\n🚀 Starting recordings...\n');

        try {
            console.log('▶️  Starting Recorder 1...');
            await recorder1.startRecording(outputPath1, options1);
            console.log('   ✓ Recorder 1 started successfully');
        } catch (error) {
            console.error('   ❌ Recorder 1 failed:', error.message);
            throw error;
        }

        // Kısa bir bekleme
        await new Promise(resolve => setTimeout(resolve, 100));

        try {
            console.log('▶️  Starting Recorder 2...');
            await recorder2.startRecording(outputPath2, options2);
            console.log('   ✓ Recorder 2 started successfully');
        } catch (error) {
            console.error('   ❌ Recorder 2 failed:', error.message);
            console.log('   ℹ️  This is expected - current implementation may not support multiple simultaneous recordings');
        }

        // 5 saniye kaydet
        console.log('\n⏱️  Recording for 5 seconds...\n');
        await new Promise(resolve => setTimeout(resolve, 5000));

        // Kayıtları durdur
        console.log('🛑 Stopping recordings...\n');

        try {
            if (recorder1.isRecording) {
                console.log('   Stopping Recorder 1...');
                await recorder1.stopRecording();
                console.log('   ✓ Recorder 1 stopped');
            }
        } catch (error) {
            console.error('   ❌ Error stopping Recorder 1:', error.message);
        }

        try {
            if (recorder2.isRecording) {
                console.log('   Stopping Recorder 2...');
                await recorder2.stopRecording();
                console.log('   ✓ Recorder 2 stopped');
            }
        } catch (error) {
            console.error('   ❌ Error stopping Recorder 2:', error.message);
        }

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
        console.log('\n' + '='.repeat(60));
        if (file1Exists && file2Exists) {
            console.log('✅ SUCCESS: Both windows recorded simultaneously!');
        } else if (file1Exists) {
            console.log('⚠️  PARTIAL: Only first window recorded');
            console.log('   Current implementation may not support multiple simultaneous recordings');
        } else {
            console.log('❌ FAILED: No recordings were created');
        }
        console.log('='.repeat(60) + '\n');

    } catch (error) {
        console.error('\n❌ Test failed:', error.message);
        console.error(error.stack);
        process.exit(1);
    }
}

// Run test
testDualWindowRecording().catch(error => {
    console.error('Fatal error:', error);
    process.exit(1);
});

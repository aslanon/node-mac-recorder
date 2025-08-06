#!/usr/bin/env node

/**
 * Window Selector + MacRecorder Integration Example
 * Bu örnek, window selector ile seçilen pencereyi doğrudan kaydetmeyi gösterir
 */

const MacRecorder = require('../index');
const path = require('path');
const fs = require('fs');

async function recordSelectedWindow() {
    console.log('🎥 Window Selection + Recording Integration');
    console.log('==========================================\n');

    const recorder = new MacRecorder();
    const selector = new MacRecorder.WindowSelector();

    try {
        // 1. İzinleri kontrol et
        console.log('1️⃣ Checking permissions...');
        const permissions = await recorder.checkPermissions();
        console.log('Permissions:', permissions);
        
        if (!permissions.screenRecording) {
            console.warn('⚠️  Screen recording permission required!');
            return;
        }

        // 2. Pencere seç
        console.log('\n2️⃣ Select a window to record...');
        console.log('Move cursor over windows and click "Select Window" button\n');

        const selectedWindow = await selector.selectWindow();
        
        console.log('✅ Selected window:', {
            title: selectedWindow.title,
            app: selectedWindow.appName,
            size: `${selectedWindow.width}x${selectedWindow.height}`,
            position: `(${selectedWindow.x}, ${selectedWindow.y})`
        });

        // 3. Çıktı dosyası hazırla
        const outputDir = path.join(__dirname, '..', 'recordings');
        if (!fs.existsSync(outputDir)) {
            fs.mkdirSync(outputDir, { recursive: true });
        }

        const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
        const fileName = `${selectedWindow.appName}-${selectedWindow.title}-${timestamp}.mov`
            .replace(/[^\w\-_.]/g, '_')
            .substring(0, 100);
        const outputPath = path.join(outputDir, fileName);

        // 4. Kayıt ayarları
        const recordingOptions = {
            windowId: selectedWindow.id,
            captureCursor: true,
            includeMicrophone: false,
            includeSystemAudio: true,
            captureArea: {
                x: selectedWindow.x - selectedWindow.screenX,
                y: selectedWindow.y - selectedWindow.screenY,
                width: selectedWindow.width,
                height: selectedWindow.height
            }
        };

        console.log('\n3️⃣ Starting recording...');
        console.log(`Output: ${outputPath}`);
        console.log('Recording options:', recordingOptions);

        // 5. Kayıt başlat
        await recorder.startRecording(outputPath, recordingOptions);

        console.log('\n🔴 Recording started!');
        console.log('Recording will stop automatically after 10 seconds...');
        console.log('Or press Ctrl+C to stop manually\n');

        // Progress tracking
        let secondsRecorded = 0;
        const progressInterval = setInterval(() => {
            secondsRecorded++;
            process.stdout.write(`\r⏱️  Recording: ${secondsRecorded}s / 10s`);
        }, 1000);

        // Ctrl+C handler
        let recordingStopped = false;
        process.on('SIGINT', async () => {
            if (!recordingStopped) {
                recordingStopped = true;
                clearInterval(progressInterval);
                console.log('\n\n🛑 Stopping recording...');
                await recorder.stopRecording();
                console.log(`✅ Recording saved: ${outputPath}`);
                process.exit(0);
            }
        });

        // 6. 10 saniye sonra durdur
        setTimeout(async () => {
            if (!recordingStopped) {
                recordingStopped = true;
                clearInterval(progressInterval);
                console.log('\n\n⏹️  Auto-stopping recording...');
                await recorder.stopRecording();
                
                // Dosya oluşup oluşmadığını kontrol et
                setTimeout(() => {
                    if (fs.existsSync(outputPath)) {
                        const stats = fs.statSync(outputPath);
                        console.log(`✅ Recording completed successfully!`);
                        console.log(`📁 File: ${outputPath}`);
                        console.log(`📊 Size: ${(stats.size / 1024 / 1024).toFixed(2)} MB`);
                        console.log('\n🎬 You can now play the video file!');
                    } else {
                        console.log('⚠️  Recording file not found. Check permissions and try again.');
                    }
                    process.exit(0);
                }, 2000);
            }
        }, 10000);

    } catch (error) {
        console.error('\n❌ Error:', error.message);
        console.error(error.stack);
    } finally {
        await selector.cleanup();
    }
}

async function selectAndAnalyze() {
    console.log('📊 Window Selection + Analysis Example');
    console.log('======================================\n');

    const selector = new MacRecorder.WindowSelector();

    try {
        console.log('Select a window to analyze...\n');
        const window = await selector.selectWindow();

        console.log('\n🔍 Window Analysis Report');
        console.log('=========================');
        
        // Basic info
        console.log(`📱 Application: ${window.appName}`);
        console.log(`🏷️  Title: "${window.title}"`);
        console.log(`🆔 Window ID: ${window.id}`);
        
        // Dimensions
        console.log(`\n📐 Dimensions:`);
        console.log(`   Size: ${window.width} x ${window.height}`);
        console.log(`   Area: ${(window.width * window.height).toLocaleString()} pixels`);
        console.log(`   Aspect Ratio: ${(window.width / window.height).toFixed(2)}`);
        
        // Position
        console.log(`\n📍 Position:`);
        console.log(`   Global: (${window.x}, ${window.y})`);
        console.log(`   Screen: ${window.screenId} at (${window.screenX}, ${window.screenY})`);
        console.log(`   Relative: (${window.x - window.screenX}, ${window.y - window.screenY})`);
        
        // Screen info
        console.log(`\n🖥️  Screen:`);
        console.log(`   Size: ${window.screenWidth} x ${window.screenHeight}`);
        console.log(`   Coverage: ${((window.width * window.height) / (window.screenWidth * window.screenHeight) * 100).toFixed(1)}%`);
        
        // Recording recommendation
        console.log(`\n🎥 Recording Recommendations:`);
        const area = window.width * window.height;
        if (area > 2000000) { // > 2M pixels
            console.log('   📺 Large window - Good for detailed content recording');
        } else if (area > 500000) { // > 500K pixels  
            console.log('   📄 Medium window - Standard recording quality');
        } else {
            console.log('   📝 Small window - Consider increasing size for better quality');
        }

        const aspectRatio = window.width / window.height;
        if (Math.abs(aspectRatio - 16/9) < 0.1) {
            console.log('   🎬 16:9 aspect ratio - Perfect for video content');
        } else if (Math.abs(aspectRatio - 4/3) < 0.1) {
            console.log('   📺 4:3 aspect ratio - Classic format');
        } else if (aspectRatio > 2) {
            console.log('   📱 Wide aspect ratio - Good for dashboard/IDE content');
        } else {
            console.log('   📄 Custom aspect ratio');
        }

        console.log(`\n✨ Analysis complete!`);

    } catch (error) {
        console.error('❌ Analysis failed:', error.message);
    } finally {
        await selector.cleanup();
    }
}

// Main function
async function main() {
    const args = process.argv.slice(2);
    
    if (args.includes('--help')) {
        console.log('Integration Examples:');
        console.log('====================');
        console.log('node examples/integration-example.js [option]');
        console.log('');
        console.log('Options:');
        console.log('  --record     Select and record a window (default)');
        console.log('  --analyze    Select and analyze a window');
        console.log('  --help       Show this help');
        return;
    }
    
    if (args.includes('--analyze')) {
        await selectAndAnalyze();
    } else {
        await recordSelectedWindow();
    }
}

if (require.main === module) {
    main().catch(console.error);
}

module.exports = {
    recordSelectedWindow,
    selectAndAnalyze
};
/**
 * Test timestamp synchronization across all files
 */

const MultiWindowRecorder = require('./MultiWindowRecorder');
const MacRecorder = require('./index');
const path = require('path');
const fs = require('fs');

const outputDir = path.join(__dirname, 'test-output');
if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
}

async function testTimestampSync() {
    console.log('🧪 Testing Timestamp Synchronization\n');
    console.log('='.repeat(70));

    const tempRecorder = new MacRecorder();
    const windows = await tempRecorder.getWindows();

    if (windows.length < 2) {
        console.error('\n❌ Need at least 2 windows open');
        process.exit(1);
    }

    console.log(`\n📋 Found ${windows.length} windows\n`);

    const validWindows = windows.filter(w =>
        w.appName !== 'Dock' && w.width > 100 && w.height > 100
    ).slice(0, 2);

    if (validWindows.length < 2) {
        console.error('❌ Not enough valid windows');
        process.exit(1);
    }

    console.log('🎯 Selected Windows:\n');
    validWindows.forEach((win, i) => {
        console.log(`${i + 1}. ${win.appName} - "${win.title}"`);
    });

    console.log('\n' + '='.repeat(70));
    console.log('\n🎬 Creating MultiWindowRecorder with camera + microphone...\n');

    const multiRecorder = new MultiWindowRecorder({
        frameRate: 30,
        enableMicrophone: true,      // Enable microphone
        captureSystemAudio: false,   // Disable system audio to simplify
        enableCamera: true,          // Enable camera
        trackCursor: true            // Enable cursor tracking
    });

    try {
        console.log('➕ Adding windows...\n');
        await multiRecorder.addWindow(validWindows[0]);
        await multiRecorder.addWindow(validWindows[1]);

        console.log('\n' + '='.repeat(70));
        console.log('\n🚀 Starting recording...\n');

        await multiRecorder.startRecording(outputDir);

        console.log('\n⏱️  Recording for 3 seconds...\n');
        await new Promise(r => setTimeout(r, 3000));

        console.log('🛑 Stopping recording...\n');
        const result = await multiRecorder.stopRecording();

        // Check file timestamps
        console.log('\n' + '='.repeat(70));
        console.log('\n📊 CHECKING FILE TIMESTAMPS:\n');

        const allFiles = fs.readdirSync(outputDir).filter(f =>
            f.startsWith('temp_') && (f.endsWith('.mov') || f.endsWith('.json'))
        );

        console.log(`Found ${allFiles.length} temp files:\n`);

        const timestampPattern = /(\d{13})/;
        const timestamps = new Map();

        allFiles.forEach(file => {
            const match = file.match(timestampPattern);
            if (match) {
                const ts = match[1];
                if (!timestamps.has(ts)) {
                    timestamps.set(ts, []);
                }
                timestamps.get(ts).push(file);
            }
            console.log(`   ${file}`);
        });

        console.log('\n📈 Timestamp Analysis:\n');

        if (timestamps.size === 1) {
            console.log('✅ SUCCESS: All files use the SAME timestamp!');
            const [ts, files] = Array.from(timestamps.entries())[0];
            console.log(`\n   Timestamp: ${ts}`);
            console.log(`   Files (${files.length}):`);
            files.forEach(f => console.log(`      - ${f}`));
        } else {
            console.log(`❌ FAILED: Found ${timestamps.size} different timestamps:`);
            timestamps.forEach((files, ts) => {
                console.log(`\n   Timestamp: ${ts}`);
                console.log(`   Files (${files.length}):`);
                files.forEach(f => console.log(`      - ${f}`));
            });
        }

        console.log('\n' + '='.repeat(70));
        console.log('\n🧹 Cleaning up...\n');
        multiRecorder.destroy();

        console.log('='.repeat(70));
        if (timestamps.size === 1) {
            console.log('\n🎉 TEST PASSED: All files synchronized!\n');
        } else {
            console.log('\n❌ TEST FAILED: Timestamps not synchronized\n');
            process.exit(1);
        }

    } catch (error) {
        console.error('\n❌ TEST FAILED:', error.message);
        console.error(error.stack);
        multiRecorder.destroy();
        process.exit(1);
    }
}

testTimestampSync().catch(error => {
    console.error('Fatal error:', error);
    process.exit(1);
});

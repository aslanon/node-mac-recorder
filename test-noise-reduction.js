const MacRecorder = require('./index.js');
const path = require('path');
const fs = require('fs');

// Test output directory
const outputDir = path.join(__dirname, 'test-output');
if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
}

const timestamp = Date.now();
const outputPath = path.join(outputDir, `noise-reduction-test-${timestamp}.mov`);

console.log('🎙️  Starting microphone recording with noise reduction...');
console.log('📝 Instructions:');
console.log('   1. Speak into your microphone (normal voice)');
console.log('   2. Type on your keyboard (heavy typing)');
console.log('   3. Click your mouse multiple times');
console.log('   4. Speak again to compare');
console.log('');
console.log('⏱️  Recording for 15 seconds...');
console.log('');

const recorder = new MacRecorder();

recorder.on('recordingStarted', () => {
    console.log('✅ Recording started!');
    console.log('🎤 Custom noise reduction is ACTIVE');
    console.log('');
    console.log('Starting countdown:');

    let countdown = 15;
    const interval = setInterval(() => {
        process.stdout.write(`\r⏱️  ${countdown} seconds remaining...  `);
        countdown--;

        if (countdown < 0) {
            clearInterval(interval);
            process.stdout.write('\r');
            console.log('⏱️  Time up! Stopping...');
            console.log('');

            recorder.stopRecording()
                .then(() => {
                    console.log('✅ Recording saved to:', outputPath);
                    console.log('');
                    console.log('🎧 Play the recording to verify:');
                    console.log(`   open "${outputPath}"`);
                    console.log('');
                    console.log('Expected results:');
                    console.log('   ✅ Voice should be clear');
                    console.log('   ✅ Keyboard typing should be significantly reduced');
                    console.log('   ✅ Mouse clicks should be filtered out');
                    process.exit(0);
                })
                .catch(err => {
                    console.error('❌ Error stopping:', err);
                    process.exit(1);
                });
        }
    }, 1000);
});

recorder.on('stopped', () => {
    console.log('🛑 Recording stopped');
});

recorder.on('completed', (result) => {
    console.log('✅ Recording completed:', result);
});

// Start recording with microphone
recorder.startRecording(outputPath, {
    includeMicrophone: true,
    includeSystemAudio: false,
    fps: 1 // Minimal FPS since we're only testing audio
}).catch(err => {
    console.error('❌ Failed to start recording:', err);
    process.exit(1);
});

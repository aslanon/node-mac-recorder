#!/usr/bin/env node

const MacRecorder = require('./index');

async function testAudioControls() {
    console.log('🎵 Audio Control Test');
    console.log('====================\n');

    const recorder = new MacRecorder();

    try {
        // Test initial state
        console.log('📋 Initial Audio State:');
        console.log(`   Microphone: ${recorder.isMicrophoneEnabled() ? '🎤 ON' : '🔇 OFF'}`);
        console.log(`   System Audio: ${recorder.isSystemAudioEnabled() ? '🔊 ON' : '🔇 OFF'}\n`);

        // Test individual controls
        console.log('🔧 Testing Individual Controls:\n');
        
        console.log('   Enabling microphone...');
        recorder.setMicrophoneEnabled(true);
        console.log(`   Microphone: ${recorder.isMicrophoneEnabled() ? '🎤 ON' : '🔇 OFF'}`);
        
        console.log('   Enabling system audio...');
        recorder.setSystemAudioEnabled(true);
        console.log(`   System Audio: ${recorder.isSystemAudioEnabled() ? '🔊 ON' : '🔇 OFF'}\n`);

        console.log('   Disabling microphone...');
        recorder.setMicrophoneEnabled(false);
        console.log(`   Microphone: ${recorder.isMicrophoneEnabled() ? '🎤 ON' : '🔇 OFF'}`);
        
        console.log('   Disabling system audio...');
        recorder.setSystemAudioEnabled(false);
        console.log(`   System Audio: ${recorder.isSystemAudioEnabled() ? '🔊 ON' : '🔇 OFF'}\n`);

        // Test bulk settings
        console.log('🔧 Testing Bulk Audio Settings:\n');
        
        console.log('   Setting both to ON...');
        let settings = recorder.setAudioSettings({
            microphone: true,
            systemAudio: true
        });
        console.log(`   Result: Microphone=${settings.microphone ? 'ON' : 'OFF'}, System Audio=${settings.systemAudio ? 'ON' : 'OFF'}\n`);

        console.log('   Setting microphone OFF, system audio ON...');
        settings = recorder.setAudioSettings({
            microphone: false,
            systemAudio: true
        });
        console.log(`   Result: Microphone=${settings.microphone ? 'ON' : 'OFF'}, System Audio=${settings.systemAudio ? 'ON' : 'OFF'}\n`);

        // Test recording with different audio settings
        const testOutput = `./test-output/audio-test-${Date.now()}.mov`;
        
        console.log('🎬 Testing Recording with Audio Settings:\n');
        
        // Test 1: No audio
        console.log('   Test 1: No Audio Recording');
        recorder.setAudioSettings({ microphone: false, systemAudio: false });
        console.log(`   Starting 3-second recording: ${testOutput}`);
        console.log(`   Audio settings: Mic=${recorder.isMicrophoneEnabled() ? 'ON' : 'OFF'}, System=${recorder.isSystemAudioEnabled() ? 'ON' : 'OFF'}`);
        
        await recorder.startRecording(testOutput);
        await new Promise(resolve => setTimeout(resolve, 3000));
        await recorder.stopRecording();
        console.log('   ✅ Recording completed (no audio)\n');

        // Test 2: Microphone only
        console.log('   Test 2: Microphone Only Recording');
        recorder.setAudioSettings({ microphone: true, systemAudio: false });
        const testOutput2 = `./test-output/audio-test-mic-${Date.now()}.mov`;
        console.log(`   Starting 3-second recording: ${testOutput2}`);
        console.log(`   Audio settings: Mic=${recorder.isMicrophoneEnabled() ? 'ON' : 'OFF'}, System=${recorder.isSystemAudioEnabled() ? 'ON' : 'OFF'}`);
        
        await recorder.startRecording(testOutput2);
        await new Promise(resolve => setTimeout(resolve, 3000));
        await recorder.stopRecording();
        console.log('   ✅ Recording completed (microphone only)\n');

        // Test 3: System audio only
        console.log('   Test 3: System Audio Only Recording');
        recorder.setAudioSettings({ microphone: false, systemAudio: true });
        const testOutput3 = `./test-output/audio-test-system-${Date.now()}.mov`;
        console.log(`   Starting 3-second recording: ${testOutput3}`);
        console.log(`   Audio settings: Mic=${recorder.isMicrophoneEnabled() ? 'ON' : 'OFF'}, System=${recorder.isSystemAudioEnabled() ? 'ON' : 'OFF'}`);
        
        await recorder.startRecording(testOutput3);
        await new Promise(resolve => setTimeout(resolve, 3000));
        await recorder.stopRecording();
        console.log('   ✅ Recording completed (system audio only)\n');

        console.log('✅ All audio control tests completed successfully!');
        console.log('\n📁 Check test-output/ directory for video files.');

    } catch (error) {
        console.error('\n❌ Test failed:', error.message);
        process.exit(1);
    }
}

if (require.main === module) {
    testAudioControls();
}
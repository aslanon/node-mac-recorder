const MacRecorder = require('./index');

function testAudioCapture() {
    console.log('🎵 Testing ScreenCaptureKit Audio Capture...\n');
    
    const recorder = new MacRecorder();
    let testCompleted = false;
    
    // Set timeout to prevent hanging
    setTimeout(() => {
        if (!testCompleted) {
            console.log('⚠️ Test timed out after 10 seconds');
            process.exit(0);
        }
    }, 10000);
    
    try {
        console.log('📱 Testing audio device enumeration...');
        
        // Test audio device enumeration - this should work without permissions
        const startTime = Date.now();
        
        recorder.getAudioDevices((err, audioDevices) => {
            const elapsed = Date.now() - startTime;
            console.log(`⏱️  getAudioDevices took ${elapsed}ms`);
            
            if (err) {
                console.error('❌ getAudioDevices failed:', err);
                testCompleted = true;
                return;
            }
            
            console.log(`✅ Found ${audioDevices.length} audio devices:`);
            
            audioDevices.slice(0, 5).forEach((device, index) => {
                console.log(`${index + 1}. "${device.name}" (${device.manufacturer || 'Unknown'})`);
                console.log(`   ID: ${device.id}`);
                console.log(`   Default: ${device.isDefault ? 'Yes' : 'No'}`);
                if (device.isSystemDevice) {
                    console.log(`   System Device: ${device.isSystemDevice ? 'Yes' : 'No'}`);
                }
                console.log('');
            });
            
            // Test permissions
            console.log('🔐 Testing audio permissions...');
            
            recorder.checkPermissions((err, hasPermissions) => {
                const elapsed2 = Date.now() - startTime;
                console.log(`⏱️  checkPermissions took ${elapsed2 - elapsed}ms`);
                
                if (err) {
                    console.error('❌ checkPermissions failed:', err);
                } else {
                    console.log(`✅ Permissions status: ${hasPermissions ? 'Granted' : 'Not granted'}`);
                }
                
                // Test microphone-specific features if available
                if (audioDevices.length > 0) {
                    const micDevice = audioDevices.find(d => d.isDefault && !d.isSystemDevice);
                    const systemDevice = audioDevices.find(d => d.isSystemDevice);
                    
                    if (micDevice) {
                        console.log(`🎤 Default microphone: "${micDevice.name}"`);
                        console.log(`   This would be used for includeMicrophone: true`);
                    }
                    
                    if (systemDevice) {
                        console.log(`🔊 System audio device found: "${systemDevice.name}"`);
                        console.log(`   This would be used for includeSystemAudio: true`);
                    } else {
                        console.log('⚠️ No system audio device detected');
                        console.log('   For system audio capture, consider installing BlackHole or similar');
                    }
                }
                
                console.log('\n✅ Audio capture tests completed successfully!');
                console.log('\n📝 Audio Configuration Summary:');
                console.log(`   • Total audio devices: ${audioDevices.length}`);
                console.log(`   • Microphone devices: ${audioDevices.filter(d => !d.isSystemDevice).length}`);
                console.log(`   • System audio devices: ${audioDevices.filter(d => d.isSystemDevice).length}`);
                console.log(`   • Permissions: ${hasPermissions ? '✅ Granted' : '❌ Need to grant'}`);
                
                testCompleted = true;
            });
        });
        
    } catch (error) {
        console.error('❌ Audio capture test failed:', error);
        testCompleted = true;
    }
}

testAudioCapture();
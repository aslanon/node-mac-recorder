<<<<<<< HEAD
const nativeBinding = require('./build/Release/mac_recorder.node');

console.log('=== ScreenCaptureKit Migration Test ===');
console.log('ScreenCaptureKit available:', nativeBinding.isScreenCaptureKitAvailable());
console.log('Displays:', nativeBinding.getDisplays().length);
console.log('Audio devices:', nativeBinding.getAudioDevices().length);
console.log('Permissions OK:', nativeBinding.checkPermissions());

const displays = nativeBinding.getDisplays();
console.log('\nDisplay info:', displays[0]);

const audioDevices = nativeBinding.getAudioDevices();
console.log('\nFirst audio device:', audioDevices[0]);

// Test starting and stopping recording
console.log('\n=== Recording Test ===');
const outputPath = '/tmp/test-recording-sck.mov';

try {
    console.log('Starting recording...');
    const success = nativeBinding.startRecording(outputPath, {
        displayId: displays[0].id,
        captureCursor: true,
        includeMicrophone: false,
        includeSystemAudio: false
    });
    
    console.log('Recording started:', success);
    
    if (success) {
        setTimeout(() => {
            console.log('Stopping recording...');
            const stopped = nativeBinding.stopRecording();
            console.log('Recording stopped:', stopped);
            
            // Check if file was created
            const fs = require('fs');
            setTimeout(() => {
                if (fs.existsSync(outputPath)) {
                    const stats = fs.statSync(outputPath);
                    console.log(`Recording file created: ${outputPath} (${stats.size} bytes)`);
                } else {
                    console.log('Recording file not found');
                }
            }, 1000);
        }, 3000); // Record for 3 seconds
    }
} catch (error) {
    console.error('Recording test failed:', error.message);
}
=======
const MacRecorder = require('./index');

function testScreenCaptureKit() {
    console.log('Testing ScreenCaptureKit migration...');
    
    const recorder = new MacRecorder();
    
    try {
        // Test getting displays
        console.log('\n1. Testing getDisplays()');
        recorder.getDisplays((err, displays) => {
            if (err) {
                console.error('getDisplays failed:', err);
                return;
            }
            console.log(`Found ${displays.length} displays:`, displays);
            
            // Test getting windows
            console.log('\n2. Testing getWindows()');
            recorder.getWindows((err, windows) => {
                if (err) {
                    console.error('getWindows failed:', err);
                    return;
                }
                console.log(`Found ${windows.length} windows:`, windows.slice(0, 3));
                
                // Test getting audio devices
                console.log('\n3. Testing getAudioDevices()');
                recorder.getAudioDevices((err, audioDevices) => {
                    if (err) {
                        console.error('getAudioDevices failed:', err);
                        return;
                    }
                    console.log(`Found ${audioDevices.length} audio devices:`, audioDevices.slice(0, 3));
                    
                    // Test permissions
                    console.log('\n4. Testing checkPermissions()');
                    recorder.checkPermissions((err, hasPermissions) => {
                        if (err) {
                            console.error('checkPermissions failed:', err);
                            return;
                        }
                        console.log(`Has permissions: ${hasPermissions}`);
                        
                        console.log('\n✅ All basic tests passed! ScreenCaptureKit migration successful.');
                    });
                });
            });
        });
        
    } catch (error) {
        console.error('❌ Test failed:', error);
    }
}

testScreenCaptureKit();
>>>>>>> screencapture

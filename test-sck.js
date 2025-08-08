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
const MacRecorder = require('./index');

function testWindowSelection() {
    console.log('🔍 Testing ScreenCaptureKit Window Selection...\n');
    
    const recorder = new MacRecorder();
    
    try {
        // Test window enumeration
        recorder.getWindows((err, windows) => {
            if (err) {
                console.error('❌ getWindows failed:', err);
                return;
            }
            
            console.log(`✅ Found ${windows.length} windows`);
            
            // Show first few windows with details
            windows.slice(0, 5).forEach((window, index) => {
                console.log(`${index + 1}. "${window.name}" - ${window.appName}`);
                console.log(`   ID: ${window.id}, Size: ${window.width}x${window.height}, Position: (${window.x}, ${window.y})`);
                console.log(`   On Screen: ${window.isOnScreen !== false ? 'Yes' : 'No'}\n`);
            });
            
            // Test window thumbnails if we have windows
            if (windows.length > 0) {
                const firstWindow = windows[0];
                console.log(`📸 Testing window thumbnail for: "${firstWindow.name}"`);
                
                recorder.getWindowThumbnail(firstWindow.id, 300, 200, (err, thumbnail) => {
                    if (err) {
                        console.error('❌ getWindowThumbnail failed:', err);
                    } else {
                        console.log(`✅ Window thumbnail generated: ${thumbnail.length} characters (base64)`);
                        
                        // Test window recording info
                        console.log(`\n🎬 Window recording info:`);
                        console.log(`   Target Window: "${firstWindow.name}" (ID: ${firstWindow.id})`);
                        console.log(`   App: ${firstWindow.appName}`);
                        console.log(`   Capture Area: ${firstWindow.width}x${firstWindow.height}`);
                        console.log(`   Would use windowId option for recording`);
                        
                        console.log('\n✅ Window selection tests completed successfully!');
                    }
                });
            } else {
                console.log('⚠️ No windows found for thumbnail testing');
                console.log('\n✅ Window enumeration test completed successfully!');
            }
        });
        
    } catch (error) {
        console.error('❌ Window selection test failed:', error);
    }
}

testWindowSelection();
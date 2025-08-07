const MacRecorder = require('./index');

async function testOverlayImprovements() {
    console.log('🎯 Testing Overlay Improvements\n');
    
    const recorder = new MacRecorder();
    const WindowSelector = MacRecorder.WindowSelector;
    const selector = new WindowSelector();
    
    try {
        console.log('1️⃣ Testing Window Selection with custom buttons...');
        console.log('   - Custom "Start Record" and "Cancel" buttons should appear');
        console.log('   - ESC key should cancel selection');
        console.log('   - Cancel button should cancel selection');
        console.log('   - Starting window selection...\n');
        
        // Start window selection (non-blocking)
        await selector.startSelection();
        
        console.log('✅ Window selection started. Move mouse over windows to see overlay.');
        console.log('   - Press ESC to cancel');
        console.log('   - Click Cancel button to cancel');
        console.log('   - Click Start Record to select window\n');
        
        // Wait for selection or timeout
        const startTime = Date.now();
        const timeout = 30000; // 30 seconds
        
        while (selector.getStatus().isSelecting && (Date.now() - startTime) < timeout) {
            await new Promise(resolve => setTimeout(resolve, 100));
        }
        
        const selectedWindow = selector.getSelectedWindow();
        
        if (selectedWindow) {
            console.log('🎬 Window selected:', selectedWindow.appName, '-', selectedWindow.title);
            console.log('   Size:', selectedWindow.width + 'x' + selectedWindow.height);
            console.log('   Position: (' + selectedWindow.x + ', ' + selectedWindow.y + ')');
            
            console.log('\n2️⃣ Testing Recording Preview Overlay...');
            console.log('   - Should show darkened overlay with window area transparent');
            
            await selector.showRecordingPreview(selectedWindow);
            console.log('✅ Recording preview shown. Check if window area is highlighted.');
            
            // Wait 3 seconds
            await new Promise(resolve => setTimeout(resolve, 3000));
            
            await selector.hideRecordingPreview();
            console.log('✅ Recording preview hidden.');
            
        } else {
            console.log('🚫 No window selected (cancelled or timeout)');
        }
        
        console.log('\n3️⃣ Testing Screen Selection with custom buttons...');
        console.log('   - Custom "Start Record" and "Cancel" buttons should appear on each screen');
        console.log('   - ESC key should cancel selection');
        console.log('   - Cancel button should cancel selection');
        
        const selectedScreen = await selector.selectScreen().catch(err => {
            console.log('🚫 Screen selection cancelled:', err.message);
            return null;
        });
        
        if (selectedScreen) {
            console.log('🖥️ Screen selected:', selectedScreen.name);
            console.log('   Resolution:', selectedScreen.resolution);
            console.log('   Position: (' + selectedScreen.x + ', ' + selectedScreen.y + ')');
        } else {
            console.log('🚫 No screen selected (cancelled or timeout)');
        }
        
        console.log('\n🎉 Overlay improvements test completed!');
        
    } catch (error) {
        console.error('❌ Test failed:', error.message);
    } finally {
        await selector.cleanup();
    }
}

// Run test
testOverlayImprovements().catch(console.error);
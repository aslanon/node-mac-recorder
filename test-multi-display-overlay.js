#!/usr/bin/env node

const WindowSelector = require('./window-selector');

async function testMultiDisplayOverlay() {
    console.log('🖥️ Multi-Display Overlay Test');
    console.log('=============================\n');

    const selector = new WindowSelector();
    
    try {
        // Check permissions first
        const permissions = await selector.checkPermissions();
        console.log('🔐 Permissions:');
        console.log(`   Screen Recording: ${permissions.screenRecording ? '✅' : '❌'}`);
        console.log(`   Accessibility: ${permissions.accessibility ? '✅' : '❌'}\n`);

        // Get display information
        const MacRecorder = require('./index');
        const recorder = new MacRecorder();
        const displays = await recorder.getDisplays();
        
        console.log(`🖥️ Found ${displays.length} display(s):`);
        displays.forEach((display, index) => {
            console.log(`   Display ${index + 1}: ${display.name} (${display.resolution}) at (${display.x}, ${display.y}) ${display.isPrimary ? '🌟 PRIMARY' : ''}`);
        });
        console.log('');

        if (displays.length < 2) {
            console.log('⚠️ Only one display detected. Connect a second display to fully test multi-display overlay functionality.');
            console.log('Continuing with single display test...\n');
        }

        let windowDetectionCount = 0;
        let displaySwitchCount = 0;
        let lastDisplayId = null;

        // Event listeners for detailed tracking
        selector.on('windowEntered', (window) => {
            windowDetectionCount++;
            
            // Try to determine which display this window is on
            let windowDisplayId = null;
            const windowCenterX = window.x + window.width / 2;
            const windowCenterY = window.y + window.height / 2;
            
            for (const display of displays) {
                if (windowCenterX >= display.x && 
                    windowCenterX < display.x + display.width &&
                    windowCenterY >= display.y && 
                    windowCenterY < display.y + display.height) {
                    windowDisplayId = display.id;
                    break;
                }
            }
            
            if (windowDisplayId !== lastDisplayId) {
                displaySwitchCount++;
                lastDisplayId = windowDisplayId;
            }
            
            const displayName = displays.find(d => d.id === windowDisplayId)?.name || 'Unknown';
            
            console.log(`\n🎯 WINDOW DETECTED #${windowDetectionCount}:`);
            console.log(`   App: ${window.appName}`);
            console.log(`   Title: "${window.title}"`);
            console.log(`   Position: (${window.x}, ${window.y})`);
            console.log(`   Size: ${window.width} × ${window.height}`);
            console.log(`   🖥️ Estimated Display: ${displayName} (ID: ${windowDisplayId})`);
            console.log(`   Display switches so far: ${displaySwitchCount}`);
            
            if (displays.length > 1) {
                console.log(`\n💡 Multi-Display Test Instructions:`);
                console.log(`   • Move cursor to windows on different displays`);
                console.log(`   • Overlay should follow cursor across displays`);
                console.log(`   • Window detection should work on all displays`);
            }
        });

        selector.on('windowLeft', (window) => {
            console.log(`\n🚪 LEFT WINDOW: ${window.appName} - "${window.title}"`);
        });

        selector.on('windowSelected', (selectedWindow) => {
            console.log('\n' + '🎉'.repeat(20));
            console.log('🎯 WINDOW SELECTED!');
            console.log('🎉'.repeat(20));
            
            const selectedDisplayName = displays.find(d => 
                selectedWindow.x >= d.x && 
                selectedWindow.x < d.x + d.width &&
                selectedWindow.y >= d.y && 
                selectedWindow.y < d.y + d.height
            )?.name || 'Unknown';
            
            console.log(`\n📊 Selection Results:`);
            console.log(`   Selected: ${selectedWindow.appName} - "${selectedWindow.title}"`);
            console.log(`   Position: (${selectedWindow.x}, ${selectedWindow.y})`);
            console.log(`   Size: ${selectedWindow.width} × ${selectedWindow.height}`);
            console.log(`   Display: ${selectedDisplayName}`);
            console.log(`\n📈 Test Statistics:`);
            console.log(`   Total window detections: ${windowDetectionCount}`);
            console.log(`   Display switches: ${displaySwitchCount}`);
            console.log(`   Multi-display support: ${displaySwitchCount > 0 || displays.length === 1 ? '✅' : '❌'}`);
            
            process.exit(0);
        });

        // Interactive selection with instructions
        console.log('🚀 Starting multi-display overlay test...\n');
        console.log('📋 Test Instructions:');
        console.log('   1. Move your cursor to windows on different displays');
        console.log('   2. Watch for overlay following cursor across displays');
        console.log('   3. Verify window detection works on all displays');
        console.log('   4. Press ENTER when you want to select a window');
        console.log('   5. Press ESC or Ctrl+C to cancel\n');

        if (displays.length > 1) {
            console.log('🖥️ Multi-Display Tips:');
            console.log('   • Try windows on both primary and secondary displays');
            console.log('   • Move cursor quickly between displays to test overlay tracking');
            console.log('   • Overlay should appear on the display where the cursor is\n');
        }

        // Setup manual selection with ENTER key
        const readline = require('readline');
        const rl = readline.createInterface({
            input: process.stdin,
            output: process.stdout
        });

        rl.on('line', () => {
            // Get current status to see if there's a window under cursor
            const status = selector.getStatus();
            if (status.nativeStatus && status.nativeStatus.currentWindow) {
                selector.emit('windowSelected', status.nativeStatus.currentWindow);
            } else {
                console.log('\n⚠️ No window under cursor. Move cursor over a window first.');
            }
        });

        await selector.startSelection();

        // Status monitoring
        let statusCount = 0;
        const statusInterval = setInterval(() => {
            statusCount++;
            
            if (statusCount % 40 === 0) { // Every 20 seconds
                console.log(`\n⏱️ Status Update (${statusCount/2}s):`);
                console.log(`   Window detections: ${windowDetectionCount}`);
                console.log(`   Display switches: ${displaySwitchCount}`);
                console.log(`   Current displays: ${displays.length}`);
                if (displays.length > 1) {
                    console.log(`   Multi-display overlay: ${displaySwitchCount > 0 ? '✅ Working' : '⏳ Waiting for cross-display movement'}`);
                }
            }
        }, 500);

        // Graceful shutdown
        process.on('SIGINT', async () => {
            clearInterval(statusInterval);
            rl.close();
            
            console.log('\n\n🛑 Test stopped by user');
            console.log('\n📊 Final Test Results:');
            console.log(`   Total window detections: ${windowDetectionCount}`);
            console.log(`   Display switches observed: ${displaySwitchCount}`);
            console.log(`   Displays available: ${displays.length}`);
            console.log(`   Multi-display support: ${displaySwitchCount > 0 || displays.length === 1 ? '✅ WORKING' : '❌ NEEDS INVESTIGATION'}`);
            
            await selector.cleanup();
            console.log('✅ Cleanup completed');
            process.exit(0);
        });

    } catch (error) {
        console.error('\n❌ Test failed:', error.message);
        process.exit(1);
    }
}

if (require.main === module) {
    testMultiDisplayOverlay();
}
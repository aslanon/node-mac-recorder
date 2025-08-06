#!/usr/bin/env node

const WindowSelector = require('./window-selector');
const readline = require('readline');

async function main() {
    console.log('🔍 Window Selector Test');
    console.log('=======================\n');

    const selector = new WindowSelector();

    try {
        // Permissions kontrolü
        console.log('1️⃣ Checking permissions...');
        const permissions = await selector.checkPermissions();
        console.log('Permissions:', permissions);
        
        if (!permissions.screenRecording || !permissions.accessibility) {
            console.warn('⚠️ Warning: Some permissions missing. Go to System Preferences > Security & Privacy');
            console.warn('   - Privacy > Screen Recording: Enable for Terminal/Node');
            console.warn('   - Privacy > Accessibility: Enable for Terminal/Node');
            console.log();
        }

        // Event listener'ları ayarla
        selector.on('selectionStarted', () => {
            console.log('✅ Window selection started');
            console.log('🖱️ Move your cursor over windows to highlight them');
            console.log('🎯 Click "Select Window" button to choose a window');
            console.log('❌ Press Ctrl+C to cancel\n');
        });

        selector.on('windowEntered', (window) => {
            console.log(`🏠 Entered window: "${window.title}" - ${window.appName}`);
        });

        selector.on('windowLeft', (window) => {
            console.log(`🚪 Left window: "${window.title}" - ${window.appName}`);
        });

        selector.on('windowSelected', (windowInfo) => {
            console.log('\n🎉 Window Selected!');
            console.log('==================');
            console.log(`Title: "${windowInfo.title}"`);
            console.log(`Application: ${windowInfo.appName}`);
            console.log(`Position: (${windowInfo.x}, ${windowInfo.y})`);
            console.log(`Size: ${windowInfo.width} x ${windowInfo.height}`);
            console.log(`Screen ID: ${windowInfo.screenId}`);
            console.log(`Screen Position: (${windowInfo.screenX}, ${windowInfo.screenY})`);
            console.log(`Screen Size: ${windowInfo.screenWidth} x ${windowInfo.screenHeight}`);
        });

        selector.on('selectionStopped', () => {
            console.log('🛑 Window selection stopped');
        });

        selector.on('error', (error) => {
            console.error('❌ Error:', error.message);
        });

        // Ctrl+C handler
        process.on('SIGINT', async () => {
            console.log('\n\n🛑 Stopping window selection...');
            await selector.cleanup();
            process.exit(0);
        });

        console.log('2️⃣ Testing window selection...\n');

        // Seçim başlat
        const selectedWindow = await selector.selectWindow();
        
        if (selectedWindow) {
            console.log('\n✨ Final result:');
            console.log(JSON.stringify(selectedWindow, null, 2));
            
            // Ek bilgiler
            console.log('\n📊 Additional Analysis:');
            console.log(`Window area: ${selectedWindow.width * selectedWindow.height} pixels`);
            console.log(`Aspect ratio: ${(selectedWindow.width / selectedWindow.height).toFixed(2)}`);
            
            // Window bounds relative to screen
            const relativeX = selectedWindow.x - selectedWindow.screenX;
            const relativeY = selectedWindow.y - selectedWindow.screenY;
            console.log(`Relative position on screen: (${relativeX}, ${relativeY})`);
            
            if (relativeX < 0 || relativeY < 0 || 
                relativeX + selectedWindow.width > selectedWindow.screenWidth ||
                relativeY + selectedWindow.height > selectedWindow.screenHeight) {
                console.log('⚠️  Window extends beyond screen boundaries (multi-monitor setup)');
            } else {
                console.log('✅ Window is fully contained within its screen');
            }
        }

    } catch (error) {
        console.error('❌ Test failed:', error.message);
        console.error(error.stack);
    } finally {
        await selector.cleanup();
        console.log('\n🧹 Cleanup completed');
        process.exit(0);
    }
}

// Alternative test function for programmatic testing
async function testWindowSelectorAPI() {
    console.log('🧪 API Test Mode');
    console.log('===============\n');

    const selector = new WindowSelector();

    try {
        // Test 1: Status before selection
        console.log('Test 1: Initial status');
        const initialStatus = selector.getStatus();
        console.log('Initial status:', initialStatus);
        console.assert(!initialStatus.isSelecting, 'Should not be selecting initially');
        console.assert(!initialStatus.hasSelectedWindow, 'Should not have selected window initially');
        console.log('✅ Initial status test passed\n');

        // Test 2: Start selection
        console.log('Test 2: Start selection');
        await selector.startSelection();
        const selectingStatus = selector.getStatus();
        console.log('Selecting status:', selectingStatus);
        console.assert(selectingStatus.isSelecting, 'Should be selecting after start');
        console.log('✅ Start selection test passed\n');

        // Wait a bit to let user move cursor
        console.log('Move your cursor over different windows for 3 seconds...');
        await new Promise(resolve => setTimeout(resolve, 3000));

        // Test 3: Stop selection
        console.log('Test 3: Stop selection');
        await selector.stopSelection();
        const stoppedStatus = selector.getStatus();
        console.log('Stopped status:', stoppedStatus);
        console.assert(!stoppedStatus.isSelecting, 'Should not be selecting after stop');
        console.log('✅ Stop selection test passed\n');

        console.log('🎉 All API tests passed!');

    } catch (error) {
        console.error('❌ API test failed:', error.message);
        throw error;
    } finally {
        await selector.cleanup();
    }
}

// Parse command line arguments
const args = process.argv.slice(2);
const testMode = args.includes('--api-test') ? 'api' : 'interactive';

if (testMode === 'api') {
    testWindowSelectorAPI().catch(console.error);
} else {
    main().catch(console.error);
}
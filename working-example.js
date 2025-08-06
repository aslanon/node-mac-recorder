#!/usr/bin/env node

const WindowSelector = require('./window-selector');

async function workingExample() {
    console.log('🎯 Window Selector - Working Example');
    console.log('====================================\n');

    const selector = new WindowSelector();

    try {
        console.log('Starting window selection...');
        console.log('Move cursor over different windows to see detection');
        console.log('The system will detect which window is under cursor');
        console.log('Press Ctrl+C to stop\n');

        let currentWindow = null;

        selector.on('windowEntered', (window) => {
            currentWindow = window;
            console.log(`\n🏠 ENTERED WINDOW:`);
            console.log(`   App: ${window.appName}`);
            console.log(`   Title: "${window.title}"`);
            console.log(`   Position: (${window.x}, ${window.y})`);
            console.log(`   Size: ${window.width} x ${window.height}`);
            console.log(`   💡 This window is now highlighted (overlay may not be visible due to macOS security)`);
        });

        selector.on('windowLeft', (window) => {
            console.log(`\n🚪 LEFT WINDOW: ${window.appName} - "${window.title}"`);
            currentWindow = null;
        });

        selector.on('windowSelected', (selectedWindow) => {
            console.log('\n🎉 WINDOW SELECTED!');
            console.log('==================');
            console.log(`App: ${selectedWindow.appName}`);
            console.log(`Title: "${selectedWindow.title}"`);
            console.log(`Position: (${selectedWindow.x}, ${selectedWindow.y})`);
            console.log(`Size: ${selectedWindow.width} x ${selectedWindow.height}`);
            console.log(`Screen: ${selectedWindow.screenId}`);
            process.exit(0);
        });

        // Manual selection trigger
        let readline = require('readline');
        const rl = readline.createInterface({
            input: process.stdin,
            output: process.stdout
        });

        console.log('💡 Pro tip: Press ENTER to select the current window under cursor');
        rl.on('line', () => {
            if (currentWindow) {
                console.log('\n✅ Manually selecting current window...');
                selector.emit('windowSelected', currentWindow);
            } else {
                console.log('\n⚠️  No window under cursor. Move cursor over a window first.');
            }
        });

        await selector.startSelection();

        // Status monitoring
        let statusCount = 0;
        const statusInterval = setInterval(() => {
            const status = selector.getStatus();
            statusCount++;
            
            if (statusCount % 20 === 0) { // Every 10 seconds
                console.log(`\n📊 Status (${statusCount/2}s): Windows detected: ${status.nativeStatus?.windowCount || 0}`);
                if (status.nativeStatus?.currentWindow) {
                    console.log(`   Current: ${status.nativeStatus.currentWindow.appName}`);
                }
            }
        }, 500);

        process.on('SIGINT', async () => {
            clearInterval(statusInterval);
            rl.close();
            console.log('\n🛑 Stopping window selector...');
            await selector.cleanup();
            console.log('✅ Cleanup completed');
            process.exit(0);
        });

    } catch (error) {
        console.error('\n❌ Error:', error.message);
        console.error(error.stack);
        process.exit(1);
    }
}

workingExample();
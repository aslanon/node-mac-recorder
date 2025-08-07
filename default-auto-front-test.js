#!/usr/bin/env node

const WindowSelector = require('./window-selector');

async function testDefaultAutoBringToFront() {
    console.log('🔝 Default Auto Bring-To-Front Test');
    console.log('====================================\n');

    const selector = new WindowSelector();

    try {
        console.log('🚀 Starting window selector with DEFAULT auto bring-to-front...');
        console.log('(Auto bring-to-front is now enabled by default)\n');
        
        console.log('📋 Instructions:');
        console.log('   • Move cursor over different windows');
        console.log('   • Each window should automatically come to front');
        console.log('   • Only the specific window should focus (not whole app)');
        console.log('   • Press D to disable auto mode');
        console.log('   • Press E to re-enable auto mode');
        console.log('   • Press Ctrl+C to exit\n');

        let windowCount = 0;
        let lastWindowId = null;

        selector.on('windowEntered', (window) => {
            if (window.id !== lastWindowId) {
                windowCount++;
                console.log(`[${windowCount}] 🎯 WINDOW: ${window.appName} - "${window.title}"`);
                console.log(`    📍 Position: (${window.x}, ${window.y})`);
                console.log(`    📏 Size: ${window.width} × ${window.height}`);
                console.log(`    🔝 Should auto-focus THIS specific window only!`);
                lastWindowId = window.id;
            }
        });

        selector.on('windowLeft', (window) => {
            console.log(`🚪 Left: ${window.appName} - "${window.title}"\n`);
        });

        // Keyboard controls
        const readline = require('readline');
        readline.emitKeypressEvents(process.stdin);
        if (process.stdin.isTTY) {
            process.stdin.setRawMode(true);
        }

        process.stdin.on('keypress', async (str, key) => {
            if (key.name === 'd') {
                console.log('\n🔄 Disabling auto bring-to-front...');
                selector.setBringToFrontEnabled(false);
                console.log('   ✅ Auto mode OFF - Windows will not auto-focus');
            } else if (key.name === 'e') {
                console.log('\n🔄 Enabling auto bring-to-front...');
                selector.setBringToFrontEnabled(true);
                console.log('   ✅ Auto mode ON - Windows will auto-focus again');
            } else if (key.ctrl && key.name === 'c') {
                console.log('\n\n🛑 Stopping...');
                console.log(`📊 Total windows encountered: ${windowCount}`);
                await selector.cleanup();
                process.exit(0);
            }
        });

        await selector.startSelection();

        // Status update every 10 seconds
        setInterval(() => {
            console.log(`\n⏱️  Status: ${windowCount} windows encountered so far`);
            console.log('   (Continue moving cursor over windows to test auto-focus)');
        }, 10000);

        // Keep running
        setInterval(() => {}, 1000);

    } catch (error) {
        console.error('❌ Error:', error.message);
        console.error(error.stack);
    } finally {
        await selector.cleanup();
    }
}

if (require.main === module) {
    testDefaultAutoBringToFront();
}
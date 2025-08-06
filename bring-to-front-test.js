#!/usr/bin/env node

const WindowSelector = require('./window-selector');

async function testBringToFront() {
    console.log('🔝 Bring To Front Test');
    console.log('======================\n');

    const selector = new WindowSelector();

    try {
        // Test 1: Manual bring to front
        console.log('📋 Test 1: Manual window bring-to-front');
        console.log('Move cursor over a window and press SPACE to bring it to front\n');

        let currentWindow = null;

        selector.on('windowEntered', (window) => {
            currentWindow = window;
            console.log(`\n🏠 Window: ${window.appName} - "${window.title}" (ID: ${window.id})`);
            console.log('   📍 Position:', `(${window.x}, ${window.y})`);
            console.log('   📏 Size:', `${window.width} × ${window.height}`);
            console.log('   💡 Press SPACE to bring this window to front');
            console.log('   💡 Press A to enable AUTO bring-to-front');
            console.log('   💡 Press D to disable AUTO bring-to-front');
        });

        selector.on('windowLeft', (window) => {
            console.log(`🚪 Left: ${window.appName} - "${window.title}"`);
            currentWindow = null;
        });

        // Keyboard controls
        const readline = require('readline');
        readline.emitKeypressEvents(process.stdin);
        if (process.stdin.isTTY) {
            process.stdin.setRawMode(true);
        }

        process.stdin.on('keypress', async (str, key) => {
            if (key.name === 'space' && currentWindow) {
                console.log(`\n🔝 Bringing window to front: ${currentWindow.appName} - "${currentWindow.title}"`);
                try {
                    const success = await selector.bringWindowToFront(currentWindow.id);
                    if (success) {
                        console.log('   ✅ Window brought to front successfully!');
                    } else {
                        console.log('   ❌ Failed to bring window to front');
                    }
                } catch (error) {
                    console.log('   ❌ Error:', error.message);
                }
            } else if (key.name === 'a') {
                console.log('\n🔄 Enabling AUTO bring-to-front mode...');
                selector.setBringToFrontEnabled(true);
                console.log('   ✅ Auto mode ON - Windows will come to front automatically');
            } else if (key.name === 'd') {
                console.log('\n🔄 Disabling AUTO bring-to-front mode...');
                selector.setBringToFrontEnabled(false);
                console.log('   ✅ Auto mode OFF - Manual control only');
            } else if (key.ctrl && key.name === 'c') {
                process.exit(0);
            }
        });

        console.log('🚀 Starting window selection...\n');
        console.log('📋 Controls:');
        console.log('   SPACE     - Bring current window to front');
        console.log('   A         - Enable AUTO bring-to-front');
        console.log('   D         - Disable AUTO bring-to-front');
        console.log('   Ctrl+C    - Exit\n');

        await selector.startSelection();

        // Keep running
        process.on('SIGINT', async () => {
            console.log('\n🛑 Stopping...');
            await selector.cleanup();
            process.exit(0);
        });

        // Prevent exit
        setInterval(() => {}, 1000);

    } catch (error) {
        console.error('❌ Error:', error.message);
        console.error(error.stack);
    } finally {
        // Cleanup
        await selector.cleanup();
    }
}

async function testAutoBringToFront() {
    console.log('🤖 Auto Bring To Front Test');
    console.log('============================\n');

    const selector = new WindowSelector();

    try {
        // Enable auto bring-to-front
        console.log('🔄 Enabling auto bring-to-front...');
        selector.setBringToFrontEnabled(true);

        let windowCount = 0;

        selector.on('windowEntered', (window) => {
            windowCount++;
            console.log(`\n[${windowCount}] 🔝 AUTO FRONT: ${window.appName} - "${window.title}"`);
            console.log(`    📍 Position: (${window.x}, ${window.y})`);
            console.log(`    📏 Size: ${window.width} × ${window.height}`);
            console.log('    🚀 Window should automatically come to front!');
        });

        console.log('✅ Auto bring-to-front enabled');
        console.log('🖱️  Move cursor over different windows');
        console.log('🔝 Each window should automatically come to front');
        console.log('⏱️  Test will run for 30 seconds\n');

        await selector.startSelection();

        // Auto-stop after 30 seconds
        setTimeout(async () => {
            console.log('\n⏰ Test completed!');
            console.log(`📊 Total windows auto-focused: ${windowCount}`);
            selector.setBringToFrontEnabled(false);
            await selector.cleanup();
            process.exit(0);
        }, 30000);

    } catch (error) {
        console.error('❌ Error:', error.message);
        await selector.cleanup();
    }
}

// Main function
async function main() {
    const args = process.argv.slice(2);
    
    if (args.includes('--auto')) {
        await testAutoBringToFront();
    } else if (args.includes('--help')) {
        console.log('Bring To Front Tests:');
        console.log('====================');
        console.log('node bring-to-front-test.js [option]');
        console.log('');
        console.log('Options:');
        console.log('  --manual    Manual bring-to-front test (default)');
        console.log('  --auto      Auto bring-to-front test');
        console.log('  --help      Show this help');
    } else {
        await testBringToFront();
    }
}

if (require.main === module) {
    main().catch(console.error);
}
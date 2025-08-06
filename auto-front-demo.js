#!/usr/bin/env node

const WindowSelector = require('./window-selector');

async function autoBringToFrontDemo() {
    console.log('🤖 Auto Bring-To-Front Demo');
    console.log('============================\n');

    const selector = new WindowSelector();

    try {
        console.log('🔄 Enabling auto bring-to-front feature...');
        selector.setBringToFrontEnabled(true);

        console.log('✅ Auto mode enabled!');
        console.log('🖱️  Now move your cursor over different windows');
        console.log('🔝 Each window should automatically come to front\n');

        let windowCount = 0;
        let lastWindowId = null;

        selector.on('windowEntered', (window) => {
            if (window.id !== lastWindowId) {
                windowCount++;
                console.log(`[${windowCount}] 🎯 AUTO-FRONT: ${window.appName} - "${window.title}"`);
                console.log(`    📍 Position: (${window.x}, ${window.y})`);
                console.log(`    📏 Size: ${window.width} × ${window.height}`);
                console.log(`    🔝 Window should come to front automatically!\n`);
                lastWindowId = window.id;
            }
        });

        selector.on('windowLeft', (window) => {
            console.log(`🚪 Left: ${window.appName} - "${window.title}"\n`);
        });

        await selector.startSelection();

        console.log('Demo started! Move cursor over different app windows to see them come to front.');
        console.log('Press Ctrl+C to stop\n');

        // Auto-stop after 60 seconds
        setTimeout(async () => {
            console.log('\n⏰ Demo completed!');
            console.log(`📊 Total windows auto-focused: ${windowCount}`);
            selector.setBringToFrontEnabled(false);
            await selector.cleanup();
            process.exit(0);
        }, 60000);

        // Manual stop
        process.on('SIGINT', async () => {
            console.log('\n\n🛑 Stopping demo...');
            console.log(`📊 Total windows auto-focused: ${windowCount}`);
            selector.setBringToFrontEnabled(false);
            await selector.cleanup();
            process.exit(0);
        });

        // Prevent exit
        setInterval(() => {}, 1000);

    } catch (error) {
        console.error('❌ Error:', error.message);
        await selector.cleanup();
    }
}

if (require.main === module) {
    autoBringToFrontDemo();
}
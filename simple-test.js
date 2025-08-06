#!/usr/bin/env node

const WindowSelector = require('./window-selector');

async function simpleTest() {
    const selector = new WindowSelector();

    console.log('🔍 Starting simple window selector test...');
    console.log('Move your cursor around - you should see overlay highlighting windows');
    console.log('Press Ctrl+C to exit\n');

    try {
        selector.on('windowEntered', (window) => {
            console.log(`➡️  Entered: ${window.appName} - "${window.title}"`);
        });

        selector.on('windowLeft', (window) => {
            console.log(`⬅️  Left: ${window.appName} - "${window.title}"`);
        });

        await selector.startSelection();
        
        // Keep running until Ctrl+C
        process.on('SIGINT', async () => {
            console.log('\n🛑 Stopping...');
            await selector.cleanup();
            process.exit(0);
        });

        // Prevent the process from exiting
        setInterval(() => {}, 1000);

    } catch (error) {
        console.error('❌ Error:', error);
    }
}

simpleTest();
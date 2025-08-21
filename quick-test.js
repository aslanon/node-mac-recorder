#!/usr/bin/env node

const WindowSelector = require('./window-selector');

async function quickTest() {
    console.log('🧪 Quick Window Selector Test');
    console.log('============================\n');

    const selector = new WindowSelector();

    try {
        console.log('✅ Starting window selection...');
        console.log('🎯 Hover over windows to see highlighting (no border)');
        console.log('🔒 Window dragging should be blocked');
        console.log('⌛ Test will auto-stop in 15 seconds\n');

        await selector.startSelection();

        // Auto stop after 15 seconds
        setTimeout(async () => {
            console.log('\n⏹️  Auto-stopping test...');
            await selector.cleanup();
            process.exit(0);
        }, 15000);

    } catch (error) {
        console.error('❌ Test failed:', error.message);
        await selector.cleanup();
        process.exit(1);
    }
}

if (require.main === module) {
    quickTest().catch(console.error);
}

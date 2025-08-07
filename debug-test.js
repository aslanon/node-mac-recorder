#!/usr/bin/env node

const WindowSelector = require('./window-selector');

async function debugTest() {
    console.log('🔍 Debug Window Selector Test');
    console.log('==============================\n');

    const selector = new WindowSelector();

    try {
        // İzinleri kontrol et
        console.log('📋 Checking permissions...');
        const permissions = await selector.checkPermissions();
        console.log('Permissions:', JSON.stringify(permissions, null, 2));
        
        if (!permissions.screenRecording || !permissions.accessibility) {
            console.log('\n❌ MISSING PERMISSIONS!');
            console.log('Please enable in System Preferences > Security & Privacy:');
            console.log('   ✓ Screen Recording - Add Terminal/your IDE');
            console.log('   ✓ Accessibility - Add Terminal/your IDE');
            console.log('\nAfter enabling permissions, restart this test.');
            return;
        }

        console.log('✅ Permissions OK\n');

        // Debug mode ile başlat
        console.log('🚀 Starting selection with debug info...');
        await selector.startSelection();
        
        let windowCount = 0;

        selector.on('windowEntered', (window) => {
            windowCount++;
            console.log(`\n[${windowCount}] 🎯 WINDOW DETECTED:`);
            console.log(`    App: ${window.appName}`);
            console.log(`    Title: "${window.title}"`);
            console.log(`    ID: ${window.id}`);
            console.log(`    Position: (${window.x}, ${window.y})`);
            console.log(`    Size: ${window.width} × ${window.height}`);
            console.log(`    🔝 Should auto-focus now...`);
        });

        selector.on('windowLeft', (window) => {
            console.log(`\n🚪 LEFT WINDOW: ${window.appName} - "${window.title}"`);
        });

        selector.on('error', (error) => {
            console.error('\n❌ ERROR:', error.message);
        });

        console.log('📋 Test Instructions:');
        console.log('   1. Move cursor over different application windows');
        console.log('   2. You should see:');
        console.log('      - Blue overlay rectangle around windows');
        console.log('      - "Select Window" button in center');
        console.log('      - Windows automatically coming to front');
        console.log('   3. If overlay not visible, check permissions');
        console.log('   4. Press Ctrl+C to exit\n');
        console.log('🖱️  START MOVING CURSOR NOW...\n');

        // Status monitoring
        let statusCount = 0;
        setInterval(() => {
            statusCount++;
            const status = selector.getStatus();
            
            if (statusCount % 50 === 0) { // Every 5 seconds
                console.log(`⏱️  Status Check #${statusCount/50}:`);
                console.log(`   - Selecting: ${status.isSelecting}`);
                console.log(`   - Windows found: ${status.nativeStatus?.windowCount || 0}`);
                console.log(`   - Overlay active: ${status.nativeStatus?.hasOverlay || false}`);
                if (status.nativeStatus?.currentWindow) {
                    console.log(`   - Current: ${status.nativeStatus.currentWindow.appName}`);
                }
                console.log('');
            }
        }, 100);

    } catch (error) {
        console.error('❌ Fatal Error:', error.message);
        console.error(error.stack);
    }
}

// Handle Ctrl+C gracefully
process.on('SIGINT', async () => {
    console.log('\n\n🛑 Stopping debug test...');
    process.exit(0);
});

if (require.main === module) {
    debugTest();
}
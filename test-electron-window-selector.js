const ElectronWindowSelector = require('./electron-window-selector');

// Electron environment simülasyonu
console.log('🧪 Testing Electron Window Selector...\n');

// Electron environment variable'ları set et
process.env.ELECTRON_VERSION = '25.0.0';

async function testElectronWindowSelector() {
    const selector = new ElectronWindowSelector();
    
    console.log(`🔍 Environment: ${selector.isElectron ? 'Electron' : 'Node.js'}`);
    
    try {
        console.log('\n1️⃣ Testing Permission Check...');
        const permissions = await selector.checkPermissions();
        console.log('✅ Permissions:', permissions);
        
        console.log('\n2️⃣ Testing Available Windows...');
        const windows = await selector.getAvailableWindows();
        console.log(`✅ Found ${windows.length} windows`);
        if (windows.length > 0) {
            console.log('   📱 Sample window:', {
                title: windows[0].title,
                appName: windows[0].appName,
                size: `${windows[0].width}x${windows[0].height}`
            });
        }
        
        console.log('\n3️⃣ Testing Available Displays...');
        const displays = await selector.getAvailableDisplays();
        console.log(`✅ Found ${displays.length} displays`);
        if (displays.length > 0) {
            console.log('   🖥️ Primary display:', {
                name: displays[0].name,
                resolution: `${displays[0].width}x${displays[0].height}`,
                isPrimary: displays[0].isPrimary
            });
        }
        
        console.log('\n4️⃣ Testing Window Selection (Electron Safe Mode)...');
        const windowSelectionPromise = selector.selectWindow();
        
        // Event listeners
        selector.on('windowSelected', (windowInfo) => {
            console.log('🎯 Window selected event:', {
                title: windowInfo.title,
                appName: windowInfo.appName,
                position: `${windowInfo.x},${windowInfo.y}`,
                size: `${windowInfo.width}x${windowInfo.height}`
            });
        });
        
        selector.on('selectionStarted', () => {
            console.log('🟢 Window selection started');
        });
        
        const selectedWindow = await windowSelectionPromise;
        console.log('✅ Window selection completed');
        
        console.log('\n5️⃣ Testing Screen Selection (Electron Safe Mode)...');
        const screenSelectionPromise = selector.selectScreen();
        
        selector.on('screenSelected', (screenInfo) => {
            console.log('🖥️ Screen selected event:', {
                name: screenInfo.name || 'Display ' + screenInfo.id,
                resolution: `${screenInfo.width}x${screenInfo.height}`,
                isPrimary: screenInfo.isPrimary
            });
        });
        
        const selectedScreen = await screenSelectionPromise;
        console.log('✅ Screen selection completed');
        
        console.log('\n6️⃣ Testing Recording Preview (Electron Safe Mode)...');
        if (selectedWindow) {
            await selector.showRecordingPreview(selectedWindow);
            console.log('✅ Recording preview shown (Electron mode - no native overlay)');
            
            await selector.hideRecordingPreview();
            console.log('✅ Recording preview hidden');
        }
        
        console.log('\n7️⃣ Testing Screen Recording Preview (Electron Safe Mode)...');
        if (selectedScreen) {
            await selector.showScreenRecordingPreview(selectedScreen);
            console.log('✅ Screen recording preview shown (Electron mode - no native overlay)');
            
            await selector.hideScreenRecordingPreview();
            console.log('✅ Screen recording preview hidden');
        }
        
        console.log('\n8️⃣ Cleanup...');
        await selector.cleanup();
        console.log('✅ Cleanup completed');
        
        console.log('\n🎉 All Electron Window Selector tests PASSED!');
        
    } catch (error) {
        console.error('\n❌ Test failed:', error.message);
        console.error('   Stack:', error.stack);
        
        // Cleanup on error
        try {
            await selector.cleanup();
        } catch (cleanupError) {
            console.error('❌ Cleanup failed:', cleanupError.message);
        }
    }
}

// Run test
testElectronWindowSelector().then(() => {
    console.log('\n✅ Test completed');
    process.exit(0);
}).catch((error) => {
    console.error('\n❌ Test suite failed:', error);
    process.exit(1);
});
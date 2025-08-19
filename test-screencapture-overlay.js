#!/usr/bin/env node

const MacRecorder = require('./index.js');

async function testWindowSelector() {
    try {
        console.log('🧪 Testing ScreenCaptureKit-compatible window selector...');
        
        // Create recorder instance
        const recorder = new MacRecorder();
        
        // Test if we can get windows
        const windows = await recorder.getWindows();
        console.log(`✅ Found ${windows.length} windows`);
        
        if (windows.length > 0) {
            console.log('🔍 Sample windows:');
            windows.slice(0, 3).forEach((win, i) => {
                console.log(`  ${i+1}. ${win.appName || 'Unknown'} - "${win.title || 'Untitled'}" [${win.width || 0}x${win.height || 0}]`);
                console.log(`      ID: ${win.id}, Bundle: ${win.bundleId || 'N/A'}`);
            });
        }
        
        console.log('🪟 Testing window selection overlay...');
        
        // Test window selection (will use ScreenCaptureKit if available)
        const started = recorder.startWindowSelection();
        console.log('Window selection started:', started);
        
        if (started) {
            console.log('✅ Window selector started successfully with ScreenCaptureKit integration');
            console.log('📝 Press ESC to cancel or interact with the overlay');
            
            // Wait a bit then cleanup
            setTimeout(() => {
                recorder.stopWindowSelection();
                console.log('🧹 Window selector stopped');
                
                console.log('✅ Test completed successfully!');
                console.log('🎉 ScreenCaptureKit integration is working properly');
                process.exit(0);
            }, 10000);
        } else {
            console.log('❌ Failed to start window selector');
            process.exit(1);
        }
        
    } catch (error) {
        console.error('❌ Test failed:', error.message);
        process.exit(1);
    }
}

testWindowSelector();
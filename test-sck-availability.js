#!/usr/bin/env node

const nativeBinding = require('./build/Release/mac_recorder.node');

console.log('Testing ScreenCaptureKit availability...');

// Test the native functions directly
try {
    console.log('Native binding methods:', Object.keys(nativeBinding));
    
    // Check if we have the getWindows method
    if (nativeBinding.getWindows) {
        console.log('✅ getWindows method available');
        const windows = nativeBinding.getWindows();
        console.log(`Found ${windows.length} windows`);
        
        if (windows.length > 0) {
            console.log('First window:', windows[0]);
        }
    } else {
        console.log('❌ getWindows method not available');
    }
    
} catch (error) {
    console.error('Error:', error.message);
}
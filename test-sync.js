const MacRecorder = require('./index');

console.log('🔄 Testing ScreenCaptureKit Synchronous Operations...\n');

try {
    const recorder = new MacRecorder();
    console.log('✅ Recorder created successfully');
    
    // Test if we can access the native module methods directly
    console.log('📋 Available methods:');
    const methods = Object.getOwnPropertyNames(recorder.__proto__);
    methods.forEach(method => {
        if (typeof recorder[method] === 'function') {
            console.log(`   • ${method}()`);
        }
    });
    
    console.log('\n🎯 Testing basic functionality:');
    
    // Test recording status (should be sync and work)
    try {
        const status = recorder.getStatus();
        console.log(`✅ getStatus(): ${JSON.stringify(status)}`);
    } catch (err) {
        console.log(`❌ getStatus() failed: ${err.message}`);
    }
    
    // Test cursor position (should be sync and work)
    try {
        const cursor = recorder.getCurrentCursorPosition();
        console.log(`✅ getCurrentCursorPosition(): x=${cursor.x}, y=${cursor.y}, type=${cursor.cursorType}`);
    } catch (err) {
        console.log(`❌ getCurrentCursorPosition() failed: ${err.message}`);
    }
    
    // Test cursor capture status (should be sync)
    try {
        const cursorStatus = recorder.getCursorCaptureStatus();
        console.log(`✅ getCursorCaptureStatus(): tracking=${cursorStatus.isTracking}`);
    } catch (err) {
        console.log(`❌ getCursorCaptureStatus() failed: ${err.message}`);
    }
    
    console.log('\n📊 ScreenCaptureKit sync tests completed');
    console.log('⚠️  Async functions (getDisplays, getWindows, getAudioDevices) may hang due to permission dialogs');
    console.log('💡 To fix: Grant screen recording permissions in System Preferences > Privacy & Security');
    
} catch (error) {
    console.error('❌ Critical error:', error);
}

process.exit(0);
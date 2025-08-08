const MacRecorder = require('./index');

async function testScreenCaptureKit() {
    console.log('Testing ScreenCaptureKit migration...');
    
    const recorder = new MacRecorder();
    
    try {
        // Test 1: Check permissions
        console.log('\n1. Testing checkPermissions()');
        const permissions = await recorder.checkPermissions();
        console.log('✅ Permissions:', permissions);
        
        // Test 2: Get displays
        console.log('\n2. Testing getDisplays()');
        const displays = await recorder.getDisplays();
        console.log(`✅ Found ${displays.length} displays:`, displays.map(d => `${d.id}:${d.width}x${d.height}`));
        
        // Test 3: Get windows
        console.log('\n3. Testing getWindows()');
        const windows = await recorder.getWindows();
        console.log(`✅ Found ${windows.length} windows:`, windows.slice(0, 3).map(w => `${w.id}:"${w.title}"`));
        
        // Test 4: Get audio devices
        console.log('\n4. Testing getAudioDevices()');
        const audioDevices = await recorder.getAudioDevices();
        console.log(`✅ Found ${audioDevices.length} audio devices:`, audioDevices.slice(0, 3).map(d => `${d.id}:"${d.name}"`));
        
        console.log('\n🎉 All ScreenCaptureKit tests passed!');
        console.log('\n✅ ScreenCaptureKit migration successful!');
        
    } catch (error) {
        console.error('❌ Test failed:', error);
    }
}

testScreenCaptureKit();
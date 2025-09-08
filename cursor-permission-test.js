const MacRecorder = require('./index.js');

async function testCursorPermissions() {
    console.log('🔒 Testing cursor tracking permissions...\n');
    
    const recorder = new MacRecorder();
    
    // Check permissions first
    console.log('1. Checking permissions:');
    const permissions = await recorder.checkPermissions();
    console.log('   Screen Recording:', permissions.screenRecording ? '✅' : '❌');
    console.log('   Accessibility:', permissions.accessibility ? '✅' : '❌');
    console.log('   Microphone:', permissions.microphone ? '✅' : '❌');
    
    if (permissions.error) {
        console.log('   Error:', permissions.error);
    }
    
    console.log('\n2. Testing direct cursor position (no capture):');
    for (let i = 0; i < 5; i++) {
        try {
            const position = recorder.getCursorPosition();
            console.log(`   Position ${i+1}: (${position.x}, ${position.y}) - ${position.cursorType}`);
            
            if (position.scaleFactor) {
                console.log(`     Scale: ${position.scaleFactor}x, Display: (${position.displayInfo?.displayX}, ${position.displayInfo?.displayY})`);
                console.log(`     Logical: ${position.displayInfo?.logicalWidth}x${position.displayInfo?.logicalHeight}`);
                console.log(`     Physical: ${position.displayInfo?.physicalWidth}x${position.displayInfo?.physicalHeight}`);
            }
            
            await new Promise(resolve => setTimeout(resolve, 500));
        } catch (error) {
            console.error(`   Error getting position ${i+1}:`, error.message);
        }
    }
    
    console.log('\n3. Testing cursor capture status:');
    const status = recorder.getCursorCaptureStatus();
    console.log('   Is Capturing:', status.isCapturing);
    console.log('   Output File:', status.outputFile);
    console.log('   Display Info:', status.displayInfo);
    
    process.exit(0);
}

testCursorPermissions().catch(console.error);
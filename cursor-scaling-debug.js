const MacRecorder = require('./index.js');

async function debugCursorScaling() {
    console.log('🔍 Debugging cursor scaling detection...\n');
    
    const recorder = new MacRecorder();
    
    // Get all displays
    const displays = await recorder.getDisplays();
    console.log('📺 Available displays:');
    displays.forEach((display, index) => {
        console.log(`   Display ${index}: ID=${display.id}, ${display.resolution} at (${display.x}, ${display.y}), Primary: ${display.isPrimary}`);
    });
    
    console.log('\n🎯 Current cursor position analysis:');
    const position = recorder.getCursorPosition();
    
    console.log(`   Logical position: (${position.x}, ${position.y})`);
    console.log(`   Cursor type: ${position.cursorType}`);
    console.log(`   Event type: ${position.eventType}`);
    
    if (position.scaleFactor) {
        console.log(`   Scale factor detected: ${position.scaleFactor}x`);
        if (position.displayInfo) {
            const info = position.displayInfo;
            console.log(`   Display bounds: (${info.displayX}, ${info.displayY})`);
            console.log(`   Logical size: ${info.logicalWidth}x${info.logicalHeight}`);
            console.log(`   Physical size: ${info.physicalWidth}x${info.physicalHeight}`);
            console.log(`   Raw position: (${position.rawX}, ${position.rawY})`);
        }
    } else {
        console.log(`   ❌ No scale factor detected`);
        console.log(`   This could mean:`);
        console.log(`     - getDisplayScalingInfo() didn't find the correct display`);
        console.log(`     - Display detection logic needs debugging`);
    }
    
    // Find which display the cursor is on
    console.log('\n🔍 Manual display detection:');
    displays.forEach((display, index) => {
        const inX = position.x >= display.x && position.x < display.x + parseInt(display.resolution.split('x')[0]);
        const inY = position.y >= display.y && position.y < display.y + parseInt(display.resolution.split('x')[1]);
        const isInside = inX && inY;
        
        console.log(`   Display ${index} (${display.resolution}): ${isInside ? '✅ CURSOR IS HERE' : '❌'}`);
        console.log(`     Bounds: X(${display.x} - ${display.x + parseInt(display.resolution.split('x')[0])}), Y(${display.y} - ${display.y + parseInt(display.resolution.split('x')[1])})`);
        console.log(`     Cursor: X(${position.x}), Y(${position.y})`);
    });
    
    process.exit(0);
}

debugCursorScaling().catch(console.error);
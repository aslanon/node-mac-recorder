const MacRecorder = require('./index.js');

async function testMacBookCursor() {
    console.log('🖥️  Testing cursor on MacBook internal display...\n');
    
    const recorder = new MacRecorder();
    
    // Get displays
    const displays = await recorder.getDisplays();
    console.log('📺 Available displays:');
    displays.forEach((display, index) => {
        console.log(`   Display ${index}: ${display.resolution} at (${display.x}, ${display.y}) - Primary: ${display.isPrimary}`);
    });
    
    console.log('\n🎯 Move your mouse to the PRIMARY MacBook display and press any key...');
    console.log('(Make sure cursor is on the built-in MacBook screen, not external monitor)\n');
    
    // Wait for keypress
    await new Promise((resolve) => {
        process.stdin.setRawMode(true);
        process.stdin.resume();
        process.stdin.once('data', () => {
            process.stdin.setRawMode(false);
            resolve();
        });
    });
    
    console.log('🔍 Testing cursor position on MacBook display:');
    for (let i = 0; i < 3; i++) {
        const position = recorder.getCursorPosition();
        console.log(`\n   Test ${i+1}:`);
        console.log(`     Cursor: (${position.x}, ${position.y})`);
        console.log(`     Cursor type: ${position.cursorType}`);
        
        // Check which display cursor is on
        const primaryDisplay = displays.find(d => d.isPrimary);
        if (primaryDisplay) {
            const isOnPrimary = position.x >= primaryDisplay.x && 
                               position.x < primaryDisplay.x + parseInt(primaryDisplay.resolution.split('x')[0]) &&
                               position.y >= primaryDisplay.y && 
                               position.y < primaryDisplay.y + parseInt(primaryDisplay.resolution.split('x')[1]);
            
            console.log(`     On primary display: ${isOnPrimary ? '✅ YES' : '❌ NO'}`);
        }
        
        if (position.scaleFactor) {
            console.log(`     Scale factor: ${position.scaleFactor}x`);
            if (position.displayInfo) {
                console.log(`     Display logical: ${position.displayInfo.logicalWidth}x${position.displayInfo.logicalHeight}`);
                console.log(`     Display physical: ${position.displayInfo.physicalWidth}x${position.displayInfo.physicalHeight}`);
                console.log(`     Raw cursor: (${position.rawX}, ${position.rawY})`);
            }
        } else {
            console.log(`     ⚠️ No scaling info detected`);
        }
        
        await new Promise(resolve => setTimeout(resolve, 1000));
    }
    
    process.exit(0);
}

testMacBookCursor().catch(console.error);
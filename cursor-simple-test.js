const MacRecorder = require('./index.js');

console.log('🎯 Simple cursor test - Move your mouse to MacBook screen...\n');

const recorder = new MacRecorder();

// Test 10 cursor positions
for (let i = 0; i < 10; i++) {
    setTimeout(() => {
        const position = recorder.getCursorPosition();
        console.log(`${i+1}. Cursor: (${position.x}, ${position.y}), Scale: ${position.scaleFactor || 'none'}`);
        
        if (position.displayInfo && position.scaleFactor > 1.1) {
            console.log(`   🎉 SCALING DETECTED! ${position.scaleFactor}x`);
            console.log(`   Logical: ${position.displayInfo.logicalWidth}x${position.displayInfo.logicalHeight}`);
            console.log(`   Physical: ${position.displayInfo.physicalWidth}x${position.displayInfo.physicalHeight}`);
            console.log(`   Raw cursor: (${position.rawX}, ${position.rawY})`);
            process.exit(0);
        }
        
        if (i === 9) {
            console.log('\n⚠️ No scaling detected. Try moving mouse to MacBook internal display.');
            process.exit(0);
        }
    }, i * 500);
}
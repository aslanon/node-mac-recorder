const MacRecorder = require('./index.js');

console.log('🔍 Debugging cursor coordinate scaling issue...\n');

const recorder = new MacRecorder();

async function testCursorScaling() {
    console.log('Getting display info...');
    const displays = await recorder.getDisplays();
    
    displays.forEach((display, index) => {
        console.log(`Display ${index}:`);
        console.log(`  Resolution: ${display.resolution}`);
        console.log(`  Position: (${display.x}, ${display.y})`);
        console.log(`  Primary: ${display.isPrimary}`);
        console.log(`  ID: ${display.id}`);
    });
    
    console.log('\n🎯 Please move your mouse to different corners and press Enter...');
    console.log('This will help us understand the coordinate mapping issue.\n');
    
    const readline = require('readline');
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout
    });
    
    let testCount = 0;
    const testPositions = [
        'Top-Left corner of the display',
        'Top-Right corner of the display', 
        'Bottom-Left corner of the display',
        'Bottom-Right corner of the display',
        'Center of the display'
    ];
    
    function nextTest() {
        if (testCount >= testPositions.length) {
            console.log('\n✅ Test completed!');
            rl.close();
            process.exit(0);
            return;
        }
        
        console.log(`\n📍 Test ${testCount + 1}: Move mouse to ${testPositions[testCount]} and press Enter:`);
        rl.question('', () => {
            const position = recorder.getCursorPosition();
            console.log(`   Raw cursor position: (${position.rawX || 'N/A'}, ${position.rawY || 'N/A'})`);
            console.log(`   Logical cursor position: (${position.x}, ${position.y})`);
            console.log(`   Scale factor: ${position.scaleFactor || 'N/A'}x`);
            
            testCount++;
            nextTest();
        });
    }
    
    nextTest();
}

testCursorScaling().catch(console.error);
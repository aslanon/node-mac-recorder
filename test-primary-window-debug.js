const MacRecorder = require('./index');
const WindowSelector = MacRecorder.WindowSelector;

async function testPrimaryWindowDebug() {
    console.log('🔍 Testing PRIMARY display window debugging...');
    
    const recorder = new MacRecorder();
    const displays = await recorder.getDisplays();
    
    const primary = displays.find(d => d.isPrimary);
    console.log(`Primary display: ${primary.name} at (${primary.x}, ${primary.y}) ${primary.width}x${primary.height}`);
    
    const selector = new WindowSelector();
    
    try {
        console.log('🚀 Starting window selection...');
        console.log('📍 IMPORTANT: Move cursor to a window ON THE PRIMARY DISPLAY');
        console.log('   - Look for windows at coordinates like (0, 50) or (100, 100)');
        console.log('   - Should see GlobalOffset: (3440, 56) for primary display');
        
        await selector.startSelection();
        
        // Let it run for 15 seconds to catch primary display windows
        await new Promise(resolve => setTimeout(resolve, 15000));
        
        await selector.stopSelection();
        
    } catch (error) {
        console.log(`❌ Test failed: ${error.message}`);
    }
}

testPrimaryWindowDebug();
const MacRecorder = require('./index');
const WindowSelector = MacRecorder.WindowSelector;

async function testCoordinateDebug() {
    console.log('🔍 Testing coordinate debugging...');
    
    const selector = new WindowSelector();
    
    try {
        console.log('🚀 Starting window selection with coordinate debugging...');
        await selector.startSelection();
        
        console.log('📍 Move cursor to PRIMARY display window and check console logs');
        
        // Let it run for 10 seconds to see debug output
        await new Promise(resolve => setTimeout(resolve, 10000));
        
        await selector.stopSelection();
        
    } catch (error) {
        console.log(`❌ Test failed: ${error.message}`);
    }
}

testCoordinateDebug();
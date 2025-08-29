const MacRecorder = require('./index');
const WindowSelector = MacRecorder.WindowSelector;

async function testFinalCoordinateFix() {
    console.log('🎯 Testing FINAL coordinate fix...');
    
    const recorder = new MacRecorder();
    const displays = await recorder.getDisplays();
    
    console.log('📊 Display setup:');
    displays.forEach(display => {
        console.log(`  ${display.name}: (${display.x}, ${display.y}) ${display.width}x${display.height} ${display.isPrimary ? '[PRIMARY]' : ''}`);
    });
    
    const selector = new WindowSelector();
    
    try {
        console.log('\n🚀 Starting window selection with coordinate fix...');
        console.log('📍 Test BOTH displays:');
        console.log('   - Primary display windows should now show buttons correctly');
        console.log('   - Secondary display windows should continue working');
        console.log('   - Look for [PRIMARY] vs [SECONDARY] tags in logs');
        
        await selector.startSelection();
        
        // Let it run for 20 seconds for thorough testing
        await new Promise(resolve => setTimeout(resolve, 20000));
        
        await selector.stopSelection();
        
        console.log('✅ Final coordinate test completed!');
        
    } catch (error) {
        console.log(`❌ Test failed: ${error.message}`);
    }
}

testFinalCoordinateFix();
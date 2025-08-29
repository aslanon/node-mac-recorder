const MacRecorder = require('./index');
const WindowSelector = MacRecorder.WindowSelector;

async function testWindowSelector() {
    console.log('🪟 Testing FIXED window selector multi-display...');
    
    const recorder = new MacRecorder();
    const displays = await recorder.getDisplays();
    
    console.log('📊 Display setup:');
    displays.forEach((display, index) => {
        console.log(`  ${display.name}: ${display.resolution} at (${display.x}, ${display.y}) ${display.isPrimary ? '[PRIMARY]' : ''}`);
    });
    
    const selector = new WindowSelector();
    
    try {
        console.log('\n🔍 Starting window selection...');
        console.log('   - Test windows on BOTH displays');
        console.log('   - Check if buttons appear correctly positioned');
        console.log('   - Primary display should now work correctly');
        
        await selector.startSelection();
        
        // Let it run for 20 seconds for thorough testing
        await new Promise(resolve => setTimeout(resolve, 20000));
        
        console.log('🛑 Stopping window selection...');
        await selector.stopSelection();
        
        console.log('✅ Window selector test completed!');
        
    } catch (error) {
        console.log(`❌ Window selector test failed: ${error.message}`);
        console.log(error.stack);
    }
}

async function testSecondaryDisplayRecording() {
    console.log('\n🎥 Testing secondary display recording...');
    
    const recorder = new MacRecorder();
    const displays = await recorder.getDisplays();
    
    const secondaryDisplay = displays.find(d => !d.isPrimary);
    if (!secondaryDisplay) {
        console.log('⚠️ No secondary display found');
        return;
    }
    
    console.log(`🖥️ Testing recording on ${secondaryDisplay.name} (ID: ${secondaryDisplay.id})`);
    
    try {
        const outputPath = `./test-output/secondary-display-fix-test.mov`;
        
        await recorder.startRecording(outputPath, {
            displayId: secondaryDisplay.id,
            captureCursor: true,
            includeMicrophone: false,
            includeSystemAudio: false
        });
        
        console.log('✅ Recording started on secondary display');
        
        // Record for 3 seconds
        await new Promise(resolve => setTimeout(resolve, 3000));
        
        await recorder.stopRecording();
        console.log('✅ Recording completed on secondary display');
        
    } catch (error) {
        console.log(`❌ Secondary display recording failed: ${error.message}`);
    }
}

async function runTests() {
    try {
        await testWindowSelector();
        await testSecondaryDisplayRecording();
        
        console.log('\n🎉 All tests completed!');
        
    } catch (error) {
        console.log(`❌ Test suite failed: ${error.message}`);
    }
}

runTests();
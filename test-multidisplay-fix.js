const MacRecorder = require('./index');
const WindowSelector = MacRecorder.WindowSelector;

console.log('🧪 Testing multi-display fixes...');

async function testDisplaySelection() {
    console.log('\n🖥️ Testing display selection:');
    
    const recorder = new MacRecorder();
    const displays = await recorder.getDisplays();
    
    console.log(`Found ${displays.length} displays:`);
    displays.forEach((display, index) => {
        console.log(`  ${index + 1}. ${display.name} (ID: ${display.id}) - ${display.resolution} at (${display.x}, ${display.y}) ${display.isPrimary ? '[PRIMARY]' : ''}`);
    });
    
    // Test recording on each display
    for (const display of displays) {
        console.log(`\n📹 Testing recording on ${display.name}:`);
        try {
            const outputPath = `./test-output/display-${display.id}-test.mov`;
            
            await recorder.startRecording(outputPath, {
                displayId: display.id,
                captureCursor: false,
                includeMicrophone: false,
                includeSystemAudio: false
            });
            
            console.log(`✅ Recording started on ${display.name}`);
            
            // Record for 2 seconds
            await new Promise(resolve => setTimeout(resolve, 2000));
            
            await recorder.stopRecording();
            console.log(`✅ Recording stopped on ${display.name}`);
            
        } catch (error) {
            console.log(`❌ Recording failed on ${display.name}: ${error.message}`);
        }
        
        // Small delay between tests
        await new Promise(resolve => setTimeout(resolve, 1000));
    }
}

async function testScreenSelector() {
    console.log('\n🎯 Testing screen selector multi-display...');
    
    const selector = new WindowSelector();
    
    try {
        console.log('🔍 Starting screen selection... (This should show overlays on ALL displays)');
        await selector.startScreenSelection();
        
        console.log('⏱️ Screen selection UI is running...');
        console.log('   - Check if overlays appear on ALL displays');
        console.log('   - Check if buttons and text are positioned correctly');
        console.log('   - Check if app icons are visible and animated');
        
        // Let it run for 10 seconds for manual inspection
        await new Promise(resolve => setTimeout(resolve, 10000));
        
        console.log('🛑 Stopping screen selection...');
        await selector.stopScreenSelection();
        
    } catch (error) {
        console.log(`❌ Screen selector test failed: ${error.message}`);
    }
}

async function testWindowSelector() {
    console.log('\n🪟 Testing window selector multi-display...');
    
    const selector = new WindowSelector();
    
    try {
        console.log('🔍 Starting window selection... (This should work across ALL displays)');
        await selector.startSelection();
        
        console.log('⏱️ Window selection UI is running...');
        console.log('   - Move cursor to windows on different displays');
        console.log('   - Check if highlighting works properly');
        console.log('   - Check if buttons appear correctly over highlighted windows');
        
        // Let it run for 15 seconds for manual inspection
        await new Promise(resolve => setTimeout(resolve, 15000));
        
        console.log('🛑 Stopping window selection...');
        await selector.stopSelection();
        
    } catch (error) {
        console.log(`❌ Window selector test failed: ${error.message}`);
    }
}

async function runTests() {
    try {
        // Check permissions first
        const recorder = new MacRecorder();
        const permissions = await recorder.checkPermissions();
        
        if (!permissions.screenRecording) {
            console.log('❌ Screen recording permission required. Enable in System Preferences > Security & Privacy > Privacy > Screen Recording');
            return;
        }
        
        await testDisplaySelection();
        await testScreenSelector();
        await testWindowSelector();
        
        console.log('\n🎉 Multi-display tests completed!');
        
    } catch (error) {
        console.log(`❌ Test suite failed: ${error.message}`);
        console.log(error.stack);
    }
}

runTests();
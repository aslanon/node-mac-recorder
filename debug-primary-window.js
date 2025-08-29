const MacRecorder = require('./index');
const WindowSelector = MacRecorder.WindowSelector;

async function debugPrimaryDisplay() {
    console.log('🔍 Debugging primary display window selector...');
    
    const recorder = new MacRecorder();
    const displays = await recorder.getDisplays();
    
    console.log('📊 Display analysis:');
    displays.forEach(display => {
        console.log(`${display.name}: (${display.x}, ${display.y}) ${display.width}x${display.height} ${display.isPrimary ? '[PRIMARY]' : '[SECONDARY]'}`);
    });
    
    // Calculate combined frame like in native code
    const primary = displays.find(d => d.isPrimary);
    const secondary = displays.find(d => !d.isPrimary);
    
    console.log('\n🧮 Coordinate calculations:');
    console.log(`Primary: (${primary.x}, ${primary.y})`);
    console.log(`Secondary: (${secondary.x}, ${secondary.y})`);
    
    // Combined frame calculation
    const minX = Math.min(primary.x, secondary.x);
    const minY = Math.min(primary.y, secondary.y);
    const maxX = Math.max(primary.x + primary.width, secondary.x + secondary.width);
    const maxY = Math.max(primary.y + primary.height, secondary.y + secondary.height);
    
    const combinedFrame = {
        x: minX,
        y: minY,
        width: maxX - minX,
        height: maxY - minY
    };
    
    console.log(`Combined frame: (${combinedFrame.x}, ${combinedFrame.y}) ${combinedFrame.width}x${combinedFrame.height}`);
    
    // Test coordinate conversion for a primary display window
    const testPrimaryWindowX = 100;  // Window at (100, 100) on primary
    const testPrimaryWindowY = 100;
    
    const localX = testPrimaryWindowX - combinedFrame.x;
    const localY = testPrimaryWindowY - combinedFrame.y;
    
    console.log(`\n🎯 Primary window test:`);
    console.log(`Global window: (${testPrimaryWindowX}, ${testPrimaryWindowY})`);
    console.log(`Combined origin: (${combinedFrame.x}, ${combinedFrame.y})`);
    console.log(`Local coordinates: (${localX}, ${localY})`);
    console.log(`Combined height: ${combinedFrame.height}`);
    console.log(`Converted Y: ${combinedFrame.height - localY - 200}`);  // Assuming 200px window height
    
    // Test for secondary display window
    const testSecondaryWindowX = secondary.x + 100;
    const testSecondaryWindowY = secondary.y + 100;
    
    const localSecondaryX = testSecondaryWindowX - combinedFrame.x;
    const localSecondaryY = testSecondaryWindowY - combinedFrame.y;
    
    console.log(`\n🎯 Secondary window test:`);
    console.log(`Global window: (${testSecondaryWindowX}, ${testSecondaryWindowY})`);
    console.log(`Local coordinates: (${localSecondaryX}, ${localSecondaryY})`);
    console.log(`Converted Y: ${combinedFrame.height - localSecondaryY - 200}`);
    
    console.log('\n🧪 Starting actual window selection test...');
    console.log('   - Move cursor to primary display windows');
    console.log('   - Check if buttons appear');
    console.log('   - Check console logs for coordinate calculations');
    
    const selector = new WindowSelector();
    
    try {
        await selector.startSelection();
        
        // Let it run for 15 seconds for debugging
        await new Promise(resolve => setTimeout(resolve, 15000));
        
        await selector.stopSelection();
        
    } catch (error) {
        console.log(`❌ Test failed: ${error.message}`);
    }
}

debugPrimaryDisplay();
const MacRecorder = require('./index');

async function debugCoordinates() {
    const recorder = new MacRecorder();
    const displays = await recorder.getDisplays();
    
    console.log('🖥️ Display coordinates analysis:');
    displays.forEach((display, index) => {
        console.log(`Display ${index}: ${display.name}`);
        console.log(`  ID: ${display.id}`);
        console.log(`  Position: (${display.x}, ${display.y})`);
        console.log(`  Size: ${display.width}x${display.height}`);
        console.log(`  isPrimary: ${display.isPrimary}`);
        console.log('');
    });
    
    // Calculate combined frame like we do in native code
    let combinedFrame = { x: 0, y: 0, width: 0, height: 0 };
    let first = true;
    
    for (const display of displays) {
        if (first) {
            combinedFrame = {
                x: display.x,
                y: display.y, 
                width: display.width,
                height: display.height
            };
            first = false;
        } else {
            const minX = Math.min(combinedFrame.x, display.x);
            const minY = Math.min(combinedFrame.y, display.y);
            const maxX = Math.max(combinedFrame.x + combinedFrame.width, display.x + display.width);
            const maxY = Math.max(combinedFrame.y + combinedFrame.height, display.y + display.height);
            
            combinedFrame = {
                x: minX,
                y: minY,
                width: maxX - minX,
                height: maxY - minY
            };
        }
    }
    
    console.log('📐 Combined frame calculation:');
    console.log(`  Origin: (${combinedFrame.x}, ${combinedFrame.y})`);
    console.log(`  Size: ${combinedFrame.width}x${combinedFrame.height}`);
    console.log('');
    
    console.log('🔄 Coordinate conversion examples:');
    displays.forEach((display, index) => {
        console.log(`Display ${index} (${display.name}):`);
        const localOriginX = display.x - combinedFrame.x;
        const localOriginY = display.y - combinedFrame.y;
        console.log(`  Global offset from combined: (${localOriginX}, ${localOriginY})`);
        
        // Test window at display origin
        const testWindowGlobalX = display.x + 100;
        const testWindowGlobalY = display.y + 100;
        const localWindowX = testWindowGlobalX - combinedFrame.x;
        const localWindowY = testWindowGlobalY - combinedFrame.y;
        
        console.log(`  Test window at (${testWindowGlobalX}, ${testWindowGlobalY}) global`);
        console.log(`  -> Local coordinates: (${localWindowX}, ${localWindowY})`);
        console.log('');
    });
}

debugCoordinates();
const MacRecorder = require('./index.js');

console.log('🧪 Testing cursor DPR scaling fixes...\n');

const recorder = new MacRecorder();

// Test basic cursor position
console.log('1. Testing basic cursor position:');
try {
    const position = recorder.getCursorPosition();
    console.log(`   Position: (${position.x}, ${position.y})`);
    
    // If we have scaling debug info, show it
    if (position.scaleFactor) {
        console.log(`   Scale factor: ${position.scaleFactor}x`);
        console.log(`   Raw position: (${position.rawX}, ${position.rawY})`);
        console.log(`   Logical position: (${position.x}, ${position.y})`);
    }
} catch (error) {
    console.error('   Error:', error.message);
}

console.log('\n2. Testing display information:');
recorder.getDisplays().then(displays => {
    displays.forEach((display, index) => {
        console.log(`   Display ${index}: ${display.resolution} at (${display.x}, ${display.y})`);
        console.log(`     Primary: ${display.isPrimary}, ID: ${display.id}`);
    });
    
    console.log('\n3. Testing cursor capture with DPR fix:');
    const outputFile = 'cursor-dpr-test.json';
    
    recorder.startCursorCapture(outputFile, 50).then(() => {
        console.log(`   ✅ Cursor capture started, saving to ${outputFile}`);
        console.log('   Move your mouse around for 5 seconds...');
        
        setTimeout(() => {
            recorder.stopCursorCapture().then(() => {
                console.log('   ✅ Cursor capture stopped');
                
                // Read and analyze the captured data
                const fs = require('fs');
                try {
                    const data = JSON.parse(fs.readFileSync(outputFile, 'utf8'));
                    if (data.length > 0) {
                        const first = data[0];
                        const last = data[data.length - 1];
                        
                        console.log(`   📊 Captured ${data.length} cursor events`);
                        console.log(`   📍 First: (${first.x}, ${first.y}) ${first.coordinateSystem || 'unknown'}`);
                        console.log(`   📍 Last: (${last.x}, ${last.y}) ${last.coordinateSystem || 'unknown'}`);
                        
                        // Check coordinate system
                        const hasCoordinateSystem = data.some(d => d.coordinateSystem);
                        console.log(`   🎯 Coordinate system info: ${hasCoordinateSystem ? 'Present' : 'Missing'}`);
                    } else {
                        console.log('   ⚠️ No cursor events captured');
                    }
                } catch (readError) {
                    console.error('   ❌ Error reading capture file:', readError.message);
                }
                
                process.exit(0);
            });
        }, 5000);
    }).catch(error => {
        console.error('   ❌ Cursor capture failed:', error.message);
        process.exit(1);
    });
}).catch(error => {
    console.error('   Error getting displays:', error.message);
    process.exit(1);
});
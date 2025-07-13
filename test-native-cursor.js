const nativeBinding = require('./build/Release/mac_recorder.node');

console.log('Testing native cursor tracking...');

// Test native startCursorTracking function directly
const testFile = 'native-cursor-test.json';
const started = nativeBinding.startCursorTracking(testFile);

console.log('Native tracking started:', started);

if (started) {
    setTimeout(() => {
        const stopped = nativeBinding.stopCursorTracking();
        console.log('Native tracking stopped:', stopped);
        
        const fs = require('fs');
        if (fs.existsSync(testFile)) {
            const content = fs.readFileSync(testFile, 'utf8');
            console.log('\nNative output:');
            try {
                const data = JSON.parse(content);
                console.log(JSON.stringify(data.slice(0, 3), null, 2)); // Show first 3 entries
                console.log('Total entries:', data.length);
            } catch (e) {
                console.log('Raw content:', content.substring(0, 500));
            }
        }
    }, 2000);
} else {
    console.log('Failed to start native tracking');
}
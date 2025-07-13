const MacRecorder = require('./index.js');
const fs = require('fs');

// Create a minimal direct test
const recorder = new MacRecorder();

// Get current cursor position to test the new field
console.log('Testing cursor position API...');
const pos = recorder.getCursorPosition();
console.log('Current cursor position:', JSON.stringify(pos, null, 2));

// Test if we can start/stop cursor tracking
console.log('\nTesting cursor tracking start/stop...');
const testFile = 'debug-cursor-output.json';

// Remove existing file
if (fs.existsSync(testFile)) {
    fs.unlinkSync(testFile);
}

const started = recorder.startCursorCapture(testFile);
console.log('Start result:', started);

if (started) {
    // Wait 1 second and check what gets written
    setTimeout(() => {
        recorder.stopCursorCapture();
        console.log('Stopped tracking');
        
        // Check file content
        if (fs.existsSync(testFile)) {
            const content = fs.readFileSync(testFile, 'utf8');
            console.log('\nFile content:');
            console.log(content);
            
            // Parse and pretty print
            try {
                const data = JSON.parse(content);
                console.log('\nParsed data:');
                console.log(JSON.stringify(data, null, 2));
            } catch (e) {
                console.log('Error parsing JSON:', e.message);
            }
        } else {
            console.log('No output file created');
        }
    }, 1000);
} else {
    console.log('Failed to start cursor tracking');
}
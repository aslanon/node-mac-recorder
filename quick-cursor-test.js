const MacRecorder = require('./index.js');
const recorder = new MacRecorder();

console.log('Starting 3-second cursor test...');
const testPath = 'quick-cursor-test.json';

// Start cursor tracking
const started = recorder.startCursorCapture(testPath);
if (started) {
    console.log('Cursor tracking started, collecting data for 3 seconds...');
    
    setTimeout(() => {
        console.log('Stopping cursor tracking...');
        recorder.stopCursorCapture();
        console.log('Done! Check quick-cursor-test.json');
    }, 3000);
} else {
    console.log('Failed to start cursor tracking');
    process.exit(1);
}
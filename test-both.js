const MacRecorder = require('./index.js');
const recorder = new MacRecorder();

console.log('Testing screen recording + cursor tracking together...');

async function testBoth() {
    try {
        // Start both simultaneously
        console.log('Starting screen recording...');
        await recorder.startRecording('./test-recordings/test-both.mov');
        
        console.log('Starting cursor tracking...');
        await recorder.startCursorCapture('./test-both-cursor.json');
        
        console.log('Both running for 3 seconds...');
        
        // Let them run together for 3 seconds
        await new Promise(resolve => setTimeout(resolve, 3000));
        
        // Stop both
        console.log('Stopping both...');
        await recorder.stopRecording();
        recorder.stopCursorCapture();
        
        console.log('✅ Both completed successfully!');
        
        // Check results
        const fs = require('fs');
        if (fs.existsSync('./test-recordings/test-both.mov')) {
            const stats = fs.statSync('./test-recordings/test-both.mov');
            console.log(`Video file: ${stats.size} bytes`);
        }
        
        if (fs.existsSync('./test-both-cursor.json')) {
            const content = fs.readFileSync('./test-both-cursor.json', 'utf8');
            const data = JSON.parse(content);
            console.log(`Cursor data: ${data.length} entries`);
            console.log('Sample entry:', JSON.stringify(data[0], null, 2));
        }
        
    } catch (error) {
        console.error('Error:', error.message);
    }
}

testBoth();
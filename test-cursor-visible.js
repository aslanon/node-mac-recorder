const MacRecorder = require('./index.js');
const recorder = new MacRecorder();

async function testCursorVisibility() {
    console.log('Testing cursor visibility in screen recording...');
    
    try {
        // Test 1: Cursor hidden (default)
        console.log('🎬 Recording with cursor HIDDEN...');
        await recorder.startRecording('./test-recordings/cursor-hidden.mov', {
            captureCursor: false
        });
        
        await new Promise(resolve => setTimeout(resolve, 2000));
        await recorder.stopRecording();
        console.log('✅ Hidden cursor recording done');
        
        // Test 2: Cursor visible  
        console.log('🎬 Recording with cursor VISIBLE...');
        await recorder.startRecording('./test-recordings/cursor-visible.mov', {
            captureCursor: true
        });
        
        await new Promise(resolve => setTimeout(resolve, 2000));
        await recorder.stopRecording();
        console.log('✅ Visible cursor recording done');
        
        // Check file sizes
        const fs = require('fs');
        const hiddenStats = fs.statSync('./test-recordings/cursor-hidden.mov');
        const visibleStats = fs.statSync('./test-recordings/cursor-visible.mov');
        
        console.log(`Hidden cursor video: ${hiddenStats.size} bytes`);
        console.log(`Visible cursor video: ${visibleStats.size} bytes`);
        
    } catch (error) {
        console.error('Error:', error.message);
    }
}

testCursorVisibility();
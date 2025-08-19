#!/usr/bin/env node

const MacRecorder = require('./index.js');

async function testWindowDetails() {
    try {
        const recorder = new MacRecorder();
        const windows = await recorder.getWindows();
        
        console.log(`Found ${windows.length} windows:`);
        
        windows.forEach((win, i) => {
            console.log(`\n${i+1}. Window ${win.id}:`);
            console.log(`   Title: "${win.title}"`);
            console.log(`   App: ${win.appName}`);
            console.log(`   Bundle: ${win.bundleId}`);
            console.log(`   Position: (${win.x}, ${win.y})`);
            console.log(`   Size: ${win.width} x ${win.height}`);
            if (win.bounds) {
                console.log(`   Bounds: (${win.bounds.x}, ${win.bounds.y}) ${win.bounds.width}x${win.bounds.height}`);
            }
            
            if (i >= 10) { // Limit output
                console.log(`\n... and ${windows.length - 11} more windows`);
                return;
            }
        });
        
    } catch (error) {
        console.error('Error:', error.message);
    }
}

testWindowDetails();
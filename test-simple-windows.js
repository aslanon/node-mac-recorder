#!/usr/bin/env node

const MacRecorder = require('./index.js');

async function test() {
    try {
        const recorder = new MacRecorder();
        console.log('Getting windows directly from native binding...');
        
        const nativeBinding = require('./build/Release/mac_recorder.node');
        const nativeWindows = nativeBinding.getWindows();
        console.log('Native windows:', nativeWindows.length);
        if (nativeWindows.length > 0) {
            console.log('First native window:', nativeWindows[0]);
        }
        
        console.log('\nGetting windows through MacRecorder class...');
        const windows = await recorder.getWindows();
        console.log('MacRecorder windows:', windows.length);
        if (windows.length > 0) {
            console.log('First MacRecorder window:', windows[0]);
        }
        
    } catch (error) {
        console.error('Error:', error);
    }
}

test();
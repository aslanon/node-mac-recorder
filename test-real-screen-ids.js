#!/usr/bin/env node

const WindowSelector = require('./window-selector');

async function testRealScreenIDs() {
    console.log('Testing real screen ID generation...\n');
    
    const selector = new WindowSelector();
    
    // Start screen selection to generate screen info
    console.log('Starting screen selection (will timeout in 3 seconds)...');
    
    const startPromise = selector.startScreenSelection();
    
    // Wait a bit for screen info to be generated
    await new Promise(resolve => setTimeout(resolve, 1000));
    
    // Try to get selected screen info (should be null since nothing selected)
    const selectedInfo = selector.getSelectedScreen();
    console.log('Selected screen info (should be null):', selectedInfo);
    
    // Clean up
    try {
        await selector.stopScreenSelection();
    } catch (e) {
        // Ignore
    }
    
    console.log('\nTest completed. Check logs above for screen creation details.');
}

testRealScreenIDs().catch(console.error);
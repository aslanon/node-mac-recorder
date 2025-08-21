#!/usr/bin/env node

const WindowSelector = require('./window-selector');

console.log('Starting screen selection...');
console.log('Click "Start Record" on ANY screen then this will show the result:');

const selector = new WindowSelector();

selector.startScreenSelection().then(() => {
    console.log('Screen selection UI shown');
    
    // Check every 500ms for selection
    const checkInterval = setInterval(() => {
        const selected = selector.getSelectedScreen();
        if (selected) {
            console.log('\n🎉 SCREEN SELECTED!');
            console.log('Selected data:', JSON.stringify(selected, null, 2));
            clearInterval(checkInterval);
            process.exit(0);
        }
    }, 500);
    
    // Timeout after 15 seconds
    setTimeout(() => {
        console.log('\n⏰ Timeout - no screen selected');
        clearInterval(checkInterval);
        process.exit(1);
    }, 15000);
    
}).catch(error => {
    console.error('Error:', error.message);
    process.exit(1);
});
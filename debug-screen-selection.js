#!/usr/bin/env node

const WindowSelector = require('./window-selector');
const MacRecorder = require('./index');

async function debugScreenSelection() {
    console.log('🔍 Screen Selection Debug Test');
    console.log('================================\n');

    const selector = new WindowSelector();
    const recorder = new MacRecorder();

    try {
        // First, let's see what displays MacRecorder sees
        console.log('📺 MacRecorder displays:');
        const macDisplays = await recorder.getDisplays();
        macDisplays.forEach((display, i) => {
            console.log(`   ${i}: ID=${display.id}, Name="${display.name}", Resolution=${display.resolution}, Primary=${display.isPrimary}`);
        });
        console.log('');

        // Start screen selection
        console.log('🖥️ Starting screen selection...');
        console.log('   Move mouse to different screens and click "Start Record" on one of them');
        console.log('');

        const selectedScreen = await selector.selectScreen();
        
        console.log('✅ Screen selected!');
        console.log('📊 Selected screen data:');
        console.log(JSON.stringify(selectedScreen, null, 2));
        
        // Check if this ID exists in MacRecorder displays
        const matchingDisplay = macDisplays.find(d => d.id === selectedScreen.id);
        
        if (matchingDisplay) {
            console.log('\n✅ MATCH FOUND in MacRecorder displays:');
            console.log(`   Selected: ${selectedScreen.name} (ID: ${selectedScreen.id})`);
            console.log(`   MacRecorder: ${matchingDisplay.name} (ID: ${matchingDisplay.id})`);
        } else {
            console.log('\n❌ NO MATCH found in MacRecorder displays!');
            console.log(`   Selected ID: ${selectedScreen.id}`);
            console.log(`   Available IDs: ${macDisplays.map(d => d.id).join(', ')}`);
        }

        console.log('\n🎬 Testing actual recording...');
        console.log('   Setting displayId option and starting short recording');
        
        // Set the display ID from screen selection
        recorder.setOptions({
            displayId: selectedScreen.id,
            includeSystemAudio: false,
            includeMicrophone: false
        });

        const testFile = `./test-output/screen-selection-test-${Date.now()}.mov`;
        console.log(`   Recording file: ${testFile}`);
        
        await recorder.startRecording(testFile);
        console.log('   Recording started...');
        
        // Record for 3 seconds
        await new Promise(resolve => setTimeout(resolve, 3000));
        
        await recorder.stopRecording();
        console.log('   Recording stopped');
        
        console.log('\n✅ Test completed! Check the recording to see if it captured the correct screen.');
        
    } catch (error) {
        console.error('\n❌ Error during test:', error.message);
        if (error.stack) {
            console.error('Stack:', error.stack);
        }
        process.exit(1);
    }
}

if (require.main === module) {
    debugScreenSelection();
}
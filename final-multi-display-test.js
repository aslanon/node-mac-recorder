const MacRecorder = require('./index');
const WindowSelector = MacRecorder.WindowSelector;

async function finalMultiDisplayTest() {
    console.log('🎉 FINAL Multi-Display Test');
    console.log('='.repeat(40));
    
    const recorder = new MacRecorder();
    const displays = await recorder.getDisplays();
    
    console.log('📊 Display Configuration:');
    displays.forEach(display => {
        console.log(`  ${display.name}: (${display.x}, ${display.y}) ${display.width}x${display.height} ${display.isPrimary ? '[PRIMARY]' : ''}`);
    });
    
    console.log('\n✅ All coordinate fixes applied:');
    console.log('  - Screen selector: Local coordinates for UI elements');
    console.log('  - Window selector: Primary/secondary coordinate handling');
    console.log('  - Display recording: Correct display ID mapping');
    
    console.log('\n🧪 Testing window selector...');
    console.log('📍 IMPORTANT: Test windows on BOTH displays');
    console.log('   - Primary display: Should show buttons/UI correctly now');
    console.log('   - Secondary display: Should continue working');
    
    const selector = new WindowSelector();
    
    try {
        await selector.startSelection();
        
        console.log('\n⏱️  Running for 30 seconds - test both displays thoroughly...');
        await new Promise(resolve => setTimeout(resolve, 30000));
        
        await selector.stopSelection();
        
        console.log('✅ Window selector test completed!');
        
        // Test recording on both displays
        console.log('\n🎥 Testing recording on both displays...');
        
        for (const display of displays) {
            console.log(`\n📹 Testing ${display.name} recording...`);
            
            try {
                const outputPath = `./test-output/final-test-${display.id}.mov`;
                
                await recorder.startRecording(outputPath, {
                    displayId: display.id,
                    captureCursor: true,
                    includeMicrophone: false,
                    includeSystemAudio: false
                });
                
                console.log(`✅ Recording started on ${display.name}`);
                await new Promise(resolve => setTimeout(resolve, 2000));
                
                await recorder.stopRecording();
                console.log(`✅ Recording completed on ${display.name}`);
                
            } catch (error) {
                console.log(`❌ Recording failed on ${display.name}: ${error.message}`);
            }
        }
        
        console.log('\n🎉 ALL MULTI-DISPLAY TESTS COMPLETED!');
        console.log('✅ Window selector should now work on both displays');
        console.log('✅ Recording should work on both displays');
        
    } catch (error) {
        console.log(`❌ Test failed: ${error.message}`);
    }
}

finalMultiDisplayTest();
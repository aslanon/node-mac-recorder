#!/usr/bin/env node

const WindowSelector = require('./window-selector');

async function testMultiScreenSelection() {
    console.log('🖥️ Multi-Screen Selection Test');
    console.log('==============================\n');

    const selector = new WindowSelector();
    
    try {
        // Check permissions first
        const permissions = await selector.checkPermissions();
        console.log('🔐 Permissions:');
        console.log(`   Screen Recording: ${permissions.screenRecording ? '✅' : '❌'}`);
        console.log(`   Accessibility: ${permissions.accessibility ? '✅' : '❌'}\n`);

        if (!permissions.screenRecording || !permissions.accessibility) {
            console.log('⚠️ Missing required permissions. Please grant permissions in System Preferences.');
            process.exit(1);
        }

        // Get display information
        const MacRecorder = require('./index');
        const recorder = new MacRecorder();
        const displays = await recorder.getDisplays();
        
        console.log(`🖥️ Found ${displays.length} display(s):`);
        displays.forEach((display, index) => {
            console.log(`   Display ${index + 1}: ${display.name} (${display.resolution}) at (${display.x}, ${display.y}) ${display.isPrimary ? '🌟 PRIMARY' : ''}`);
        });
        console.log('');

        if (displays.length < 2) {
            console.log('⚠️ Only one display detected. Connect a second display to fully test multi-screen selection functionality.');
            console.log('Continuing with single display test...\n');
        } else {
            console.log('✅ Multiple displays detected. Perfect for multi-screen testing!\n');
        }

        console.log('🚀 Starting multi-screen selection test...\n');
        console.log('📋 What to expect:');
        console.log('   1. Overlay will appear on ALL screens simultaneously');
        console.log('   2. The screen where your mouse is located will be HIGHLIGHTED (brighter)');
        console.log('   3. Other screens will be dimmer');
        console.log('   4. Move mouse between screens to see the highlighting change');
        console.log('   5. Click "Start Record" on the screen you want to record');
        console.log('   6. Press ESC to cancel\n');

        if (displays.length > 1) {
            console.log('🖱️ Multi-Screen Instructions:');
            console.log('   • Move your mouse from one screen to another');
            console.log('   • Watch the overlay highlighting follow your mouse');
            console.log('   • Notice how the active screen becomes brighter');
            console.log('   • All screens should show the overlay simultaneously\n');
        }

        console.log('⏱️ Starting screen selection in 3 seconds...');
        await new Promise(resolve => setTimeout(resolve, 3000));

        // Start screen selection
        const success = await selector.startScreenSelection();
        
        if (!success) {
            console.error('❌ Failed to start screen selection');
            process.exit(1);
        }

        console.log('✅ Screen selection started successfully!');
        console.log('🖱️ Move your mouse between screens to test highlighting...\n');

        // Monitor for selection completion
        let checkCount = 0;
        const selectionChecker = setInterval(() => {
            checkCount++;
            const selectedScreen = selector.getSelectedScreen();
            
            if (selectedScreen) {
                clearInterval(selectionChecker);
                
                console.log('\n' + '🎉'.repeat(25));
                console.log('🎯 SCREEN SELECTED!');
                console.log('🎉'.repeat(25));
                
                console.log(`\n📊 Selected Screen Details:`);
                console.log(`   Name: ${selectedScreen.name}`);
                console.log(`   Resolution: ${selectedScreen.resolution}`);
                console.log(`   Position: (${selectedScreen.x}, ${selectedScreen.y})`);
                console.log(`   Size: ${selectedScreen.width} × ${selectedScreen.height}`);
                console.log(`   Primary: ${selectedScreen.isPrimary ? 'Yes' : 'No'}`);
                
                console.log(`\n✅ Multi-screen selection test completed successfully!`);
                console.log(`📈 Test ran for ${(checkCount * 100) / 1000} seconds`);
                
                process.exit(0);
            }
            
            // Show progress every 5 seconds
            if (checkCount % 50 === 0) {
                const elapsed = (checkCount * 100) / 1000;
                console.log(`⏱️ Test running for ${elapsed}s - Move mouse between screens to test highlighting`);
                
                if (displays.length > 1) {
                    console.log('💡 Remember: The overlay should appear on ALL screens, but only the one with your mouse should be bright');
                }
            }
        }, 100); // Check every 100ms

        // Timeout after 60 seconds
        setTimeout(() => {
            clearInterval(selectionChecker);
            console.log('\n⏰ Test timeout reached (60 seconds)');
            console.log('🛑 Stopping screen selection...');
            
            selector.stopScreenSelection().then(() => {
                console.log('✅ Screen selection stopped');
                
                if (displays.length > 1) {
                    console.log('\n📊 Multi-Screen Test Summary:');
                    console.log('   Expected behavior:');
                    console.log('   ✓ Overlays should have appeared on all screens');
                    console.log('   ✓ Mouse screen should have been highlighted brighter');
                    console.log('   ✓ Non-mouse screens should have been dimmer');
                    console.log('   ✓ Highlighting should have changed as you moved mouse');
                } else {
                    console.log('\n📊 Single-Screen Test Summary:');
                    console.log('   ✓ Overlay should have appeared on your screen');
                    console.log('   ✓ Screen should have been highlighted');
                }
                
                process.exit(0);
            }).catch((error) => {
                console.error('❌ Error stopping screen selection:', error.message);
                process.exit(1);
            });
        }, 60000);

        // Handle Ctrl+C gracefully
        process.on('SIGINT', async () => {
            clearInterval(selectionChecker);
            console.log('\n\n🛑 Test interrupted by user');
            
            try {
                await selector.stopScreenSelection();
                console.log('✅ Screen selection stopped');
            } catch (error) {
                console.log('⚠️ Error during cleanup:', error.message);
            }
            
            console.log('\n📊 Test Results Summary:');
            console.log(`   Displays available: ${displays.length}`);
            console.log(`   Test duration: ${(checkCount * 100) / 1000} seconds`);
            if (displays.length > 1) {
                console.log('   Multi-screen support: Test interrupted before completion');
            }
            
            process.exit(0);
        });

    } catch (error) {
        console.error('\n❌ Test failed:', error.message);
        if (error.stack) {
            console.error('Stack trace:', error.stack);
        }
        process.exit(1);
    }
}

if (require.main === module) {
    testMultiScreenSelection();
}
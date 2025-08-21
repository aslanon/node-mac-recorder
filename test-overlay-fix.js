#!/usr/bin/env node

const ElectronWindowSelector = require('./electron-window-selector.js');

console.log('🧪 Testing Fixed Overlay Functionality');
console.log('=====================================');

async function testOverlayFunctionality() {
    const selector = new ElectronWindowSelector();
    
    try {
        console.log('\n🔍 Environment Check:');
        const status = selector.getStatus();
        console.log(`  - Electron Mode: ${status.isElectron}`);
        
        console.log('\n🪟 Testing Window Detection...');
        
        // Test real-time window detection
        console.log('Move your mouse over different windows...');
        console.log('Press Ctrl+C to stop\n');
        
        let lastWindowId = null;
        
        const checkInterval = setInterval(async () => {
            try {
                // Simulate what Electron app would do - poll for current window
                const windowStatus = require('./build/Release/mac_recorder.node').getWindowSelectionStatus();
                
                if (windowStatus && windowStatus.currentWindow) {
                    const window = windowStatus.currentWindow;
                    
                    if (window.id !== lastWindowId) {
                        lastWindowId = window.id;
                        
                        console.log(`🎯 Window Detected: ${window.appName} - "${window.title}"`);
                        console.log(`   📍 Position: (${window.x}, ${window.y})`);
                        console.log(`   📏 Size: ${window.width}x${window.height}`);
                        
                        if (window.screenId !== undefined) {
                            console.log(`   🖥️ Screen: ${window.screenId} (${window.screenWidth}x${window.screenHeight})`);
                        }
                        console.log('');
                    }
                } else if (lastWindowId !== null) {
                    lastWindowId = null;
                    console.log('🚪 No window under cursor\n');
                }
            } catch (error) {
                console.error('Error during window detection:', error.message);
            }
        }, 100); // Check every 100ms for smooth tracking
        
        // Handle Ctrl+C gracefully
        process.on('SIGINT', () => {
            console.log('\n\n🛑 Stopping test...');
            clearInterval(checkInterval);
            selector.cleanup().then(() => {
                console.log('✅ Cleanup completed');
                process.exit(0);
            });
        });
        
    } catch (error) {
        console.error('❌ Test failed:', error.message);
        process.exit(1);
    }
}

// Set Electron environment for testing
process.env.ELECTRON_VERSION = '25.0.0';

testOverlayFunctionality();
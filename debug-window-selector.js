#!/usr/bin/env node

const WindowSelector = require('./window-selector');

async function debugWindowSelector() {
    console.log('🔍 Window Selector Debug Mode');
    console.log('=============================\n');

    const selector = new WindowSelector();

    try {
        // 1. İzin kontrolü
        console.log('1️⃣ Checking permissions...');
        const permissions = await selector.checkPermissions();
        console.log('Permissions:', JSON.stringify(permissions, null, 2));

        if (!permissions.screenRecording || !permissions.accessibility) {
            console.warn('⚠️ Missing permissions detected!');
            console.warn('Go to: System Preferences > Security & Privacy > Privacy');
            console.warn('Enable for Terminal/Node in both:');
            console.warn('- Screen Recording');
            console.warn('- Accessibility');
            console.log();
        }

        // 2. Native status before start
        console.log('\n2️⃣ Native status before start:');
        const initialStatus = selector.getStatus();
        console.log(JSON.stringify(initialStatus, null, 2));

        // 3. Start selection with detailed logging
        console.log('\n3️⃣ Starting window selection...');
        
        selector.on('selectionStarted', () => {
            console.log('✅ Selection started event received');
        });

        selector.on('windowEntered', (window) => {
            console.log(`🏠 Window entered: "${window.title}" (${window.appName})`);
        });

        selector.on('windowLeft', (window) => {
            console.log(`🚪 Window left: "${window.title}" (${window.appName})`);
        });

        selector.on('windowSelected', (window) => {
            console.log('🎯 Window selected:', window.title);
        });

        selector.on('error', (error) => {
            console.error('❌ Error event:', error);
        });

        await selector.startSelection();

        // 4. Status after start
        console.log('\n4️⃣ Status after start:');
        const runningStatus = selector.getStatus();
        console.log(JSON.stringify(runningStatus, null, 2));

        // 5. Detailed native status monitoring
        console.log('\n5️⃣ Monitoring native status (10 seconds)...');
        console.log('Move your cursor over different windows');
        console.log('The overlay should appear over windows\n');

        for (let i = 0; i < 20; i++) {
            await new Promise(resolve => setTimeout(resolve, 500));
            const status = selector.getStatus();
            
            process.stdout.write(`\r[${i+1}/20] `);
            process.stdout.write(`Selecting: ${status.nativeStatus?.isSelecting || false}, `);
            process.stdout.write(`Overlay: ${status.nativeStatus?.hasOverlay || false}, `);
            process.stdout.write(`Windows: ${status.nativeStatus?.windowCount || 0}`);
            
            if (status.nativeStatus?.currentWindow) {
                process.stdout.write(`, Current: ${status.nativeStatus.currentWindow.appName}`);
            }
        }

        console.log('\n\n6️⃣ Final status:');
        const finalStatus = selector.getStatus();
        console.log(JSON.stringify(finalStatus, null, 2));

    } catch (error) {
        console.error('\n❌ Debug failed:', error.message);
        console.error('Stack:', error.stack);
    } finally {
        console.log('\n🛑 Stopping selection...');
        await selector.cleanup();
    }
}

// Alternative: Test native functions directly
async function testNativeFunctions() {
    console.log('🧪 Testing Native Functions Directly');
    console.log('====================================\n');

    try {
        // Try to load native binding directly
        let nativeBinding;
        try {
            nativeBinding = require("./build/Release/mac_recorder.node");
        } catch (error) {
            try {
                nativeBinding = require("./build/Debug/mac_recorder.node");
            } catch (debugError) {
                console.error('❌ Cannot load native module');
                console.error('Release error:', error.message);
                console.error('Debug error:', debugError.message);
                return;
            }
        }

        console.log('✅ Native module loaded successfully');

        // Test if window selector functions exist
        console.log('\n🔍 Available native functions:');
        const functions = [
            'startWindowSelection',
            'stopWindowSelection',
            'getSelectedWindowInfo',
            'getWindowSelectionStatus'
        ];

        for (const func of functions) {
            if (typeof nativeBinding[func] === 'function') {
                console.log(`✅ ${func} - available`);
            } else {
                console.log(`❌ ${func} - missing`);
            }
        }

        // Test direct native call
        console.log('\n🚀 Testing direct native startWindowSelection...');
        try {
            const result = nativeBinding.startWindowSelection();
            console.log('Native start result:', result);

            if (result) {
                console.log('✅ Native selection started');
                
                // Check status
                const status = nativeBinding.getWindowSelectionStatus();
                console.log('Native status:', JSON.stringify(status, null, 2));

                // Wait a bit
                console.log('\nWaiting 3 seconds for overlay to appear...');
                await new Promise(resolve => setTimeout(resolve, 3000));

                // Stop
                const stopResult = nativeBinding.stopWindowSelection();
                console.log('Native stop result:', stopResult);
            } else {
                console.log('❌ Native selection failed to start');
            }
        } catch (nativeError) {
            console.error('❌ Native function error:', nativeError.message);
        }

    } catch (error) {
        console.error('❌ Native test failed:', error.message);
    }
}

// Main function
async function main() {
    const args = process.argv.slice(2);
    
    if (args.includes('--native')) {
        await testNativeFunctions();
    } else {
        await debugWindowSelector();
    }
}

if (require.main === module) {
    main().catch(console.error);
}
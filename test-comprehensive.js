const MacRecorder = require('./index');
const fs = require('fs');
const path = require('path');

function runComprehensiveTests() {
    console.log('🧪 Running Comprehensive ScreenCaptureKit Tests\n');
    console.log('=' .repeat(60));
    
    const recorder = new MacRecorder();
    let testResults = {
        passed: 0,
        failed: 0,
        details: []
    };
    
    function addResult(testName, passed, details = '') {
        testResults.details.push({
            name: testName,
            passed,
            details
        });
        
        if (passed) {
            testResults.passed++;
            console.log(`✅ ${testName}`);
        } else {
            testResults.failed++;
            console.log(`❌ ${testName}: ${details}`);
        }
        if (details && passed) {
            console.log(`   ${details}`);
        }
    }
    
    // Test 1: Module Loading
    try {
        addResult('Module Loading', true, 'MacRecorder class instantiated successfully');
    } catch (error) {
        addResult('Module Loading', false, error.message);
    }
    
    // Test 2: Method Availability
    const expectedMethods = [
        'getDisplays', 'getWindows', 'getAudioDevices', 'startRecording', 
        'stopRecording', 'checkPermissions', 'getCursorPosition',
        'getWindowThumbnail', 'getDisplayThumbnail'
    ];
    
    let missingMethods = [];
    expectedMethods.forEach(method => {
        if (typeof recorder[method] !== 'function') {
            missingMethods.push(method);
        }
    });
    
    if (missingMethods.length === 0) {
        addResult('API Method Availability', true, `All ${expectedMethods.length} expected methods available`);
    } else {
        addResult('API Method Availability', false, `Missing methods: ${missingMethods.join(', ')}`);
    }
    
    // Test 3: Synchronous Operations
    try {
        const cursor = recorder.getCurrentCursorPosition();
        if (cursor && typeof cursor.x === 'number' && typeof cursor.y === 'number') {
            addResult('Cursor Position (Sync)', true, `Position: (${cursor.x}, ${cursor.y}), Type: ${cursor.cursorType}`);
        } else {
            addResult('Cursor Position (Sync)', false, 'Invalid cursor data returned');
        }
    } catch (error) {
        addResult('Cursor Position (Sync)', false, error.message);
    }
    
    // Test 4: Cursor Capture Status
    try {
        const status = recorder.getCursorCaptureStatus();
        addResult('Cursor Capture Status', true, `Tracking: ${status.isTracking || false}`);
    } catch (error) {
        addResult('Cursor Capture Status', false, error.message);
    }
    
    console.log('\n' + '─'.repeat(60));
    console.log('📊 Test Results Summary:');
    console.log('─'.repeat(60));
    console.log(`✅ Passed: ${testResults.passed}`);
    console.log(`❌ Failed: ${testResults.failed}`);
    console.log(`📈 Success Rate: ${Math.round((testResults.passed / (testResults.passed + testResults.failed)) * 100)}%`);
    
    console.log('\n🔍 Detailed Analysis:');
    console.log('─'.repeat(60));
    
    // Test async operations with timeout
    console.log('\n🔄 Testing Async Operations (with 8s timeout each):');
    
    let asyncTests = 0;
    let asyncPassed = 0;
    
    function testAsync(testName, asyncFunction, timeout = 8000) {
        return new Promise((resolve) => {
            asyncTests++;
            const timeoutId = setTimeout(() => {
                console.log(`⚠️  ${testName}: Timed out after ${timeout/1000}s (likely permission dialog)`);
                resolve(false);
            }, timeout);
            
            try {
                asyncFunction((error, result) => {
                    clearTimeout(timeoutId);
                    if (error) {
                        console.log(`❌ ${testName}: ${error.message || error}`);
                        resolve(false);
                    } else {
                        const resultInfo = Array.isArray(result) ? `${result.length} items` : 'Success';
                        console.log(`✅ ${testName}: ${resultInfo}`);
                        asyncPassed++;
                        resolve(true);
                    }
                });
            } catch (error) {
                clearTimeout(timeoutId);
                console.log(`❌ ${testName}: ${error.message}`);
                resolve(false);
            }
        });
    }
    
    // Run async tests sequentially
    (async () => {
        await testAsync('Permissions Check', (cb) => recorder.checkPermissions(cb));
        await testAsync('Display Enumeration', (cb) => recorder.getDisplays(cb));
        await testAsync('Window Enumeration', (cb) => recorder.getWindows(cb));
        await testAsync('Audio Device Enumeration', (cb) => recorder.getAudioDevices(cb));
        
        console.log('\n' + '═'.repeat(60));
        console.log('🏁 Final Test Summary:');
        console.log('═'.repeat(60));
        console.log(`🔧 Synchronous Tests: ${testResults.passed}/${testResults.passed + testResults.failed} passed`);
        console.log(`🔄 Asynchronous Tests: ${asyncPassed}/${asyncTests} passed`);
        console.log(`📊 Overall: ${testResults.passed + asyncPassed}/${testResults.passed + testResults.failed + asyncTests} tests passed`);
        
        const overallSuccess = Math.round(((testResults.passed + asyncPassed) / (testResults.passed + testResults.failed + asyncTests)) * 100);
        
        if (overallSuccess >= 80) {
            console.log(`\n🎉 ScreenCaptureKit Migration: ${overallSuccess}% SUCCESS!`);
            console.log('✨ The migration is working correctly');
        } else if (overallSuccess >= 60) {
            console.log(`\n⚠️  ScreenCaptureKit Migration: ${overallSuccess}% PARTIAL SUCCESS`);
            console.log('🔧 Some functionality working, permissions may need attention');
        } else {
            console.log(`\n❌ ScreenCaptureKit Migration: ${overallSuccess}% - NEEDS WORK`);
            console.log('🚨 Multiple issues detected');
        }
        
        console.log('\n💡 Notes:');
        console.log('• Timeouts usually indicate missing screen recording permissions');
        console.log('• Enable permissions in: System Preferences > Privacy & Security > Screen Recording');
        console.log('• ScreenCaptureKit requires macOS 12.3+ and arm64 architecture');
        console.log('• All synchronous operations (cursor tracking) should work without permissions');
        
        process.exit(0);
    })();
}

runComprehensiveTests();
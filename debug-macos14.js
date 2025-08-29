const MacRecorder = require('./index');

console.log('🧪 macOS 14/13 Debug Test');
console.log('=========================================');
console.log('');
console.log('This script helps debug recording issues on macOS 14 and earlier.');
console.log('Please run this and share the complete console output.');
console.log('');

async function debugMacOS14() {
  const recorder = new MacRecorder();
  
  try {
    // Create test output directory
    const fs = require('fs');
    if (!fs.existsSync('./test-output')) {
      fs.mkdirSync('./test-output');
    }
    
    console.log('📋 System Information:');
    const os = require('os');
    console.log('  OS:', os.type(), os.release());
    console.log('  Architecture:', os.arch());
    console.log('  Platform:', os.platform());
    
    // Check permissions first
    console.log('');
    console.log('🔐 Checking Permissions...');
    try {
      const permissions = await recorder.checkPermissions();
      console.log('  Screen Recording Permission:', permissions.screenRecording ? '✅ GRANTED' : '❌ DENIED');
      console.log('  Accessibility Permission:', permissions.accessibility ? '✅ GRANTED' : '❌ DENIED');
      
      if (!permissions.screenRecording) {
        console.log('');
        console.log('❌ CRITICAL: Screen Recording permission is DENIED');
        console.log('   Please grant permission in System Preferences > Security & Privacy > Privacy > Screen Recording');
        console.log('   Then restart this test.');
        return;
      }
    } catch (permError) {
      console.log('  Permission check failed:', permError.message);
    }
    
    console.log('');
    console.log('🎯 Starting Recording Test...');
    console.log('Expected behavior:');
    console.log('  • System should detect macOS version');
    console.log('  • macOS 15+ uses ScreenCaptureKit');  
    console.log('  • macOS 14/13 uses AVFoundation fallback');
    console.log('  • You should see detailed logs below');
    console.log('');
    
    const outputPath = './test-output/debug-test.mov';
    
    const success = await recorder.startRecording(outputPath, {
      captureCursor: true,
      includeMicrophone: false,
      includeSystemAudio: true,
      displayId: null // Use primary display
    });
    
    if (success) {
      console.log('✅ Recording started successfully');
      console.log('⏱️ Recording for 3 seconds...');
      
      await new Promise(resolve => setTimeout(resolve, 3000));
      
      console.log('🛑 Stopping recording...');
      await recorder.stopRecording();
      
      // Check if file was created
      const fs = require('fs');
      if (fs.existsSync(outputPath)) {
        const stats = fs.statSync(outputPath);
        console.log('✅ Recording file created:', outputPath);
        console.log('   File size:', Math.round(stats.size / 1024), 'KB');
        console.log('');
        console.log('🎉 SUCCESS: Recording works on your system!');
      } else {
        console.log('❌ Recording file was not created');
        console.log('   Expected:', outputPath);
      }
    } else {
      console.log('❌ Recording failed to start');
      console.log('');
      console.log('🔍 Troubleshooting Steps:');
      console.log('1. Check console logs above for specific error messages');
      console.log('2. Verify Screen Recording permission is granted');
      console.log('3. Try restarting your application');
      console.log('4. Check if output directory exists and is writable');
    }
    
  } catch (error) {
    console.log('❌ Error during test:', error.message);
    if (error.stack) {
      console.log('Stack trace:', error.stack);
    }
  }
  
  console.log('');
  console.log('📞 Support Information:');
  console.log('If recording still fails, please share:');
  console.log('1. Complete console output from this test');
  console.log('2. Your macOS version (System Settings > About)');
  console.log('3. Permission screenshots from System Settings');
}

// Run the debug test
debugMacOS14();
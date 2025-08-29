const MacRecorder = require('./index');

async function testMacOS14Recording() {
  const recorder = new MacRecorder();
  
  console.log('🧪 macOS 14 Recording Test');
  console.log('This will test AVFoundation fallback path when ScreenCaptureKit fails or is not available');
  console.log('');
  
  try {
    const outputPath = './test-output/macos14-test.mov';
    
    console.log('📹 Starting recording test...');
    console.log('Expected behavior on macOS 14:');
    console.log('  1. System detects macOS 14.x');
    console.log('  2. Skips ScreenCaptureKit (only for macOS 15+)');
    console.log('  3. Uses AVFoundation fallback');
    console.log('  4. Records at 15fps with H.264 encoding');
    console.log('');
    
    const success = await recorder.startRecording(outputPath, {
      captureCursor: true,
      includeMicrophone: false,
      includeSystemAudio: true,
      displayId: null // Use main display
    });
    
    if (success) {
      console.log('✅ Recording started successfully');
      console.log('⏱️ Recording for 3 seconds...');
      
      await new Promise(resolve => setTimeout(resolve, 3000));
      
      console.log('🛑 Stopping recording...');
      await recorder.stopRecording();
      
      console.log('✅ macOS 14 test completed successfully!');
      console.log('📁 Output file: ' + outputPath);
    } else {
      console.log('❌ Recording failed to start');
      console.log('');
      console.log('Troubleshooting steps:');
      console.log('1. Check Screen Recording permission in System Preferences');
      console.log('2. Ensure macOS version is 14.0 or later');
      console.log('3. Check console logs for detailed error messages');
    }
  } catch (error) {
    console.log('❌ Error during test:', error.message);
    if (error.stack) {
      console.log('Stack trace:', error.stack);
    }
  }
}

// Run the test
testMacOS14Recording();
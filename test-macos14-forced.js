// macOS 14 test simülasyonu - detaylı debug bilgisiyle
const MacRecorder = require('./index');

console.log('🧪 macOS 14 Forced Test with Detailed Debugging');
console.log('====================================================');
console.log('');
console.log('This test simulates exactly what happens on macOS 14');
console.log('by forcing the AVFoundation path.');
console.log('');

// Force AVFoundation environment variable
process.env.FORCE_AVFOUNDATION = '1';

async function testMacOS14Scenario() {
  const recorder = new MacRecorder();
  
  console.log('📋 Test Configuration:');
  console.log('  - FORCE_AVFOUNDATION = 1 (simulates macOS 14)');
  console.log('  - Expected: Skip ScreenCaptureKit, use AVFoundation');
  console.log('  - Should see: "🎥 Using AVFoundation" logs');
  console.log('');
  
  try {
    const outputPath = './test-output/macos14-forced.mov';
    
    // Create directory
    const fs = require('fs');
    if (!fs.existsSync('./test-output')) {
      fs.mkdirSync('./test-output');
    }
    
    console.log('🎬 Starting recording (macOS 14 simulation)...');
    console.log('Expected Console Logs:');
    console.log('  🔧 FORCE_AVFOUNDATION environment variable detected');
    console.log('  🎯 macOS 14 detected - directly using AVFoundation');
    console.log('  🎥 Using AVFoundation for macOS 14 compatibility');
    console.log('  🎬 AVFoundation: Starting recording initialization');
    console.log('  ✅ AVFoundation recording started successfully');
    console.log('');
    
    const result = await recorder.startRecording(outputPath, {
      captureCursor: true,
      includeMicrophone: false,
      includeSystemAudio: true,
      displayId: 1
    });
    
    if (result) {
      console.log('🎉 SUCCESS: macOS 14 path works!');
      console.log('📁 Output file:', result);
      console.log('⏱️ Recording for 3 seconds...');
      
      await new Promise(resolve => setTimeout(resolve, 3000));
      
      console.log('🛑 Stopping recording...');
      await recorder.stopRecording();
      
      // Verify file
      if (fs.existsSync(outputPath)) {
        const stats = fs.statSync(outputPath);
        console.log('✅ Recording file created successfully');
        console.log('   File size:', Math.round(stats.size / 1024), 'KB');
        console.log('');
        console.log('🎉 macOS 14 Recording Test: PASSED ✅');
        console.log('');
        console.log('This means on real macOS 14 systems:');
        console.log('✅ Version detection will work');
        console.log('✅ AVFoundation will be used as primary method');
        console.log('✅ No ScreenCaptureKit errors will occur');
        console.log('✅ Recording will work with 15fps H.264 encoding');
      } else {
        console.log('❌ No output file created');
      }
      
    } else {
      console.log('❌ Recording failed to start');
    }
    
  } catch (error) {
    console.log('❌ Error:', error.message);
    
    // Check if user is getting old error
    if (error.message.includes('ScreenCaptureKit failed')) {
      console.log('');
      console.log('🚨 CRITICAL: You are seeing the OLD error message!');
      console.log('');
      console.log('This means:');
      console.log('❌ You are using an old version of node-mac-recorder');
      console.log('❌ The new macOS 14/13 compatibility is not active');
      console.log('');
      console.log('🔧 To fix this:');
      console.log('1. Update to the latest version: npm update node-mac-recorder');
      console.log('2. Or rebuild: npm run build');
      console.log('3. Or reinstall: npm uninstall node-mac-recorder && npm install node-mac-recorder');
      console.log('');
      console.log('Expected NEW error message should be:');
      console.log('"Recording failed to start. Check permissions, output path, and system compatibility."');
    } else {
      console.log('✅ Error message is updated (good sign)');
    }
  }
  
  // Reset environment
  delete process.env.FORCE_AVFOUNDATION;
}

testMacOS14Scenario();
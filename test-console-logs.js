const MacRecorder = require('./index');

console.log('🔍 Console Log Detection Test');
console.log('This test shows which recording method is being used');
console.log('========================================================');

async function testConsoleOutput() {
  const recorder = new MacRecorder();
  
  try {
    console.log('📋 Starting recording test...');
    console.log('Expected to see detailed native logs in Console.app or terminal');
    console.log('');
    
    const outputPath = './test-output/console-log-test.mov';
    
    // Create test output directory
    const fs = require('fs');
    if (!fs.existsSync('./test-output')) {
      fs.mkdirSync('./test-output');
    }
    
    console.log('🎬 Calling startRecording...');
    const result = await recorder.startRecording(outputPath, {
      captureCursor: false,
      includeMicrophone: false,
      includeSystemAudio: false,
      displayId: 1
    });
    
    if (result) {
      console.log('✅ Recording started successfully!');
      console.log('📝 Result:', result);
      
      await new Promise(resolve => setTimeout(resolve, 2000));
      
      console.log('🛑 Stopping recording...');
      await recorder.stopRecording();
      console.log('✅ Recording stopped');
      
      // Check what method was used by looking at file size/existence
      if (fs.existsSync(outputPath)) {
        const stats = fs.statSync(outputPath);
        console.log('📁 File created:', stats.size, 'bytes');
        console.log('');
        console.log('🎉 SUCCESS: Recording works!');
      }
    } else {
      console.log('❌ Recording failed');
    }
    
  } catch (error) {
    console.log('❌ JavaScript Error:', error.message);
    console.log('❌ This is the error your app would see');
    
    // Check if it's the old error message
    if (error.message.includes('ScreenCaptureKit failed')) {
      console.log('');
      console.log('🚨 PROBLEM: Still seeing old ScreenCaptureKit error');
      console.log('   This means the new logic is not being used');
      console.log('   Possible causes:');
      console.log('   1. Module not rebuilt properly');
      console.log('   2. Cache issue');
      console.log('   3. Wrong macOS version detection');
    }
  }
  
  console.log('');
  console.log('📊 If you see this test:');
  console.log('✅ Module loads correctly');
  console.log('✅ JavaScript layer works'); 
  console.log('❓ Check Console.app for native logs');
  console.log('');
  console.log('🔍 To see native logs:');
  console.log('   1. Open Console.app');
  console.log('   2. Filter by "node" process');
  console.log('   3. Look for "🎯 Smart Recording Engine Selection"');
  console.log('   4. Look for "macOS Version:" detection');
}

testConsoleOutput();
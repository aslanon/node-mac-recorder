# macOS 13/14 Recording Troubleshooting Guide

## Expected Behavior by macOS Version

The system automatically detects macOS version and uses the most compatible recording method:

- **macOS 15+**: Uses ScreenCaptureKit (30fps, full features)
- **macOS 14**: Uses AVFoundation fallback (15fps, stable)
- **macOS 13**: Uses AVFoundation fallback (15fps, limited features)
- **macOS < 13**: Not supported

## Debug Steps for macOS 13/14 Issues

### 1. Check Console Logs

When running your application, check for these log messages:

**macOS 14:**
```
🖥️ macOS Version: 14.x.x
🎯 macOS 14 detected - using AVFoundation for better compatibility
🎥 Using AVFoundation for macOS 14 compatibility
🎥 RECORDING METHOD: AVFoundation (Fallback)
```

**macOS 13:**
```
🖥️ macOS Version: 13.x.x
🎯 macOS 13 detected - using AVFoundation (limited features)
🎥 Using AVFoundation for macOS 13 compatibility (limited features)
🎥 RECORDING METHOD: AVFoundation (Fallback)
```

### 2. Test AVFoundation Directly

You can force AVFoundation mode for testing:

```javascript
// Set environment variable before running
process.env.FORCE_AVFOUNDATION = "1";

const MacRecorder = require('node-mac-recorder');
const recorder = new MacRecorder();

async function test() {
  const success = await recorder.startRecording('./test.mov', {
    captureCursor: true,
    includeMicrophone: false,
    includeSystemAudio: true
  });
  
  if (success) {
    console.log('✅ AVFoundation recording started');
    setTimeout(async () => {
      await recorder.stopRecording();
      console.log('✅ Recording completed');
    }, 3000);
  } else {
    console.log('❌ Recording failed');
  }
}

test();
```

### 3. Common Issues and Solutions

**Issue**: Recording starts but no video file created
- **Cause**: Permission issues
- **Solution**: Check Screen Recording permission in System Preferences

**Issue**: Audio not recorded
- **Cause**: Microphone permission missing
- **Solution**: Check Microphone permission in System Preferences

**Issue**: Recording fails silently
- **Cause**: Invalid display ID or output path
- **Solution**: Use default display (don't specify displayId) and ensure output directory exists

### 4. Permission Requirements

macOS 14 requires these permissions:
- ✅ Screen Recording (System Preferences > Privacy & Security)
- ✅ Microphone (if includeMicrophone: true)
- ✅ Accessibility (for cursor tracking)

### 5. Technical Details

**AVFoundation Implementation (macOS 14):**
- Video: H.264 encoding at 15fps
- Audio: AAC encoding at 44.1kHz
- Screen capture: CGDisplayCreateImage
- Memory management: Automatic cleanup

**Differences from ScreenCaptureKit:**
- Lower frame rate (15fps vs 30fps) for stability
- No automatic window exclusion
- Simpler audio routing

**macOS 13 Specific Limitations:**
- Audio features may have reduced compatibility
- Some advanced recording options may not work
- Recommended to test thoroughly on target systems

## Contact

If recording still fails on macOS 14 after following this guide, please provide:
1. macOS version (`sw_vers`)
2. Console logs from the application
3. Permission status screenshots
4. Minimal reproduction code
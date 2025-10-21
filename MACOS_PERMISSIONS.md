# macOS Permission Checklist

This project relies on system-level frameworks (ScreenCaptureKit, AVFoundation) that require explicit permissions. When integrating the native module into an app (Electron, standalone macOS app, etc.), make sure the host application's `Info.plist` defines the usage descriptions below.

## Required `Info.plist` keys

```xml
<key>NSCameraUsageDescription</key>
<string>Allow camera access for screen recording companion video.</string>

<key>NSMicrophoneUsageDescription</key>
<string>Allow microphone access for audio capture.</string>

<key>NSCameraUseContinuityCameraDeviceType</key>
<true/>

<key>com.apple.security.device.audio-input</key>
<true/>

<key>com.apple.security.device.camera</key>
<true/>
```

> `NSCameraUseContinuityCameraDeviceType` removes the runtime warning when Continuity Camera devices are detected. macOS 14+ expects this key whenever Continuity Camera APIs are used.
> The `com.apple.security.*` entitlements are only required for sandboxed / hardened runtime builds. Omit them if your distribution does not use the macOS sandbox.

During local development you can temporarily bypass the Continuity Camera check by running with `ALLOW_CONTINUITY_CAMERA=1`, but Apple still recommends setting the Info.plist key for shipping applications.

### Screen recording

Screen recording permissions are granted by the user via the OS **Screen Recording** privacy panel. There is no `Info.plist` key to request it, but your app should guide the user to approve it.

## Electron apps

Add the keys above to `Info.plist` (located under `electron-builder` config or the generated app bundle). For example, with `electron-builder`, use the `mac.plist` option:

```jsonc
// package.json
{
  "build": {
    "mac": {
      "extendInfo": {
        "NSCameraUsageDescription": "Allow camera access...",
        "NSMicrophoneUsageDescription": "Allow microphone access...",
        "NSCameraUseContinuityCameraDeviceType": true,
        "com.apple.security.device.audio-input": true,
        "com.apple.security.device.camera": true
      }
    }
  }
}
```

## Native permission prompts

The module proactively requests camera and microphone permissions when recording starts (`AVCaptureDevice requestAccess`). If access is denied, the native start call fails with an explanatory error.

Make sure to run your app once, respond to the permission prompts, and instruct testers to do the same.

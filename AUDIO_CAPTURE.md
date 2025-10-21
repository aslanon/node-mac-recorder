# Audio Capture Guide

This guide explains how to record microphone and/or system audio alongside the silent screen recording output.

## 1. Enumerate audio devices

```js
const recorder = new MacRecorder();
const devices = await recorder.getAudioDevices();
/*
[
  {
    id: "BuiltInMicDeviceID",
    name: "MacBook Pro Microphone",
    manufacturer: "Apple Inc.",
    isDefault: true,
    transportType: 0
  },
  ...
]
*/
```

Pick the `id` you want to capture. For system audio you typically need to select a loopback device (e.g. BlackHole, Loopback, VB-Cable).

## 2. Configure the capture

```js
recorder.setAudioSettings({
  microphone: true,
  systemAudio: true,
});

recorder.setSystemAudioDevice("LoopbackDeviceID"); // optional
recorder.setAudioDevice("BuiltInMicDeviceID");     // microphone device – use setOptions or setAudioSettings
```

If you only want system audio, disable the microphone flag. When both flags are true on macOS 15+, ScreenCaptureKit mixes the feeds automatically. On older macOS versions (where the module falls back to AVFoundation) you should provide a loopback device that already mixes both sources.

## 3. Start recording

```js
await recorder.startRecording("./output.mov", {
  includeMicrophone: true,
  includeSystemAudio: true,
  systemAudioDeviceId: "LoopbackDeviceID",
  audioDeviceId: "BuiltInMicDeviceID",
});
```

The recorder automatically creates `temp_audio_<timestamp>.webm` next to the main video file. The timestamp matches the cursor and camera companion files so you can synchronise them later.

### File format fallback

- macOS 15+ → Opus audio inside a WebM container.  
- macOS 13–14 → Apple does not expose a WebM audio writer, so the clip is stored in a QuickTime container while keeping the `.webm` extension (transcode if you require a strict WebM file).

## 4. Stop recording

```js
const result = await recorder.stopRecording();
console.log(result.audioOutputPath); // temp_audio_<timestamp>.webm
```

The `audioCaptureStarted` / `audioCaptureStopped` events fire with the resolved path and shared session timestamp, letting you update your Electron UI instantly.

## 5. Status helpers

```js
const status = recorder.getAudioCaptureStatus();
// {
//   isCapturing: true,
//   outputFile: "/tmp/temp_audio_1720000000000.webm",
//   deviceIds: { microphone: "...", system: "..." },
//   includeMicrophone: true,
//   includeSystemAudio: true,
//   sessionTimestamp: 1720000000000
// }
```

## 6. Limitations

- On macOS versions that fall back to AVFoundation (13/14), system audio capture requires a virtual loopback device. The module records whichever device you select as `systemAudioDeviceId`.
- ScreenCaptureKit automatically mixes microphone + system audio when both flags are enabled. If you need isolated stems, run separate recordings with different device selections.

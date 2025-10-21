# Camera Capture Guide

This guide shows how to capture an external or built‑in camera feed alongside the standard screen recording workflow.

## 1. Discover available cameras

Use the new helper to list all video-capable devices. Each entry includes the best resolution Apple reports for that device.

```js
const cameras = await recorder.getCameraDevices();
/* Example entry:
{
  id: "BuiltInCameraID",
  name: "FaceTime HD Camera",
  position: "front",
  maxResolution: { width: 1920, height: 1080, maxFrameRate: 60 }
}
*/
```

Pick an `id` and store it for future sessions (it is stable across restarts).

## 2. Enable camera capture

```js
recorder.setCameraDevice(selectedCameraId); // optional – default camera is used otherwise
recorder.setCameraEnabled(true);
```

Camera recording is completely independent from system audio and microphone settings; only video frames are captured.

The companion file is always silent—no audio tracks are written.

## 3. Start recording

When you call `startRecording`, the module automatically creates a file named `temp_camera_<timestamp>.webm` next to the main screen recording output:

```js
await recorder.startRecording("/tmp/output.mov", {
  includeSystemAudio: true,
  captureCamera: true,          // shorthand for enabling camera inside options
  cameraDeviceId: selectedCameraId,
});
```

Internally this mirrors the cursor workflow: the camera file is placed in the same directory as `/tmp/output.mov`, sharing the same timestamp that the cursor JSON uses. No extra cleanup is required.

### File format fallback

- macOS 15+ → VP9 video inside a real WebM container.  
- macOS 13–14 → Apple does not expose a WebM writer, so the clip is stored in a QuickTime container even though the filename remains `.webm`. Transcode to another format if you need a strict WebM file.

The `cameraCaptureStarted` and `cameraCaptureStopped` events include the resolved path and the shared `sessionTimestamp` so the UI can react immediately.

## 4. Stop recording

`stopRecording()` stops the screen capture and the camera recorder together:

```js
const result = await recorder.stopRecording();
console.log(result.outputPath);        // screen video
console.log(result.cameraOutputPath);  // companion camera clip (or null if disabled)
```

## 5. Integrating with Electron live previews

Use the same `cameraDeviceId` with `navigator.mediaDevices.getUserMedia({ video: { deviceId } })` to show a live preview while the native module records in the background. The native pipeline does not consume the camera stream, so sharing the device with Electron is supported as long as the hardware allows concurrent access.

## 6. API quick reference

- `getCameraDevices()`  
- `setCameraEnabled(enabled)` / `isCameraEnabled()`  
- `setCameraDevice(deviceId)`  
- `getCameraCaptureStatus()` – returns `{ isCapturing, outputFile, deviceId, sessionTimestamp }`  
- Events: `cameraCaptureStarted`, `cameraCaptureStopped`

With these helpers you can drive the camera UI inside an Electron app while preserving the high-resolution screen capture handled by ScreenCaptureKit or AVFoundation.

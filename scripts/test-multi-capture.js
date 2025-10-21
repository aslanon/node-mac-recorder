const MacRecorder = require("../index");
const path = require("path");
const fs = require("fs");

async function main() {
	const recorder = new MacRecorder();

	// Optional: list audio and camera devices for reference
	const audioDevices = await recorder.getAudioDevices();
	const cameraDevices = await recorder.getCameraDevices();

	console.log("Audio devices:");
	audioDevices.forEach((device, idx) => {
		console.log(`${idx + 1}. ${device.name} (id: ${device.id})`);
	});

	console.log("\nCamera devices:");
	cameraDevices.forEach((device, idx) => {
		console.log(`${idx + 1}. ${device.name} (id: ${device.id})`);
	});

	// Pick the first available devices (customize as needed)
const preferredCamera = cameraDevices.find(device => !device.requiresContinuityCameraPermission);
const selectedCameraId = preferredCamera ? preferredCamera.id : null;
if (!selectedCameraId && cameraDevices.length > 0) {
	console.warn("Skipping camera capture: only Continuity Camera devices detected. Add NSCameraUseContinuityCameraDeviceType to Info.plist or set ALLOW_CONTINUITY_CAMERA=1.");
}

if (selectedCameraId) {
	console.log(`\nSelected camera: ${preferredCamera.name} (id: ${selectedCameraId})`);
} else {
	console.log("\nSelected camera: none (camera capture disabled)");
}
	const selectedMicId = audioDevices[0]?.id || null;

if (selectedCameraId) {
	recorder.setCameraDevice(selectedCameraId);
	recorder.setCameraEnabled(true);
}

	recorder.setAudioSettings({
		microphone: !!selectedMicId,
		systemAudio: true,
	});

	if (selectedMicId) {
		recorder.setAudioDevice(selectedMicId);
	}

	const outputDir = path.resolve(__dirname, "../tmp-tests");
	if (!fs.existsSync(outputDir)) {
		fs.mkdirSync(outputDir, { recursive: true });
	}

	const outputPath = path.join(outputDir, `test_capture_${Date.now()}.mov`);
	console.log("\nStarting recording to:", outputPath);

	recorder.on("recordingStarted", (payload) => {
		console.log("recordingStarted", payload);
	});
	recorder.on("cameraCaptureStarted", (payload) => {
		console.log("cameraCaptureStarted", payload);
	});
	recorder.on("audioCaptureStarted", (payload) => {
		console.log("audioCaptureStarted", payload);
	});
	recorder.on("cameraCaptureStopped", (payload) => {
		console.log("cameraCaptureStopped", payload);
	});
	recorder.on("audioCaptureStopped", (payload) => {
		console.log("audioCaptureStopped", payload);
	});
	recorder.on("stopped", (payload) => {
		console.log("stopped", payload);
	});
	recorder.on("completed", (filePath) => {
		console.log("completed", filePath);
	});

	await recorder.startRecording(outputPath, {
		includeMicrophone: !!selectedMicId,
		includeSystemAudio: true,
		captureCursor: true,
		captureCamera: !!selectedCameraId,
	});

	console.log("Recording for 10 seconds...");
	await new Promise((resolve) => setTimeout(resolve, 10_000));

	const result = await recorder.stopRecording();
	console.log("\nRecording finished:", result);

	console.log("\nArtifacts:");
	console.log("Video:", result.outputPath);
	console.log("Camera:", result.cameraOutputPath);
	console.log("Audio:", result.audioOutputPath);
	console.log("Session timestamp:", result.sessionTimestamp);
}

main().catch((error) => {
	console.error("Test capture failed:", error);
	process.exit(1);
});

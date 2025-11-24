const fs = require("fs");
const path = require("path");
const MacRecorder = require("../index");

const OUTPUT_DIR = path.join(__dirname, "..", "output", "repeat-camera");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const fsp = fs.promises;

async function ensureDir(dir) {
	await fsp.mkdir(dir, { recursive: true });
}

async function renameWithPrefix(filePath, label) {
	if (!filePath || !fs.existsSync(filePath)) {
		return null;
	}

	const base = path.basename(filePath);
	const prefixedBase = base.startsWith(`${label}_`) ? base : `${label}_${base}`;
	const target = path.join(OUTPUT_DIR, prefixedBase);

	if (target === filePath) {
		return filePath; // Already prefixed
	}

	await fsp.rename(filePath, target);
	return target;
}

async function runRecording(recorder, label) {
	console.log(`\n▶️ Recording ${label}...`);

	const screenTarget = path.join(OUTPUT_DIR, `${label}_screen.mov`);
	const options = {
		includeMicrophone: true,
		includeSystemAudio: true,
		captureCursor: true,
		captureCamera: true,
		frameRate: 60,
		quality: "high",
		preferScreenCaptureKit: true,
	};

	await recorder.startRecording(screenTarget, options);

	// Capture cursor path before stopRecording clears it
	const cursorPath = recorder.cursorCaptureFile;

	// Record 5 seconds
	await sleep(5000);

	const stopResult = await recorder.stopRecording();

	const renamed = {
		screen: await renameWithPrefix(stopResult.outputPath, label),
		camera: await renameWithPrefix(stopResult.cameraOutputPath, label),
		audio: await renameWithPrefix(stopResult.audioOutputPath, label),
		cursor: await renameWithPrefix(cursorPath, label),
	};

	console.log(`✅ Recording ${label} finished`);
	console.log(`   Screen : ${renamed.screen || "missing"}`);
	console.log(`   Camera : ${renamed.camera || "missing"}`);
	console.log(`   Audio  : ${renamed.audio || "missing"}`);
	console.log(`   Cursor : ${renamed.cursor || "missing"}`);
}

async function main() {
	await ensureDir(OUTPUT_DIR);

	const recorder = new MacRecorder();

	try {
		await runRecording(recorder, "1");
		await sleep(1000); // short pause between runs
		await runRecording(recorder, "2");

		console.log(`\nAll files saved to: ${OUTPUT_DIR}`);
	} catch (error) {
		console.error("❌ Test failed:", error);
		process.exitCode = 1;
	}
}

main();

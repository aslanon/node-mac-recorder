/*
 Simple test runner: starts a 2s recording with ScreenCaptureKit and exclusions.
 */
const fs = require("fs");
const path = require("path");
const MacRecorder = require("..");

async function sleep(ms) {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
	const recorder = new MacRecorder();
	const outDir = path.resolve(process.cwd(), "test-output");
	const outPath = path.join(outDir, `sc-exclude-${Date.now()}.mov`);
	await fs.promises.mkdir(outDir, { recursive: true });

	console.log("[TEST] Starting 2s recording with SC exclusions...");
	// Try to ensure overlays are not active in this process

	const perms = await recorder.checkPermissions();
	if (!perms?.screenRecording) {
		console.error(
			"[TEST] Screen Recording permission is not granted. Enable it in System Settings → Privacy & Security → Screen Recording for Terminal/Node, then re-run."
		);
		process.exit(1);
	}

	try {
		await recorder.startRecording(outPath, {
			useScreenCaptureKit: true,
			captureCursor: false,
			excludedAppBundleIds: ["com.apple.Safari"],
		});
	} catch (e) {
		console.error("[TEST] Failed to start recording:", e.message);
		process.exit(1);
	}

	await sleep(2000);

	try {
		const result = await recorder.stopRecording();
		console.log("[TEST] Stopped. Result:", result);
	} catch (e) {
		console.error("[TEST] Failed to stop recording:", e.message);
		process.exit(1);
	}

	// SCRecordingOutput write may be async; wait up to 10s for the file
	const deadline = Date.now() + 10000;
	let stats = null;
	while (Date.now() < deadline) {
		if (fs.existsSync(outPath)) {
			stats = fs.statSync(outPath);
			if (stats.size > 0) break;
		}
		await sleep(200);
	}

	if (stats && fs.existsSync(outPath)) {
		console.log(`[TEST] Output saved: ${outPath} (${stats.size} bytes)`);
	} else {
		console.error("[TEST] Output file not found or empty:", outPath);
		process.exit(1);
	}
}

main().catch((e) => {
	console.error("[TEST] Unhandled error:", e);
	process.exit(1);
});

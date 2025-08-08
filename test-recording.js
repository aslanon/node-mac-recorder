const MacRecorder = require("./index");
const path = require("path");
const fs = require("fs");

async function testRecording() {
	console.log("🎬 Testing ScreenCaptureKit Recording...\n");

	const recorder = new MacRecorder();
	const outputDir = path.join(__dirname, "test-output");

	// Create test output directory
	if (!fs.existsSync(outputDir)) {
		fs.mkdirSync(outputDir);
		console.log("📁 Created test-output directory");
	}

	const outputFile = path.resolve(outputDir, "sck-test-recording.mov");
	console.log(`📹 Output file: ${outputFile}`);

	// Test recording options
	const recordingOptions = {
		captureCursor: true,
		excludeCurrentApp: true,
		includeMicrophone: true,
		includeSystemAudio: true, // Disable to avoid permission issues for now
		displayId: null, // Will use main display
	};

	console.log(
		"📝 Recording options:",
		JSON.stringify(recordingOptions, null, 2)
	);
	console.log("\n🚀 Starting recording test...");

	try {
		// Test current cursor position before recording
		const cursor = recorder.getCurrentCursorPosition();
		console.log(
			`🖱️  Current cursor: x=${cursor.x}, y=${cursor.y}, type=${cursor.cursorType}`
		);

		// Determine a window to exclude (prefer a window with name containing "Cursor")
		try {
			const windows = await recorder.getWindows();
			if (Array.isArray(windows) && windows.length) {
				const pick =
					windows.find(
						(w) =>
							(typeof w.appName === "string" && /cursor/i.test(w.appName)) ||
							(typeof w.name === "string" && /cursor/i.test(w.name)) ||
							(typeof w.title === "string" && /cursor/i.test(w.title))
					) || windows[0];
				const wid = pick?.id ?? pick?.windowId ?? pick?.windowID ?? null;
				if (wid != null) {
					recordingOptions.excludeWindowIds = [Number(wid)];
				}
			}
		} catch (_) {}

		// Start recording
		console.log("▶️  Attempting to start recording...");

		// Start recording without callback first
		console.log("🔍 Attempting startRecording without callback...");

		let startResult;
		try {
			startResult = await recorder.startRecording(outputFile, recordingOptions);
			console.log(`📊 startRecording resolved: ${startResult}`);
		} catch (error) {
			console.error("❌ startRecording threw error:", error.message);
			console.error("Stack:", error.stack);
			return;
		}

		if (startResult) {
			console.log("✅ Recording started successfully");
			console.log("⏱️  Recording for 3 seconds...");

			// Record for ~6 seconds
			setTimeout(async () => {
				console.log("⏹️  Stopping recording...");

				let stopResult;
				try {
					stopResult = await recorder.stopRecording();
					console.log(
						`📊 stopRecording resolved: ${JSON.stringify(stopResult)}`
					);

					if (stopResult && stopResult.code === 0) {
						console.log("✅ Stop recording command sent");
					} else {
						console.log("❌ Failed to send stop recording command");
					}
				} catch (error) {
					console.error("❌ stopRecording threw error:", error.message);
					console.error("Stack:", error.stack);
				}

				// Final check after a longer delay
				setTimeout(() => {
					console.log("\n📊 Final Results:");

					try {
						if (fs.existsSync(outputFile)) {
							const stats = fs.statSync(outputFile);
							console.log(`✅ Recording file exists: ${stats.size} bytes`);
							console.log(`📁 Location: ${outputFile}`);
							console.log("🎯 ScreenCaptureKit recording test PASSED");
						} else {
							console.log("❌ Recording file does not exist");
							console.log(
								"🔍 This might be due to permissions or ScreenCaptureKit configuration"
							);
						}
					} catch (error) {
						console.error("❌ Final check error:", error.message);
					}

					console.log("\n✅ Recording test completed");
				}, 4000);
			}, 6000);
		} else {
			console.log("❌ Failed to start recording");
			console.log("🔍 Possible causes:");
			console.log("   • Screen recording permissions not granted");
			console.log("   • ScreenCaptureKit not available (requires macOS 12.3+)");
			console.log("   • Display/window selection issues");
		}
	} catch (error) {
		console.error("❌ Recording test failed with exception:", error);
	}
}

// Handle process exit
process.on("SIGINT", () => {
	console.log("\n⚠️  Recording test interrupted");
	process.exit(0);
});

testRecording();

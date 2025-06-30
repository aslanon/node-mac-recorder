const MacRecorder = require("./");
const fs = require("fs");
const path = require("path");

async function saveBase64Image(base64String, filePath) {
	// Remove the data:image/png;base64, prefix if it exists
	const base64Data = base64String.replace(/^data:image\/png;base64,/, "");

	// Create directory if it doesn't exist
	const dir = path.dirname(filePath);
	if (!fs.existsSync(dir)) {
		fs.mkdirSync(dir, { recursive: true });
	}

	// Write the file
	fs.writeFileSync(filePath, base64Data, "base64");
	console.log(`✅ Saved image to: ${filePath}`);
}

async function captureTest() {
	const recorder = new MacRecorder();

	// Create output directory
	const outputDir = path.join(__dirname, "thumbnails");
	if (!fs.existsSync(outputDir)) {
		fs.mkdirSync(outputDir, { recursive: true });
	}

	console.log("📸 Testing Display Capture");

	// Get displays
	const displays = await recorder.getDisplays();
	console.log(`Found ${displays.length} displays`);

	// Capture each display
	for (const display of displays) {
		console.log(
			`\nCapturing display ${display.id} (${display.width}x${display.height})`
		);
		try {
			const thumbnail = await recorder.getDisplayThumbnail(display.id, {
				maxWidth: 800,
				maxHeight: 600,
			});

			const fileName = `display_${display.id}.png`;
			const filePath = path.join(outputDir, fileName);
			await saveBase64Image(thumbnail, filePath);
		} catch (error) {
			console.error(`Failed to capture display ${display.id}:`, error);
		}
	}

	console.log("\n📸 Testing Window Capture");

	// Get windows
	const windows = await recorder.getWindows();
	console.log(`Found ${windows.length} windows`);

	// Capture each window
	for (const window of windows) {
		console.log(
			`\nCapturing window "${window.appName}" (${window.width}x${window.height})`
		);
		try {
			const thumbnail = await recorder.getWindowThumbnail(window.id, {
				maxWidth: 800,
				maxHeight: 600,
			});

			const fileName = `window_${window.id}_${window.appName.replace(
				/[^a-z0-9]/gi,
				"_"
			)}.png`;
			const filePath = path.join(outputDir, fileName);
			await saveBase64Image(thumbnail, filePath);
		} catch (error) {
			console.error(`Failed to capture window "${window.appName}":`, error);
		}
	}

	console.log(
		"\n✅ Test completed. Check the thumbnails directory for results."
	);
}

captureTest().catch(console.error);

const MacRecorder = require("./index.js");
const fs = require("fs");
const path = require("path");

async function runTests() {
	const recorder = new MacRecorder();

	console.log("🎯 macOS Screen Recorder Test Suite\n");

	// 1. Permission Check
	console.log("1️⃣ Testing Permissions...");
	try {
		const hasPermissions = await recorder.checkPermissions();
		console.log(`✅ Permissions: ${hasPermissions ? "Granted" : "Denied"}\n`);
	} catch (error) {
		console.error("❌ Permission check failed:", error.message);
	}

	// 2. Audio Devices Test
	console.log("2️⃣ Testing Audio Devices...");
	try {
		const audioDevices = await recorder.getAudioDevices();
		console.log(`✅ Found ${audioDevices.length} audio devices:`);
		audioDevices.forEach((device, index) => {
			console.log(
				`   ${index}: ${device.name} ${device.isDefault ? "(Default)" : ""}`
			);
		});
		console.log();
	} catch (error) {
		console.error("❌ Audio devices test failed:", error.message);
	}

	// 3. Displays Test
	console.log("3️⃣ Testing Displays...");
	try {
		const displays = await recorder.getDisplays();
		console.log(`✅ Found ${displays.length} displays:`);
		displays.forEach((display, index) => {
			console.log(
				`   ${index}: ${display.resolution} at (${display.x}, ${display.y}) ${
					display.isPrimary ? "(Primary)" : ""
				}`
			);
		});
		console.log();
	} catch (error) {
		console.error("❌ Displays test failed:", error.message);
	}

	// 4. Windows Test
	console.log("4️⃣ Testing Windows...");
	try {
		const windows = await recorder.getWindows();
		console.log(`✅ Found ${windows.length} windows:`);
		windows.slice(0, 5).forEach((window, index) => {
			console.log(
				`   ${index}: [${window.appName}] ${window.name} (${window.width}x${window.height})`
			);
		});
		if (windows.length > 5) {
			console.log(`   ... and ${windows.length - 5} more windows`);
		}
		console.log();
	} catch (error) {
		console.error("❌ Windows test failed:", error.message);
	}

	// 5. Display Thumbnail Test
	console.log("5️⃣ Testing Display Thumbnails...");
	try {
		const displays = await recorder.getDisplays();
		if (displays.length > 0) {
			const display = displays[0];
			const thumbnail = await recorder.getDisplayThumbnail(display.id, {
				maxWidth: 200,
				maxHeight: 150,
			});
			console.log(
				`✅ Display thumbnail captured: ${thumbnail.substring(0, 50)}... (${
					thumbnail.length
				} chars)`
			);
		} else {
			console.log("⚠️ No displays found for thumbnail test");
		}
		console.log();
	} catch (error) {
		console.error("❌ Display thumbnail test failed:", error.message);
	}

	// 6. Window Thumbnail Test
	console.log("6️⃣ Testing Window Thumbnails...");
	try {
		const windows = await recorder.getWindows();
		if (windows.length > 0) {
			const window = windows[0];
			const thumbnail = await recorder.getWindowThumbnail(window.id, {
				maxWidth: 200,
				maxHeight: 150,
			});
			console.log(
				`✅ Window thumbnail captured for [${
					window.appName
				}]: ${thumbnail.substring(0, 50)}... (${thumbnail.length} chars)`
			);
		} else {
			console.log("⚠️ No windows found for thumbnail test");
		}
		console.log();
	} catch (error) {
		console.error("❌ Window thumbnail test failed:", error.message);
	}

	// 7. Module Info Test
	console.log("7️⃣ Testing Module Info...");
	try {
		const info = recorder.getModuleInfo();
		console.log("✅ Module Info:");
		console.log(`   Version: ${info.version}`);
		console.log(`   Platform: ${info.platform}`);
		console.log(`   Architecture: ${info.arch}`);
		console.log(`   Node Version: ${info.nodeVersion}`);
		console.log();
	} catch (error) {
		console.error("❌ Module info test failed:", error.message);
	}

	// 8. Recording Status Test
	console.log("8️⃣ Testing Recording Status...");
	try {
		const status = recorder.getStatus();
		console.log("✅ Recording Status:", status);
		console.log();
	} catch (error) {
		console.error("❌ Recording status test failed:", error.message);
	}

	console.log("🎉 Test Suite Completed!");
	console.log("\n💡 To test recording functionality:");
	console.log("   const recorder = new MacRecorder();");
	console.log('   await recorder.startRecording("./test-recording.mov");');
	console.log("   // Wait some time...");
	console.log("   await recorder.stopRecording();");
}

// Run tests with error handling
runTests().catch((error) => {
	console.error("💥 Test suite failed:", error.message);
	console.error(error.stack);
	process.exit(1);
});

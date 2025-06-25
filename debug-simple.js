const MacRecorder = require("./index.js");

async function simpleTest() {
	const recorder = new MacRecorder();

	try {
		const windows = await recorder.getWindows();
		const displays = await recorder.getDisplays();

		console.log("📺 Displays:");
		displays.forEach((d, i) => {
			console.log(`  ${i}: ${d.resolution} at (${d.x}, ${d.y})`);
		});

		const targetWindow = windows.find(
			(w) => w.width > 300 && w.height > 300 && w.appName !== "Dock"
		);

		if (!targetWindow) {
			console.log("❌ Test penceresi bulunamadı");
			return;
		}

		console.log(`\n🎯 Test penceresi: ${targetWindow.appName}`);
		console.log(`Koordinatlar: (${targetWindow.x}, ${targetWindow.y})`);
		console.log(`Boyut: ${targetWindow.width}x${targetWindow.height}`);

		console.log("\n🔧 WindowId ile startRecording...");
		await recorder.startRecording("./test-simple.mov", {
			windowId: targetWindow.id,
			includeSystemAudio: false,
			includeMicrophone: false,
		});

		const status = recorder.getStatus();
		console.log("\n📊 Recording Status:");
		console.log("captureArea:", status.options.captureArea);
		console.log("displayId:", status.options.displayId);
		console.log("windowId:", status.options.windowId);

		await new Promise((resolve) => setTimeout(resolve, 2000));
		await recorder.stopRecording();

		console.log("\n✅ Test tamamlandı!");
	} catch (error) {
		console.error("❌ Hata:", error.message);
	}
}

simpleTest();

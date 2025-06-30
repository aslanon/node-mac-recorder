const MacRecorder = require("./");

async function testListing() {
	const recorder = new MacRecorder();

	console.log("📺 Testing Displays with Thumbnails");
	const displays = await recorder.getDisplaysWithThumbnails({
		maxWidth: 200,
		maxHeight: 150,
	});
	console.log(`Found ${displays.length} displays:`);
	for (const display of displays) {
		console.log(`\nDisplay ID: ${display.id}`);
		console.log(`Resolution: ${display.width}x${display.height}`);
		console.log(`Position: (${display.x}, ${display.y})`);
		console.log(`Primary: ${display.isPrimary}`);
		console.log(
			`Thumbnail included: ${display.thumbnail.substring(0, 50)}... (${
				display.thumbnail.length
			} chars)`
		);
	}

	console.log("\n🪟 Testing Windows with Thumbnails");
	const windows = await recorder.getWindowsWithThumbnails({
		maxWidth: 200,
		maxHeight: 150,
	});
	console.log(`Found ${windows.length} windows:`);
	for (const window of windows.slice(0, 3)) {
		// Just show first 3 for brevity
		console.log(`\nWindow: ${window.appName}`);
		console.log(`ID: ${window.id}`);
		console.log(`Size: ${window.width}x${window.height}`);
		console.log(
			`Thumbnail included: ${window.thumbnail.substring(0, 50)}... (${
				window.thumbnail.length
			} chars)`
		);
	}
	if (windows.length > 3) {
		console.log(`\n... and ${windows.length - 3} more windows`);
	}
}

testListing().catch(console.error);

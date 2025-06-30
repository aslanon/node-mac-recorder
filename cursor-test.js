const MacRecorder = require("./index.js");

const recorder = new MacRecorder();

console.log("Starting cursor tracking test...");
console.log(
	"Move your cursor around different applications to test cursor type detection"
);
console.log("The test will run for 10 seconds");

try {
	recorder.startCursorCapture("./cursor-data.json");

	setTimeout(() => {
		recorder.stopCursorCapture();
		console.log("Test completed. Check cursor-data.json for results");
		process.exit(0);
	}, 10000);
} catch (error) {
	console.error("Error during cursor tracking:", error);
	process.exit(1);
}

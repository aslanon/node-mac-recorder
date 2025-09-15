#!/usr/bin/env node

const MacRecorder = require('./index.js');
const path = require('path');
const fs = require('fs');

// Test output directory
const outputDir = './test-output';
if (!fs.existsSync(outputDir)) {
	fs.mkdirSync(outputDir, { recursive: true });
}

const recorder = new MacRecorder();

async function testWindowRecording() {
	console.log('🎬 Testing window recording with automatic cursor tracking...');

	try {
		// Test permissions first
		const permissions = await recorder.checkPermissions();
		console.log('📋 Permissions:', permissions);

		if (!permissions.screenRecording) {
			console.log('❌ Screen recording permission required');
			return;
		}

		// Get windows
		const windows = await recorder.getWindows();
		console.log(`🪟 Found ${windows.length} windows`);

		// Find a suitable window to record (preferably a visible one)
		const visibleWindows = windows.filter(w => w.width > 200 && w.height > 100);
		if (visibleWindows.length === 0) {
			console.log('❌ No suitable windows found for recording');
			return;
		}

		const targetWindow = visibleWindows[0];
		console.log(`🎯 Target window: ${targetWindow.appName} (${targetWindow.width}x${targetWindow.height})`);
		console.log(`📍 Window position: (${targetWindow.x}, ${targetWindow.y})`);

		// Setup recording options
		const timestamp = Date.now();
		const videoPath = path.join(outputDir, `window-test-${timestamp}.mov`);

		console.log(`🎥 Starting window recording to: ${videoPath}`);
		console.log('🖱️  Cursor tracking will use window-relative coordinates');
		console.log('💡 Move your mouse over the target window to generate cursor data');

		// Start recording the specific window (cursor tracking will start automatically)
		await recorder.startRecording(videoPath, {
			includeMicrophone: false,
			includeSystemAudio: false,
			captureCursor: true,
			windowId: targetWindow.id
		});

		console.log('✅ Window recording started successfully!');
		console.log('🖱️  Cursor tracking started automatically with window-relative coordinates');
		console.log('⏰ Recording for 8 seconds...');
		console.log(`🔍 Please move your mouse over the "${targetWindow.appName}" window`);

		// Wait for 8 seconds
		await new Promise(resolve => setTimeout(resolve, 8000));

		console.log('🛑 Stopping recording...');

		// Stop recording (cursor tracking will stop automatically)
		const result = await recorder.stopRecording();

		console.log('✅ Recording stopped:', result);
		console.log('📁 Checking output files...');

		// Wait a moment for files to be written
		await new Promise(resolve => setTimeout(resolve, 1000));

		// Check for video file
		if (fs.existsSync(videoPath)) {
			const videoStats = fs.statSync(videoPath);
			console.log(`📹 Video file created: ${path.basename(videoPath)} (${videoStats.size} bytes)`);
		} else {
			console.log('❌ Video file not found');
		}

		// Check for cursor file
		const files = fs.readdirSync(outputDir);
		const cursorFile = files.find(f => f.startsWith('temp_cursor_') && f.endsWith('.json'));

		if (cursorFile) {
			const cursorPath = path.join(outputDir, cursorFile);
			const cursorStats = fs.statSync(cursorPath);
			console.log(`🖱️  Cursor file created: ${cursorFile} (${cursorStats.size} bytes)`);

			// Read and validate cursor data
			try {
				const cursorData = JSON.parse(fs.readFileSync(cursorPath, 'utf8'));
				console.log(`📊 Cursor data points: ${cursorData.length}`);

				if (cursorData.length > 0) {
					const first = cursorData[0];
					const last = cursorData[cursorData.length - 1];

					console.log(`📍 First cursor position: (${first.x}, ${first.y}) at ${first.timestamp}ms`);
					console.log(`📍 Last cursor position: (${last.x}, ${last.y}) at ${last.timestamp}ms`);
					console.log(`📐 Coordinate system: ${first.coordinateSystem}`);

					if (first.windowInfo) {
						console.log(`🪟 Window info: ${first.windowInfo.width}x${first.windowInfo.height}`);
						console.log(`🌐 Original window position: (${first.windowInfo.originalWindow?.x}, ${first.windowInfo.originalWindow?.y})`);
					}

					// Analyze cursor positions
					const windowRelativePositions = cursorData.filter(d => d.coordinateSystem === 'window-relative');
					if (windowRelativePositions.length > 0) {
						console.log(`✅ ${windowRelativePositions.length} window-relative cursor positions recorded`);

						// Check if coordinates are within window bounds
						const validPositions = windowRelativePositions.filter(d =>
							d.x >= 0 && d.y >= 0 &&
							d.x <= targetWindow.width && d.y <= targetWindow.height
						);

						console.log(`✅ ${validPositions.length}/${windowRelativePositions.length} positions within window bounds`);
					}
				}
			} catch (parseError) {
				console.log('⚠️  Could not parse cursor data:', parseError.message);
			}
		} else {
			console.log('❌ Cursor file not found');
		}

		console.log('✅ Window recording test completed!');

	} catch (error) {
		console.error('❌ Test failed:', error.message);
		console.error(error.stack);
	}
}

// Run the test
testWindowRecording().then(() => {
	console.log('🏁 Window recording test finished');
	process.exit(0);
}).catch(error => {
	console.error('💥 Fatal error:', error);
	process.exit(1);
});
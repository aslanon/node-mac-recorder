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

async function testIntegratedRecording() {
	console.log('🎬 Testing integrated screen recording with automatic cursor tracking...');

	try {
		// Test permissions first
		const permissions = await recorder.checkPermissions();
		console.log('📋 Permissions:', permissions);

		if (!permissions.screenRecording) {
			console.log('❌ Screen recording permission required');
			return;
		}

		// Get displays and windows
		const displays = await recorder.getDisplays();
		const windows = await recorder.getWindows();

		console.log(`📺 Found ${displays.length} displays and ${windows.length} windows`);

		// Setup recording options
		const timestamp = Date.now();
		const videoPath = path.join(outputDir, `integrated-test-${timestamp}.mov`);

		console.log(`🎥 Starting recording to: ${videoPath}`);
		console.log('📍 Cursor tracking will start automatically and create a JSON file in the same directory');

		// Start recording (cursor tracking will start automatically)
		// Use the primary display (displayId: 1) where cursor is located
		await recorder.startRecording(videoPath, {
			includeMicrophone: false,
			includeSystemAudio: false,
			captureCursor: true,
			displayId: 1  // Use primary display where cursor is located
		});

		console.log('✅ Recording started successfully!');
		console.log('🖱️  Cursor tracking started automatically');
		console.log('⏰ Recording for 5 seconds...');
		console.log('💡 Move your mouse around to generate cursor data');

		// Wait for 5 seconds
		await new Promise(resolve => setTimeout(resolve, 5000));

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
			console.log(`📹 Video file created: ${videoPath} (${videoStats.size} bytes)`);
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
					console.log(`📐 Coordinate system: ${first.coordinateSystem || 'global'}`);
				}
			} catch (parseError) {
				console.log('⚠️  Could not parse cursor data:', parseError.message);
			}
		} else {
			console.log('❌ Cursor file not found');
		}

		console.log('✅ Test completed successfully!');

	} catch (error) {
		console.error('❌ Test failed:', error.message);
		console.error(error.stack);
	}
}

// Run the test
testIntegratedRecording().then(() => {
	console.log('🏁 All tests finished');
	process.exit(0);
}).catch(error => {
	console.error('💥 Fatal error:', error);
	process.exit(1);
});
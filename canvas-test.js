const MacRecorder = require('./index.js');
const path = require('path');
const fs = require('fs');
const http = require('http');

async function startHttpServer(port = 8080) {
	return new Promise((resolve, reject) => {
		const server = http.createServer((req, res) => {
			const rootDir = __dirname;
			let filePath = path.join(rootDir, req.url === '/' ? 'canvas-player.html' : req.url);

			// Security: prevent directory traversal
			if (!filePath.startsWith(rootDir)) {
				res.writeHead(403);
				res.end('Forbidden');
				return;
			}

			// Check if file exists
			if (!fs.existsSync(filePath)) {
				res.writeHead(404);
				res.end('Not found');
				return;
			}

			// Determine content type
			const ext = path.extname(filePath);
			const contentTypes = {
				'.html': 'text/html',
				'.js': 'text/javascript',
				'.json': 'application/json',
				'.mov': 'video/quicktime',
				'.mp4': 'video/mp4',
				'.webm': 'video/webm',
				'.css': 'text/css'
			};

			const contentType = contentTypes[ext] || 'application/octet-stream';

			// Read and serve file
			fs.readFile(filePath, (err, data) => {
				if (err) {
					res.writeHead(500);
					res.end('Error loading file');
					return;
				}

				res.writeHead(200, {
					'Content-Type': contentType,
					'Access-Control-Allow-Origin': '*'
				});
				res.end(data);
			});
		});

		server.listen(port, () => {
			console.log(`\n🌐 HTTP Server started at http://localhost:${port}`);
			resolve(server);
		});

		server.on('error', (err) => {
			if (err.code === 'EADDRINUSE') {
				console.log(`   Port ${port} is busy, trying ${port + 1}...`);
				startHttpServer(port + 1).then(resolve).catch(reject);
			} else {
				reject(err);
			}
		});
	});
}

async function runCanvasTest() {
	console.log('🎬 Canvas Test: Starting 10-second recording with all features...\n');

	const recorder = new MacRecorder();
	const outputDir = path.join(__dirname, 'test-output');

	// Ensure output directory exists
	if (!fs.existsSync(outputDir)) {
		fs.mkdirSync(outputDir, { recursive: true });
	}

	try {
		// Check permissions first
		const permissions = await recorder.checkPermissions();
		console.log('📋 Permissions:', permissions);

		if (!permissions.screenRecording) {
			console.error('❌ Screen recording permission not granted!');
			console.error('   Please enable screen recording in System Preferences > Security & Privacy');
			process.exit(1);
		}

		// Get available devices
		console.log('\n🔍 Detecting devices...');
		const cameras = await recorder.getCameraDevices();
		const audioDevices = await recorder.getAudioDevices();
		const displays = await recorder.getDisplays();

		console.log(`   📹 Cameras found: ${cameras.length}`);
		if (cameras.length > 0) {
			cameras.forEach((cam, i) => {
				console.log(`      ${i + 1}. ${cam.name} (${cam.position})`);
			});
		}

		console.log(`   🎙️  Audio devices found: ${audioDevices.length}`);
		if (audioDevices.length > 0) {
			audioDevices.forEach((dev, i) => {
				console.log(`      ${i + 1}. ${dev.name}${dev.isDefault ? ' (default)' : ''}`);
			});
		}

		console.log(`   🖥️  Displays found: ${displays.length}`);
		displays.forEach((display, i) => {
			console.log(`      ${i + 1}. ${display.name} ${display.resolution}${display.isPrimary ? ' (primary)' : ''}`);
		});

		// Setup recording options
		const outputPath = path.join(outputDir, 'screen.mov');
		const recordingOptions = {
			includeMicrophone: true,
			includeSystemAudio: false, // Typically off to avoid feedback
			captureCursor: true,
			captureCamera: cameras.length > 0,
			cameraDeviceId: cameras.length > 0 ? cameras[0].id : null,
			quality: 'high',
			frameRate: 60
		};

		console.log('\n⚙️  Recording options:', recordingOptions);
		console.log('\n🎥 Starting recording...');

		// Event listeners for tracking
		recorder.on('recordingStarted', (info) => {
			console.log('\n✅ Recording started!');
			console.log('   Screen output:', info.outputPath);
			if (info.cameraOutputPath) {
				console.log('   Camera output:', info.cameraOutputPath);
			}
			if (info.audioOutputPath) {
				console.log('   Audio output:', info.audioOutputPath);
			}
			if (info.cursorOutputPath) {
				console.log('   Cursor data:', info.cursorOutputPath);
			}
			console.log('   Session timestamp:', info.sessionTimestamp);
		});

		recorder.on('timeUpdate', (seconds) => {
			process.stdout.write(`\r⏱️  Recording: ${seconds}/10 seconds`);
		});

		// Start recording
		await recorder.startRecording(outputPath, recordingOptions);

		// Record for 10 seconds
		await new Promise(resolve => setTimeout(resolve, 10000));

		console.log('\n\n🛑 Stopping recording...');
		const result = await recorder.stopRecording();

		console.log('\n✅ Recording completed!');
		console.log('   Screen:', result.outputPath);
		if (result.cameraOutputPath) {
			console.log('   Camera:', result.cameraOutputPath);
		}
		if (result.audioOutputPath) {
			console.log('   Audio:', result.audioOutputPath);
		}

		// Find cursor data file
		const files = fs.readdirSync(outputDir);
		const cursorFile = files.find(f => f.startsWith('temp_cursor_') && f.endsWith('.json'));
		const cursorPath = cursorFile ? path.join(outputDir, cursorFile) : null;

		if (cursorPath && fs.existsSync(cursorPath)) {
			console.log('   Cursor:', cursorPath);

			// Validate cursor data
			const cursorData = JSON.parse(fs.readFileSync(cursorPath, 'utf8'));
			console.log(`   Cursor events captured: ${cursorData.length}`);
		}

		// Create metadata file for the player
		const metadata = {
			recordingTimestamp: result.sessionTimestamp,
			syncTimestamp: result.syncTimestamp,
			duration: 10,
			files: {
				screen: path.basename(result.outputPath),
				camera: result.cameraOutputPath ? path.basename(result.cameraOutputPath) : null,
				audio: result.audioOutputPath ? path.basename(result.audioOutputPath) : null,
				cursor: cursorFile
			},
			options: recordingOptions
		};

		const metadataPath = path.join(outputDir, 'recording-metadata.json');
		fs.writeFileSync(metadataPath, JSON.stringify(metadata, null, 2));
		console.log('   Metadata:', metadataPath);

		// Start HTTP server to avoid CORS issues
		console.log('\n🎨 Starting Canvas Player...');
		const server = await startHttpServer(8080);
		const serverPort = server.address().port;
		const url = `http://localhost:${serverPort}/canvas-player.html`;

		console.log(`   URL: ${url}`);
		console.log('\n✨ Opening player in browser...');
		console.log('   Press Ctrl+C to stop the server when done.\n');

		// Open in browser (macOS)
		const { exec } = require('child_process');
		exec(`open "${url}"`);

		// Keep server running
		process.on('SIGINT', () => {
			console.log('\n\n👋 Shutting down server...');
			server.close(() => {
				console.log('✅ Server closed. Goodbye!');
				process.exit(0);
			});
		});

	} catch (error) {
		console.error('\n❌ Error:', error.message);
		console.error(error.stack);
		process.exit(1);
	}
}

runCanvasTest();

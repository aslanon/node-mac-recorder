# node-mac-recorder

A powerful native macOS screen recording Node.js package with advanced window selection, multi-display support, and granular audio controls. Built with AVFoundation for optimal performance.

## Features

✨ **Advanced Recording Capabilities**

- 🖥️ **Full Screen Recording** - Capture entire displays
- 🪟 **Window-Specific Recording** - Record individual application windows
- 🎯 **Area Selection** - Record custom screen regions
- 🖱️ **Multi-Display Support** - Automatic display detection and selection
- 🎨 **Cursor Control** - Toggle cursor visibility in recordings
- 🖱️ **Cursor Tracking** - Track mouse position, cursor types, and click events

🎵 **Granular Audio Controls**

- 🎤 **Microphone Audio** - Separate microphone control (default: off)
- 🔊 **System Audio** - System audio capture (default: on)
- 📻 **Audio Device Listing** - Enumerate available audio devices
- 🎛️ **Device Selection** - Choose specific audio input devices

🔧 **Smart Window Management**

- 📋 **Window Discovery** - List all visible application windows
- 🎯 **Automatic Coordinate Conversion** - Handle multi-display coordinate systems
- 📐 **Display ID Detection** - Automatically select correct display for window recording
- 🖼️ **Window Filtering** - Smart filtering of recordable windows
- 👁️ **Preview Thumbnails** - Generate window and display preview images

⚙️ **Customization Options**

- 🎬 **Quality Control** - Adjustable recording quality presets
- 🎞️ **Frame Rate Control** - Custom frame rate settings
- 📁 **Flexible Output** - Custom output paths and formats
- 🔐 **Permission Management** - Built-in permission checking

## Installation

```bash
npm install node-mac-recorder
```

### Requirements

- **macOS 10.15+** (Catalina or later)
- **Node.js 14+**
- **Xcode Command Line Tools**
- **Screen Recording Permission** (automatically requested)
- **CPU Architecture**: Intel (x64) and Apple Silicon (ARM64) supported

### Build Requirements

```bash
# Install Xcode Command Line Tools
xcode-select --install

# The package will automatically build native modules during installation
```

**Apple Silicon Support**: The package automatically builds for the correct architecture (ARM64 on Apple Silicon, x64 on Intel) during installation. No additional configuration required.

## Quick Start

```javascript
const MacRecorder = require("node-mac-recorder");

const recorder = new MacRecorder();

// Simple full-screen recording
await recorder.startRecording("./output.mov");
await new Promise((resolve) => setTimeout(resolve, 5000)); // Record for 5 seconds
await recorder.stopRecording();
```

## API Reference

### Constructor

```javascript
const recorder = new MacRecorder();
```

### Methods

#### `startRecording(outputPath, options?)`

Starts screen recording with the specified options.

```javascript
await recorder.startRecording("./recording.mov", {
	// Audio Controls
	includeMicrophone: false, // Enable microphone (default: false)
	includeSystemAudio: true, // Enable system audio (default: true)
	audioDeviceId: "device-id", // Specific audio input device (default: system default)

	// Display & Window Selection
	displayId: 0, // Display index (null = main display)
	windowId: 12345, // Specific window ID
	captureArea: {
		// Custom area selection
		x: 100,
		y: 100,
		width: 800,
		height: 600,
	},

	// Recording Options
	quality: "high", // 'low', 'medium', 'high'
	frameRate: 30, // FPS (15, 30, 60)
	captureCursor: false, // Show cursor (default: false)
});
```

#### `stopRecording()`

Stops the current recording.

```javascript
const result = await recorder.stopRecording();
console.log("Recording saved to:", result.outputPath);
```

#### `getWindows()`

Returns a list of all recordable windows.

```javascript
const windows = await recorder.getWindows();
console.log(windows);
// [
//   {
//     id: 12345,
//     name: "My App Window",
//     appName: "MyApp",
//     x: 100, y: 200,
//     width: 800, height: 600
//   },
//   ...
// ]
```

#### `getDisplays()`

Returns information about all available displays.

```javascript
const displays = await recorder.getDisplays();
console.log(displays);
// [
//   {
//     id: 69733504,
//     name: "Display 1",
//     resolution: "2048x1330",
//     x: 0, y: 0
//   },
//   ...
// ]
```

#### `getAudioDevices()`

Returns a list of available audio input devices.

```javascript
const devices = await recorder.getAudioDevices();
console.log(devices);
// [
//   {
//     id: "device-id",
//     name: "Built-in Microphone",
//     manufacturer: "Apple Inc.",
//     isDefault: true
//   },
//   ...
// ]
```

#### `checkPermissions()`

Checks macOS recording permissions.

```javascript
const permissions = await recorder.checkPermissions();
console.log(permissions);
// {
//   screenRecording: true,
//   microphone: true,
//   accessibility: true
// }
```

#### `getStatus()`

Returns current recording status and options.

```javascript
const status = recorder.getStatus();
console.log(status);
// {
//   isRecording: true,
//   outputPath: "./recording.mov",
//   options: { ... },
//   recordingTime: 15
// }
```

#### `getWindowThumbnail(windowId, options?)`

Captures a thumbnail preview of a specific window.

```javascript
const thumbnail = await recorder.getWindowThumbnail(12345, {
	maxWidth: 400, // Maximum width (default: 300)
	maxHeight: 300, // Maximum height (default: 200)
});

// Returns: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA..."
// Can be used directly in <img> tags or saved as file
```

#### `getDisplayThumbnail(displayId, options?)`

Captures a thumbnail preview of a specific display.

```javascript
const thumbnail = await recorder.getDisplayThumbnail(0, {
	maxWidth: 400, // Maximum width (default: 300)
	maxHeight: 300, // Maximum height (default: 200)
});

// Returns: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA..."
// Perfect for display selection UI
```

### Cursor Tracking Methods

#### `startCursorCapture(outputPath)`

Starts automatic cursor tracking and saves data to JSON file in real-time.

```javascript
await recorder.startCursorCapture("./cursor-data.json");
// Cursor tracking started - automatically writing to file
```

#### `stopCursorCapture()`

Stops cursor tracking and closes the output file.

```javascript
await recorder.stopCursorCapture();
// Tracking stopped, file closed
```

**JSON Output Format:**

```json
[
	{
		"x": 851,
		"y": 432,
		"timestamp": 201,
		"cursorType": "default",
		"type": "move"
	},
	{
		"x": 851,
		"y": 432,
		"timestamp": 220,
		"cursorType": "pointer",
		"type": "mousedown"
	}
]
```

**Cursor Types:** `default`, `pointer`, `text`, `grab`, `grabbing`, `ew-resize`, `ns-resize`, `crosshair`  
**Event Types:** `move`, `mousedown`, `mouseup`, `rightmousedown`, `rightmouseup`

## Usage Examples

### Window-Specific Recording

```javascript
const recorder = new MacRecorder();

// List available windows
const windows = await recorder.getWindows();
console.log("Available windows:");
windows.forEach((win, i) => {
	console.log(`${i + 1}. ${win.appName} - ${win.name}`);
});

// Record a specific window
const targetWindow = windows.find((w) => w.appName === "Safari");
await recorder.startRecording("./safari-recording.mov", {
	windowId: targetWindow.id,
	includeSystemAudio: false,
	includeMicrophone: true,
	captureCursor: true,
});

await new Promise((resolve) => setTimeout(resolve, 10000)); // 10 seconds
await recorder.stopRecording();
```

### Multi-Display Recording

```javascript
const recorder = new MacRecorder();

// List available displays
const displays = await recorder.getDisplays();
console.log("Available displays:");
displays.forEach((display, i) => {
	console.log(`${i}: ${display.resolution} at (${display.x}, ${display.y})`);
});

// Record from second display
await recorder.startRecording("./second-display.mov", {
	displayId: 1, // Second display
	quality: "high",
	frameRate: 60,
});

await new Promise((resolve) => setTimeout(resolve, 5000));
await recorder.stopRecording();
```

### Custom Area Recording

```javascript
const recorder = new MacRecorder();

// Record specific screen area
await recorder.startRecording("./area-recording.mov", {
	captureArea: {
		x: 200,
		y: 100,
		width: 1200,
		height: 800,
	},
	quality: "medium",
	captureCursor: false,
});

await new Promise((resolve) => setTimeout(resolve, 8000));
await recorder.stopRecording();
```

### Audio-Only System Recording

```javascript
const recorder = new MacRecorder();

// Record system audio without microphone
await recorder.startRecording("./system-audio.mov", {
	includeMicrophone: false,
	includeSystemAudio: true,
	captureArea: { x: 0, y: 0, width: 1, height: 1 }, // Minimal video
});
```

### Event-Driven Recording

```javascript
const recorder = new MacRecorder();

// Listen to recording events
recorder.on("started", (outputPath) => {
	console.log("Recording started:", outputPath);
});

recorder.on("stopped", (result) => {
	console.log("Recording stopped:", result);
});

recorder.on("timeUpdate", (seconds) => {
	console.log(`Recording time: ${seconds}s`);
});

recorder.on("completed", (outputPath) => {
	console.log("Recording completed:", outputPath);
});

await recorder.startRecording("./event-recording.mov");
```

### Window Selection with Thumbnails

```javascript
const recorder = new MacRecorder();

// Get windows with thumbnail previews
const windows = await recorder.getWindows();

console.log("Available windows with previews:");
for (const window of windows) {
	console.log(`${window.appName} - ${window.name}`);

	try {
		// Generate thumbnail for each window
		const thumbnail = await recorder.getWindowThumbnail(window.id, {
			maxWidth: 200,
			maxHeight: 150,
		});

		console.log(`Thumbnail: ${thumbnail.substring(0, 50)}...`);

		// Use thumbnail in your UI:
		// <img src="${thumbnail}" alt="Window Preview" />
	} catch (error) {
		console.log(`No preview available: ${error.message}`);
	}
}
```

### Display Selection Interface

```javascript
const recorder = new MacRecorder();

async function createDisplaySelector() {
	const displays = await recorder.getDisplays();

	const displayOptions = await Promise.all(
		displays.map(async (display, index) => {
			try {
				const thumbnail = await recorder.getDisplayThumbnail(display.id);
				return {
					id: display.id,
					name: `Display ${index + 1}`,
					resolution: display.resolution,
					thumbnail: thumbnail,
					isPrimary: display.isPrimary,
				};
			} catch (error) {
				return {
					id: display.id,
					name: `Display ${index + 1}`,
					resolution: display.resolution,
					thumbnail: null,
					isPrimary: display.isPrimary,
				};
			}
		})
	);

	return displayOptions;
}
```

### Cursor Tracking Usage

```javascript
const MacRecorder = require("node-mac-recorder");

async function trackUserInteraction() {
	const recorder = new MacRecorder();

	try {
		// Start cursor tracking - automatically writes to file
		await recorder.startCursorCapture("./user-interactions.json");
		console.log("✅ Cursor tracking started...");

		// Track for 5 seconds
		console.log("📱 Move mouse and click for 5 seconds...");
		await new Promise((resolve) => setTimeout(resolve, 5000));

		// Stop tracking
		await recorder.stopCursorCapture();
		console.log("✅ Cursor tracking completed!");

		// Analyze the data
		const fs = require("fs");
		const data = JSON.parse(
			fs.readFileSync("./user-interactions.json", "utf8")
		);

		console.log(`📄 ${data.length} events recorded`);

		// Count clicks
		const clicks = data.filter((d) => d.type === "mousedown").length;
		if (clicks > 0) {
			console.log(`🖱️ ${clicks} clicks detected`);
		}

		// Most used cursor type
		const cursorTypes = {};
		data.forEach((item) => {
			cursorTypes[item.cursorType] = (cursorTypes[item.cursorType] || 0) + 1;
		});

		const mostUsed = Object.keys(cursorTypes).reduce((a, b) =>
			cursorTypes[a] > cursorTypes[b] ? a : b
		);
		console.log(`🎯 Most used cursor: ${mostUsed}`);
	} catch (error) {
		console.error("❌ Error:", error.message);
	}
}

trackUserInteraction();
```

### Combined Screen Recording + Cursor Tracking

```javascript
const MacRecorder = require("node-mac-recorder");

async function recordWithCursorTracking() {
	const recorder = new MacRecorder();

	try {
		// Start both screen recording and cursor tracking
		await Promise.all([
			recorder.startRecording("./screen-recording.mov", {
				captureCursor: false, // Don't show cursor in video
				includeSystemAudio: true,
				quality: "high",
			}),
			recorder.startCursorCapture("./cursor-data.json"),
		]);

		console.log("✅ Recording screen and tracking cursor...");

		// Record for 10 seconds
		await new Promise((resolve) => setTimeout(resolve, 10000));

		// Stop both
		await Promise.all([recorder.stopRecording(), recorder.stopCursorCapture()]);

		console.log("✅ Recording completed!");
		console.log("📁 Files created:");
		console.log("   - screen-recording.mov");
		console.log("   - cursor-data.json");
	} catch (error) {
		console.error("❌ Error:", error.message);
	}
}

recordWithCursorTracking();
```

## Integration Examples

### Electron Integration

```javascript
// In main process
const { ipcMain } = require("electron");
const MacRecorder = require("node-mac-recorder");

const recorder = new MacRecorder();

ipcMain.handle("start-recording", async (event, options) => {
	try {
		await recorder.startRecording("./recording.mov", options);
		return { success: true };
	} catch (error) {
		return { success: false, error: error.message };
	}
});

ipcMain.handle("stop-recording", async () => {
	const result = await recorder.stopRecording();
	return result;
});

ipcMain.handle("get-windows", async () => {
	return await recorder.getWindows();
});
```

### Express.js API

```javascript
const express = require("express");
const MacRecorder = require("node-mac-recorder");

const app = express();
const recorder = new MacRecorder();

app.post("/start-recording", async (req, res) => {
	try {
		const { windowId, duration } = req.body;
		await recorder.startRecording("./api-recording.mov", { windowId });

		setTimeout(async () => {
			await recorder.stopRecording();
		}, duration * 1000);

		res.json({ status: "started" });
	} catch (error) {
		res.status(500).json({ error: error.message });
	}
});

app.get("/windows", async (req, res) => {
	const windows = await recorder.getWindows();
	res.json(windows);
});
```

## Advanced Features

### Automatic Display Detection

When recording windows, the package automatically:

1. **Detects Window Location** - Determines which display contains the window
2. **Converts Coordinates** - Translates global coordinates to display-relative coordinates
3. **Sets Display ID** - Automatically selects the correct display for recording
4. **Handles Multi-Monitor** - Works seamlessly across multiple displays

```javascript
// Window at (-2000, 100) on second display
// Automatically converts to (440, 100) on display 1
await recorder.startRecording("./auto-display.mov", {
	windowId: 12345, // Package handles display detection automatically
});
```

### Smart Window Filtering

The `getWindows()` method automatically filters out:

- System windows (Dock, Menu Bar)
- Hidden windows
- Very small windows (< 50x50 pixels)
- Windows without names

### Performance Optimization

- **Native Implementation** - Uses AVFoundation for optimal performance
- **Minimal Overhead** - Low CPU usage during recording
- **Memory Efficient** - Proper memory management in native layer
- **Quality Presets** - Balanced quality/performance options

## Testing

Run the included demo to test cursor tracking:

```bash
node cursor-test.js
```

This will:

- ✅ Start cursor tracking for 5 seconds
- 📱 Capture mouse movements and clicks
- 📄 Save data to `cursor-data.json`
- 🖱️ Report clicks detected

## Troubleshooting

### Permission Issues

If recording fails, check macOS permissions:

```bash
# Open System Preferences > Security & Privacy > Screen Recording
# Ensure your app/terminal has permission
```

### Build Errors

```bash
# Reinstall with verbose output
npm install node-mac-recorder --verbose

# Clear npm cache
npm cache clean --force

# Ensure Xcode tools are installed
xcode-select --install
```

### Recording Issues

1. **Empty/Black Video**: Check screen recording permissions
2. **No Audio**: Verify audio permissions and device availability
3. **Window Not Found**: Ensure target window is visible and not minimized
4. **Coordinate Issues**: Window may be on different display (handled automatically)

### Debug Information

```javascript
// Get module information
const info = recorder.getModuleInfo();
console.log("Module info:", info);

// Check recording status
const status = recorder.getStatus();
console.log("Recording status:", status);

// Verify permissions
const permissions = await recorder.checkPermissions();
console.log("Permissions:", permissions);
```

## Performance Considerations

- **Recording Quality**: Higher quality increases file size and CPU usage
- **Frame Rate**: 30fps recommended for most use cases, 60fps for smooth motion
- **Audio**: System audio capture adds minimal overhead
- **Window Recording**: Slightly more efficient than full-screen recording
- **Multi-Display**: No significant performance impact

## File Formats

- **Output Format**: MOV (QuickTime)
- **Video Codec**: H.264
- **Audio Codec**: AAC
- **Container**: QuickTime compatible

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Changelog

### Latest Updates

- ✅ **Cursor Tracking**: Track mouse position, cursor types, and click events with JSON export
- ✅ **Window Recording**: Automatic coordinate conversion for multi-display setups
- ✅ **Audio Controls**: Separate microphone and system audio controls
- ✅ **Display Selection**: Multi-monitor support with automatic detection
- ✅ **Smart Filtering**: Improved window detection and filtering
- ✅ **Performance**: Optimized native implementation

---

**Made for macOS** 🍎 | **Built with AVFoundation** 📹 | **Node.js Ready** 🚀

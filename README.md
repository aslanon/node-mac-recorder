# node-mac-recorder

A powerful native macOS screen recording Node.js package with advanced window selection, multi-display support, and granular audio controls. Built with AVFoundation for optimal performance.

## Features

✨ **Advanced Recording Capabilities**

- 🖥️ **Full Screen Recording** - Capture entire displays
- 🪟 **Window-Specific Recording** - Record individual application windows
- 🎯 **Area Selection** - Record custom screen regions
- 🖱️ **Multi-Display Support** - Automatic display detection and selection
- 🎨 **Cursor Control** - Toggle cursor visibility in recordings

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

Lists all available audio input devices.

```javascript
const devices = await recorder.getAudioDevices();
console.log(devices);
// [
//   {
//     id: "device-id-123",
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

- ✅ **Window Recording**: Automatic coordinate conversion for multi-display setups
- ✅ **Audio Controls**: Separate microphone and system audio controls
- ✅ **Display Selection**: Multi-monitor support with automatic detection
- ✅ **Smart Filtering**: Improved window detection and filtering
- ✅ **Performance**: Optimized native implementation

---

**Made for macOS** 🍎 | **Built with AVFoundation** 📹 | **Node.js Ready** 🚀

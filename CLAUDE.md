# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**ELECTRON-FIRST PRIORITY**: node-mac-recorder is a Node.js native addon specifically designed and optimized for Electron.js applications. It provides macOS screen recording capabilities using ScreenCaptureKit (macOS 15+) and AVFoundation (macOS 13+). The package allows recording of full screens, specific windows, or custom areas, with support for multi-display setups, audio capture, and cursor tracking.

### **🚀 CRITICAL: Electron.js Support**
This module is **PRIMARILY BUILT FOR ELECTRON.JS**. All features work seamlessly in Electron applications without any restrictions. Both ScreenCaptureKit and AVFoundation are fully supported in Electron environments.

## Build System & Commands

### Building the Native Module

```bash
npm run build      # Build the native module using node-gyp
npm run rebuild    # Clean rebuild of the native module
npm run clean      # Clean build artifacts
npm install        # Runs install.js which builds the module automatically
```

### Testing

```bash
npm test           # Run the main test suite (test.js)
node cursor-test.js # Test cursor tracking functionality only
node test.js       # Run comprehensive API tests
```

### Development

The package uses node-gyp for building the native C++/Objective-C module. Requires:

- macOS 10.15+ (Catalina or later)
- Xcode Command Line Tools
- Node.js 14+

## Architecture

### Core Components

**Main Entry Point**

- `index.js` - Main MacRecorder class (EventEmitter-based)
- Handles all high-level recording operations and coordinate transformations

**Native Module** (`src/`)

- `mac_recorder.mm` - Main native module entry point and N-API bindings
- `screen_capture.mm` - AVFoundation-based screen/window recording
- `audio_capture.mm` - Audio device enumeration and capture
- `cursor_tracker.mm` - Real-time cursor position and event tracking

**Build Configuration**

- `binding.gyp` - Native module build configuration
- Links against AVFoundation, ScreenCaptureKit, AppKit, and other macOS frameworks

### Key Features

1. **Multi-Display Support**: Automatic display detection and coordinate conversion
2. **Window Recording**: Smart window detection with thumbnail generation
3. **Audio Control**: Separate microphone and system audio controls with device selection
4. **Cursor Tracking**: Real-time cursor position, type, and click event capture
5. **Permission Management**: Built-in macOS permission checking and requesting

### Coordinate System Handling

The package handles complex multi-display coordinate transformations:

- Global macOS coordinates (can be negative for secondary displays)
- Display-relative coordinates (always positive, 0-based)
- Automatic window-to-display mapping for recording

## API Structure

### Main Class Methods

- `startRecording(outputPath, options)` - Begin screen/window recording
- `stopRecording()` - Stop recording and finalize video file
- `getWindows()` - List all recordable application windows
- `getDisplays()` - Get all available displays with metadata
- `getAudioDevices()` - Enumerate available audio input devices
- `checkPermissions()` - Verify macOS recording permissions

### Cursor Tracking

- `startCursorCapture(filepath, options)` - Begin real-time cursor tracking to JSON
  - `options.windowInfo` - Window information for window-relative coordinates
  - `options.windowRelative` - Set to true for window-relative coordinates
- `stopCursorCapture()` - Stop tracking and close output file
- `getCursorPosition()` - Get current cursor position and state

### Events

The MacRecorder class emits the following events:

- `recordingStarted` - Emitted immediately when recording starts with recording details
- `started` - Emitted when recording is confirmed started (legacy event)
- `stopped` - Emitted when recording stops
- `completed` - Emitted when recording file is finalized
- `timeUpdate` - Emitted every second with elapsed time
- `cursorCaptureStarted` - Emitted when cursor capture begins
- `cursorCaptureStopped` - Emitted when cursor capture ends

### Thumbnails

- `getWindowThumbnail(windowId, options)` - Capture window preview image
- `getDisplayThumbnail(displayId, options)` - Capture display preview image

## Development Notes

### Testing Strategy

- Use `npm test` for full API validation
- `cursor-test.js` for testing cursor tracking specifically
- Test files create output in `test-output/` directory

### Common Development Patterns

- All recording operations are Promise-based
- Event emission for recording state changes (`recordingStarted`, `started`, `stopped`, `completed`)
- `recordingStarted` event provides immediate notification with recording details
- Automatic permission checking before operations
- Error handling with descriptive messages for permission issues
- Cursor tracking supports multiple coordinate systems:
  - Global coordinates (default)
  - Display-relative coordinates (when recording)
  - Window-relative coordinates (with windowInfo parameter)

### Platform Requirements & Framework Selection

**ELECTRON-FIRST ARCHITECTURE:**
- **Primary Target**: Electron.js applications (full support, no restrictions)
- **Secondary**: Node.js standalone applications
- macOS only (enforced in install.js)
- Native module compilation required on install
- Requires screen recording and accessibility permissions

**Framework Selection Logic (Electron Priority):**
- **macOS 15+ + Electron**: ScreenCaptureKit with full capabilities
- **macOS 15+ + Node.js**: ScreenCaptureKit with full capabilities  
- **macOS 14 + Electron**: AVFoundation with full capabilities
- **macOS 13 + Electron**: AVFoundation with limited features
- **macOS 14 + Node.js**: AVFoundation with full capabilities
- **macOS 13 + Node.js**: AVFoundation with limited features

### File Outputs

- Video recordings: `.mov` format (H.264/AAC)
- Cursor data: JSON format with timestamped events
  - `x`, `y`: Cursor coordinates (coordinate system dependent)
  - `timestamp`: Time from capture start (ms)
  - `unixTimeMs`: Unix timestamp
  - `cursorType`: macOS cursor type
  - `type`: Event type (move, click, etc.)
  - `coordinateSystem`: "global", "display-relative", or "window-relative"
  - `windowInfo`: Window metadata (when using window-relative coordinates)
- Thumbnails: Base64-encoded PNG data URIs

## Troubleshooting

### Build Issues

1. Ensure Xcode Command Line Tools: `xcode-select --install`
2. Clean rebuild: `npm run clean && npm run build`
3. Check Node.js version compatibility (14+)

### Runtime Issues

1. Permission failures: Check System Preferences > Security & Privacy
2. Recording failures: Verify target windows/displays are accessible
3. Audio issues: Check audio device availability and permissions

### Native Module Loading

The module tries loading from `build/Release/` first, then falls back to `build/Debug/` with helpful error messages if neither exists.

### **⚡ CRITICAL IMPLEMENTATION NOTES**

**ELECTRON.JS IS THE PRIMARY TARGET:**
1. **No Electron Restrictions**: All Electron detection logic is for optimization, NOT blocking
2. **Framework Support**: Both ScreenCaptureKit and AVFoundation work perfectly in Electron
3. **Environment Detection**: Code detects Electron to provide enhanced logging and optimization
4. **macOS Compatibility**: 
   - macOS 15+ (Sequoia+): Use ScreenCaptureKit for best performance
   - macOS 14 (Sonoma): Use AVFoundation with full feature set
   - macOS 13 (Ventura): Use AVFoundation with basic features
5. **Error Handling**: Any "Recording failed to start" errors should trigger fallback logic, never blocking

**NEVER BLOCK ELECTRON ENVIRONMENTS** - This is a core design principle.

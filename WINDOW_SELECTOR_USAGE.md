# Window Selector Usage Guide

The `WindowSelector` module provides native macOS window and screen selection with overlay interfaces. This guide shows how to use it in both Node.js and Electron applications.

## Basic Setup

```javascript
const MacRecorder = require('node-mac-recorder');
const WindowSelector = MacRecorder.WindowSelector;

const selector = new WindowSelector();
```

## Core Features

### 1. Window Selection with Overlay

Select any window on screen with visual highlights:

```javascript
// Method 1: Promise-based selection
async function selectWindow() {
    try {
        const selectedWindow = await selector.selectWindow();
        console.log('Selected window:', selectedWindow);
        // Returns: { id, title, appName, x, y, width, height }
    } catch (error) {
        console.log('Selection cancelled or failed:', error.message);
    }
}

// Method 2: Event-based selection with more control
async function selectWindowWithEvents() {
    // Listen for events
    selector.on('windowEntered', (window) => {
        console.log('Mouse over window:', window.title);
    });
    
    selector.on('windowLeft', (window) => {
        console.log('Mouse left window:', window.title);
    });
    
    selector.on('windowSelected', (window) => {
        console.log('Window selected:', window);
        // Handle selection
    });
    
    // Start selection
    await selector.startSelection();
    
    // Selection runs until user clicks or you call stopSelection()
    // setTimeout(() => selector.stopSelection(), 10000); // Auto-stop after 10s
}
```

### 2. Screen Selection with Overlay

Select entire screens (useful for multi-monitor setups):

```javascript
async function selectScreen() {
    try {
        const selectedScreen = await selector.selectScreen();
        console.log('Selected screen:', selectedScreen);
        // Returns: { id, width, height, x, y, name }
    } catch (error) {
        console.log('Screen selection cancelled:', error.message);
    }
}

// Manual control
async function manualScreenSelection() {
    await selector.startScreenSelection();
    
    // Check for selection periodically
    const checkSelection = setInterval(() => {
        const selected = selector.getSelectedScreen();
        if (selected) {
            console.log('Screen selected:', selected);
            clearInterval(checkSelection);
            selector.stopScreenSelection();
        }
    }, 100);
    
    // Auto-cancel after 30 seconds
    setTimeout(() => {
        clearInterval(checkSelection);
        selector.stopScreenSelection();
    }, 30000);
}
```

### 3. Recording Preview Overlays

Show preview of what will be recorded:

```javascript
async function showRecordingPreview() {
    // Get a window first
    const recorder = new MacRecorder();
    const windows = await recorder.getWindows();
    const targetWindow = windows[0];
    
    // Show preview overlay (darkens screen, highlights window)
    await selector.showRecordingPreview(targetWindow);
    
    // Show for 3 seconds
    setTimeout(async () => {
        await selector.hideRecordingPreview();
    }, 3000);
}

// Screen recording preview
async function showScreenRecordingPreview() {
    const recorder = new MacRecorder();
    const displays = await recorder.getDisplays();
    const targetScreen = displays[0];
    
    await selector.showScreenRecordingPreview(targetScreen);
    
    // Hide after delay
    setTimeout(async () => {
        await selector.hideScreenRecordingPreview();
    }, 3000);
}
```

### 4. Status and Cleanup

```javascript
// Check current status
const status = selector.getStatus();
console.log(status);
// Returns: { isSelecting, hasSelectedWindow, selectedWindow, nativeStatus }

// Cleanup when done
await selector.cleanup();
```

## Electron Integration

**IMPORTANT**: In Electron environments, the window selector automatically switches to "safe mode" to prevent NSWindow overlay crashes. Instead of creating native overlays, it provides window/screen lists that you can display in your Electron UI.

### Main Process Usage

```javascript
// In main.cjs or main.js
const { ipcMain } = require('electron');
const MacRecorder = require('node-mac-recorder');
const WindowSelector = MacRecorder.WindowSelector;

let windowSelector = null;

ipcMain.handle('window-selector-init', () => {
    windowSelector = new WindowSelector();
    // In Electron, this will automatically use safe mode
    return true;
});

// Get available windows (safe for Electron)
ipcMain.handle('get-available-windows', async () => {
    try {
        const windows = await windowSelector.getAvailableWindows();
        return { success: true, windows: windows };
    } catch (error) {
        return { success: false, error: error.message };
    }
});

// Select window by ID (no overlay needed)
ipcMain.handle('select-window-by-id', async (event, windowInfo) => {
    try {
        const selectedWindow = windowSelector.selectWindowById(windowInfo);
        return { success: true, window: selectedWindow };
    } catch (error) {
        return { success: false, error: error.message };
    }
});

// Get available screens (safe for Electron)
ipcMain.handle('get-available-screens', async () => {
    try {
        const recorder = new MacRecorder();
        const screens = await recorder.getDisplays();
        return { success: true, screens: screens };
    } catch (error) {
        return { success: false, error: error.message };
    }
});

ipcMain.handle('window-selector-cleanup', async () => {
    if (windowSelector) {
        await windowSelector.cleanup();
        windowSelector = null;
    }
    return true;
});
```

### Renderer Process Usage

```javascript
// In renderer.js or React component
const { ipcRenderer } = require('electron');

class ScreenRecorder {
    async selectWindow() {
        // Initialize selector
        await ipcRenderer.invoke('window-selector-init');
        
        // Select window
        const result = await ipcRenderer.invoke('window-selector-select');
        
        if (result.success) {
            console.log('Selected window:', result.window);
            return result.window;
        } else {
            throw new Error(result.error);
        }
    }
    
    async selectScreen() {
        await ipcRenderer.invoke('window-selector-init');
        
        const result = await ipcRenderer.invoke('screen-selector-select');
        
        if (result.success) {
            console.log('Selected screen:', result.screen);
            return result.screen;
        } else {
            throw new Error(result.error);
        }
    }
    
    async cleanup() {
        await ipcRenderer.invoke('window-selector-cleanup');
    }
}

// Usage in React component
function RecordingComponent() {
    const [selectedWindow, setSelectedWindow] = useState(null);
    const recorder = new ScreenRecorder();
    
    const handleSelectWindow = async () => {
        try {
            const window = await recorder.selectWindow();
            setSelectedWindow(window);
        } catch (error) {
            console.error('Window selection failed:', error);
        }
    };
    
    return (
        <div>
            <button onClick={handleSelectWindow}>
                Select Window to Record
            </button>
            {selectedWindow && (
                <div>
                    Selected: {selectedWindow.title} ({selectedWindow.appName})
                </div>
            )}
        </div>
    );
}
```

## Complete Electron Example

```javascript
// main.cjs
const { app, BrowserWindow, ipcMain } = require('electron');
const MacRecorder = require('node-mac-recorder');
const WindowSelector = MacRecorder.WindowSelector;

let mainWindow;
let windowSelector;
let recorder;

function createWindow() {
    mainWindow = new BrowserWindow({
        width: 800,
        height: 600,
        webPreferences: {
            nodeIntegration: true,
            contextIsolation: false
        }
    });
    
    mainWindow.loadFile('index.html');
}

// Initialize services
ipcMain.handle('init-services', async () => {
    recorder = new MacRecorder();
    windowSelector = new WindowSelector();
    return true;
});

// Window selection
ipcMain.handle('select-window', async () => {
    try {
        const window = await windowSelector.selectWindow();
        return { success: true, data: window };
    } catch (error) {
        return { success: false, error: error.message };
    }
});

// Screen selection
ipcMain.handle('select-screen', async () => {
    try {
        const screen = await windowSelector.selectScreen();
        return { success: true, data: screen };
    } catch (error) {
        return { success: false, error: error.message };
    }
});

// Start recording
ipcMain.handle('start-recording', async (event, windowInfo, outputPath) => {
    try {
        const options = {
            windowId: windowInfo.id,
            captureCursor: true,
            includeSystemAudio: false
        };
        
        await recorder.startRecording(outputPath, options);
        return { success: true };
    } catch (error) {
        return { success: false, error: error.message };
    }
});

// Stop recording
ipcMain.handle('stop-recording', async () => {
    try {
        await recorder.stopRecording();
        return { success: true };
    } catch (error) {
        return { success: false, error: error.message };
    }
});

app.whenReady().then(createWindow);
```

```html
<!-- index.html -->
<!DOCTYPE html>
<html>
<head>
    <title>Screen Recorder</title>
</head>
<body>
    <h1>Screen Recorder</h1>
    
    <button id="selectWindow">Select Window</button>
    <button id="selectScreen">Select Screen</button>
    <button id="startRecord">Start Recording</button>
    <button id="stopRecord">Stop Recording</button>
    
    <div id="status"></div>
    
    <script>
        const { ipcRenderer } = require('electron');
        
        let selectedWindow = null;
        let selectedScreen = null;
        
        // Initialize
        ipcRenderer.invoke('init-services');
        
        document.getElementById('selectWindow').addEventListener('click', async () => {
            const result = await ipcRenderer.invoke('select-window');
            if (result.success) {
                selectedWindow = result.data;
                document.getElementById('status').innerHTML = 
                    `Selected Window: ${selectedWindow.title}`;
            } else {
                alert('Window selection failed: ' + result.error);
            }
        });
        
        document.getElementById('selectScreen').addEventListener('click', async () => {
            const result = await ipcRenderer.invoke('select-screen');
            if (result.success) {
                selectedScreen = result.data;
                document.getElementById('status').innerHTML = 
                    `Selected Screen: ${selectedScreen.width}x${selectedScreen.height}`;
            } else {
                alert('Screen selection failed: ' + result.error);
            }
        });
        
        document.getElementById('startRecord').addEventListener('click', async () => {
            if (!selectedWindow) {
                alert('Please select a window first');
                return;
            }
            
            const outputPath = `/tmp/recording-${Date.now()}.mov`;
            const result = await ipcRenderer.invoke('start-recording', selectedWindow, outputPath);
            
            if (result.success) {
                document.getElementById('status').innerHTML = 'Recording started...';
            } else {
                alert('Recording failed: ' + result.error);
            }
        });
        
        document.getElementById('stopRecord').addEventListener('click', async () => {
            const result = await ipcRenderer.invoke('stop-recording');
            if (result.success) {
                document.getElementById('status').innerHTML = 'Recording stopped';
            }
        });
    </script>
</body>
</html>
```

## Key Points for AI Integration

1. **Asynchronous Operations**: All selection methods return Promises
2. **Event-Driven**: Use events for real-time feedback during selection
3. **Error Handling**: Always wrap in try-catch blocks
4. **Cleanup Required**: Call `cleanup()` when done to prevent memory leaks
5. **Permissions Required**: Needs macOS screen recording permissions
6. **Multi-Monitor Support**: Screen selection works with multiple displays
7. **Window Filtering**: Automatically filters out invalid/hidden windows

## Permissions

The module requires macOS screen recording permissions. Users will be prompted automatically, or check programmatically:

```javascript
const permissions = await selector.checkPermissions();
if (!permissions.screenRecording) {
    console.log('Screen recording permission required');
    // Guide user to System Preferences > Privacy & Security > Screen Recording
}
```

This covers all major use cases for integrating window/screen selection into AI-powered applications.
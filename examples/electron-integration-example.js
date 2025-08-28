// Electron Integration Example for node-mac-recorder
// This example shows how to use the Electron-safe version in an Electron app

const { app, BrowserWindow, ipcMain, dialog } = require("electron");
const path = require("path");

// Import the Electron-safe version
const ElectronSafeMacRecorder = require("../electron-safe-index");

let mainWindow;
let recorder;

function createWindow() {
	// Create the browser window
	mainWindow = new BrowserWindow({
		width: 1200,
		height: 800,
		webPreferences: {
			nodeIntegration: false,
			contextIsolation: true,
			preload: path.join(__dirname, "electron-preload.js"),
		},
	});

	// Load the app
	mainWindow.loadFile("electron-renderer.html");

	// Initialize the Electron-safe recorder
	try {
		recorder = new ElectronSafeMacRecorder();
		console.log("✅ ElectronSafeMacRecorder initialized");

		// Setup event listeners
		recorder.on("recordingStarted", (data) => {
			console.log("🎬 Recording started:", data);
			mainWindow.webContents.send("recording-started", data);
		});

		recorder.on("stopped", (result) => {
			console.log("🛑 Recording stopped:", result);
			mainWindow.webContents.send("recording-stopped", result);
		});

		recorder.on("completed", (outputPath) => {
			console.log("✅ Recording completed:", outputPath);
			mainWindow.webContents.send("recording-completed", outputPath);
		});

		recorder.on("timeUpdate", (elapsed) => {
			mainWindow.webContents.send("recording-time-update", elapsed);
		});
	} catch (error) {
		console.error("❌ Failed to initialize recorder:", error);
		dialog.showErrorBox(
			"Recorder Error",
			"Failed to initialize screen recorder. Please ensure the Electron-safe module is built."
		);
	}
}

// IPC handlers for safe communication with renderer
ipcMain.handle("recorder:getModuleInfo", async () => {
	try {
		return recorder ? recorder.getModuleInfo() : null;
	} catch (error) {
		console.error("Error getting module info:", error);
		return { error: error.message };
	}
});

ipcMain.handle("recorder:checkPermissions", async () => {
	try {
		return await recorder.checkPermissions();
	} catch (error) {
		console.error("Error checking permissions:", error);
		return { error: error.message };
	}
});

ipcMain.handle("recorder:getDisplays", async () => {
	try {
		return await recorder.getDisplays();
	} catch (error) {
		console.error("Error getting displays:", error);
		return [];
	}
});

ipcMain.handle("recorder:getWindows", async () => {
	try {
		return await recorder.getWindows();
	} catch (error) {
		console.error("Error getting windows:", error);
		return [];
	}
});

ipcMain.handle(
	"recorder:startRecording",
	async (event, outputPath, options) => {
		try {
			if (!recorder) {
				throw new Error("Recorder not initialized");
			}

			console.log("🎬 Starting recording with options:", options);
			const result = await recorder.startRecording(outputPath, options);
			return { success: true, result };
		} catch (error) {
			console.error("Error starting recording:", error);
			return { success: false, error: error.message };
		}
	}
);

ipcMain.handle("recorder:stopRecording", async () => {
	try {
		if (!recorder) {
			throw new Error("Recorder not initialized");
		}

		console.log("🛑 Stopping recording");
		const result = await recorder.stopRecording();
		return { success: true, result };
	} catch (error) {
		console.error("Error stopping recording:", error);
		return { success: false, error: error.message };
	}
});

ipcMain.handle("recorder:getStatus", async () => {
	try {
		return recorder ? recorder.getStatus() : null;
	} catch (error) {
		console.error("Error getting status:", error);
		return { error: error.message };
	}
});

ipcMain.handle("recorder:getCursorPosition", async () => {
	try {
		return recorder ? recorder.getCursorPosition() : null;
	} catch (error) {
		console.error("Error getting cursor position:", error);
		return { error: error.message };
	}
});

ipcMain.handle(
	"recorder:getDisplayThumbnail",
	async (event, displayId, options) => {
		try {
			return await recorder.getDisplayThumbnail(displayId, options);
		} catch (error) {
			console.error("Error getting display thumbnail:", error);
			return null;
		}
	}
);

ipcMain.handle(
	"recorder:getWindowThumbnail",
	async (event, windowId, options) => {
		try {
			return await recorder.getWindowThumbnail(windowId, options);
		} catch (error) {
			console.error("Error getting window thumbnail:", error);
			return null;
		}
	}
);

ipcMain.handle("dialog:showSaveDialog", async () => {
	const result = await dialog.showSaveDialog(mainWindow, {
		title: "Save Recording",
		defaultPath: "recording.mov",
		filters: [{ name: "Movies", extensions: ["mov", "mp4"] }],
	});
	return result;
});

// App event listeners
app.whenReady().then(createWindow);

app.on("window-all-closed", () => {
	// Stop any ongoing recording before quitting
	if (recorder && recorder.getStatus().isRecording) {
		console.log("🛑 Stopping recording before quit");
		recorder.stopRecording().finally(() => {
			if (process.platform !== "darwin") {
				app.quit();
			}
		});
	} else {
		if (process.platform !== "darwin") {
			app.quit();
		}
	}
});

app.on("activate", () => {
	if (BrowserWindow.getAllWindows().length === 0) {
		createWindow();
	}
});

// Handle app termination gracefully
process.on("SIGINT", async () => {
	console.log("🛑 SIGINT received, stopping recording...");
	if (recorder && recorder.getStatus().isRecording) {
		try {
			await recorder.stopRecording();
		} catch (error) {
			console.error("Error stopping recording on exit:", error);
		}
	}
	app.quit();
});

process.on("SIGTERM", async () => {
	console.log("🛑 SIGTERM received, stopping recording...");
	if (recorder && recorder.getStatus().isRecording) {
		try {
			await recorder.stopRecording();
		} catch (error) {
			console.error("Error stopping recording on exit:", error);
		}
	}
	app.quit();
});

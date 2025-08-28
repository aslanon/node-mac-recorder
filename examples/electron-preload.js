// Preload script for secure IPC communication
const { contextBridge, ipcRenderer } = require("electron");

// Expose protected methods that allow the renderer process to use
// the ipcRenderer without exposing the entire object
contextBridge.exposeInMainWorld("electronAPI", {
	// Recorder API
	recorder: {
		getModuleInfo: () => ipcRenderer.invoke("recorder:getModuleInfo"),
		checkPermissions: () => ipcRenderer.invoke("recorder:checkPermissions"),
		getDisplays: () => ipcRenderer.invoke("recorder:getDisplays"),
		getWindows: () => ipcRenderer.invoke("recorder:getWindows"),
		startRecording: (outputPath, options) =>
			ipcRenderer.invoke("recorder:startRecording", outputPath, options),
		stopRecording: () => ipcRenderer.invoke("recorder:stopRecording"),
		getStatus: () => ipcRenderer.invoke("recorder:getStatus"),
		getCursorPosition: () => ipcRenderer.invoke("recorder:getCursorPosition"),
		getDisplayThumbnail: (displayId, options) =>
			ipcRenderer.invoke("recorder:getDisplayThumbnail", displayId, options),
		getWindowThumbnail: (windowId, options) =>
			ipcRenderer.invoke("recorder:getWindowThumbnail", windowId, options),

		// Event listeners
		onRecordingStarted: (callback) =>
			ipcRenderer.on("recording-started", callback),
		onRecordingStopped: (callback) =>
			ipcRenderer.on("recording-stopped", callback),
		onRecordingCompleted: (callback) =>
			ipcRenderer.on("recording-completed", callback),
		onTimeUpdate: (callback) =>
			ipcRenderer.on("recording-time-update", callback),

		// Remove listeners
		removeAllListeners: () => {
			ipcRenderer.removeAllListeners("recording-started");
			ipcRenderer.removeAllListeners("recording-stopped");
			ipcRenderer.removeAllListeners("recording-completed");
			ipcRenderer.removeAllListeners("recording-time-update");
		},
	},

	// Dialog API
	dialog: {
		showSaveDialog: () => ipcRenderer.invoke("dialog:showSaveDialog"),
	},
});

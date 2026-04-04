"use strict";

async function resolveCursorDisplayInfo(recorder, options) {
	if (options.videoRelative && options.displayInfo) {
		let videoOffsetX = 0;
		let videoOffsetY = 0;
		let videoWidth =
			options.displayInfo.width || options.displayInfo.logicalWidth;
		let videoHeight =
			options.displayInfo.height || options.displayInfo.logicalHeight;

		if (options.recordingType === "window" && options.windowId) {
			if (options.captureArea) {
				videoOffsetX = options.captureArea.x;
				videoOffsetY = options.captureArea.y;
				videoWidth = options.captureArea.width;
				videoHeight = options.captureArea.height;
			}
		} else if (options.recordingType === "area" && options.captureArea) {
			videoOffsetX = options.captureArea.x;
			videoOffsetY = options.captureArea.y;
			videoWidth = options.captureArea.width;
			videoHeight = options.captureArea.height;
		}

		recorder.cursorDisplayInfo = {
			displayId: options.displayInfo.displayId || options.displayInfo.id,
			displayX: options.displayInfo.x || 0,
			displayY: options.displayInfo.y || 0,
			displayWidth:
				options.displayInfo.width || options.displayInfo.logicalWidth,
			displayHeight:
				options.displayInfo.height || options.displayInfo.logicalHeight,
			videoOffsetX,
			videoOffsetY,
			videoWidth,
			videoHeight,
			videoRelative: true,
			recordingType: options.recordingType || "display",
			captureArea: options.captureArea,
			windowId: options.windowId,
			multiWindowBounds: options.multiWindowBounds || null,
		};
		return;
	}

	if (recorder.recordingDisplayInfo) {
		recorder.cursorDisplayInfo = {
			...recorder.recordingDisplayInfo,
			displayX: recorder.recordingDisplayInfo.x || 0,
			displayY: recorder.recordingDisplayInfo.y || 0,
			displayWidth:
				recorder.recordingDisplayInfo.width ||
				recorder.recordingDisplayInfo.logicalWidth,
			displayHeight:
				recorder.recordingDisplayInfo.height ||
				recorder.recordingDisplayInfo.logicalHeight,
			videoOffsetX: 0,
			videoOffsetY: 0,
			videoWidth:
				recorder.recordingDisplayInfo.width ||
				recorder.recordingDisplayInfo.logicalWidth,
			videoHeight:
				recorder.recordingDisplayInfo.height ||
				recorder.recordingDisplayInfo.logicalHeight,
			videoRelative: true,
			recordingType: options.recordingType || "display",
			multiWindowBounds: options.multiWindowBounds || null,
		};
		return;
	}

	try {
		const displays = await recorder.getDisplays();
		const mainDisplay =
			displays.find((d) => d.isPrimary) || displays[0];
		if (mainDisplay) {
			let w = mainDisplay.width;
			let h = mainDisplay.height;
			const res = mainDisplay.resolution;
			if ((w == null || h == null) && res) {
				const parts = String(res).split("x");
				if (w == null) {
					w = parseInt(parts[0], 10);
				}
				if (h == null) {
					h = parseInt(parts[1], 10);
				}
			}
			if (!Number.isFinite(w) || w <= 0) {
				w = 1920;
			}
			if (!Number.isFinite(h) || h <= 0) {
				h = 1080;
			}
			recorder.cursorDisplayInfo = {
				displayId: mainDisplay.id,
				x: mainDisplay.x,
				y: mainDisplay.y,
				width: w,
				height: h,
				multiWindowBounds: options.multiWindowBounds || null,
			};
		}
	} catch {
		recorder.cursorDisplayInfo = null;
	}
}

module.exports = { resolveCursorDisplayInfo };

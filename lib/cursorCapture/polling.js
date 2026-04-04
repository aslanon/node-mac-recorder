"use strict";

const fs = require("fs");
const { resolveCursorDisplayInfo } = require("./displayInfo");

const IS_ELECTRON = !!(
	process &&
	process.versions &&
	process.versions.electron
);

const TEXT_INPUT_SAMPLE_MS = IS_ELECTRON ? 280 : 95;

const TEXT_INPUT_GRACE_MS = IS_ELECTRON ? 3200 : 600;

function shouldCaptureCursorSample(lastCapturedData, currentData) {
	if (!lastCapturedData) {
		return true;
	}
	const last = lastCapturedData;
	if (currentData.type !== last.type) {
		return true;
	}
	if (
		Math.abs(currentData.x - last.x) >= 2 ||
		Math.abs(currentData.y - last.y) >= 2
	) {
		return true;
	}
	if (currentData.cursorType !== last.cursorType) {
		return true;
	}
	return false;
}

function transformGlobalToVideo(globalX, globalY, d) {
	if (!d || !d.videoRelative) {
		return {
			x: globalX,
			y: globalY,
			coordinateSystem: "global",
			outsideVideo: false,
		};
	}
	const displayRelativeX = globalX - d.displayX;
	const displayRelativeY = globalY - d.displayY;
	const x = displayRelativeX - d.videoOffsetX;
	const y = displayRelativeY - d.videoOffsetY;
	const outsideVideo =
		x < 0 ||
		y < 0 ||
		x >= d.videoWidth ||
		y >= d.videoHeight;
	return {
		x,
		y,
		coordinateSystem: outsideVideo
			? "video-relative-outside"
			: "video-relative",
		outsideVideo,
	};
}

function transformInputFrameGlobal(ifr, d) {
	if (!ifr || typeof ifr !== "object") {
		return {};
	}
	const ox = Number(ifr.x);
	const oy = Number(ifr.y);
	const tw = transformGlobalToVideo(ox, oy, d);
	return {
		x: tw.x,
		y: tw.y,
		width: Number(ifr.width) || 0,
		height: Number(ifr.height) || 0,
	};
}

function tryAppendTextInput(
	recorder,
	nativeBinding,
	filepath,
	position,
	timestamp,
) {
	if (typeof nativeBinding.getTextInputSnapshot !== "function") {
		return;
	}
	if (timestamp < TEXT_INPUT_GRACE_MS) {
		return;
	}
	const ct = position.cursorType || "";
	if (ct !== "text" && ct !== "vertical-text") {
		return;
	}
	const wall = Date.now();
	if (wall - (recorder._tiSampleWallMs || 0) < TEXT_INPUT_SAMPLE_MS) {
		return;
	}
	recorder._tiSampleWallMs = wall;

	let snap = null;
	try {
		snap = nativeBinding.getTextInputSnapshot();
	} catch {
		return;
	}
	if (
		!snap ||
		!Number.isFinite(snap.caretX) ||
		!Number.isFinite(snap.caretY)
	) {
		return;
	}

	const d = recorder.cursorDisplayInfo;
	const caretT = transformGlobalToVideo(snap.caretX, snap.caretY, d);
	const mouseGX = position.x;
	const mouseGY = position.y;
	const mouseT = transformGlobalToVideo(mouseGX, mouseGY, d);

	const inputFrameVid = transformInputFrameGlobal(snap.inputFrame, d);

	const tiRow = {
		x: mouseT.x,
		y: mouseT.y,
		timestamp,
		unixTimeMs: wall,
		cursorType: "text",
		type: "textInput",
		caretX: caretT.x,
		caretY: caretT.y,
		inputFrame: inputFrameVid,
		coordinateSystem: caretT.coordinateSystem,
		recordingType: d?.recordingType || "display",
		videoInfo: d
			? {
					width: d.videoWidth,
					height: d.videoHeight,
					offsetX: d.videoOffsetX,
					offsetY: d.videoOffsetY,
				}
			: {},
		displayInfo: d
			? {
					displayId: d.displayId,
					width: d.displayWidth,
					height: d.displayHeight,
				}
			: {},
	};

	if (
		recorder.cursorCaptureFirstWrite &&
		recorder.cursorCaptureSessionTimestamp
	) {
		tiRow._syncMetadata = {
			videoStartTime: recorder.cursorCaptureSessionTimestamp,
			cursorStartTime: recorder.cursorCaptureStartTime,
			offsetMs:
				recorder.cursorCaptureStartTime -
				recorder.cursorCaptureSessionTimestamp,
		};
	}

	const le = recorder._lastTextInputEmitted;
	if (
		le &&
		Math.abs(le.caretX - tiRow.caretX) < 0.75 &&
		Math.abs(le.caretY - tiRow.caretY) < 0.75 &&
		timestamp - le.timestamp < 220
	) {
		return;
	}
	recorder._lastTextInputEmitted = {
		caretX: tiRow.caretX,
		caretY: tiRow.caretY,
		timestamp,
	};

	const jsonString = JSON.stringify(tiRow);
	if (recorder.cursorCaptureFirstWrite) {
		fs.appendFileSync(filepath, jsonString);
		recorder.cursorCaptureFirstWrite = false;
	} else {
		fs.appendFileSync(filepath, "," + jsonString);
	}
}

function queueDeferredTextInputSample(
	recorder,
	nativeBinding,
	filepath,
	position,
	timestamp,
) {
	if (typeof nativeBinding.getTextInputSnapshot !== "function") {
		return;
	}
	if (timestamp < TEXT_INPUT_GRACE_MS) {
		return;
	}
	const ct = position.cursorType || "";
	if (ct !== "text" && ct !== "vertical-text") {
		return;
	}
	if (recorder._tiDeferredPending) {
		return;
	}
	recorder._tiDeferredPending = true;
	const pos = {
		x: position.x,
		y: position.y,
		cursorType: position.cursorType,
		eventType: position.eventType,
	};
	const ts = timestamp;
	setImmediate(() => {
		recorder._tiDeferredPending = false;
		if (!recorder.cursorCaptureFile || recorder.cursorCaptureFile !== filepath) {
			return;
		}
		try {
			tryAppendTextInput(recorder, nativeBinding, filepath, pos, ts);
		} catch {
			/* ignore */
		}
	});
}

async function startCursorCapture(recorder, nativeBinding, intervalOrFilepath, options = {}) {
	let filepath;
	let interval = 20;

	if (typeof intervalOrFilepath === "number") {
		interval = Math.max(10, intervalOrFilepath);
		filepath = `cursor-data-${Date.now()}.json`;
	} else if (typeof intervalOrFilepath === "string") {
		filepath = intervalOrFilepath;
	} else {
		throw new Error("Parameter must be interval (number) or filepath (string)");
	}

	if (recorder.cursorCaptureInterval) {
		throw new Error("Cursor capture is already running");
	}

	const syncStartTime = options.startTimestamp || Date.now();

	if (options.multiWindowBounds && options.multiWindowBounds.length > 0) {
		try {
			const allWindows = await recorder.getWindows();
			for (const windowInfo of options.multiWindowBounds) {
				const windowData = allWindows.find(
					(w) => w.id === windowInfo.windowId,
				);
				if (windowData) {
					windowInfo.bounds = {
						x: windowData.x || 0,
						y: windowData.y || 0,
						width: windowData.width || 0,
						height: windowData.height || 0,
					};
				}
			}
		} catch (error) {
			console.warn(
				"Failed to fetch window bounds for multi-window cursor tracking:",
				error.message,
			);
		}
	}

	await resolveCursorDisplayInfo(recorder, options);

	return new Promise((resolve, reject) => {
		try {
			fs.writeFileSync(filepath, "[");

			recorder.cursorCaptureFile = filepath;
			recorder.cursorCaptureStartTime = syncStartTime;
			recorder.cursorCaptureFirstWrite = true;
			recorder.lastCapturedData = null;
			recorder.cursorCaptureSessionTimestamp = recorder.sessionTimestamp;
			recorder._tiSampleWallMs = 0;
			recorder._lastTextInputEmitted = null;
			recorder._tiDeferredPending = false;

			recorder.cursorCaptureInterval = setInterval(() => {
				try {
					const position = nativeBinding.getCursorPosition();
					const timestamp =
						Date.now() - recorder.cursorCaptureStartTime;

					let x = position.x;
					let y = position.y;
					let coordinateSystem = "global";

					const di = recorder.cursorDisplayInfo;
					if (di && di.videoRelative) {
						const displayRelativeX = position.x - di.displayX;
						const displayRelativeY = position.y - di.displayY;
						x = displayRelativeX - di.videoOffsetX;
						y = displayRelativeY - di.videoOffsetY;
						coordinateSystem = "video-relative";
						const outsideVideo =
							x < 0 ||
							y < 0 ||
							x >= di.videoWidth ||
							y >= di.videoHeight;
						if (outsideVideo) {
							coordinateSystem = "video-relative-outside";
						}
					}

					const cursorData = {
						x,
						y,
						timestamp,
						unixTimeMs: Date.now(),
						cursorType: position.cursorType,
						type: position.eventType || "move",
						coordinateSystem,
						recordingType: di?.recordingType || "display",
						videoInfo: di
							? {
									width: di.videoWidth,
									height: di.videoHeight,
									offsetX: di.videoOffsetX,
									offsetY: di.videoOffsetY,
								}
							: {},
						displayInfo: di
							? {
									displayId: di.displayId,
									width: di.displayWidth,
									height: di.displayHeight,
								}
							: {},
					};

					if (di?.multiWindowBounds && di.multiWindowBounds.length > 0) {
						const location = { hover: null, click: null };
						let windowRelativeCoords = null;
						for (const windowInfo of di.multiWindowBounds) {
							if (windowInfo.bounds) {
								const { x: wx, y: wy, width: ww, height: wh } =
									windowInfo.bounds;
								if (
									position.x >= wx &&
									position.x <= wx + ww &&
									position.y >= wy &&
									position.y <= wy + wh
								) {
									location.hover = windowInfo.windowId;
									windowRelativeCoords = {
										windowId: windowInfo.windowId,
										x: position.x - wx,
										y: position.y - wy,
										windowWidth: ww,
										windowHeight: wh,
									};
									const eventType = position.eventType || "";
									if (
										eventType === "mousedown" ||
										eventType === "mouseup" ||
										eventType === "drag" ||
										eventType === "rightmousedown" ||
										eventType === "rightmouseup" ||
										eventType === "rightdrag"
									) {
										location.click = windowInfo.windowId;
									}
									break;
								}
							}
						}
						cursorData.location = location;
						if (windowRelativeCoords) {
							cursorData.windowRelative = windowRelativeCoords;
						}
					}

					if (
						recorder.cursorCaptureFirstWrite &&
						recorder.cursorCaptureSessionTimestamp
					) {
						cursorData._syncMetadata = {
							videoStartTime: recorder.cursorCaptureSessionTimestamp,
							cursorStartTime: recorder.cursorCaptureStartTime,
							offsetMs:
								recorder.cursorCaptureStartTime -
								recorder.cursorCaptureSessionTimestamp,
						};
					}

					if (shouldCaptureCursorSample(recorder.lastCapturedData, cursorData)) {
						const jsonString = JSON.stringify(cursorData);
						if (recorder.cursorCaptureFirstWrite) {
							fs.appendFileSync(filepath, jsonString);
							recorder.cursorCaptureFirstWrite = false;
						} else {
							fs.appendFileSync(filepath, "," + jsonString);
						}
						recorder.lastCapturedData = { ...cursorData };
					}

					queueDeferredTextInputSample(
						recorder,
						nativeBinding,
						filepath,
						position,
						timestamp,
					);
				} catch (error) {
					console.error("Cursor capture error:", error);
				}
			}, interval);

			recorder.emit("cursorCaptureStarted", filepath);
			resolve(true);
		} catch (error) {
			reject(error);
		}
	});
}

async function stopCursorCapture(recorder) {
	return new Promise((resolve, reject) => {
		try {
			if (!recorder.cursorCaptureInterval) {
				return resolve(false);
			}
			clearInterval(recorder.cursorCaptureInterval);
			recorder.cursorCaptureInterval = null;

			if (recorder.cursorCaptureFile) {
				fs.appendFileSync(recorder.cursorCaptureFile, "]");
				recorder.cursorCaptureFile = null;
			}

			recorder.lastCapturedData = null;
			recorder.cursorCaptureStartTime = null;
			recorder.cursorCaptureFirstWrite = true;
			recorder.cursorDisplayInfo = null;
			recorder._tiSampleWallMs = 0;
			recorder._lastTextInputEmitted = null;
			recorder._tiDeferredPending = false;

			recorder.emit("cursorCaptureStopped");
			resolve(true);
		} catch (error) {
			reject(error);
		}
	});
}

module.exports = {
	startCursorCapture,
	stopCursorCapture,
	shouldCaptureCursorSample,
};

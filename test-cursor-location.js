/**
 * Test cursor location detection in multi-window setup
 */

const MacRecorder = require('./index');
const path = require('path');
const fs = require('fs');

async function testCursorLocation() {
    console.log('🧪 Testing Cursor Location Detection\n');

    const recorder = new MacRecorder();

    // Get available windows
    const windows = await recorder.getWindows();
    console.log(`📋 Found ${windows.length} windows:\n`);

    windows.slice(0, 5).forEach((win, i) => {
        console.log(`${i + 1}. ${win.appName} - "${win.title}"`);
        console.log(`   Bounds: x=${win.x}, y=${win.y}, w=${win.width}, h=${win.height}`);
    });

    if (windows.length < 2) {
        console.error('\n❌ Need at least 2 windows for this test');
        process.exit(1);
    }

    // Use first two valid windows
    const validWindows = windows.filter(w =>
        w.appName !== 'Dock' && w.width > 100 && w.height > 100
    );

    const window1 = validWindows[0];
    const window2 = validWindows[1];

    console.log(`\n🎯 Testing with these windows:`);
    console.log(`1. ${window1.appName} (ID: ${window1.id})`);
    console.log(`   Bounds: x=${window1.x}, y=${window1.y}, w=${window1.width}, h=${window1.height}`);
    console.log(`2. ${window2.appName} (ID: ${window2.id})`);
    console.log(`   Bounds: x=${window2.x}, y=${window2.y}, w=${window2.width}, h=${window2.height}`);

    console.log(`\n📍 Move cursor over different windows and click...`);
    console.log(`⏱️  Monitoring for 10 seconds...\n`);

    const multiWindowBounds = [
        {
            windowId: window1.id,
            appName: window1.appName,
            bounds: {
                x: window1.x,
                y: window1.y,
                width: window1.width,
                height: window1.height
            }
        },
        {
            windowId: window2.id,
            appName: window2.appName,
            bounds: {
                x: window2.x,
                y: window2.y,
                width: window2.width,
                height: window2.height
            }
        }
    ];

    let lastLocation = null;
    let count = 0;

    const interval = setInterval(() => {
        const pos = recorder.getCursorPosition();

        // Detect location
        const location = { hover: null, click: null };

        for (const windowInfo of multiWindowBounds) {
            const { x: wx, y: wy, width: ww, height: wh } = windowInfo.bounds;
            if (pos.x >= wx && pos.x <= wx + ww &&
                pos.y >= wy && pos.y <= wy + wh) {
                location.hover = windowInfo.windowId;

                if (pos.eventType === 'mousedown' || pos.eventType === 'mouseup') {
                    location.click = windowInfo.windowId;
                }
                break;
            }
        }

        // Always log if there's an event (not just move) or location changed
        const locationChanged = JSON.stringify(location) !== JSON.stringify(lastLocation);
        const isClick = pos.eventType === 'mousedown' || pos.eventType === 'mouseup' ||
                       pos.eventType === 'rightmousedown' || pos.eventType === 'rightmouseup';
        const isEvent = pos.eventType !== 'move';

        if (locationChanged || isClick || isEvent) {
            const windowName = location.hover
                ? multiWindowBounds.find(w => w.windowId === location.hover)?.appName
                : 'None';

            console.log(`[${count}] x:${pos.x}, y:${pos.y}, type:${pos.eventType}, window:${windowName} (ID:${location.hover})`);

            if (location.click) {
                const clickWindowName = multiWindowBounds.find(w => w.windowId === location.click)?.appName;
                console.log(`       🖱️  CLICK on ${clickWindowName} (ID:${location.click})`);
            }

            lastLocation = location;
        }

        count++;
        if (count >= 100) { // 10 seconds
            clearInterval(interval);
            console.log('\n✅ Test completed!');
            process.exit(0);
        }
    }, 100);
}

testCursorLocation().catch(error => {
    console.error('❌ Test failed:', error);
    process.exit(1);
});

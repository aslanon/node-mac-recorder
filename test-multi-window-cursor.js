const MacRecorder = require('./index.js');
const path = require('path');
const fs = require('fs');

async function testMultiWindowCursor() {
    const recorder = new MacRecorder();

    console.log('🎯 Testing Multi-Window Cursor with Window-Relative Coordinates\n');

    try {
        // Get windows
        const windows = await recorder.getWindows();
        console.log('🪟 Available windows:');
        windows.slice(0, 10).forEach((win, idx) => {
            console.log(`  ${idx}: ${win.appName} - "${win.name}" (${win.width}x${win.height}) at (${win.x}, ${win.y})`);
        });

        // Select 2 windows for testing
        console.log('\n📝 Please select 2 windows by their index (e.g., "0,3"):');
        console.log('   (For testing, we\'ll use windows 0 and 1 automatically)\n');

        // For demo, use first 2 windows
        const selectedIndices = [0, 1];
        const selectedWindows = selectedIndices.map(idx => windows[idx]).filter(Boolean);

        if (selectedWindows.length < 2) {
            console.log('❌ Need at least 2 windows for multi-window test');
            return;
        }

        console.log('✅ Selected windows:');
        selectedWindows.forEach(win => {
            console.log(`   - ${win.appName}: "${win.name}" (ID: ${win.id})`);
            console.log(`     Position: (${win.x}, ${win.y}), Size: ${win.width}x${win.height}`);
        });

        // Prepare multiWindowBounds
        const multiWindowBounds = selectedWindows.map(win => ({
            windowId: win.id,
            // bounds will be populated by startCursorCapture
        }));

        // Output paths
        const timestamp = Date.now();
        const cursorFile = path.join(__dirname, 'test-output', `multi-window-cursor-${timestamp}.json`);

        console.log('\n🎬 Starting cursor capture with multi-window tracking...');

        // Start cursor capture with multiWindowBounds
        await recorder.startCursorCapture(cursorFile, {
            multiWindowBounds: multiWindowBounds,
            startTimestamp: timestamp
        });

        console.log('✅ Cursor capture started');
        console.log('📍 Move your cursor over the selected windows and click');
        console.log('⏱️ Recording for 10 seconds...\n');

        // Record for 10 seconds
        await new Promise(resolve => setTimeout(resolve, 10000));

        console.log('🛑 Stopping cursor capture...');
        await recorder.stopCursorCapture();

        console.log('\n✅ Cursor data saved to:', cursorFile);

        // Analyze the cursor data
        console.log('\n🔍 Analyzing cursor data...');
        const cursorData = JSON.parse(fs.readFileSync(cursorFile, 'utf8'));

        const eventsWithWindowRelative = cursorData.filter(e => e.windowRelative);
        const windowHovers = new Map();

        cursorData.forEach(event => {
            if (event.location && event.location.hover) {
                const windowId = event.location.hover;
                windowHovers.set(windowId, (windowHovers.get(windowId) || 0) + 1);
            }
        });

        console.log(`   Total cursor events: ${cursorData.length}`);
        console.log(`   Events with window-relative coords: ${eventsWithWindowRelative.length}`);
        console.log('   Window hover counts:');
        for (const [windowId, count] of windowHovers) {
            const win = selectedWindows.find(w => w.id === windowId);
            console.log(`     - Window ${windowId} (${win?.appName || 'Unknown'}): ${count} events`);
        }

        // Show example of window-relative data
        if (eventsWithWindowRelative.length > 0) {
            console.log('\n📊 Example cursor event with window-relative coords:');
            const example = eventsWithWindowRelative[0];
            console.log(JSON.stringify({
                timestamp: example.timestamp,
                globalCoords: { x: example.x, y: example.y },
                coordinateSystem: example.coordinateSystem,
                location: example.location,
                windowRelative: example.windowRelative,
                cursorType: example.cursorType,
                type: example.type
            }, null, 2));

            console.log('\n✨ HOW TO USE IN DESKTOP APP:');
            console.log('   1. Read windowRelative.windowId to know which window cursor is over');
            console.log('   2. Use windowRelative.x and windowRelative.y as coords relative to window top-left (0,0)');
            console.log('   3. Position cursor on canvas: canvasWindowX + windowRelative.x, canvasWindowY + windowRelative.y');
            console.log('   4. This works regardless of where you position the window on canvas!');
            console.log('\n   Example:');
            console.log('     // Window positioned at (100, 200) on canvas');
            console.log('     const cursorX = 100 + event.windowRelative.x;');
            console.log('     const cursorY = 200 + event.windowRelative.y;');
            console.log('     ctx.drawCursor(cursorX, cursorY, event.cursorType);');
        } else {
            console.log('\n⚠️ No cursor events with window-relative coords detected');
            console.log('   Make sure to move cursor over the selected windows during recording');
        }

        console.log('\n✅ Test completed successfully!');

    } catch (error) {
        console.error('❌ Test failed:', error.message);
        console.error(error.stack);
    }
}

testMultiWindowCursor().catch(console.error);

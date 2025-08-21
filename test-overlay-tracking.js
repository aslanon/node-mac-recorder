#!/usr/bin/env node

/**
 * Test script to analyze overlay tracking issues during window movement
 */

const WindowSelector = require('./window-selector');

async function testOverlayTracking() {
    console.log('🔬 OVERLAY TRACKING ANALYSIS');
    console.log('=============================\n');

    const selector = new WindowSelector();

    try {
        // Track mouse vs overlay position data
        let mousePositions = [];
        let overlayUpdates = [];
        let windowMovements = [];
        
        selector.on('windowEntered', (window) => {
            const timestamp = Date.now();
            overlayUpdates.push({
                timestamp,
                type: 'entered',
                window: {
                    id: window.id,
                    title: window.title,
                    appName: window.appName,
                    x: window.x,
                    y: window.y,
                    width: window.width,
                    height: window.height
                }
            });
            
            console.log(`🏠 [${new Date(timestamp).toISOString().substr(11,12)}] ENTERED: "${window.title}" at (${window.x}, ${window.y}) ${window.width}×${window.height}`);
        });

        selector.on('windowLeft', (window) => {
            const timestamp = Date.now();
            overlayUpdates.push({
                timestamp,
                type: 'left',
                window: {
                    id: window.id,
                    title: window.title,
                    x: window.x,
                    y: window.y
                }
            });
            
            console.log(`🚪 [${new Date(timestamp).toISOString().substr(11,12)}] LEFT: "${window.title}" from (${window.x}, ${window.y})`);
        });

        console.log('🎯 Starting window selection...');
        console.log('📍 Move your cursor over windows and drag them around');
        console.log('⏰ Test will run for 30 seconds\n');

        await selector.startSelection();
        
        // Periodically log mouse position and compare with overlay state
        const trackingInterval = setInterval(async () => {
            try {
                const status = selector.getStatus();
                const timestamp = Date.now();
                
                if (status.nativeStatus?.currentWindow) {
                    const window = status.nativeStatus.currentWindow;
                    mousePositions.push({
                        timestamp,
                        windowId: window.id,
                        windowPos: { x: window.x, y: window.y },
                        windowSize: { width: window.width, height: window.height }
                    });
                    
                    // Check for window movement by comparing with previous position
                    const prevPos = mousePositions.find(p => 
                        p.windowId === window.id && 
                        p.timestamp < timestamp - 100 && // at least 100ms ago
                        (p.windowPos.x !== window.x || p.windowPos.y !== window.y)
                    );
                    
                    if (prevPos) {
                        windowMovements.push({
                            timestamp,
                            windowId: window.id,
                            title: window.title,
                            from: prevPos.windowPos,
                            to: { x: window.x, y: window.y },
                            deltaX: window.x - prevPos.windowPos.x,
                            deltaY: window.y - prevPos.windowPos.y
                        });
                        
                        console.log(`📍 [${new Date(timestamp).toISOString().substr(11,12)}] MOVED: "${window.title}" (${prevPos.windowPos.x}, ${prevPos.windowPos.y}) → (${window.x}, ${window.y}) Δ(${window.x - prevPos.windowPos.x}, ${window.y - prevPos.windowPos.y})`);
                    }
                }
            } catch (err) {
                // Ignore errors during status check
            }
        }, 50); // Check every 50ms for high resolution tracking

        // Run test for 30 seconds
        await new Promise(resolve => setTimeout(resolve, 30000));
        
        clearInterval(trackingInterval);
        console.log('\n⏹️  Test completed. Analyzing data...\n');

        // Analysis
        console.log('📊 ANALYSIS RESULTS:');
        console.log('====================\n');
        
        console.log(`📝 Total overlay updates: ${overlayUpdates.length}`);
        console.log(`📝 Total mouse position samples: ${mousePositions.length}`);
        console.log(`📝 Detected window movements: ${windowMovements.length}\n`);

        // Analyze window movement patterns
        if (windowMovements.length > 0) {
            console.log('🔍 WINDOW MOVEMENT PATTERNS:');
            
            const movementsByWindow = {};
            windowMovements.forEach(move => {
                if (!movementsByWindow[move.windowId]) {
                    movementsByWindow[move.windowId] = [];
                }
                movementsByWindow[move.windowId].push(move);
            });
            
            for (const [windowId, moves] of Object.entries(movementsByWindow)) {
                const firstMove = moves[0];
                const lastMove = moves[moves.length - 1];
                const totalDeltaX = Math.abs(lastMove.to.x - firstMove.from.x);
                const totalDeltaY = Math.abs(lastMove.to.y - firstMove.from.y);
                const duration = lastMove.timestamp - firstMove.timestamp;
                
                console.log(`   Window "${firstMove.title}" (ID: ${windowId}):`);
                console.log(`     Movements: ${moves.length}`);
                console.log(`     Total displacement: (${totalDeltaX}, ${totalDeltaY}) pixels`);
                console.log(`     Duration: ${duration}ms`);
                console.log(`     Average speed: ${(Math.sqrt(totalDeltaX*totalDeltaX + totalDeltaY*totalDeltaY) / (duration/1000)).toFixed(1)} px/sec\n`);
            }
        }
        
        // Analyze update frequency
        if (overlayUpdates.length > 1) {
            console.log('⏱️  OVERLAY UPDATE TIMING:');
            const intervals = [];
            for (let i = 1; i < overlayUpdates.length; i++) {
                intervals.push(overlayUpdates[i].timestamp - overlayUpdates[i-1].timestamp);
            }
            
            if (intervals.length > 0) {
                const avgInterval = intervals.reduce((a, b) => a + b, 0) / intervals.length;
                const minInterval = Math.min(...intervals);
                const maxInterval = Math.max(...intervals);
                
                console.log(`     Average update interval: ${avgInterval.toFixed(1)}ms (${(1000/avgInterval).toFixed(1)} FPS)`);
                console.log(`     Min interval: ${minInterval}ms`);
                console.log(`     Max interval: ${maxInterval}ms\n`);
            }
        }

    } catch (error) {
        console.error('❌ Test failed:', error.message);
    } finally {
        console.log('🛑 Cleaning up...');
        await selector.cleanup();
    }
}

if (require.main === module) {
    testOverlayTracking().catch(console.error);
}

module.exports = testOverlayTracking;
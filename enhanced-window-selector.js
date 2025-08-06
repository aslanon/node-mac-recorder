#!/usr/bin/env node

const WindowSelector = require('./window-selector');

async function enhancedWindowSelector() {
    console.log('🎯 Enhanced Window Selector');
    console.log('===========================\n');

    const selector = new WindowSelector();

    try {
        // İzinleri kontrol et
        const permissions = await selector.checkPermissions();
        console.log('🔐 Permissions:');
        console.log(`   Screen Recording: ${permissions.screenRecording ? '✅' : '❌'}`);
        console.log(`   Accessibility: ${permissions.accessibility ? '✅' : '❌'}`);
        console.log(`   Microphone: ${permissions.microphone ? '✅' : '❌'}\n`);

        let currentWindow = null;
        let windowHistory = [];

        // Event listeners with detailed output
        selector.on('windowEntered', (window) => {
            currentWindow = window;
            windowHistory.push({
                action: 'entered',
                timestamp: new Date().toLocaleTimeString(),
                window: window
            });

            // Clear console (optional - comment out if you want to keep history)
            // console.clear();
            
            console.log('\n' + '='.repeat(80));
            console.log('🏠 WINDOW ENTERED');
            console.log('='.repeat(80));
            
            displayWindowInfo(window);
            
            console.log('\n💡 Controls:');
            console.log('   • Press ENTER to select this window');
            console.log('   • Move cursor to another window to switch');
            console.log('   • Press Ctrl+C to exit');
        });

        selector.on('windowLeft', (window) => {
            windowHistory.push({
                action: 'left',
                timestamp: new Date().toLocaleTimeString(),
                window: window
            });

            console.log('\n🚪 LEFT WINDOW: ' + getWindowLabel(window));
            currentWindow = null;
        });

        selector.on('windowSelected', (selectedWindow) => {
            console.log('\n' + '🎉'.repeat(20));
            console.log('🎯 WINDOW SELECTED!');
            console.log('🎉'.repeat(20));
            
            displayWindowInfo(selectedWindow, true);
            
            // Show usage statistics
            console.log('\n📊 Session Statistics:');
            console.log(`   Total windows explored: ${new Set(windowHistory.map(h => h.window.id)).size}`);
            console.log(`   Total interactions: ${windowHistory.length}`);
            
            process.exit(0);
        });

        // Manual selection with ENTER key
        const readline = require('readline');
        const rl = readline.createInterface({
            input: process.stdin,
            output: process.stdout
        });

        rl.on('line', () => {
            if (currentWindow) {
                selector.emit('windowSelected', currentWindow);
            } else {
                console.log('\n⚠️  No window under cursor. Move cursor over a window first.');
            }
        });

        // Start selection
        console.log('🚀 Starting enhanced window selection...\n');
        console.log('📋 Instructions:');
        console.log('   1. Move your cursor over different windows');
        console.log('   2. Watch the detailed window information appear');
        console.log('   3. Press ENTER when you want to select the current window');
        console.log('   4. The overlay should highlight windows (may not be visible due to macOS security)\n');

        await selector.startSelection();

        // Detailed status monitoring
        let statusCount = 0;
        const statusInterval = setInterval(() => {
            const status = selector.getStatus();
            statusCount++;
            
            // Show periodic status
            if (statusCount % 40 === 0) { // Every 20 seconds
                console.log(`\n⏱️  Status Update (${statusCount/2}s):`);
                console.log(`   Windows available: ${status.nativeStatus?.windowCount || 0}`);
                console.log(`   Selection active: ${status.isSelecting ? '✅' : '❌'}`);
                console.log(`   Overlay present: ${status.nativeStatus?.hasOverlay ? '✅' : '❌'}`);
                if (currentWindow) {
                    console.log(`   Current focus: ${getWindowLabel(currentWindow)}`);
                }
                console.log('   (Move cursor over windows to see details)\n');
            }
        }, 500);

        // Graceful shutdown
        process.on('SIGINT', async () => {
            clearInterval(statusInterval);
            rl.close();
            
            console.log('\n\n🛑 Shutting down...');
            
            if (windowHistory.length > 0) {
                console.log('\n📈 Session Summary:');
                const uniqueApps = [...new Set(windowHistory.map(h => h.window.appName))];
                console.log(`   Apps explored: ${uniqueApps.join(', ')}`);
                console.log(`   Total windows: ${new Set(windowHistory.map(h => h.window.id)).size}`);
            }
            
            await selector.cleanup();
            console.log('✅ Cleanup completed');
            process.exit(0);
        });

    } catch (error) {
        console.error('\n❌ Error:', error.message);
        process.exit(1);
    }
}

function displayWindowInfo(window, isSelected = false) {
    const prefix = isSelected ? '🎯' : '📱';
    
    console.log(`\n${prefix} Application: ${window.appName}`);
    console.log(`📄 Title: "${window.title}"`);
    console.log(`🆔 Window ID: ${window.id}`);
    
    console.log(`\n📍 Position & Size:`);
    console.log(`   Global Position: (${window.x}, ${window.y})`);
    console.log(`   Dimensions: ${window.width} × ${window.height} pixels`);
    console.log(`   Total Area: ${(window.width * window.height).toLocaleString()} pixels`);
    console.log(`   Aspect Ratio: ${(window.width / window.height).toFixed(2)}`);
    
    if (window.screenId !== undefined) {
        console.log(`\n🖥️  Screen Information:`);
        console.log(`   Screen ID: ${window.screenId}`);
        if (window.screenX !== undefined && window.screenY !== undefined) {
            console.log(`   Screen Origin: (${window.screenX}, ${window.screenY})`);
            console.log(`   Screen Size: ${window.screenWidth} × ${window.screenHeight}`);
            
            // Calculate relative position
            const relativeX = window.x - window.screenX;
            const relativeY = window.y - window.screenY;
            console.log(`   Relative Position: (${relativeX}, ${relativeY})`);
            
            // Screen coverage
            const screenArea = window.screenWidth * window.screenHeight;
            const windowArea = window.width * window.height;
            const coverage = ((windowArea / screenArea) * 100).toFixed(1);
            console.log(`   Screen Coverage: ${coverage}%`);
        }
    }
    
    // Position analysis
    console.log(`\n📐 Analysis:`);
    if (window.width > 1000 && window.height > 600) {
        console.log('   📺 Large window - Good for detailed content');
    } else if (window.width > 500 && window.height > 300) {
        console.log('   📄 Medium window - Standard size');
    } else {
        console.log('   📝 Small window - Compact application');
    }
    
    const aspectRatio = window.width / window.height;
    if (Math.abs(aspectRatio - 16/9) < 0.1) {
        console.log('   🎬 16:9 aspect ratio - Video optimized');
    } else if (aspectRatio > 2) {
        console.log('   📱 Wide window - Good for dashboards');
    } else if (aspectRatio < 1) {
        console.log('   📋 Tall window - Document/chat style');
    }
    
    console.log(`\n⏰ Detected at: ${new Date().toLocaleTimeString()}`);
}

function getWindowLabel(window) {
    return `${window.appName} - "${window.title}"`;
}

if (require.main === module) {
    enhancedWindowSelector();
}
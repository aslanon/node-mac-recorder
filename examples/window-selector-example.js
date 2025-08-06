#!/usr/bin/env node

const WindowSelector = require('../window-selector');

async function simpleExample() {
    console.log('🔍 Simple Window Selection Example');
    console.log('===================================\n');

    const selector = new WindowSelector();

    try {
        // Basit pencere seçimi
        console.log('Click on any window to select it...\n');
        const selectedWindow = await selector.selectWindow();
        
        console.log('Selected window:', {
            title: selectedWindow.title,
            app: selectedWindow.appName,
            position: `(${selectedWindow.x}, ${selectedWindow.y})`,
            size: `${selectedWindow.width}x${selectedWindow.height}`
        });

        return selectedWindow;

    } catch (error) {
        console.error('Error:', error.message);
        throw error;
    } finally {
        await selector.cleanup();
    }
}

async function advancedExample() {
    console.log('🎯 Advanced Window Selection with Events');
    console.log('=========================================\n');

    const selector = new WindowSelector();

    return new Promise(async (resolve, reject) => {
        try {
            // Event listener'ları ayarla
            selector.on('windowEntered', (window) => {
                console.log(`🏠 Hovering over: "${window.title}" (${window.appName})`);
            });

            selector.on('windowLeft', (window) => {
                console.log(`🚪 Left: "${window.title}"`);
            });

            selector.on('windowSelected', (window) => {
                console.log(`\n✅ Selected: "${window.title}" from ${window.appName}`);
                console.log(`📍 Position: (${window.x}, ${window.y})`);
                console.log(`📏 Size: ${window.width} x ${window.height}`);
                console.log(`🖥️ Screen: ${window.screenId} at (${window.screenX}, ${window.screenY})`);
                resolve(window);
            });

            selector.on('error', (error) => {
                console.error('❌ Selection error:', error.message);
                reject(error);
            });

            // Cancel handler
            process.on('SIGINT', async () => {
                console.log('\n🛑 Cancelled by user');
                await selector.cleanup();
                process.exit(0);
            });

            console.log('Move cursor over windows to see them highlighted');
            console.log('Click "Select Window" to choose one');
            console.log('Press Ctrl+C to cancel\n');

            await selector.startSelection();

        } catch (error) {
            reject(error);
        }
    });
}

async function multipleSelectionExample() {
    console.log('🔄 Multiple Window Selection Example');
    console.log('=====================================\n');

    const selector = new WindowSelector();
    const selectedWindows = [];

    try {
        for (let i = 1; i <= 3; i++) {
            console.log(`\n🎯 Selection ${i}/3:`);
            console.log('Select a window...\n');

            const window = await selector.selectWindow();
            selectedWindows.push({
                selection: i,
                title: window.title,
                app: window.appName,
                position: { x: window.x, y: window.y },
                size: { width: window.width, height: window.height },
                screen: window.screenId
            });

            console.log(`✅ Selection ${i} complete: "${window.title}"`);
        }

        console.log('\n📋 Summary of selected windows:');
        selectedWindows.forEach((win, index) => {
            console.log(`${index + 1}. "${win.title}" (${win.app}) - ${win.size.width}x${win.size.height}`);
        });

        return selectedWindows;

    } catch (error) {
        console.error('Error during multiple selection:', error.message);
        throw error;
    } finally {
        await selector.cleanup();
    }
}

async function windowAnalysisExample() {
    console.log('📊 Window Analysis Example');
    console.log('===========================\n');

    const selector = new WindowSelector();

    try {
        const window = await selector.selectWindow();
        
        console.log('🔍 Detailed Window Analysis:');
        console.log('============================');
        
        // Basic info
        console.log(`📱 Application: ${window.appName}`);
        console.log(`🏷️ Title: "${window.title}"`);
        console.log(`🆔 Window ID: ${window.id}`);
        
        // Position & Size
        console.log(`\n📍 Position & Dimensions:`);
        console.log(`   Global position: (${window.x}, ${window.y})`);
        console.log(`   Size: ${window.width} x ${window.height}`);
        console.log(`   Area: ${window.width * window.height} pixels`);
        console.log(`   Aspect ratio: ${(window.width / window.height).toFixed(2)}`);
        
        // Screen info
        console.log(`\n🖥️ Screen Information:`);
        console.log(`   Screen ID: ${window.screenId}`);
        console.log(`   Screen origin: (${window.screenX}, ${window.screenY})`);
        console.log(`   Screen size: ${window.screenWidth} x ${window.screenHeight}`);
        
        // Relative position on screen
        const relativeX = window.x - window.screenX;
        const relativeY = window.y - window.screenY;
        console.log(`   Relative position: (${relativeX}, ${relativeY})`);
        
        // Window positioning analysis
        console.log(`\n🎯 Position Analysis:`);
        const centerX = relativeX + window.width / 2;
        const centerY = relativeY + window.height / 2;
        const screenCenterX = window.screenWidth / 2;
        const screenCenterY = window.screenHeight / 2;
        
        console.log(`   Window center: (${centerX.toFixed(0)}, ${centerY.toFixed(0)})`);
        console.log(`   Screen center: (${screenCenterX.toFixed(0)}, ${screenCenterY.toFixed(0)})`);
        
        if (Math.abs(centerX - screenCenterX) < 50 && Math.abs(centerY - screenCenterY) < 50) {
            console.log(`   🎯 Window is centered on screen`);
        } else {
            const position = [];
            if (centerY < screenCenterY / 2) position.push('top');
            else if (centerY > screenCenterY * 1.5) position.push('bottom');
            else position.push('middle');
            
            if (centerX < screenCenterX / 2) position.push('left');
            else if (centerX > screenCenterX * 1.5) position.push('right');
            else position.push('center');
            
            console.log(`   📍 Window is positioned at ${position.join('-')} of screen`);
        }
        
        // Size classification
        console.log(`\n📏 Size Classification:`);
        const screenArea = window.screenWidth * window.screenHeight;
        const windowArea = window.width * window.height;
        const areaPercentage = (windowArea / screenArea) * 100;
        
        console.log(`   Occupies ${areaPercentage.toFixed(1)}% of screen area`);
        
        if (areaPercentage > 75) {
            console.log(`   📺 Large window (> 75% of screen)`);
        } else if (areaPercentage > 25) {
            console.log(`   📄 Medium window (25-75% of screen)`);
        } else {
            console.log(`   📝 Small window (< 25% of screen)`);
        }
        
        return window;

    } catch (error) {
        console.error('Error during window analysis:', error.message);
        throw error;
    } finally {
        await selector.cleanup();
    }
}

// Main function to run examples
async function main() {
    const args = process.argv.slice(2);
    
    if (args.includes('--help')) {
        console.log('Window Selector Examples:');
        console.log('========================');
        console.log('node examples/window-selector-example.js [option]');
        console.log('');
        console.log('Options:');
        console.log('  --simple      Simple window selection (default)');
        console.log('  --advanced    Advanced example with events');
        console.log('  --multiple    Select multiple windows');
        console.log('  --analysis    Detailed window analysis');
        console.log('  --help        Show this help');
        return;
    }
    
    try {
        if (args.includes('--advanced')) {
            await advancedExample();
        } else if (args.includes('--multiple')) {
            await multipleSelectionExample();
        } else if (args.includes('--analysis')) {
            await windowAnalysisExample();
        } else {
            await simpleExample();
        }
        
        console.log('\n🎉 Example completed successfully!');
        
    } catch (error) {
        console.error('\n❌ Example failed:', error.message);
        process.exit(1);
    }
}

if (require.main === module) {
    main();
}

module.exports = {
    simpleExample,
    advancedExample,
    multipleSelectionExample,
    windowAnalysisExample
};
const MacRecorder = require('./index');

async function listAllWindows() {
    const recorder = new MacRecorder();

    console.log('🔍 Listing all available windows...\n');

    try {
        const windows = await recorder.getWindows();

        console.log(`✅ Found ${windows.length} windows:\n`);
        console.log('='.repeat(80));

        windows.forEach((win, idx) => {
            console.log(`\n${idx + 1}. ${win.appName}`);
            console.log(`   Title: "${win.title}"`);
            console.log(`   Window ID: ${win.id}`);
            console.log(`   Size: ${win.width}x${win.height}`);
            console.log(`   Position: (${win.x}, ${win.y})`);
            console.log(`   Owner PID: ${win.ownerPID}`);
        });

        console.log('\n' + '='.repeat(80));
        console.log(`\nTotal: ${windows.length} windows available for recording`);

    } catch (error) {
        console.error('❌ Error:', error.message);
        console.error(error.stack);
    }
}

listAllWindows();

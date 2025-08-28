const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

console.log("🔨 Building Electron-safe macOS recorder module...\n");

// Check if we're on macOS
if (process.platform !== "darwin") {
	console.error("❌ This package only works on macOS");
	process.exit(1);
}

// Check if Xcode Command Line Tools are installed
console.log("🔍 Checking Xcode Command Line Tools...");
const xcodebuild = spawn("xcode-select", ["--print-path"], { stdio: "pipe" });

xcodebuild.on("close", (code) => {
	if (code !== 0) {
		console.error("❌ Xcode Command Line Tools not found!");
		console.log("📦 Please install with: xcode-select --install");
		process.exit(1);
	}

	console.log("✅ Xcode Command Line Tools found");
	buildElectronSafeModule();
});

function buildElectronSafeModule() {
	console.log("\n🏗️  Building Electron-safe native module...");
	console.log("📁 Using binding file: electron-safe-binding.gyp");

	// Run node-gyp configure and build with electron-safe binding
	const nodeGyp = spawn(
		"node-gyp",
		["configure", "build", "--binding_gyp_path=electron-safe-binding.gyp"],
		{
			stdio: "inherit",
			env: {
				...process.env,
				npm_config_build_from_source: "true",
				ELECTRON_SAFE_BUILD: "1",
			},
		}
	);

	nodeGyp.on("close", (code) => {
		if (code === 0) {
			console.log("\n✅ Electron-safe native module built successfully!");
			console.log("🎉 electron-safe mac-recorder is ready to use");

			// Check if build output exists
			const buildPath = path.join(
				__dirname,
				"build",
				"Release",
				"mac_recorder_electron.node"
			);
			if (fs.existsSync(buildPath)) {
				console.log("📁 Native module location:", buildPath);

				// Create a test file
				createElectronSafeTest();
			} else {
				console.log("⚠️ Native module file not found at expected location");
			}
		} else {
			console.error("\n❌ Build failed with code:", code);
			console.log("\n🔧 Troubleshooting:");
			console.log(
				"1. Make sure Xcode Command Line Tools are installed: xcode-select --install"
			);
			console.log("2. Check Node.js version (requires 14.0.0+)");
			console.log("3. Try: npm run clean && npm run build:electron-safe");
			console.log(
				"4. Check that all Electron-safe source files exist in src/electron_safe/"
			);
			process.exit(1);
		}
	});

	nodeGyp.on("error", (error) => {
		console.error("\n❌ Build error:", error.message);
		console.log(
			"\n📦 Make sure node-gyp is installed: npm install -g node-gyp"
		);
		process.exit(1);
	});
}

function createElectronSafeTest() {
	const testContent = `const ElectronSafeMacRecorder = require('./electron-safe-index');

console.log('🧪 Testing Electron-safe Mac Recorder');

async function testElectronSafe() {
    try {
        const recorder = new ElectronSafeMacRecorder();
        
        console.log('📋 Module info:', recorder.getModuleInfo());
        
        // Test permissions
        const permissions = await recorder.checkPermissions();
        console.log('🔐 Permissions:', permissions);
        
        // Test displays
        const displays = await recorder.getDisplays();
        console.log('📺 Displays:', displays.length);
        
        // Test windows
        const windows = await recorder.getWindows();
        console.log('🪟 Windows:', windows.length);
        
        // Test cursor position
        try {
            const cursor = recorder.getCursorPosition();
            console.log('🖱️ Cursor:', cursor);
        } catch (e) {
            console.log('⚠️ Cursor position error (normal in some environments):', e.message);
        }
        
        console.log('✅ All basic tests passed - Electron-safe module is working!');
        
    } catch (error) {
        console.error('❌ Test failed:', error.message);
        process.exit(1);
    }
}

testElectronSafe();
`;

	fs.writeFileSync(path.join(__dirname, "test-electron-safe.js"), testContent);
	console.log("📝 Created test file: test-electron-safe.js");
	console.log("🎯 Run: node test-electron-safe.js");
}

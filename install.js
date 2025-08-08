const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

console.log("🔨 Installing node-mac-recorder...\n");

// Check if we're on macOS
if (process.platform !== "darwin") {
	console.error("❌ This package only works on macOS");
	process.exit(1);
}

// Prefer prebuilds on supported platforms
const prebuildPath = path.join(
	__dirname,
	"prebuilds",
	`darwin-${process.arch}`,
	"node.napi.node"
);
if (
	process.platform === "darwin" &&
	process.arch === "arm64" &&
	fs.existsSync(prebuildPath)
) {
	console.log("✅ Using prebuilt binary:", prebuildPath);
	console.log("🎉 node-mac-recorder is ready to use (no compilation needed)");
	process.exit(0);
}

// Fallback to building from source
console.log("🔍 Checking Xcode Command Line Tools...");
const xcodebuild = spawn("xcode-select", ["--print-path"], { stdio: "pipe" });

xcodebuild.on("close", (code) => {
	if (code !== 0) {
		console.error("❌ Xcode Command Line Tools not found!");
		console.log("📦 Please install with: xcode-select --install");
		process.exit(1);
	}

	console.log("✅ Xcode Command Line Tools found");
	buildNativeModule();
});

function buildNativeModule() {
	console.log("\n🏗️  Building native module...");

	// Run node-gyp rebuild
	const nodeGyp = spawn("node-gyp", ["rebuild"], {
		stdio: "inherit",
		env: { ...process.env, npm_config_build_from_source: "true" },
	});

	nodeGyp.on("close", (code) => {
		if (code === 0) {
			console.log("\n✅ Native module built successfully!");
			console.log("🎉 node-mac-recorder is ready to use");

			// Check if build output exists
			const buildPath = path.join(
				__dirname,
				"build",
				"Release",
				"mac_recorder.node"
			);
			if (fs.existsSync(buildPath)) {
				console.log("📁 Native module location:", buildPath);
			}
		} else {
			console.error("\n❌ Build failed with code:", code);
			console.log("\n🔧 Troubleshooting:");
			console.log(
				"1. Make sure Xcode Command Line Tools are installed: xcode-select --install"
			);
			console.log("2. Check Node.js version (requires 14.0.0+)");
			console.log("3. Try: npm run clean && npm run build");
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

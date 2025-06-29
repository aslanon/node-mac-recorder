const MacRecorder = require("./index");
const path = require("path");
const fs = require("fs");

async function testCursorCapture() {
	console.log("🎯 Cursor Capture Demo\n");

	const recorder = new MacRecorder();
	const outputPath = path.join(__dirname, "cursor-data.json");

	try {
		// Başlat
		await recorder.startCursorCapture(outputPath);
		console.log("✅ Kayıt başladı...");

		// 5 saniye bekle
		console.log("📱 5 saniye hareket ettirin, tıklayın...");

		for (let i = 5; i > 0; i--) {
			process.stdout.write(`⏳ ${i}... `);
			await new Promise((resolve) => setTimeout(resolve, 1000));
		}
		console.log("\n");

		// Durdur
		await recorder.stopCursorCapture();
		console.log("✅ Kayıt tamamlandı!");

		// Sonuç
		if (fs.existsSync(outputPath)) {
			const data = JSON.parse(fs.readFileSync(outputPath, "utf8"));
			console.log(`📄 ${data.length} event kaydedildi -> ${outputPath}`);

			// Basit istatistik
			const clicks = data.filter((d) => d.type === "mousedown").length;
			if (clicks > 0) {
				console.log(`🖱️  ${clicks} click algılandı`);
			}
		}
	} catch (error) {
		console.error("❌ Hata:", error.message);
	}
}

// Direkt çalıştır
if (require.main === module) {
	testCursorCapture().catch(console.error);
}

module.exports = { testCursorCapture };

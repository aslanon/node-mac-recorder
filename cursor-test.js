const MacRecorder = require("./index");
const path = require("path");
const fs = require("fs");

async function testCursorTracking() {
	console.log("🎯 Cursor Tracking Test Başlatılıyor...\n");

	const recorder = new MacRecorder();

	try {
		// Cursor tracking başlat
		const outputPath = path.join(__dirname, "cursor-data.json");
		console.log("📍 Cursor tracking başlatılıyor...");
		console.log("📁 Output dosyası:", outputPath);

		await recorder.startCursorTracking(outputPath);
		console.log("✅ Cursor tracking başlatıldı!");

		// Durum kontrolü
		const status = recorder.getCursorTrackingStatus();
		console.log("📊 Tracking durumu:", status);

		// 5 saniye bekle ve pozisyon örnekleri al
		console.log(
			"\n🎬 5 saniye boyunca cursor hareketlerinizi takip ediyoruz..."
		);
		console.log("💡 Fare hareket ettirin, tıklayın ve sürükleyin!");

		// Manuel data collection - JavaScript tarafında polling
		const manualData = [];
		const startTime = Date.now();

		for (let i = 5; i > 0; i--) {
			console.log(`⏳ ${i} saniye kaldı...`);

			// 100ms'de bir pozisyon al (10 FPS)
			for (let j = 0; j < 10; j++) {
				const position = recorder.getCursorPosition();
				const timestamp = Date.now() - startTime;

				manualData.push({
					x: position.x,
					y: position.y,
					timestamp: timestamp,
					cursorType: position.cursorType,
					type: "move",
				});

				await new Promise((resolve) => setTimeout(resolve, 100));
			}

			// Son pozisyonu göster
			if (manualData.length > 0) {
				const lastPos = manualData[manualData.length - 1];
				console.log(
					`📌 Pozisyon: x=${lastPos.x}, y=${lastPos.y}, tip=${lastPos.cursorType}`
				);
			}
		}

		// Manuel veriyi dosyaya kaydet
		console.log(
			`\n📝 Manuel data collection: ${manualData.length} pozisyon toplandı`
		);
		const manualPath = path.join(__dirname, "manual-cursor-data.json");
		fs.writeFileSync(manualPath, JSON.stringify(manualData, null, 2));
		console.log(`📄 Manuel veriler kaydedildi: ${manualPath}`);

		// Tracking durdur
		console.log("\n🛑 Cursor tracking durduruluyor...");
		await recorder.stopCursorTracking();
		console.log("✅ Cursor tracking durduruldu!");

		// Final durum kontrolü
		const finalStatus = recorder.getCursorTrackingStatus();
		console.log("📊 Final durumu:", finalStatus);

		// Dosya kontrolü
		if (fs.existsSync(outputPath)) {
			const data = JSON.parse(fs.readFileSync(outputPath, "utf8"));
			console.log(
				`\n📄 JSON dosyası oluşturuldu: ${data.length} adet cursor verisi kaydedildi`
			);

			// İlk birkaç veriyi göster
			if (data.length > 0) {
				console.log("\n📝 İlk 3 cursor verisi:");
				data.slice(0, 3).forEach((item, index) => {
					console.log(
						`${index + 1}. x:${item.x}, y:${item.y}, timestamp:${
							item.timestamp
						}, cursorType:${item.cursorType}, type:${item.type}`
					);
				});

				if (data.length > 3) {
					console.log(`... ve ${data.length - 3} adet daha`);
				}
			}

			// Cursor tipleri istatistiği
			const cursorTypes = {};
			const eventTypes = {};
			data.forEach((item) => {
				cursorTypes[item.cursorType] = (cursorTypes[item.cursorType] || 0) + 1;
				eventTypes[item.type] = (eventTypes[item.type] || 0) + 1;
			});

			console.log("\n📈 Cursor Tipleri İstatistiği:");
			Object.keys(cursorTypes).forEach((type) => {
				console.log(`  ${type}: ${cursorTypes[type]} adet`);
			});

			console.log("\n🎭 Event Tipleri İstatistiği:");
			Object.keys(eventTypes).forEach((type) => {
				console.log(`  ${type}: ${eventTypes[type]} adet`);
			});
		} else {
			console.log("❌ JSON dosyası oluşturulamadı!");
		}
	} catch (error) {
		console.error("❌ Hata:", error.message);
	}

	console.log("\n🎉 Test tamamlandı!");
}

// Ek fonksiyonlar test et
async function testCursorPositionOnly() {
	console.log("\n🎯 Anlık Cursor Pozisyon Testi...");

	const recorder = new MacRecorder();

	try {
		for (let i = 0; i < 5; i++) {
			const position = recorder.getCursorPosition();
			console.log(
				`📌 Pozisyon ${i + 1}: x=${position.x}, y=${position.y}, tip=${
					position.cursorType
				}`
			);
			await new Promise((resolve) => setTimeout(resolve, 500));
		}
	} catch (error) {
		console.error("❌ Pozisyon alma hatası:", error.message);
	}
}

// Test menüsü
async function main() {
	console.log("🚀 MacRecorder Cursor Tracking Test Menüsü\n");

	const args = process.argv.slice(2);

	if (args.includes("--position")) {
		await testCursorPositionOnly();
	} else if (args.includes("--full")) {
		await testCursorTracking();
	} else {
		console.log("Kullanım:");
		console.log(
			"  node cursor-test.js --full     # Tam cursor tracking testi (5 saniye)"
		);
		console.log(
			"  node cursor-test.js --position # Sadece anlık pozisyon testi"
		);
		console.log("\nÖrnek:");
		console.log("  node cursor-test.js --full");
	}
}

if (require.main === module) {
	main().catch(console.error);
}

module.exports = { testCursorTracking, testCursorPositionOnly };

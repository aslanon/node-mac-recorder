const MacRecorder = require("./index.js");
const fs = require("fs");
const path = require("path");

async function testRecorder() {
	const recorder = new MacRecorder();

	console.log("🧪 node-mac-recorder Test Başlatılıyor...\n");

	try {
		// Test 1: Cihaz listelerini al
		console.log("📱 Cihazlar listeleniyor...");

		const audioDevices = await recorder.getAudioDevices();
		console.log(
			"🔊 Ses Cihazları:",
			audioDevices.length > 0 ? audioDevices : "Bulunamadı"
		);

		const displays = await recorder.getDisplays();
		console.log("🖥️  Ekranlar:", displays.length > 0 ? displays : "Bulunamadı");

		const windows = await recorder.getWindows();
		console.log(
			"🪟 Pencereler:",
			windows.length > 0 ? windows.slice(0, 5) : "Bulunamadı"
		); // İlk 5 pencere

		console.log("\n");

		// Test 2: Screenshot al

		// Test 3: 5 saniyelik tam ekran kayıt testi
		console.log("\n🎥 5 saniyelik tam ekran kayıt testi başlatılıyor...");
		console.log("⚠️  macOS izin penceresi açılabilir!");

		const outputPath = "./test-recording.mp4";

		// Event listeners
		recorder.on("started", (path) => {
			console.log("✅ Kayıt başladı:", path);
		});

		recorder.on("timeUpdate", (seconds) => {
			process.stdout.write(`\r⏱️  Kayıt süresi: ${seconds} saniye`);
		});

		recorder.on("completed", (path) => {
			console.log("\n✅ Kayıt tamamlandı:", path);
			console.log(
				"📁 Dosya boyutu:",
				fs.existsSync(path)
					? (fs.statSync(path).size / 1024 / 1024).toFixed(2) + " MB"
					: "Dosya bulunamadı"
			);
		});

		recorder.on("error", (error) => {
			console.error("\n❌ Kayıt hatası:", error.message);
		});

		// Kayıt başlat
		await recorder.startRecording(outputPath, {
			quality: "medium",
			frameRate: 30,
			captureCursor: false, // Default false olarak test edelim
			includeMicrophone: false, // Default false
			includeSystemAudio: true, // Default true
		});

		// 5 saniye bekle
		await new Promise((resolve) => setTimeout(resolve, 5000));

		// Kayıt durdur
		console.log("\n\n🛑 Kayıt durduruluyor...");
		const result = await recorder.stopRecording();
		console.log("✅ Kayıt durduruldu. Kod:", result.code);

		// Test 4: Pencere kayıt testi
		console.log("\n🪟 Pencere kayıt testi başlatılıyor...");

		// Uygun pencere bul
		const goodWindows = windows.filter(
			(w) =>
				w.width > 300 &&
				w.height > 300 &&
				w.appName !== "Dock" &&
				w.name.trim() !== ""
		);

		if (goodWindows.length > 0) {
			// En uygun pencereyi seç (browser > editor > diğer)
			let targetWindow =
				goodWindows.find(
					(w) =>
						w.appName.includes("Chrome") ||
						w.appName.includes("Safari") ||
						w.appName.includes("Firefox")
				) ||
				goodWindows.find(
					(w) => w.appName.includes("Code") || w.appName.includes("Cursor")
				) ||
				goodWindows[0];

			console.log(
				`🎯 Test penceresi: ${targetWindow.appName} - ${targetWindow.name}`
			);
			console.log(`📐 Boyut: ${targetWindow.width}x${targetWindow.height}`);

			const windowOutputPath = "./test-window-recording.mp4";

			await recorder.startRecording(windowOutputPath, {
				windowId: targetWindow.id,
				quality: "medium",
				frameRate: 30,
				captureCursor: true, // Pencere testinde cursor görmek faydalı
				includeMicrophone: false,
				includeSystemAudio: true,
			});

			console.log("✅ Pencere kaydı başladı!");

			// 3 saniye pencere kayıt
			await new Promise((resolve) => setTimeout(resolve, 3000));

			const windowResult = await recorder.stopRecording();
			console.log("✅ Pencere kaydı durduruldu. Kod:", windowResult.code);

			console.log("📋 Pencere kayıt dosyası:", windowOutputPath);
		} else {
			console.log("⚠️  Uygun pencere bulunamadı, pencere testi atlandı");
		}

		// Test 5: Durum kontrolü
		console.log("\n📊 Kayıt durumu:", recorder.getStatus());

		console.log("\n🎉 Tüm testler tamamlandı!");
		console.log("\n📋 Test dosyaları:");
		console.log("  - Tam ekran video:", outputPath);
		if (goodWindows.length > 0) {
			console.log("  - Pencere video:", "./test-window-recording.mp4");
		}
		console.log("\n💡 Test dosyalarını manuel olarak kontrol edin.");
	} catch (error) {
		console.error("\n❌ Test hatası:", error.message);

		if (error.message.includes("Native module not found")) {
			console.log("\n🔨 Native Modül Hatası:");
			console.log("1. npm run rebuild");
			console.log("2. Xcode Command Line Tools kurulu olduğundan emin olun");
			console.log(
				"3. node-gyp global olarak kurulu olmalı: npm install -g node-gyp"
			);
		}

		if (
			error.message.includes("Permission denied") ||
			error.message.includes("not permitted")
		) {
			console.log("\n🔒 İzin Hatası Çözümü:");
			console.log("1. Sistem Tercihleri > Güvenlik ve Gizlilik > Gizlilik");
			console.log('2. "Ekran Kaydı" sekmesine git');
			console.log("3. Terminal veya uygulamanızı listeye ekleyin");
			console.log("4. Testi tekrar çalıştırın");
		}

		if (error.message.includes("AVFoundation")) {
			console.log("\n📦 AVFoundation Hatası:");
			console.log("macOS sürümünüz çok eski olabilir (10.14+ gerekli)");
		}
	}
}

// Test çalıştır
if (require.main === module) {
	testRecorder();
}

module.exports = testRecorder;

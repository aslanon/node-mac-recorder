const MacRecorder = require("./index.js");

async function demo() {
	const recorder = new MacRecorder();

	console.log("🎬 MacOS Recorder Demo\n");

	try {
		// 1. İzinleri kontrol et
		console.log("🔒 İzinler kontrol ediliyor...");
		const permissions = await recorder.checkPermissions();
		console.log("İzin durumu:", permissions);

		if (!permissions.screenRecording) {
			console.log(
				"⚠️  Ekran kaydı izni gerekli! Sistem Ayarları > Güvenlik ve Gizlilik > Gizlilik > Ekran Kaydı"
			);
			return;
		}

		// 2. Mevcut cihazları listele
		console.log("\n📱 Mevcut cihazlar:");
		const audioDevices = await recorder.getAudioDevices();
		const displays = await recorder.getDisplays();

		console.log("🔊 Ses cihazları:", audioDevices.length, "adet");
		audioDevices.forEach((device, i) => {
			console.log(`  ${i + 1}. ${device.name}`);
		});

		console.log("🖥️  Ekranlar:", displays.length, "adet");
		displays.forEach((display, i) => {
			console.log(`  ${i + 1}. ${display.name} (${display.resolution})`);
		});

		// 3. Screenshot al

		// 4. Kısa video kaydı
		console.log("\n🎥 3 saniyelik video kaydı başlatılıyor...");

		// Event listener'lar
		recorder.on("started", (path) => {
			console.log("🟢 Kayıt başladı:", path);
		});

		recorder.on("timeUpdate", (seconds) => {
			process.stdout.write(`\r⏱️  ${seconds} saniye`);
		});

		recorder.on("completed", (path) => {
			console.log("\n✅ Kayıt tamamlandı:", path);
		});

		// Kayıt başlat
		await recorder.startRecording("./demo-recording.mp4", {
			includeMicrophone: false, // Default false (mikrofon kapalı)
			includeSystemAudio: true, // Default true (sistem sesi açık)
			quality: "medium",
			captureCursor: false, // Default false olarak demo
		});

		// 3 saniye bekle
		await new Promise((resolve) => setTimeout(resolve, 3000));

		// Kayıt durdur
		console.log("\n🛑 Kayıt durduruluyor...");
		const result = await recorder.stopRecording();

		console.log("📊 Sonuç:", result);

		// 5. Modül bilgilerini göster
		console.log("\n📋 Modül bilgileri:");
		const info = recorder.getModuleInfo();
		console.log(info);

		console.log("\n🎉 Demo tamamlandı!");
		console.log("📁 Oluşturulan dosyalar:");
		console.log("  - demo-recording.mp4");
	} catch (error) {
		console.error("❌ Hata:", error.message);
	}
}

// Demo çalıştır
if (require.main === module) {
	demo();
}

module.exports = demo;

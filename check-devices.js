#!/usr/bin/env node

const MacRecorder = require('./index.js');
const recorder = new MacRecorder();

async function checkDevices() {
	console.log('\n🔍 TÜM CİHAZLARI KONTROL ET:\n');

	const cameras = await recorder.getCameraDevices();
	console.log(`📹 Kamera Cihazları (${cameras.length}):`);
	cameras.forEach(cam => {
		console.log(`\n   - ${cam.name}`);
		console.log(`     ID: ${cam.id}`);
		console.log(`     Type: ${cam.deviceType || 'N/A'}`);
		console.log(`     Manufacturer: ${cam.manufacturer}`);
		console.log(`     Transport: ${cam.transportType}`);
		console.log(`     Continuity: ${cam.requiresContinuityCameraPermission ? 'YES' : 'NO'}`);
		console.log(`     Connected: ${cam.isConnected ? 'YES' : 'NO'}`);
	});

	const audio = await recorder.getAudioDevices();
	console.log(`\n🎙️ Ses Cihazları (${audio.length}):`);
	audio.forEach(aud => {
		console.log(`\n   - ${aud.name}`);
		console.log(`     ID: ${aud.id}`);
		console.log(`     Manufacturer: ${aud.manufacturer}`);
		console.log(`     Transport: ${aud.transportType}`);
		console.log(`     Default: ${aud.isDefault ? 'YES' : 'NO'}`);
	});

	console.log('\n✅ İPUCU: iPhone bağlı değilse, Wi-Fi veya USB ile bağla\n');
	console.log('Continuity Camera şartları:');
	console.log('  1. iPhone ve Mac aynı Apple ID ile giriş yapmış olmalı');
	console.log('  2. Her ikisinde de Bluetooth ve Wi-Fi açık olmalı');
	console.log('  3. iPhone Handoff açık olmalı\n');
}

checkDevices().catch(err => console.error('Hata:', err));

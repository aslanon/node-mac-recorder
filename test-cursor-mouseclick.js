const MacRecorder = require('./index.js');
const recorder = new MacRecorder();
const native = require('./build/Release/mac_recorder.node');
const fs = require('fs');

console.log('\n🎯 CURSOR MAPPING TEST - NSCursor Raw Data Toplama\n');
console.log('─'.repeat(120));
console.log('\nBu test her CSS cursor tipinin gerçek NSCursor özelliklerini toplar.\n');

// CSS cursor tipleri (benzersiz, tekrarsız)
const cursorList = [
    "auto",
    "default",
    "none",
    "context-menu",
    "help",
    "pointer",
    "progress",
    "wait",
    "cell",
    "crosshair",
    "text",
    "vertical-text",
    "alias",
    "copy",
    "move",
    "no-drop",
    "not-allowed",
    "grab",
    "grabbing",
    "all-scroll",
    "col-resize",
    "row-resize",
    "n-resize",
    "e-resize",
    "s-resize",
    "w-resize",
    "ne-resize",
    "nw-resize",
    "se-resize",
    "sw-resize",
    "ew-resize",
    "ns-resize",
    "nesw-resize",
    "nwse-resize",
    "zoom-in",
    "zoom-out"
];

let currentIndex = 0;
let cursorMapping = {}; // CSS type -> NSCursor raw data
let isWaitingForClick = false;

console.log(`📋 ${cursorList.length} benzersiz cursor tipi test edilecek:\n`);
cursorList.forEach((cursor, index) => {
    console.log(`   ${(index).toString().padStart(2)}. ${cursor}`);
});

console.log('\n' + '─'.repeat(120));
console.log('\n💡 Nasıl Kullanılır:');
console.log('   1. Arayüzde gösterilen CSS cursor tipini bul');
console.log('   2. O cursor üzerine gelip TIKLA');
console.log('   3. NSCursor raw data otomatik kaydedilecek');
console.log('   4. Sonraki cursor tipine geçecek');
console.log('   5. 36 cursor bitince mapping dosyası oluşacak\n');
console.log('─'.repeat(120));

function showNextCursor() {
    if (currentIndex >= cursorList.length) {
        finishTest();
        return;
    }

    const cursorType = cursorList[currentIndex];
    console.log(`\n\n🎯 [${currentIndex + 1}/${cursorList.length}] CSS Cursor: "${cursorType}"`);
    console.log('👆 Arayüzde bu cursor üzerine git ve TIKLA...\n');
    isWaitingForClick = true;
}

function recordCursorOnClick(debugInfo) {
    if (!isWaitingForClick) return;

    isWaitingForClick = false;
    const cssType = cursorList[currentIndex];

    console.log('✅ NSCursor RAW DATA KAYDEDİLDİ:');
    console.log('─'.repeat(80));
    console.log(`📋 CSS Type:        ${cssType}`);
    console.log(`🏷️  NSCursor Class:  ${debugInfo.className || 'N/A'}`);
    console.log(`🆔 Pointer Address: ${debugInfo.pointerAddress || 'N/A'}`);
    console.log(`#️⃣  Hash:            ${debugInfo.hash || 'N/A'}`);
    console.log(`🌱 Seed:            ${debugInfo.seed || 'N/A'}`);
    console.log(`🏷️  Private Name:   ${debugInfo.privateName || 'N/A'}`);
    console.log(`🔑 Fingerprint:     ${debugInfo.fingerprint || 'N/A'}`);
    console.log(`📝 Description:     ${debugInfo.description || 'N/A'}`);

    if (debugInfo.image) {
        const img = debugInfo.image;
        console.log(`📐 Image Size:      ${img.width.toFixed(1)} x ${img.height.toFixed(1)}`);
        console.log(`📊 Aspect Ratio:    ${img.aspectRatio.toFixed(4)}`);
    }

    if (debugInfo.hotspot) {
        const hs = debugInfo.hotspot;
        console.log(`🎯 Hotspot (abs):   (${hs.x.toFixed(1)}, ${hs.y.toFixed(1)})`);
        console.log(`🎯 Hotspot (rel):   (${(hs.relativeX * 100).toFixed(1)}%, ${(hs.relativeY * 100).toFixed(1)}%)`);
    }

    console.log('');
    console.log(`🔍 Detection Results:`);
    console.log(`   Direct:  ${debugInfo.directDetection || 'N/A'}`);
    console.log(`   System:  ${debugInfo.systemDetection || 'N/A'}`);
    console.log(`   AX:      ${debugInfo.axDetection || 'null'}`);
    console.log(`   Final:   ${debugInfo.finalType || 'N/A'}`);
    console.log('─'.repeat(80));

    // Mapping'e kaydet
    cursorMapping[cssType] = {
        cssType: cssType,
        nsCursorClass: debugInfo.className,
        pointerAddress: debugInfo.pointerAddress,
        hash: debugInfo.hash,
        seed: debugInfo.seed,
        description: debugInfo.description,
        imageSize: debugInfo.image ? {
            width: debugInfo.image.width,
            height: debugInfo.image.height,
            aspectRatio: debugInfo.image.aspectRatio
        } : null,
        hotspot: debugInfo.hotspot ? {
            x: debugInfo.hotspot.x,
            y: debugInfo.hotspot.y,
            relativeX: debugInfo.hotspot.relativeX,
            relativeY: debugInfo.hotspot.relativeY
        } : null,
        detection: {
            direct: debugInfo.directDetection,
            system: debugInfo.systemDetection,
            ax: debugInfo.axDetection,
            final: debugInfo.finalType
        },
        privateName: debugInfo.privateName || null,
        fingerprint: debugInfo.fingerprint || null
    };

    currentIndex++;

    // 400ms bekle sonraki cursor'a geç
    setTimeout(() => {
        showNextCursor();
    }, 400);
}

function finishTest() {
    console.log('\n\n🎉 TÜM CURSOR TİPLERİ KAYDEDİLDİ!\n');
    console.log('─'.repeat(120));
    console.log(`\n📊 ${Object.keys(cursorMapping).length} cursor tipi için NSCursor raw data toplandı.\n`);
    console.log('─'.repeat(120));
    console.log('\n📋 CURSOR MAPPING ÖZET:\n');

    Object.keys(cursorMapping).forEach(cssType => {
        const data = cursorMapping[cssType];
        const detectedCorrectly = cssType === data.detection.final ? '✅' : '❌';

        console.log(`${detectedCorrectly} ${cssType.padEnd(20)} => Detected: ${(data.detection.final || 'N/A').padEnd(15)} | Class: ${data.nsCursorClass || 'N/A'}`);
    });

    console.log('\n' + '─'.repeat(120));

    // Analiz için yardımcı bilgiler
    console.log('\n🔍 DETECTION ACCURACY:\n');

    let correctCount = 0;
    let incorrectCount = 0;

    Object.keys(cursorMapping).forEach(cssType => {
        const data = cursorMapping[cssType];
        if (cssType === data.detection.final) {
            correctCount++;
        } else {
            incorrectCount++;
        }
    });

    console.log(`   ✅ Correct: ${correctCount}/${Object.keys(cursorMapping).length}`);
    console.log(`   ❌ Incorrect: ${incorrectCount}/${Object.keys(cursorMapping).length}`);
    console.log(`   📈 Success Rate: ${((correctCount / Object.keys(cursorMapping).length) * 100).toFixed(1)}%`);

    // Yanlış algılananları göster
    if (incorrectCount > 0) {
        console.log('\n❌ INCORRECT DETECTIONS:\n');
        Object.keys(cursorMapping).forEach(cssType => {
            const data = cursorMapping[cssType];
            if (cssType !== data.detection.final) {
                console.log(`   ${cssType.padEnd(20)} => Detected as: ${data.detection.final || 'N/A'}`);
                if (data.imageSize) {
                    console.log(`      Image: ${data.imageSize.width.toFixed(1)}x${data.imageSize.height.toFixed(1)} ratio=${data.imageSize.aspectRatio.toFixed(4)}`);
                }
                if (data.hotspot) {
                    console.log(`      Hotspot: (${data.hotspot.x.toFixed(1)}, ${data.hotspot.y.toFixed(1)}) rel=(${(data.hotspot.relativeX * 100).toFixed(1)}%, ${(data.hotspot.relativeY * 100).toFixed(1)}%)`);
                }
                console.log('');
            }
        });
    }

    // JSON dosyasına kaydet
    const output = {
        metadata: {
            timestamp: new Date().toISOString(),
            totalCursorTypes: Object.keys(cursorMapping).length,
            correctDetections: correctCount,
            incorrectDetections: incorrectCount,
            successRate: ((correctCount / Object.keys(cursorMapping).length) * 100).toFixed(1) + '%'
        },
        cursorMapping: cursorMapping
    };

    fs.writeFileSync('cursor-nscursor-mapping.json', JSON.stringify(output, null, 2));
    console.log('\n✅ NSCursor mapping "cursor-nscursor-mapping.json" dosyasına kaydedildi!\n');
    console.log('─'.repeat(120));
    console.log('\n💡 Bu dosyayı kullanarak cursor detection kodunu düzeltebiliriz!\n');

    process.exit(0);
}

// Mouse click monitoring
let lastClickTime = 0;
let monitoringInterval = null;

console.log('\n⏳ 3 saniye sonra başlayacak...\n');

setTimeout(() => {
    console.log('\n🚀 TEST BAŞLADI! Arayüzde sırayla cursorlara tıkla!\n');
    console.log('─'.repeat(120));
    showNextCursor();

    // Mouse click'i sürekli kontrol et
    monitoringInterval = setInterval(() => {
        try {
            const pos = recorder.getCursorPosition();

            // Mouse down eventi
            if (pos && pos.eventType === 'mousedown') {
                const now = Date.now();

                // Debounce - 500ms
                if (now - lastClickTime > 500) {
                    lastClickTime = now;

                    // Debug info al
                    const debugInfo = native.getCursorDebugInfo();
                    recordCursorOnClick(debugInfo);
                }
            }
        } catch (err) {
            // Sessizce devam et
        }
    }, 50);

}, 3000);

// Ctrl+C handler
process.on('SIGINT', () => {
    if (monitoringInterval) {
        clearInterval(monitoringInterval);
    }
    finishTest();
});

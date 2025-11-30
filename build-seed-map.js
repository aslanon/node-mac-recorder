const MacRecorder = require('./index.js');
const recorder = new MacRecorder();
const fs = require('fs');

console.log('\n🎯 SEED MAPPING BUILDER\n');
console.log('═'.repeat(100));
console.log('\n📋 Bu tool tüm cursor tiplerinin seed mapping\'ini oluşturur.\n');

// Tüm CSS cursor tipleri (HTML'deki sırayla)
const cursorTypes = [
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
let seedMapping = {}; // cursorType -> seed
let isWaitingForClick = false;

console.log(`\n📝 ${cursorTypes.length} cursor tipi için seed toplanacak:\n`);
cursorTypes.forEach((cursor, index) => {
    console.log(`   ${(index + 1).toString().padStart(2)}. ${cursor}`);
});

console.log('\n' + '═'.repeat(100));
console.log('\n💡 Nasıl Kullanılır:');
console.log('   1. test-all-cursors.html dosyası tarayıcıda açık olmalı');
console.log('   2. Bu script size hangi cursor\'a tıklamanız gerektiğini söyleyecek');
console.log('   3. HTML\'deki o cursor kutusuna TIKLAYIN');
console.log('   4. Seed otomatik kaydedilecek ve bir sonrakine geçilecek');
console.log('   5. Tüm cursor\'lar bitince seed-mapping.json oluşturulacak\n');
console.log('═'.repeat(100));

function showNextCursor() {
    if (currentIndex >= cursorTypes.length) {
        finishMapping();
        return;
    }

    const cursorType = cursorTypes[currentIndex];
    console.log(`\n\n🎯 [${currentIndex + 1}/${cursorTypes.length}] "${cursorType}" cursor'una tıkla`);
    console.log('👆 HTML\'de bu cursor kutusunu bul ve TIKLA...\n');
    isWaitingForClick = true;
}

function recordSeedOnClick(pos) {
    if (!isWaitingForClick) return;

    isWaitingForClick = false;
    const cursorType = cursorTypes[currentIndex];
    const seed = pos.seed || -1;

    console.log(`✅ Kaydedildi: ${cursorType.padEnd(20)} → seed: ${seed}`);

    // Mapping'e ekle
    seedMapping[cursorType] = seed;

    currentIndex++;

    // 200ms bekle sonraki cursor'a geç
    setTimeout(() => {
        showNextCursor();
    }, 200);
}

function finishMapping() {
    console.log('\n\n🎉 TÜM CURSOR TİPLERİ İÇİN SEED TOPLANDI!\n');
    console.log('═'.repeat(100));
    console.log(`\n✅ ${Object.keys(seedMapping).length} cursor tipi kaydedildi.\n`);
    console.log('═'.repeat(100));

    // Reverse mapping oluştur: seed -> cursorType
    const seedToType = {};
    Object.keys(seedMapping).forEach(cursorType => {
        const seed = seedMapping[cursorType];
        if (seed > 0) {
            // Eğer bu seed zaten başka bir cursor'a atanmışsa, not ekle
            if (seedToType[seed]) {
                console.log(`⚠️  Seed collision: ${seed} both ${seedToType[seed]} and ${cursorType}`);
                // İlk gördüğümüzü tut, ama not ekle
                if (!seedToType[seed].includes('/')) {
                    seedToType[seed] = `${seedToType[seed]}/${cursorType}`;
                } else {
                    seedToType[seed] += `/${cursorType}`;
                }
            } else {
                seedToType[seed] = cursorType;
            }
        }
    });

    console.log('\n📊 SEED MAPPING ÖZET:\n');
    console.log('Cursor Type          -> Seed');
    console.log('─'.repeat(100));
    Object.keys(seedMapping).sort().forEach(cursorType => {
        const seed = seedMapping[cursorType];
        console.log(`${cursorType.padEnd(20)} → ${seed}`);
    });

    console.log('\n\n📊 REVERSE MAPPING (Seed -> Cursor):\n');
    console.log('Seed      -> Cursor Type');
    console.log('─'.repeat(100));
    Object.keys(seedToType).sort((a, b) => parseInt(a) - parseInt(b)).forEach(seed => {
        console.log(`${seed.padEnd(10)} → ${seedToType[seed]}`);
    });

    // Dosyaya kaydet
    const output = {
        metadata: {
            timestamp: new Date().toISOString(),
            totalCursorTypes: Object.keys(seedMapping).length,
            uniqueSeeds: Object.keys(seedToType).length
        },
        cursorToSeed: seedMapping,
        seedToCursor: seedToType
    };

    fs.writeFileSync('seed-mapping.json', JSON.stringify(output, null, 2));
    console.log('\n✅ Mapping "seed-mapping.json" dosyasına kaydedildi!\n');

    // C++ için kod üret
    console.log('\n═'.repeat(100));
    console.log('\n📝 C++ KODU (cursor_tracker.mm için):\n');
    console.log('static NSString* cursorTypeFromSeed(int seed) {');
    console.log('    switch(seed) {');

    Object.keys(seedToType).sort((a, b) => parseInt(a) - parseInt(b)).forEach(seed => {
        const cursorType = seedToType[seed];
        // Eğer collision varsa (örn: "auto/default"), ilkini al
        const primaryType = cursorType.split('/')[0];
        console.log(`        case ${seed}: return @"${primaryType}";`);
    });

    console.log('        default: return nil;');
    console.log('    }');
    console.log('}\n');
    console.log('═'.repeat(100));

    process.exit(0);
}

// Mouse click monitoring
let lastClickTime = 0;
let monitoringInterval = null;

console.log('\n⏳ test-all-cursors.html açık mı? 3 saniye sonra başlıyoruz...\n');

setTimeout(() => {
    console.log('🚀 TEST BAŞLADI! HTML\'deki cursor kutularına tıklayın!\n');
    console.log('═'.repeat(100));
    showNextCursor();

    // Mouse click'i sürekli kontrol et
    monitoringInterval = setInterval(() => {
        try {
            const pos = recorder.getCursorPosition();

            // Mouse down eventi
            if (pos && pos.eventType === 'mousedown') {
                const now = Date.now();

                // Debounce - 300ms
                if (now - lastClickTime > 300) {
                    lastClickTime = now;
                    recordSeedOnClick(pos);
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
    console.log('\n\n⚠️  Yarıda kesildi. Şimdiye kadar toplanan data:\n');
    Object.keys(seedMapping).forEach(cursorType => {
        console.log(`${cursorType.padEnd(20)} → ${seedMapping[cursorType]}`);
    });
    console.log('\n');
    process.exit(0);
});

const MacRecorder = require('./index.js');
const recorder = new MacRecorder();

console.log('\n🎯 CURSOR DETECTION ACCURACY TEST\n');
console.log('═'.repeat(100));
console.log('\n📋 test-all-cursors.html açık olmalı. Her cursor\'a tıklayın.\n');
console.log('═'.repeat(100));

const cursorTypes = [
    "auto", "default", "none", "context-menu", "help", "pointer",
    "progress", "wait", "cell", "crosshair", "text", "vertical-text",
    "alias", "copy", "move", "no-drop", "not-allowed", "grab",
    "grabbing", "all-scroll", "col-resize", "row-resize", "n-resize",
    "e-resize", "s-resize", "w-resize", "ne-resize", "nw-resize",
    "se-resize", "sw-resize", "ew-resize", "ns-resize", "nesw-resize",
    "nwse-resize", "zoom-in", "zoom-out"
];

let currentIndex = 0;
let results = {}; // expected -> detected
let lastClickTime = 0;

function showNextCursor() {
    if (currentIndex >= cursorTypes.length) {
        showResults();
        return;
    }

    const expected = cursorTypes[currentIndex];
    console.log(`\n[${currentIndex + 1}/${cursorTypes.length}] "${expected}" kutusuna tıkla...`);
}

function recordClick(pos) {
    const expected = cursorTypes[currentIndex];
    const detected = pos.cursorType || 'unknown';

    const match = expected === detected ? '✅' : '❌';
    console.log(`${match} Beklenen: ${expected.padEnd(15)} → Algılanan: ${detected.padEnd(15)}`);

    results[expected] = detected;
    currentIndex++;

    setTimeout(showNextCursor, 200);
}

function showResults() {
    console.log('\n\n' + '═'.repeat(100));
    console.log('\n🎉 TEST TAMAMLANDI!\n');
    console.log('═'.repeat(100));

    let correct = 0;
    let incorrect = 0;

    console.log('\n📊 SONUÇLAR:\n');
    console.log('Beklenen         → Algılanan');
    console.log('─'.repeat(100));

    Object.keys(results).forEach(expected => {
        const detected = results[expected];
        const match = expected === detected ? '✅' : '❌';

        if (expected === detected) {
            correct++;
        } else {
            incorrect++;
        }

        console.log(`${match} ${expected.padEnd(15)} → ${detected.padEnd(15)}`);
    });

    console.log('\n' + '═'.repeat(100));
    console.log(`\n✅ Doğru: ${correct}/${cursorTypes.length} (${((correct/cursorTypes.length)*100).toFixed(1)}%)`);
    console.log(`❌ Yanlış: ${incorrect}/${cursorTypes.length} (${((incorrect/cursorTypes.length)*100).toFixed(1)}%)`);
    console.log('\n' + '═'.repeat(100));

    if (incorrect > 0) {
        console.log('\n❌ YANLIŞ TESPİT EDİLENLER:\n');
        Object.keys(results).forEach(expected => {
            const detected = results[expected];
            if (expected !== detected) {
                console.log(`   ${expected.padEnd(15)} → ${detected}`);
            }
        });
    }

    console.log('\n');
    process.exit(0);
}

console.log('\n⏳ 3 saniye sonra başlıyoruz...\n');

setTimeout(() => {
    console.log('🚀 BAŞLA! HTML\'deki cursor kutularına SIRAYLA tıklayın!\n');
    console.log('═'.repeat(100));
    showNextCursor();

    const interval = setInterval(() => {
        try {
            const pos = recorder.getCursorPosition();

            if (pos && pos.eventType === 'mousedown') {
                const now = Date.now();

                if (now - lastClickTime > 300) {
                    lastClickTime = now;
                    recordClick(pos);
                }
            }
        } catch (err) {
            // Sessizce devam et
        }
    }, 50);

    // Ctrl+C handler
    process.on('SIGINT', () => {
        clearInterval(interval);
        showResults();
    });

}, 3000);

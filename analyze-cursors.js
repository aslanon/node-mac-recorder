const fs = require('fs');

// cursor-nscursor-mapping.json'u oku
const mapping = JSON.parse(fs.readFileSync('cursor-nscursor-mapping.json', 'utf8'));

console.log('\n📊 CURSOR DETECTION ANALYSIS\n');
console.log('═'.repeat(100));

// Group by image size
const byImageSize = {};
Object.keys(mapping.cursorMapping).forEach(cssType => {
    const data = mapping.cursorMapping[cssType];
    if (!data.imageSize) return;

    const key = `${data.imageSize.width}x${data.imageSize.height}`;
    if (!byImageSize[key]) {
        byImageSize[key] = [];
    }
    byImageSize[key].push({
        cssType,
        hotspot: data.hotspot,
        detected: data.detection.final
    });
});

console.log('\n🔍 CURSORS GROUPED BY IMAGE SIZE:\n');
Object.keys(byImageSize).sort().forEach(size => {
    const cursors = byImageSize[size];
    console.log(`\n${size} (${cursors.length} cursor${cursors.length > 1 ? 's' : ''}):`);
    cursors.forEach(c => {
        const match = c.cssType === c.detected ? '✅' : '❌';
        console.log(`   ${match} ${c.cssType.padEnd(20)} → detected: ${c.detected.padEnd(15)} | hotspot: (${c.hotspot.relativeX.toFixed(3)}, ${c.hotspot.relativeY.toFixed(3)})`);
    });
});

console.log('\n\n');
console.log('═'.repeat(100));
console.log('\n💡 RECOMMENDATIONS:\n');

console.log('\n1. **28x40 cursors** (hepsi aynı görünüyor):');
console.log('   - auto, default, context-menu, progress, wait, copy, no-drop, not-allowed');
console.log('   - Çözüm: NSCursor pointer comparison veya description string parsing');

console.log('\n2. **24x24 cursors**:');
console.log('   - crosshair vs move/all-scroll');
console.log('   - Hotspot farklı: crosshair=(0.458, 0.458), move=(0.5, 0.5)');

console.log('\n3. **32x32 cursors**:');
console.log('   - pointer vs grab/grabbing');
console.log('   - Hotspot farklı: pointer=(0.406, 0.25), grab=(0.5, 0.531)');
console.log('   - grab vs grabbing: description içinde "closed" var mı kontrol et');

console.log('\n4. **22x22 cursors** (tüm diagonal resize\'lar):');
console.log('   - ne-resize, nw-resize, se-resize, sw-resize, nesw-resize, nwse-resize');
console.log('   - Hepsi görsel olarak aynı - NSCursor API ile ayırt edilemez!');

console.log('\n5. **18x18 cursors**:');
console.log('   - help vs cell');
console.log('   - Ayırt edilemez - ikisi de aynı image');

console.log('\n\n');
console.log('═'.repeat(100));
console.log('\n🎯 EXPECTED ACCURACY:\n');

const total = Object.keys(mapping.cursorMapping).length;
const correct = Object.keys(mapping.cursorMapping).filter(cssType => {
    const data = mapping.cursorMapping[cssType];
    return data.detection.final === cssType;
}).length;

console.log(`Current: ${correct}/${total} = ${((correct/total)*100).toFixed(1)}%`);

// Realistic best case
const impossible = [
    'auto',  // same as default
    'context-menu', 'progress', 'wait', 'copy', 'no-drop', 'not-allowed',  // all 28x40 with same hotspot
    'move', 'all-scroll',  // same 24x24
    'cell',  // same as help
    'grabbing',  // same as grab
    'n-resize', 's-resize',  // same as ns-resize
    'e-resize', 'w-resize',  // same as ew-resize
    'ne-resize', 'nw-resize', 'se-resize', 'sw-resize', 'nesw-resize',  // all same as nwse-resize
    'zoom-out'  // same as zoom-in
];

const realistic = total - impossible.length;
console.log(`Best realistic: ${realistic}/${total} = ${((realistic/total)*100).toFixed(1)}%`);
console.log(`\nNote: ${impossible.length} cursors are visually identical to others and cannot be distinguished by image alone.`);

console.log('\n');

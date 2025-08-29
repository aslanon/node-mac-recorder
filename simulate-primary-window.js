// Simülasyon: Primary display koordinat hesabı

const displays = [
    { name: 'Display 1', x: 0, y: 0, width: 2048, height: 1330, isPrimary: true },
    { name: 'Display 2', x: -3440, y: -56, width: 3440, height: 1440, isPrimary: false }
];

// Combined frame calculation
const minX = Math.min(...displays.map(d => d.x));
const minY = Math.min(...displays.map(d => d.y));
const maxX = Math.max(...displays.map(d => d.x + d.width));
const maxY = Math.max(...displays.map(d => d.y + d.height));

const combinedFrame = {
    x: minX,
    y: minY,
    width: maxX - minX,
    height: maxY - minY
};

console.log('📐 Display Setup:');
displays.forEach(d => console.log(`  ${d.name}: (${d.x}, ${d.y}) ${d.width}x${d.height} ${d.isPrimary ? '[PRIMARY]' : ''}`));

console.log(`\n📐 Combined Frame: (${combinedFrame.x}, ${combinedFrame.y}) ${combinedFrame.width}x${combinedFrame.height}`);

// Test primary window
const primaryWindow = { x: 100, y: 100, width: 1000, height: 800 };

const globalOffset = { x: combinedFrame.x, y: combinedFrame.y };

const localX = primaryWindow.x - globalOffset.x;  // 100 - (-3440) = 3540
const localY = (combinedFrame.height - (primaryWindow.y - globalOffset.y)) - primaryWindow.height;

const localWindowCenterX = localX + (primaryWindow.width / 2);  // 3540 + 500 = 4040
const localWindowCenterY = localY + (primaryWindow.height / 2);

console.log(`\n🎯 Primary Window Test: (${primaryWindow.x}, ${primaryWindow.y}) ${primaryWindow.width}x${primaryWindow.height}`);
console.log(`  GlobalOffset: (${globalOffset.x}, ${globalOffset.y})`);
console.log(`  LocalCoords: (${localX}, ${localY})`);
console.log(`  LocalWindowCenter: (${localWindowCenterX}, ${localWindowCenterY})`);
console.log(`  Expected range for primary: X should be 0-${displays.find(d => d.isPrimary).width}`);
console.log(`  ❌ PROBLEM: LocalX ${localX} is way outside primary display bounds!`);

console.log(`\n💡 SOLUTION: Primary display windows should stay at their global positions`);
console.log(`   - Primary windows have global coords that are already correct for overlay`);
console.log(`   - Only secondary display windows need coordinate transformation`);

// Test secondary window  
const secondaryWindow = { x: -3340, y: 44, width: 3440, height: 1415 };
const secLocalX = secondaryWindow.x - globalOffset.x;  // -3340 - (-3440) = 100
const secLocalWindowCenterX = secLocalX + (secondaryWindow.width / 2);  // 100 + 1720 = 1820

console.log(`\n🎯 Secondary Window Test: (${secondaryWindow.x}, ${secondaryWindow.y}) ${secondaryWindow.width}x${secondaryWindow.height}`);
console.log(`  LocalCoords: (${secLocalX}, ???)`);
console.log(`  LocalWindowCenter: (${secLocalWindowCenterX}, ???)`);
console.log(`  ✅ This looks correct for secondary display`);
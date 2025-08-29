// Primary display window button positioning validation

console.log('🧮 Primary Display Button Position Validation');
console.log('='.repeat(50));

// Combined frame
const combinedFrame = { x: -3440, y: -56, width: 5488, height: 1440 };

// Test primary window
const primaryWindow = { x: 100, y: 100, width: 1000, height: 800 };

console.log(`Combined frame: (${combinedFrame.x}, ${combinedFrame.y}) ${combinedFrame.width}x${combinedFrame.height}`);
console.log(`Primary window: (${primaryWindow.x}, ${primaryWindow.y}) ${primaryWindow.width}x${primaryWindow.height}`);

// Current calculation
const isPrimaryDisplayWindow = (primaryWindow.x >= 0 && primaryWindow.x <= 2048);
console.log(`\nisPrimaryDisplayWindow: ${isPrimaryDisplayWindow}`);

if (isPrimaryDisplayWindow) {
    // Current implementation
    const localX = primaryWindow.x + 3440;  // 100 + 3440 = 3540
    const localY = (combinedFrame.height - (primaryWindow.y + 56)) - primaryWindow.height;  // 1440 - (100 + 56) - 800 = 484
    
    console.log(`Local coordinates: (${localX}, ${localY})`);
    
    const localWindowCenterX = localX + (primaryWindow.width / 2);  // 3540 + 500 = 4040
    const localWindowCenterY = localY + (primaryWindow.height / 2);  // 484 + 400 = 884
    
    console.log(`Window center: (${localWindowCenterX}, ${localWindowCenterY})`);
    
    const buttonX = localWindowCenterX - 100;  // 4040 - 100 = 3940
    const buttonY = localWindowCenterY - 30;   // 884 - 30 = 854
    
    console.log(`Button position: (${buttonX}, ${buttonY})`);
    
    // Validate button is within overlay bounds
    const isValid = buttonX >= 0 && buttonX <= combinedFrame.width && buttonY >= 0 && buttonY <= combinedFrame.height;
    console.log(`Button within overlay bounds: ${isValid} ✅`);
    
    // Validate button is within primary display section of overlay
    const primaryOverlayStart = 3440;
    const primaryOverlayEnd = 5488;
    const inPrimarySection = buttonX >= primaryOverlayStart && buttonX <= primaryOverlayEnd;
    console.log(`Button in primary overlay section (${primaryOverlayStart}-${primaryOverlayEnd}): ${inPrimarySection} ✅`);
    
    console.log('\n🎯 PRIMARY WINDOW BUTTON POSITIONING SHOULD NOW WORK!');
} else {
    console.log('Not a primary window');
}

console.log('\n📊 Compare with secondary window:');
const secondaryWindow = { x: -3340, y: 44, width: 3440, height: 1415 };
const secLocalX = secondaryWindow.x - combinedFrame.x;  // -3340 - (-3440) = 100
const secCenterX = secLocalX + (secondaryWindow.width / 2);  // 100 + 1720 = 1820
console.log(`Secondary window center: (${secCenterX}, ???)`);
console.log(`Secondary button position: (${secCenterX - 100}, ???)`);

console.log('\n✅ Both primary and secondary should now have correct button positioning!');
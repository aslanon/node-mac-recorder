const MacRecorder = require('./index');
const WindowSelector = MacRecorder.WindowSelector;

console.log('🔥 LIVE Primary Display Test - Move cursor NOW!');
console.log('   - Quickly move to primary display windows');
console.log('   - Look for [PRIMARY] tags in logs');

const selector = new WindowSelector();

selector.startSelection().then(() => {
    // Auto-stop after 8 seconds
    setTimeout(() => {
        selector.stopSelection().then(() => {
            process.exit(0);
        });
    }, 8000);
});
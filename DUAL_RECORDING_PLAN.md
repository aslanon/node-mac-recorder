# Dual/Multiple Window Recording Implementation Plan

## Problem
Current implementation uses **global state** in native code, allowing only ONE recording at a time.

## Goal
Support **multiple simultaneous recordings** - each with its own:
- Window/Display target
- Output file (temp_screen_0_xxx.mov, temp_screen_1_xxx.mov, etc.)
- Independent start/stop control

## Required Changes

### 1. Native Code Refactoring (screen_capture_kit.mm)

#### Current (Global State):
```objc
static SCStream *g_stream = nil;
static BOOL g_isRecording = NO;
static NSString *g_outputPath = nil;
static AVAssetWriter *g_videoWriter = nil;
```

#### New (Session-Based State):
```objc
// Recording session structure
@interface RecordingSession : NSObject
@property (nonatomic, strong) NSString *sessionId;
@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, strong) NSString *outputPath;
@property (nonatomic, strong) AVAssetWriter *videoWriter;
@property (nonatomic, strong) AVAssetWriterInput *videoInput;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, assign) BOOL isRecording;
@property (nonatomic, assign) CMTime startTime;
// ... other session-specific state
@end

// Global session registry
static NSMutableDictionary<NSString *, RecordingSession *> *g_sessions = nil;
static dispatch_queue_t g_sessionsQueue = nil;
```

#### Key Changes:

1. **Session Management Functions**:
   ```objc
   + (NSString *)createRecordingSession;
   + (RecordingSession *)getSession:(NSString *)sessionId;
   + (void)removeSession:(NSString *)sessionId;
   + (NSArray<NSString *> *)getActiveSessions;
   ```

2. **Modified API**:
   ```objc
   // Old: + (BOOL)startRecordingWithConfiguration:(NSDictionary *)config
   // New:
   + (NSString *)startRecordingWithConfiguration:(NSDictionary *)config
                                        delegate:(id)delegate
                                           error:(NSError **)error;
   // Returns: sessionId (e.g., "rec_1762850131780")

   // Old: + (void)stopRecording;
   // New:
   + (BOOL)stopRecording:(NSString *)sessionId;
   ```

3. **Stream Output Delegates**:
   - Each session needs its own video/audio output delegates
   - Delegates must know which session they belong to
   - Frame callbacks route to correct writer

### 2. JavaScript API Updates (index.js)

#### Add Session Support:

```javascript
class MacRecorder extends EventEmitter {
    constructor() {
        super();
        this.sessionId = null;  // Unique session ID from native
        this.isRecording = false;
        // ... existing code
    }

    async startRecording(outputPath, options = {}) {
        // ... existing setup code ...

        // Start native recording with session support
        const recordingOptions = {
            ...options,
            // Request specific session management
            createNewSession: true
        };

        // Native returns sessionId
        const result = nativeBinding.startRecording(
            outputPath,
            recordingOptions
        );

        this.sessionId = result.sessionId;
        this.isRecording = true;
        // ...
    }

    async stopRecording() {
        if (!this.sessionId) {
            throw new Error("No active recording session");
        }

        // Stop specific session
        const success = nativeBinding.stopRecording(this.sessionId);
        // ...
    }
}
```

### 3. File Naming Strategy

When multiple recordings are active:

```javascript
// First recording
const timestamp = Date.now();
const outputPath1 = `temp_screen_${timestamp}.mov`;

// Second recording (same timestamp, different index)
const outputPath2 = `temp_screen_1_${timestamp}.mov`;

// Third recording
const outputPath3 = `temp_screen_2_${timestamp}.mov`;
```

Or use session IDs:
```javascript
const outputPath = `temp_screen_${sessionId}.mov`;
```

## Implementation Steps

### Phase 1: Core Session Infrastructure ✅
- [ ] Create RecordingSession class
- [ ] Add session registry (Map/Dictionary)
- [ ] Implement session lifecycle methods
- [ ] Add thread-safe session access

### Phase 2: Refactor Native Recording ⏳
- [ ] Update startRecording to return sessionId
- [ ] Modify video output delegates to use session
- [ ] Modify audio output delegates to use session
- [ ] Update stopRecording to accept sessionId
- [ ] Test single session (backward compatibility)

### Phase 3: Multi-Session Support 🔜
- [ ] Test two simultaneous recordings
- [ ] Test different targets (window vs display)
- [ ] Add session limits (max 4 simultaneous?)
- [ ] Handle memory/performance implications

### Phase 4: JavaScript API 🔜
- [ ] Update MacRecorder to use sessions
- [ ] Add getActiveSessions() method
- [ ] Add getAllRecordingStatuses() method
- [ ] Update documentation

### Phase 5: Testing 🧪
- [ ] Test dual window recording
- [ ] Test dual display recording
- [ ] Test mixed (window + display)
- [ ] Performance benchmarks
- [ ] Memory usage tests

## Technical Considerations

### Memory & Performance
- Each SCStream captures frames independently
- 2 recordings @ 1080p 60fps = ~240MB/s uncompressed
- Limit simultaneous recordings (recommend max 4)
- Add memory warnings

### Thread Safety
- Use dispatch_queue for session access
- Prevent race conditions on session creation/removal
- Careful with delegate callbacks

### File Naming
- Option A: Use indices (temp_screen_0_xxx, temp_screen_1_xxx)
- Option B: Use session IDs (temp_screen_rec_xxx)
- Option C: Let user specify base name

### Backward Compatibility
- Single recording should work as before
- Default behavior: create implicit session
- Advanced users: explicit session management

## Example Usage

```javascript
const MacRecorder = require('node-mac-recorder');

async function recordTwoWindows() {
    const recorder1 = new MacRecorder();
    const recorder2 = new MacRecorder();

    const windows = await recorder1.getWindows();

    // Start both recordings
    await recorder1.startRecording('output/window1.mov', {
        windowId: windows[0].id
    });

    await recorder2.startRecording('output/window2.mov', {
        windowId: windows[1].id
    });

    // Record for 10 seconds
    await new Promise(r => setTimeout(r, 10000));

    // Stop both
    await recorder1.stopRecording();
    await recorder2.stopRecording();

    console.log('Both recordings complete!');
}
```

## Timeline Estimate

- **Phase 1-2**: 4-6 hours (core infrastructure)
- **Phase 3**: 2-3 hours (multi-session testing)
- **Phase 4**: 1-2 hours (JS API updates)
- **Phase 5**: 2-3 hours (comprehensive testing)

**Total: ~10-14 hours** for complete implementation

## Questions to Decide

1. **Session Limit**: Max how many simultaneous recordings? (Recommend 2-4)
2. **File Naming**: Automatic indices or user-specified?
3. **API Style**: Explicit sessions or implicit (current MacRecorder instances)?
4. **Performance**: Add automatic quality reduction for multiple streams?
5. **Error Handling**: What if one session fails? Stop all or continue others?

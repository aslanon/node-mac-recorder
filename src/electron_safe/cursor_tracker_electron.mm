#import <napi.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>

// Thread-safe cursor tracking for Electron
static dispatch_queue_t g_cursorQueue = nil;

static void initializeCursorQueue() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_cursorQueue = dispatch_queue_create("com.macrecorder.cursor.electron", DISPATCH_QUEUE_SERIAL);
    });
}

// NAPI Function: Get Cursor Position (Electron-safe)
Napi::Value GetCursorPositionElectronSafe(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        initializeCursorQueue();
        
        __block CGPoint mouseLocation = CGPointZero;
        __block NSString *cursorType = @"arrow";
        
        dispatch_sync(g_cursorQueue, ^{
            @try {
                // Get mouse location
                mouseLocation = [NSEvent mouseLocation];
                
                // Convert to screen coordinates (flip Y)
                NSArray *screens = [NSScreen screens];
                if (screens.count > 0) {
                    NSScreen *mainScreen = screens[0];
                    CGFloat screenHeight = mainScreen.frame.size.height;
                    mouseLocation.y = screenHeight - mouseLocation.y;
                }
                
                // Get cursor type safely
                NSCursor *currentCursor = [NSCursor currentCursor];
                if (currentCursor) {
                    if (currentCursor == [NSCursor arrowCursor]) {
                        cursorType = @"arrow";
                    } else if (currentCursor == [NSCursor IBeamCursor]) {
                        cursorType = @"ibeam";
                    } else if (currentCursor == [NSCursor pointingHandCursor]) {
                        cursorType = @"hand";
                    } else if (currentCursor == [NSCursor resizeLeftRightCursor]) {
                        cursorType = @"resize-horizontal";
                    } else if (currentCursor == [NSCursor resizeUpDownCursor]) {
                        cursorType = @"resize-vertical";
                    } else {
                        cursorType = @"default";
                    }
                }
                
            } @catch (NSException *e) {
                NSLog(@"❌ Exception getting cursor position: %@", e.reason);
            }
        });
        
        Napi::Object result = Napi::Object::New(env);
        result.Set("x", Napi::Number::New(env, mouseLocation.x));
        result.Set("y", Napi::Number::New(env, mouseLocation.y));
        result.Set("cursorType", Napi::String::New(env, [cursorType UTF8String]));
        result.Set("eventType", Napi::String::New(env, "move"));
        
        return result;
        
    } @catch (NSException *e) {
        NSLog(@"❌ Fatal exception in GetCursorPositionElectronSafe: %@", e.reason);
        Napi::Error::New(env, "Failed to get cursor position").ThrowAsJavaScriptException();
        return env.Null();
    }
}

// Initialize cursor tracker module
Napi::Object InitCursorTrackerElectron(Napi::Env env, Napi::Object exports) {
    @try {
        initializeCursorQueue();
        
        exports.Set("getCursorPosition", Napi::Function::New(env, GetCursorPositionElectronSafe));
        
        NSLog(@"✅ Electron-safe cursor tracker initialized");
        return exports;
        
    } @catch (NSException *e) {
        NSLog(@"❌ Exception initializing cursor tracker: %@", e.reason);
        return exports;
    }
}

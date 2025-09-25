#import <napi.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>
#import "../logging.h"

// Thread-safe cursor tracking for Electron
static dispatch_queue_t g_cursorQueue = nil;

static void initializeCursorQueue() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_cursorQueue = dispatch_queue_create("com.macrecorder.cursor.electron", DISPATCH_QUEUE_SERIAL);
    });
}

static NSString* MapCursorToType(NSCursor *cursor) {
    if (!cursor) return @"default";

    if (cursor == [NSCursor arrowCursor]) return @"default";
    if (cursor == [NSCursor IBeamCursor]) return @"text";
    if ([NSCursor respondsToSelector:@selector(IBeamCursorForVerticalLayout)] &&
        cursor == [NSCursor IBeamCursorForVerticalLayout]) return @"text";
    if (cursor == [NSCursor pointingHandCursor]) return @"pointer";
    if ([NSCursor respondsToSelector:@selector(resizeLeftRightCursor)]) {
        if (cursor == [NSCursor resizeLeftRightCursor] ||
            [NSCursor instancesRespondToSelector:@selector(resizeLeftCursor)] && (cursor == [NSCursor resizeLeftCursor]) ||
            [NSCursor instancesRespondToSelector:@selector(resizeRightCursor)] && (cursor == [NSCursor resizeRightCursor])) {
            return @"col-resize";
        }
    }
    if ([NSCursor respondsToSelector:@selector(resizeUpDownCursor)]) {
        if (cursor == [NSCursor resizeUpDownCursor] ||
            [NSCursor instancesRespondToSelector:@selector(resizeUpCursor)] && (cursor == [NSCursor resizeUpCursor]) ||
            [NSCursor instancesRespondToSelector:@selector(resizeDownCursor)] && (cursor == [NSCursor resizeDownCursor])) {
            return @"ns-resize";
        }
    }
    if ([NSCursor respondsToSelector:@selector(openHandCursor)] && cursor == [NSCursor openHandCursor]) return @"grab";
    if ([NSCursor respondsToSelector:@selector(closedHandCursor)] && cursor == [NSCursor closedHandCursor]) return @"grabbing";
    if ([NSCursor respondsToSelector:@selector(crosshairCursor)] && cursor == [NSCursor crosshairCursor]) return @"crosshair";
    if ([NSCursor respondsToSelector:@selector(operationNotAllowedCursor)] && cursor == [NSCursor operationNotAllowedCursor]) return @"not-allowed";
    if ([NSCursor respondsToSelector:@selector(dragCopyCursor)] && cursor == [NSCursor dragCopyCursor]) return @"copy";
    if ([NSCursor respondsToSelector:@selector(dragLinkCursor)] && cursor == [NSCursor dragLinkCursor]) return @"alias";
    if ([NSCursor respondsToSelector:@selector(contextualMenuCursor)] && cursor == [NSCursor contextualMenuCursor]) return @"context-menu";

    return @"default";
}

// NAPI Function: Get Cursor Position (Electron-safe)
Napi::Value GetCursorPositionElectronSafe(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        initializeCursorQueue();
        __block CGPoint mouseLocation = CGPointZero;
        __block NSString *cursorType = @"default";

        dispatch_sync(g_cursorQueue, ^{
            @try {
                // Use CGEventGetLocation to match global logical coordinates used elsewhere
                CGEventRef event = CGEventCreate(NULL);
                mouseLocation = CGEventGetLocation(event);
                if (event) CFRelease(event);

                // Prefer currentSystemCursor when available for accurate system-wide state
                NSCursor *cursor = nil;
                if ([NSCursor respondsToSelector:@selector(currentSystemCursor)]) {
                    cursor = [NSCursor performSelector:@selector(currentSystemCursor)];
                }
                if (!cursor) {
                    cursor = [NSCursor currentCursor];
                }
                cursorType = MapCursorToType(cursor);
                MRLog(@"Electron-safe cursor: %@ at (%.0f,%.0f)", cursorType, mouseLocation.x, mouseLocation.y);
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
        
        MRLog(@"✅ Electron-safe cursor tracker initialized");
        return exports;
        
    } @catch (NSException *e) {
        NSLog(@"❌ Exception initializing cursor tracker: %@", e.reason);
        return exports;
    }
}

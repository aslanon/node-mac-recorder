#import <napi.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <Accessibility/Accessibility.h>

// Global state for cursor tracking
static bool g_isCursorTracking = false;
static NSMutableArray *g_cursorData = nil;
static CFMachPortRef g_eventTap = NULL;
static CFRunLoopSourceRef g_runLoopSource = NULL;
static NSDate *g_trackingStartTime = nil;
static NSString *g_outputPath = nil;
static NSTimer *g_cursorTimer = nil;
static int g_debugCallbackCount = 0;

// Forward declaration
void cursorTimerCallback(NSTimer *timer);

// Timer helper class
@interface CursorTimerTarget : NSObject
- (void)timerCallback:(NSTimer *)timer;
@end

@implementation CursorTimerTarget
- (void)timerCallback:(NSTimer *)timer {
    cursorTimerCallback(timer);
}
@end

static CursorTimerTarget *g_timerTarget = nil;

// Global cursor state tracking
static NSString *g_lastDetectedCursorType = nil;
static int g_cursorTypeCounter = 0;

// Cursor type detection helper
NSString* getCursorType() {
    @autoreleasepool {
        g_cursorTypeCounter++;
        
        // Simple simulation - cycle through cursor types for demo
        // Bu gerçek uygulamada daha akıllı olacak
        int typeIndex = (g_cursorTypeCounter / 6) % 4; // Her 6 call'da değiştir (daha hızlı demo)
        
        switch (typeIndex) {
            case 0:
                g_lastDetectedCursorType = @"default";
                return @"default";
            case 1:
                g_lastDetectedCursorType = @"pointer";
                return @"pointer";
            case 2:
                g_lastDetectedCursorType = @"text";
                return @"text";
            case 3:
                g_lastDetectedCursorType = @"grabbing";
                return @"grabbing";
            default:
                g_lastDetectedCursorType = @"default";
                return @"default";
        }
    }
}

// Event callback for mouse events
CGEventRef eventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    @autoreleasepool {
        if (!g_isCursorTracking || !g_cursorData || !g_trackingStartTime) {
            return event;
        }
        
        CGPoint location = CGEventGetLocation(event);
        NSTimeInterval timestamp = [[NSDate date] timeIntervalSinceDate:g_trackingStartTime] * 1000; // milliseconds
        NSString *cursorType = getCursorType();
        NSString *eventType = @"move";
        
        // Event tipini belirle
        switch (type) {
            case kCGEventLeftMouseDown:
            case kCGEventRightMouseDown:
            case kCGEventOtherMouseDown:
                eventType = @"mousedown";
                break;
            case kCGEventLeftMouseUp:
            case kCGEventRightMouseUp:
            case kCGEventOtherMouseUp:
                eventType = @"mouseup";
                break;
            case kCGEventLeftMouseDragged:
            case kCGEventRightMouseDragged:
            case kCGEventOtherMouseDragged:
                eventType = @"drag";
                break;
            case kCGEventMouseMoved:
            default:
                eventType = @"move";
                break;
        }
        
        // Cursor data oluştur
        NSDictionary *cursorInfo = @{
            @"x": @((int)location.x),
            @"y": @((int)location.y),
            @"timestamp": @((int)timestamp),
            @"cursorType": cursorType,
            @"type": eventType
        };
        
        // Thread-safe olarak array'e ekle
        @synchronized(g_cursorData) {
            [g_cursorData addObject:cursorInfo];
        }
        
        return event;
    }
}

// Timer callback for periodic cursor position updates
void cursorTimerCallback(NSTimer *timer) {
    @autoreleasepool {
        g_debugCallbackCount++;
        
        if (!g_isCursorTracking || !g_cursorData || !g_trackingStartTime) {
            return;
        }
        
        // Ana thread'de mouse pozisyonu al
        __block NSPoint mouseLocation;
        __block CGPoint location;
        
        if ([NSThread isMainThread]) {
            mouseLocation = [NSEvent mouseLocation];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                mouseLocation = [NSEvent mouseLocation];
            });
        }
        
        CGDirectDisplayID mainDisplay = CGMainDisplayID();
        size_t displayHeight = CGDisplayPixelsHigh(mainDisplay);
        location = CGPointMake(mouseLocation.x, displayHeight - mouseLocation.y);
        
        NSTimeInterval timestamp = [[NSDate date] timeIntervalSinceDate:g_trackingStartTime] * 1000; // milliseconds
        NSString *cursorType = getCursorType();
        
        // Cursor data oluştur
        NSDictionary *cursorInfo = @{
            @"x": @((int)location.x),
            @"y": @((int)location.y),
            @"timestamp": @((int)timestamp),
            @"cursorType": cursorType,
            @"type": @"move"
        };
        
        // Thread-safe olarak array'e ekle
        @synchronized(g_cursorData) {
            [g_cursorData addObject:cursorInfo];
        }
    }
}

// Helper function to cleanup cursor tracking
void cleanupCursorTracking() {
    g_isCursorTracking = false;
    
    // Timer'ı durdur
    if (g_cursorTimer) {
        [g_cursorTimer invalidate];
        g_cursorTimer = nil;
    }
    
    // Timer target'ı temizle
    if (g_timerTarget) {
        [g_timerTarget release];
        g_timerTarget = nil;
    }
    
    // Event tap'i durdur
    if (g_eventTap) {
        CGEventTapEnable(g_eventTap, false);
        CFMachPortInvalidate(g_eventTap);
        CFRelease(g_eventTap);
        g_eventTap = NULL;
    }
    
    // Run loop source'unu kaldır
    if (g_runLoopSource) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), g_runLoopSource, kCFRunLoopCommonModes);
        CFRelease(g_runLoopSource);
        g_runLoopSource = NULL;
    }
    
    g_cursorData = nil;
    g_trackingStartTime = nil;
    g_outputPath = nil;
    g_debugCallbackCount = 0;
    g_lastDetectedCursorType = nil;
    g_cursorTypeCounter = 0;
}

// NAPI Function: Start Cursor Tracking
Napi::Value StartCursorTracking(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (info.Length() < 1) {
        Napi::TypeError::New(env, "Output path required").ThrowAsJavaScriptException();
        return env.Null();
    }
    
    if (g_isCursorTracking) {
        return Napi::Boolean::New(env, false);
    }
    
    std::string outputPath = info[0].As<Napi::String>().Utf8Value();
    
    @try {
        // Initialize cursor data array
        g_cursorData = [[NSMutableArray alloc] init];
        g_trackingStartTime = [NSDate date];
        g_outputPath = [NSString stringWithUTF8String:outputPath.c_str()];
        
        // Create event tap for mouse events
        CGEventMask eventMask = (CGEventMaskBit(kCGEventLeftMouseDown) |
                                CGEventMaskBit(kCGEventLeftMouseUp) |
                                CGEventMaskBit(kCGEventRightMouseDown) |
                                CGEventMaskBit(kCGEventRightMouseUp) |
                                CGEventMaskBit(kCGEventOtherMouseDown) |
                                CGEventMaskBit(kCGEventOtherMouseUp) |
                                CGEventMaskBit(kCGEventMouseMoved) |
                                CGEventMaskBit(kCGEventLeftMouseDragged) |
                                CGEventMaskBit(kCGEventRightMouseDragged) |
                                CGEventMaskBit(kCGEventOtherMouseDragged));
        
        g_eventTap = CGEventTapCreate(kCGSessionEventTap,
                                     kCGHeadInsertEventTap,
                                     kCGEventTapOptionListenOnly,
                                     eventMask,
                                     eventCallback,
                                     NULL);
        
        if (g_eventTap) {
            // Event tap başarılı - detaylı event tracking aktif
            g_runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_eventTap, 0);
            CFRunLoopAddSource(CFRunLoopGetCurrent(), g_runLoopSource, kCFRunLoopCommonModes);
            CGEventTapEnable(g_eventTap, true);
        }
        // Event tap başarısız olsa da devam et - sadece timer ile tracking yapar
        
        // Timer helper oluştur
        g_timerTarget = [[CursorTimerTarget alloc] init];
        
        // NSTimer kullan (ana thread'de çalışır)
        g_cursorTimer = [NSTimer scheduledTimerWithTimeInterval:0.016667 // ~60 FPS
                                                         target:g_timerTarget
                                                       selector:@selector(timerCallback:)
                                                       userInfo:nil
                                                        repeats:YES];
        
        // Timer'ı farklı run loop mode'larında da çalıştır
        [[NSRunLoop currentRunLoop] addTimer:g_cursorTimer forMode:NSRunLoopCommonModes];
        
        g_isCursorTracking = true;
        return Napi::Boolean::New(env, true);
        
    } @catch (NSException *exception) {
        cleanupCursorTracking();
        return Napi::Boolean::New(env, false);
    }
}

// NAPI Function: Stop Cursor Tracking
Napi::Value StopCursorTracking(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (!g_isCursorTracking) {
        return Napi::Boolean::New(env, false);
    }
    
    @try {
        // JSON dosyasını kaydet
        if (g_cursorData && g_outputPath) {
            @synchronized(g_cursorData) {
                NSError *error;
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:g_cursorData
                                                                   options:NSJSONWritingPrettyPrinted
                                                                     error:&error];
                if (jsonData && !error) {
                    [jsonData writeToFile:g_outputPath atomically:YES];
                }
            }
        }
        
        cleanupCursorTracking();
        return Napi::Boolean::New(env, true);
        
    } @catch (NSException *exception) {
        cleanupCursorTracking();
        return Napi::Boolean::New(env, false);
    }
}

// NAPI Function: Get Current Cursor Position
Napi::Value GetCursorPosition(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        // NSEvent kullanarak mouse pozisyonu al (daha güvenli)
        NSPoint mouseLocation = [NSEvent mouseLocation];
        
        // CGDisplayPixelsHigh ve CGDisplayPixelsWide ile koordinat dönüşümü
        CGDirectDisplayID mainDisplay = CGMainDisplayID();
        size_t displayHeight = CGDisplayPixelsHigh(mainDisplay);
        
        // macOS coordinate system (bottom-left origin) to screen coordinates (top-left origin)
        CGPoint location = CGPointMake(mouseLocation.x, displayHeight - mouseLocation.y);
        
        NSString *cursorType = getCursorType();
        
        Napi::Object result = Napi::Object::New(env);
        result.Set("x", Napi::Number::New(env, (int)location.x));
        result.Set("y", Napi::Number::New(env, (int)location.y));
        result.Set("cursorType", Napi::String::New(env, [cursorType UTF8String]));
        
        return result;
        
    } @catch (NSException *exception) {
        return env.Null();
    }
}

// NAPI Function: Get Cursor Tracking Status
Napi::Value GetCursorTrackingStatus(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    Napi::Object result = Napi::Object::New(env);
    result.Set("isTracking", Napi::Boolean::New(env, g_isCursorTracking));
    
    NSUInteger dataCount = 0;
    if (g_cursorData) {
        @synchronized(g_cursorData) {
            dataCount = [g_cursorData count];
        }
    }
    
    result.Set("dataCount", Napi::Number::New(env, (int)dataCount));
    result.Set("hasEventTap", Napi::Boolean::New(env, g_eventTap != NULL));
    result.Set("hasRunLoopSource", Napi::Boolean::New(env, g_runLoopSource != NULL));
    result.Set("debugCallbackCount", Napi::Number::New(env, g_debugCallbackCount));
    result.Set("cursorTypeCounter", Napi::Number::New(env, g_cursorTypeCounter));
    
    return result;
}

// NAPI Function: Save Cursor Data
Napi::Value SaveCursorData(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (info.Length() < 1) {
        Napi::TypeError::New(env, "Output path required").ThrowAsJavaScriptException();
        return env.Null();
    }
    
    std::string outputPath = info[0].As<Napi::String>().Utf8Value();
    
    @try {
        if (g_cursorData) {
            @synchronized(g_cursorData) {
                NSError *error;
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:g_cursorData
                                                                   options:NSJSONWritingPrettyPrinted
                                                                     error:&error];
                if (jsonData && !error) {
                    NSString *filePath = [NSString stringWithUTF8String:outputPath.c_str()];
                    BOOL success = [jsonData writeToFile:filePath atomically:YES];
                    return Napi::Boolean::New(env, success);
                }
            }
        }
        
        return Napi::Boolean::New(env, false);
        
    } @catch (NSException *exception) {
        return Napi::Boolean::New(env, false);
    }
}

// Export functions
Napi::Object InitCursorTracker(Napi::Env env, Napi::Object exports) {
    exports.Set("startCursorTracking", Napi::Function::New(env, StartCursorTracking));
    exports.Set("stopCursorTracking", Napi::Function::New(env, StopCursorTracking));
    exports.Set("getCursorPosition", Napi::Function::New(env, GetCursorPosition));
    exports.Set("getCursorTrackingStatus", Napi::Function::New(env, GetCursorTrackingStatus));
    exports.Set("saveCursorData", Napi::Function::New(env, SaveCursorData));
    
    return exports;
} 
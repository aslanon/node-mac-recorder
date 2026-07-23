// keyboard_tracker.mm
// Kayıt sırasında kullanıcının klavye KISAYOLLARINI (shortcut) yakalar.
// cursor_tracker.mm'deki CGEventTap altyapısıyla aynı desende çalışır: global bir
// keyDown event tap kurar, her kısayol basımını zaman damgalı JSON olarak dosyaya
// yazar. GİZLİLİK: yalnızca bir modifier (⌘ / ⌃ / ⌥) ile birlikte basılan tuşlar
// yakalanır; düz metin yazımı (parola vb.) KAYDEDİLMEZ.

#import <napi.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Carbon/Carbon.h>
#import "logging.h"

// ---- Global durum (tek aktif oturum) --------------------------------------
static CFMachPortRef g_kbEventTap = NULL;
static CFRunLoopSourceRef g_kbRunLoopSource = NULL;
static NSFileHandle *g_kbFileHandle = nil;
static NSString *g_kbOutputPath = nil;
static BOOL g_kbIsTracking = NO;
static BOOL g_kbIsFirstWrite = YES;
static double g_kbStartUnixMs = 0.0; // Senkron için referans başlangıç (ms)

static double NowUnixMs() {
    return [[NSDate date] timeIntervalSince1970] * 1000.0;
}

// Özel (yazılamayan) tuşların okunabilir isimleri. Diğer tuşlar için
// charactersIgnoringModifiers kullanılır.
static NSString *SpecialKeyName(unsigned short keyCode) {
    switch (keyCode) {
        case kVK_Return:        return @"Enter";
        case kVK_ANSI_KeypadEnter: return @"Enter";
        case kVK_Tab:           return @"Tab";
        case kVK_Space:         return @"Space";
        case kVK_Delete:        return @"Delete";      // Backspace
        case kVK_ForwardDelete: return @"ForwardDelete";
        case kVK_Escape:        return @"Esc";
        case kVK_Home:          return @"Home";
        case kVK_End:           return @"End";
        case kVK_PageUp:        return @"PageUp";
        case kVK_PageDown:      return @"PageDown";
        case kVK_LeftArrow:     return @"Left";
        case kVK_RightArrow:    return @"Right";
        case kVK_DownArrow:     return @"Down";
        case kVK_UpArrow:       return @"Up";
        case kVK_F1:  return @"F1";
        case kVK_F2:  return @"F2";
        case kVK_F3:  return @"F3";
        case kVK_F4:  return @"F4";
        case kVK_F5:  return @"F5";
        case kVK_F6:  return @"F6";
        case kVK_F7:  return @"F7";
        case kVK_F8:  return @"F8";
        case kVK_F9:  return @"F9";
        case kVK_F10: return @"F10";
        case kVK_F11: return @"F11";
        case kVK_F12: return @"F12";
        default:      return nil;
    }
}

static NSString *JsonEscape(NSString *input) {
    if (!input) return @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:input.length + 2];
    NSUInteger len = input.length;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [input characterAtIndex:i];
        switch (c) {
            case '"':  [out appendString:@"\\\""]; break;
            case '\\': [out appendString:@"\\\\"]; break;
            case '\n': [out appendString:@"\\n"]; break;
            case '\r': [out appendString:@"\\r"]; break;
            case '\t': [out appendString:@"\\t"]; break;
            default:
                if (c < 0x20) {
                    [out appendFormat:@"\\u%04x", c];
                } else {
                    [out appendFormat:@"%C", c];
                }
        }
    }
    return out;
}

static void WriteKeyboardEvent(NSString *jsonObject) {
    if (!g_kbFileHandle || !jsonObject) return;
    @try {
        NSString *chunk = g_kbIsFirstWrite ? jsonObject : [@"," stringByAppendingString:jsonObject];
        [g_kbFileHandle writeData:[chunk dataUsingEncoding:NSUTF8StringEncoding]];
        g_kbIsFirstWrite = NO;
    } @catch (NSException *e) {
        // Sessizce devam et
    }
}

// keyDown event callback — yalnızca modifier'lı basımları (kısayol) yazar.
static CGEventRef KeyboardEventCallback(CGEventTapProxy proxy,
                                        CGEventType type,
                                        CGEventRef event,
                                        void *refcon) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (g_kbEventTap) {
            CGEventTapEnable(g_kbEventTap, true);
        }
        return event;
    }

    if (type != kCGEventKeyDown || !g_kbIsTracking) {
        return event;
    }

    @autoreleasepool {
        CGEventFlags flags = CGEventGetFlags(event);
        BOOL hasCommand = (flags & kCGEventFlagMaskCommand) != 0;
        BOOL hasControl = (flags & kCGEventFlagMaskControl) != 0;
        BOOL hasOption  = (flags & kCGEventFlagMaskAlternate) != 0;
        BOOL hasShift   = (flags & kCGEventFlagMaskShift) != 0;
        BOOL hasFn      = (flags & kCGEventFlagMaskSecondaryFn) != 0;

        // GİZLİLİK: Kısayol = ⌘ / ⌃ / ⌥ içermeli. Sadece Shift veya düz tuş → atla.
        if (!(hasCommand || hasControl || hasOption)) {
            return event;
        }

        unsigned short keyCode = (unsigned short)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);

        NSString *keyName = SpecialKeyName(keyCode);
        NSString *chars = @"";
        NSEvent *nsEvent = nil;
        @try {
            nsEvent = [NSEvent eventWithCGEvent:event];
        } @catch (NSException *e) {
            nsEvent = nil;
        }
        if (!keyName) {
            NSString *raw = nsEvent ? [nsEvent charactersIgnoringModifiers] : nil;
            if (raw.length > 0) {
                chars = raw;
                keyName = [raw uppercaseString];
            } else {
                keyName = [NSString stringWithFormat:@"Key%d", (int)keyCode];
            }
        } else {
            chars = keyName;
        }

        double unixMs = NowUnixMs();
        double relMs = g_kbStartUnixMs > 0 ? (unixMs - g_kbStartUnixMs) : 0.0;
        if (relMs < 0) relMs = 0;

        NSString *json = [NSString stringWithFormat:
            @"{\"timestamp\":%.0f,\"unixTimeMs\":%.0f,\"type\":\"keydown\",\"keyCode\":%d,"
            @"\"key\":\"%@\",\"chars\":\"%@\",\"modifiers\":{\"meta\":%@,\"control\":%@,"
            @"\"alt\":%@,\"shift\":%@,\"fn\":%@}}",
            relMs, unixMs, (int)keyCode,
            JsonEscape(keyName), JsonEscape(chars),
            hasCommand ? @"true" : @"false",
            hasControl ? @"true" : @"false",
            hasOption ? @"true" : @"false",
            hasShift ? @"true" : @"false",
            hasFn ? @"true" : @"false"];

        WriteKeyboardEvent(json);
    }

    return event;
}

static void CleanupKeyboardTracking() {
    g_kbIsTracking = NO;

    if (g_kbFileHandle) {
        @try {
            // Açılış "[" başlangıçta yazıldığı için burada her zaman sadece "]" ile kapat.
            // (boş durumda dosya "[]" olur, dolu durumda "[{...},{...}]")
            [g_kbFileHandle writeData:[@"]" dataUsingEncoding:NSUTF8StringEncoding]];
            [g_kbFileHandle synchronizeFile];
            [g_kbFileHandle closeFile];
        } @catch (NSException *e) {
            // yut
        }
        g_kbFileHandle = nil;
    }

    if (g_kbEventTap) {
        CGEventTapEnable(g_kbEventTap, false);
        // CFRelease yapmıyoruz — cursor_tracker.mm ile aynı yaklaşım (sistem yönetsin)
        g_kbEventTap = NULL;
    }
    if (g_kbRunLoopSource) {
        g_kbRunLoopSource = NULL;
    }

    g_kbOutputPath = nil;
    g_kbIsFirstWrite = YES;
    g_kbStartUnixMs = 0.0;
}

// ---- NAPI: startKeyboardTracking(outputPath, startTimestampMs?) -----------
Napi::Value StartKeyboardTracking(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    if (info.Length() < 1 || !info[0].IsString()) {
        Napi::TypeError::New(env, "Output path required").ThrowAsJavaScriptException();
        return env.Null();
    }

    if (g_kbIsTracking) {
        return Napi::Boolean::New(env, false);
    }

    std::string outputPath = info[0].As<Napi::String>().Utf8Value();
    double startTs = 0.0;
    if (info.Length() >= 2 && info[1].IsNumber()) {
        startTs = info[1].As<Napi::Number>().DoubleValue();
    }

    @try {
        g_kbOutputPath = [NSString stringWithUTF8String:outputPath.c_str()];

        [[NSFileManager defaultManager] createFileAtPath:g_kbOutputPath contents:nil attributes:nil];
        g_kbFileHandle = [[NSFileHandle fileHandleForWritingAtPath:g_kbOutputPath] retain];
        if (!g_kbFileHandle) {
            return Napi::Boolean::New(env, false);
        }
        [g_kbFileHandle truncateFileAtOffset:0];
        [g_kbFileHandle writeData:[@"[" dataUsingEncoding:NSUTF8StringEncoding]];

        g_kbIsFirstWrite = YES;
        g_kbStartUnixMs = startTs > 0 ? startTs : NowUnixMs();

        CGEventMask eventMask = CGEventMaskBit(kCGEventKeyDown);
        g_kbEventTap = CGEventTapCreate(kCGSessionEventTap,
                                        kCGHeadInsertEventTap,
                                        kCGEventTapOptionListenOnly,
                                        eventMask,
                                        KeyboardEventCallback,
                                        NULL);

        if (!g_kbEventTap) {
            NSLog(@"⚠️  Failed to create keyboard event tap (requires Accessibility permission)");
            CleanupKeyboardTracking();
            return Napi::Boolean::New(env, false);
        }

        g_kbRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_kbEventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), g_kbRunLoopSource, kCFRunLoopCommonModes);
        CGEventTapEnable(g_kbEventTap, true);

        g_kbIsTracking = YES;
        NSLog(@"✅ Keyboard shortcut tracking active");
        return Napi::Boolean::New(env, true);
    } @catch (NSException *exception) {
        CleanupKeyboardTracking();
        return Napi::Boolean::New(env, false);
    }
}

// ---- NAPI: stopKeyboardTracking() -----------------------------------------
Napi::Value StopKeyboardTracking(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (!g_kbIsTracking) {
        return Napi::Boolean::New(env, false);
    }
    @try {
        CleanupKeyboardTracking();
        return Napi::Boolean::New(env, true);
    } @catch (NSException *exception) {
        CleanupKeyboardTracking();
        return Napi::Boolean::New(env, false);
    }
}

// ---- NAPI: getKeyboardTrackingStatus() ------------------------------------
Napi::Value GetKeyboardTrackingStatus(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    Napi::Object status = Napi::Object::New(env);
    status.Set("isTracking", Napi::Boolean::New(env, g_kbIsTracking));
    status.Set("outputPath",
               g_kbOutputPath ? Napi::String::New(env, [g_kbOutputPath UTF8String])
                              : env.Null());
    return status;
}

Napi::Object InitKeyboardTracker(Napi::Env env, Napi::Object exports) {
    exports.Set("startKeyboardTracking", Napi::Function::New(env, StartKeyboardTracking));
    exports.Set("stopKeyboardTracking", Napi::Function::New(env, StopKeyboardTracking));
    exports.Set("getKeyboardTrackingStatus", Napi::Function::New(env, GetKeyboardTrackingStatus));
    return exports;
}

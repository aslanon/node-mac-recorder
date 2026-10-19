// scroll_tracker.mm
// Kayıt sırasında SAYFA KAYDIRMA girdisini yakalar (Creavit Scroll Reconstruction).
//
//  - Mouse tekerleği ve trackpad: kCGEventScrollWheel (piksel delta, sürekli mi,
//    parmak fazı, momentum fazı). Trackpad'de parmak kalktıktan sonraki kayma
//    (momentum) ayrıca işaretlenir.
//  - Klavye ile kaydırma: PageUp/PageDown, Space, Home/End, ↑/↓ (⌘/⌃/⌥ olmadan).
//
// Olaylar bellekte bir tamponda tutulur; JS tarafı (index.js cursor yakalama
// döngüsü) drainScrollEvents() ile alıp cursor dosyasına `type: "scroll"`
// kaydı olarak, cursor ile AYNI zaman ve koordinat dönüşümüyle yazar.
//
// GİZLİLİK: hiçbir yazı tuşu kaydedilmez. Yazı tuşlarına yalnızca "son yazma
// anı" için bakılır: yazarken basılan Space / ok tuşları kaydırma sayılmaz ve
// kaydedilmez (metin içinde imleç hareketi ya da kelime arası boşluk).

#import <napi.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Carbon/Carbon.h>
#include <mutex>
#include <string>
#include <vector>
#import "sync_timeline.h"

namespace {

struct ScrollEventRecord {
    double unixMs;
    double x;
    double y;
    double deltaY;
    double deltaX;
    int continuous;   // 1 = trackpad / Magic Mouse (piksel hassasiyetli), 0 = tekerlek
    int phase;        // kCGScrollWheelEventScrollPhase (1 began, 2 changed, 4 ended, 8 cancelled, 128 may begin)
    int momentumPhase;// kCGScrollWheelEventMomentumPhase (1 begin, 2 continue, 3 end)
    std::string key;  // klavye ile kaydırmada tuş adı, aksi halde boş
};

constexpr size_t kMaxBufferedEvents = 8192;
constexpr double kTypingQuietMs = 1500.0;

std::mutex g_scrollMutex;
std::vector<ScrollEventRecord> g_scrollEvents;
CFMachPortRef g_scrollEventTap = NULL;
CFRunLoopSourceRef g_scrollRunLoopSource = NULL;
bool g_scrollIsTracking = false;
double g_lastTypingUnixMs = 0.0;
size_t g_droppedEvents = 0;

double NowUnixMs() {
    return [[NSDate date] timeIntervalSince1970] * 1000.0;
}

const char *ScrollKeyName(CGKeyCode keyCode) {
    switch (keyCode) {
        case kVK_PageDown:  return "PageDown";
        case kVK_PageUp:    return "PageUp";
        case kVK_Space:     return "Space";
        case kVK_Home:      return "Home";
        case kVK_End:       return "End";
        case kVK_DownArrow: return "Down";
        case kVK_UpArrow:   return "Up";
        default:            return nullptr;
    }
}

void PushEvent(const ScrollEventRecord &record) {
    std::lock_guard<std::mutex> lock(g_scrollMutex);
    if (g_scrollEvents.size() >= kMaxBufferedEvents) {
        // JS döngüsü takılırsa en eskiyi at (bellek sınırı).
        g_scrollEvents.erase(g_scrollEvents.begin());
        g_droppedEvents += 1;
    }
    g_scrollEvents.push_back(record);
}

CGEventRef ScrollEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (g_scrollEventTap) CGEventTapEnable(g_scrollEventTap, true);
        return event;
    }
    if (!g_scrollIsTracking || MRSyncIsPaused()) return event;

    @autoreleasepool {
        const double now = NowUnixMs();
        if (type == kCGEventScrollWheel) {
            const CGPoint location = CGEventGetLocation(event);
            ScrollEventRecord record;
            record.unixMs = now;
            record.x = location.x;
            record.y = location.y;
            record.continuous = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous);
            // Piksel deltası (her iki cihaz için de); tekerlekte satır deltası × satır yüksekliği.
            record.deltaY = CGEventGetDoubleValueField(event, kCGScrollWheelEventPointDeltaAxis1);
            record.deltaX = CGEventGetDoubleValueField(event, kCGScrollWheelEventPointDeltaAxis2);
            record.phase = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventScrollPhase);
            record.momentumPhase = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventMomentumPhase);
            if (record.deltaY == 0 && record.deltaX == 0 && record.phase == 0 && record.momentumPhase == 0) {
                return event;
            }
            PushEvent(record);
            return event;
        }

        if (type == kCGEventKeyDown) {
            const CGEventFlags flags = CGEventGetFlags(event);
            const bool shortcut = (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate)) != 0;
            const CGKeyCode keyCode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
            const char *name = ScrollKeyName(keyCode);
            if (!name) {
                // Yazı tuşu: KAYDEDİLMEZ, yalnızca zamanı hatırlanır.
                if (!shortcut) g_lastTypingUnixMs = now;
                return event;
            }
            if (shortcut) return event;
            if (now - g_lastTypingUnixMs < kTypingQuietMs) return event;
            const CGPoint location = CGEventGetLocation(event);
            ScrollEventRecord record;
            record.unixMs = now;
            record.x = location.x;
            record.y = location.y;
            record.deltaY = 0;
            record.deltaX = 0;
            record.continuous = 0;
            record.phase = 0;
            record.momentumPhase = 0;
            record.key = name;
            if (keyCode == kVK_Space && (flags & kCGEventFlagMaskShift)) record.key = "ShiftSpace";
            PushEvent(record);
        }
    }
    return event;
}

void CleanupScrollTracking() {
    g_scrollIsTracking = false;
    if (g_scrollEventTap) {
        CGEventTapEnable(g_scrollEventTap, false);
        if (g_scrollRunLoopSource) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), g_scrollRunLoopSource, kCFRunLoopCommonModes);
        }
        // cursor_tracker.mm / keyboard_tracker.mm ile aynı yaklaşım: CFRelease yok.
        g_scrollEventTap = NULL;
    }
    g_scrollRunLoopSource = NULL;
}

} // namespace

// ---- NAPI: startScrollTracking() -------------------------------------------
Napi::Value StartScrollTracking(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (g_scrollIsTracking) return Napi::Boolean::New(env, true);
    @try {
        {
            std::lock_guard<std::mutex> lock(g_scrollMutex);
            g_scrollEvents.clear();
            g_droppedEvents = 0;
        }
        g_lastTypingUnixMs = 0.0;
        CGEventMask mask = CGEventMaskBit(kCGEventScrollWheel) | CGEventMaskBit(kCGEventKeyDown);
        g_scrollEventTap = CGEventTapCreate(kCGSessionEventTap,
                                            kCGHeadInsertEventTap,
                                            kCGEventTapOptionListenOnly,
                                            mask,
                                            ScrollEventCallback,
                                            NULL);
        if (!g_scrollEventTap) {
            NSLog(@"⚠️  Failed to create scroll event tap (requires Accessibility / Input Monitoring permission)");
            CleanupScrollTracking();
            return Napi::Boolean::New(env, false);
        }
        g_scrollRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_scrollEventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), g_scrollRunLoopSource, kCFRunLoopCommonModes);
        CGEventTapEnable(g_scrollEventTap, true);
        g_scrollIsTracking = true;
        NSLog(@"✅ Scroll input tracking active");
        return Napi::Boolean::New(env, true);
    } @catch (NSException *exception) {
        CleanupScrollTracking();
        return Napi::Boolean::New(env, false);
    }
}

// ---- NAPI: stopScrollTracking() --------------------------------------------
Napi::Value StopScrollTracking(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    const bool wasTracking = g_scrollIsTracking;
    CleanupScrollTracking();
    return Napi::Boolean::New(env, wasTracking);
}

// ---- NAPI: drainScrollEvents() → [{unixTimeMs, x, y, deltaY, deltaX, continuous, phase, momentumPhase, key?}]
Napi::Value DrainScrollEvents(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    std::vector<ScrollEventRecord> events;
    {
        std::lock_guard<std::mutex> lock(g_scrollMutex);
        events.swap(g_scrollEvents);
    }
    Napi::Array out = Napi::Array::New(env, events.size());
    for (size_t i = 0; i < events.size(); i += 1) {
        const ScrollEventRecord &e = events[i];
        Napi::Object item = Napi::Object::New(env);
        item.Set("unixTimeMs", Napi::Number::New(env, e.unixMs));
        item.Set("x", Napi::Number::New(env, e.x));
        item.Set("y", Napi::Number::New(env, e.y));
        item.Set("deltaY", Napi::Number::New(env, e.deltaY));
        item.Set("deltaX", Napi::Number::New(env, e.deltaX));
        item.Set("continuous", Napi::Boolean::New(env, e.continuous != 0));
        item.Set("phase", Napi::Number::New(env, e.phase));
        item.Set("momentumPhase", Napi::Number::New(env, e.momentumPhase));
        if (!e.key.empty()) item.Set("key", Napi::String::New(env, e.key));
        out.Set(static_cast<uint32_t>(i), item);
    }
    return out;
}

// ---- NAPI: getScrollTrackingStatus() ---------------------------------------
Napi::Value GetScrollTrackingStatus(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    Napi::Object status = Napi::Object::New(env);
    std::lock_guard<std::mutex> lock(g_scrollMutex);
    status.Set("isTracking", Napi::Boolean::New(env, g_scrollIsTracking));
    status.Set("buffered", Napi::Number::New(env, (double)g_scrollEvents.size()));
    status.Set("dropped", Napi::Number::New(env, (double)g_droppedEvents));
    return status;
}

Napi::Object InitScrollTracker(Napi::Env env, Napi::Object exports) {
    exports.Set("startScrollTracking", Napi::Function::New(env, StartScrollTracking));
    exports.Set("stopScrollTracking", Napi::Function::New(env, StopScrollTracking));
    exports.Set("drainScrollEvents", Napi::Function::New(env, DrainScrollEvents));
    exports.Set("getScrollTrackingStatus", Napi::Function::New(env, GetScrollTrackingStatus));
    return exports;
}

// text_input_tracker.mm
// Kayıt sırasında YAZMA anlarını ve metin imlecinin (caret) ekrandaki yerini
// yakalar (Creavit LeadCam: yazarken zoom'u tutma + caret'i takip eden pan).
//
//  - Yazma: global keyDown (yalnızca dinleme). ⌘ / ⌃ ile basılanlar (kısayol),
//    Esc ve F tuşları sayılmaz. ⌥ ve Shift serbest (Türkçe klavyede @, € vb.).
//  - Caret: odaklı uygulamanın odaklı öğesinden Accessibility API ile
//    AXSelectedTextRange → AXBoundsForRange. Alınamazsa odaklı alanın çerçevesi
//    (AXPosition + AXSize) yazılır; o da yoksa yalnızca yazma anı.
//  - Chrome / Electron web içeriği AX ağacını ancak istenince açar: odaklı
//    uygulamaya kayıt boyunca AXManualAccessibility = true verilir, kayıt
//    bitince yalnızca bizim açtıklarımız geri kapatılır.
//
// AX sorguları event tap'i asla bloklamaz: tuş anı ana thread'de kaydedilir,
// sorgu ayrı bir seri kuyrukta 40 ms sonra yapılır (uygulama tuşu işlesin,
// caret yeni yerine gitsin). Arka arkaya gelen tuşlar tek sorguda birleşir
// (en fazla ~25 sorgu/sn). Uygulama / öğe sorgularının zaman aşımı 0,2 sn.
//
// Olaylar bellekte tutulur; JS (index.js cursor yakalama döngüsü)
// drainTextInputEvents() ile alıp cursor dosyasına `type: "textinput"`
// kaydı olarak, cursor ile AYNI zaman ve koordinat dönüşümüyle yazar.
//
// GİZLİLİK: hangi tuşa basıldığı / yazılan metin HİÇ kaydedilmez. Yalnızca
// zaman, birleşen tuş sayısı ve caret / alan dikdörtgeni. Parola alanlarında
// (secure input) macOS tuşları zaten event tap'e vermez.

#import <napi.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Carbon/Carbon.h>
#include <unistd.h>
#include <cmath>
#include <mutex>
#include <set>
#include <string>
#include <vector>
#import "sync_timeline.h"

namespace {

struct TextInputRecord {
    double unixMs;      // son tuşun anı
    double mouseX;
    double mouseY;
    int keys;           // bu kayıtta birleşen tuş sayısı
    int textTarget;     // 1 metin alanı, 0 metin alanı değil, -1 bilinmiyor
    bool hasCaret;
    double caretX, caretY, caretW, caretH;   // global (sol üst köşe) nokta
    bool hasField;
    double fieldX, fieldY, fieldW, fieldH;
};

constexpr size_t kMaxBufferedEvents = 8192;
constexpr double kQueryDelaySec = 0.04;
constexpr float kAxTimeoutSec = 0.2f;

std::mutex g_tiMutex;
std::vector<TextInputRecord> g_tiEvents;
size_t g_tiDropped = 0;

// Bekleyen (henüz sorgulanmamış) tuşlar — g_tiMutex ile korunur.
int g_pendingKeys = 0;
double g_pendingLastKeyMs = 0.0;
double g_pendingMouseX = 0.0;
double g_pendingMouseY = 0.0;
bool g_queryScheduled = false;

CFMachPortRef g_tiEventTap = NULL;
CFRunLoopSourceRef g_tiRunLoopSource = NULL;
volatile bool g_tiIsTracking = false;
dispatch_queue_t g_axQueue = NULL;

// AXManualAccessibility: denenen ve bizim açtığımız uygulamalar (yalnızca g_axQueue'da).
std::set<pid_t> g_axTriedPids;
std::set<pid_t> g_axEnabledPids;

// Event tap içinde nesne üretmeden (autorelease pool gerekmez).
double NowUnixMs() {
    return (CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970) * 1000.0;
}

bool IsIgnoredKey(CGKeyCode keyCode) {
    switch (keyCode) {
        case kVK_Escape:
        case kVK_F1: case kVK_F2: case kVK_F3: case kVK_F4: case kVK_F5: case kVK_F6:
        case kVK_F7: case kVK_F8: case kVK_F9: case kVK_F10: case kVK_F11: case kVK_F12:
        case kVK_F13: case kVK_F14: case kVK_F15: case kVK_F16: case kVK_F17: case kVK_F18:
        case kVK_F19: case kVK_F20:
        case kVK_VolumeUp: case kVK_VolumeDown: case kVK_Mute:
        case kVK_Help:
            return true;
        default:
            return false;
    }
}

bool Finite(double v) { return std::isfinite(v); }

bool CopyPoint(AXUIElementRef element, CFStringRef attribute, CGPoint *out) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || !value) return false;
    bool ok = false;
    if (CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType((AXValueRef)value) == kAXValueTypeCGPoint) {
        ok = AXValueGetValue((AXValueRef)value, kAXValueTypeCGPoint, out);
    }
    CFRelease(value);
    return ok;
}

bool CopySize(AXUIElementRef element, CFStringRef attribute, CGSize *out) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || !value) return false;
    bool ok = false;
    if (CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType((AXValueRef)value) == kAXValueTypeCGSize) {
        ok = AXValueGetValue((AXValueRef)value, kAXValueTypeCGSize, out);
    }
    CFRelease(value);
    return ok;
}

bool CopyRange(AXUIElementRef element, CFRange *out) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute, &value) != kAXErrorSuccess || !value) return false;
    bool ok = false;
    if (CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType((AXValueRef)value) == kAXValueTypeCFRange) {
        ok = AXValueGetValue((AXValueRef)value, kAXValueTypeCFRange, out);
    }
    CFRelease(value);
    return ok;
}

bool BoundsForRange(AXUIElementRef element, CFRange range, CGRect *out) {
    if (range.location < 0 || range.length < 0) return false;
    AXValueRef param = AXValueCreate(kAXValueTypeCFRange, &range);
    if (!param) return false;
    CFTypeRef value = NULL;
    AXError err = AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute, param, &value);
    CFRelease(param);
    if (err != kAXErrorSuccess || !value) return false;
    bool ok = false;
    if (CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType((AXValueRef)value) == kAXValueTypeCGRect) {
        ok = AXValueGetValue((AXValueRef)value, kAXValueTypeCGRect, out);
    }
    CFRelease(value);
    return ok;
}

// Bir satır yüksekliği kadar, sıfır olmayan, makul bir dikdörtgen mi?
bool PlausibleCaretRect(CGRect r) {
    if (!Finite(r.origin.x) || !Finite(r.origin.y) || !Finite(r.size.width) || !Finite(r.size.height)) return false;
    if (r.size.height <= 1.0 || r.size.height > 600.0) return false;
    if (r.size.width < 0.0 || r.size.width > 2400.0) return false;
    if (r.origin.x == 0.0 && r.origin.y == 0.0) return false;
    return true;
}

bool IsTextRole(AXUIElementRef element) {
    CFTypeRef role = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXRoleAttribute, &role) != kAXErrorSuccess || !role) return false;
    bool text = false;
    if (CFGetTypeID(role) == CFStringGetTypeID()) {
        NSString *r = (NSString *)role;
        text = [r isEqualToString:(NSString *)kAXTextFieldRole] ||
               [r isEqualToString:(NSString *)kAXTextAreaRole] ||
               [r isEqualToString:(NSString *)kAXComboBoxRole] ||
               [r isEqualToString:@"AXSearchField"];
    }
    CFRelease(role);
    return text;
}

// Chrome / Electron web içeriğinin AX ağacını aç (yalnızca bir kez dener).
void EnsureManualAccessibility(AXUIElementRef app, pid_t pid) {
    if (pid <= 0 || pid == getpid()) return;
    if (g_axTriedPids.count(pid)) return;
    g_axTriedPids.insert(pid);
    CFTypeRef current = NULL;
    bool alreadyOn = false;
    if (AXUIElementCopyAttributeValue(app, CFSTR("AXManualAccessibility"), &current) == kAXErrorSuccess && current) {
        alreadyOn = CFGetTypeID(current) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)current);
        CFRelease(current);
    }
    if (alreadyOn) return;
    if (AXUIElementSetAttributeValue(app, CFSTR("AXManualAccessibility"), kCFBooleanTrue) == kAXErrorSuccess) {
        g_axEnabledPids.insert(pid);
    }
}

// Caret ve alan bilgisini doldurur (g_axQueue üzerinde çalışır).
void QueryCaret(TextInputRecord &rec) {
    rec.textTarget = -1;
    rec.hasCaret = false;
    rec.hasField = false;
    if (!AXIsProcessTrusted()) return;

    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    if (!systemWide) return;
    // NOT: zaman aşımı system-wide öğeye verilmez (verilirse süreçteki TÜM AX
    // çağrılarının varsayılanı değişir — cursor_tracker dahil). Bu kuyruk zaten
    // arka planda; takılan bir uygulama yalnızca bu sorguyu geciktirir.

    AXUIElementRef app = NULL;
    AXUIElementRef focused = NULL;
    if (AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute, (CFTypeRef *)&app) == kAXErrorSuccess && app) {
        AXUIElementSetMessagingTimeout(app, kAxTimeoutSec);
        pid_t pid = 0;
        if (AXUIElementGetPid(app, &pid) == kAXErrorSuccess) EnsureManualAccessibility(app, pid);
        AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, (CFTypeRef *)&focused);
    }
    if (!focused) {
        AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute, (CFTypeRef *)&focused);
    }

    if (focused) {
        AXUIElementSetMessagingTimeout(focused, kAxTimeoutSec);
        CGPoint pos;
        CGSize size;
        if (CopyPoint(focused, kAXPositionAttribute, &pos) && CopySize(focused, kAXSizeAttribute, &size) &&
            Finite(pos.x) && Finite(pos.y) && size.width > 1 && size.height > 1) {
            rec.hasField = true;
            rec.fieldX = pos.x;
            rec.fieldY = pos.y;
            rec.fieldW = size.width;
            rec.fieldH = size.height;
        }

        CFRange sel;
        if (CopyRange(focused, &sel)) {
            rec.textTarget = 1;
            // Seçim varsa imleç seçimin sonundadır (Shift+ok ile genişletme).
            const CFIndex caret = sel.location + MAX((CFIndex)0, sel.length);
            CGRect r;
            bool found = false;
            double cx = 0, cy = 0, w = 0, h = 0;
            if (BoundsForRange(focused, CFRangeMake(caret, 0), &r) && PlausibleCaretRect(r)) {
                cx = r.origin.x + r.size.width / 2.0;
                found = true;
            } else if (BoundsForRange(focused, CFRangeMake(caret, 1), &r) && PlausibleCaretRect(r)) {
                cx = r.origin.x; // sonraki karakterin sol kenarı
                found = true;
            } else if (caret > 0 && BoundsForRange(focused, CFRangeMake(caret - 1, 1), &r) && PlausibleCaretRect(r)) {
                cx = r.origin.x + r.size.width; // önceki karakterin sağ kenarı
                found = true;
            }
            if (found) {
                cy = r.origin.y + r.size.height / 2.0;
                w = r.size.width;
                h = r.size.height;
                // Alanın çok dışına düşen sonuç (yanlış koordinat) kullanılmaz.
                bool inside = true;
                if (rec.hasField) {
                    const double pad = MAX(40.0, h * 2.0);
                    inside = cx >= rec.fieldX - pad && cx <= rec.fieldX + rec.fieldW + pad &&
                             cy >= rec.fieldY - pad && cy <= rec.fieldY + rec.fieldH + pad;
                }
                if (inside) {
                    rec.hasCaret = true;
                    rec.caretX = cx;
                    rec.caretY = cy;
                    rec.caretW = w;
                    rec.caretH = h;
                }
            }
        } else {
            rec.textTarget = IsTextRole(focused) ? 1 : 0;
        }
        CFRelease(focused);
    }
    if (app) CFRelease(app);
    CFRelease(systemWide);
}

void PushRecord(const TextInputRecord &rec) {
    std::lock_guard<std::mutex> lock(g_tiMutex);
    if (g_tiEvents.size() >= kMaxBufferedEvents) {
        g_tiEvents.erase(g_tiEvents.begin());
        g_tiDropped += 1;
    }
    g_tiEvents.push_back(rec);
}

void FlushPending() {
    TextInputRecord rec;
    {
        std::lock_guard<std::mutex> lock(g_tiMutex);
        g_queryScheduled = false;
        if (!g_tiIsTracking || g_pendingKeys <= 0) {
            g_pendingKeys = 0;
            return;
        }
        rec.keys = g_pendingKeys;
        rec.unixMs = g_pendingLastKeyMs;
        rec.mouseX = g_pendingMouseX;
        rec.mouseY = g_pendingMouseY;
        g_pendingKeys = 0;
    }
    @autoreleasepool {
        @try {
            QueryCaret(rec);
        } @catch (NSException *e) {
            rec.textTarget = -1;
            rec.hasCaret = false;
            rec.hasField = false;
        }
    }
    if (!g_tiIsTracking) return;
    PushRecord(rec);
}

CGEventRef TextInputEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (g_tiEventTap) CGEventTapEnable(g_tiEventTap, true);
        return event;
    }
    if (type != kCGEventKeyDown || !g_tiIsTracking || MRSyncIsPaused()) return event;

    const CGEventFlags flags = CGEventGetFlags(event);
    if (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl)) return event; // kısayol
    const CGKeyCode keyCode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (IsIgnoredKey(keyCode)) return event;

    const CGPoint location = CGEventGetLocation(event);
    bool schedule = false;
    {
        std::lock_guard<std::mutex> lock(g_tiMutex);
        g_pendingKeys += 1;
        g_pendingLastKeyMs = NowUnixMs();
        g_pendingMouseX = location.x;
        g_pendingMouseY = location.y;
        if (!g_queryScheduled) {
            g_queryScheduled = true;
            schedule = true;
        }
    }
    if (schedule && g_axQueue) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kQueryDelaySec * NSEC_PER_SEC)), g_axQueue, ^{
            FlushPending();
        });
    }
    return event;
}

void RestoreManualAccessibility() {
    for (pid_t pid : g_axEnabledPids) {
        AXUIElementRef app = AXUIElementCreateApplication(pid);
        if (!app) continue;
        AXUIElementSetMessagingTimeout(app, kAxTimeoutSec);
        AXUIElementSetAttributeValue(app, CFSTR("AXManualAccessibility"), kCFBooleanFalse);
        CFRelease(app);
    }
    g_axEnabledPids.clear();
    g_axTriedPids.clear();
}

void CleanupTextInputTracking() {
    g_tiIsTracking = false;
    if (g_tiEventTap) {
        CGEventTapEnable(g_tiEventTap, false);
        if (g_tiRunLoopSource) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), g_tiRunLoopSource, kCFRunLoopCommonModes);
        }
        // Diğer tracker'larla aynı yaklaşım: CFRelease yok.
        g_tiEventTap = NULL;
    }
    g_tiRunLoopSource = NULL;
    {
        std::lock_guard<std::mutex> lock(g_tiMutex);
        g_pendingKeys = 0;
    }
    if (g_axQueue) {
        // Kuyruktaki son sorgu bitsin, sonra açtığımız AX ağaçlarını kapat.
        dispatch_async(g_axQueue, ^{
            RestoreManualAccessibility();
        });
    }
}

} // namespace

// ---- NAPI: startTextInputTracking() ----------------------------------------
Napi::Value StartTextInputTracking(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (g_tiIsTracking) return Napi::Boolean::New(env, true);
    @try {
        if (!g_axQueue) {
            g_axQueue = dispatch_queue_create("com.creavit.recorder.textinput", DISPATCH_QUEUE_SERIAL);
        }
        {
            std::lock_guard<std::mutex> lock(g_tiMutex);
            g_tiEvents.clear();
            g_tiDropped = 0;
            g_pendingKeys = 0;
            g_queryScheduled = false;
        }
        CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
        g_tiEventTap = CGEventTapCreate(kCGSessionEventTap,
                                        kCGHeadInsertEventTap,
                                        kCGEventTapOptionListenOnly,
                                        mask,
                                        TextInputEventCallback,
                                        NULL);
        if (!g_tiEventTap) {
            NSLog(@"⚠️  Failed to create text input event tap (requires Accessibility / Input Monitoring permission)");
            CleanupTextInputTracking();
            return Napi::Boolean::New(env, false);
        }
        g_tiRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_tiEventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), g_tiRunLoopSource, kCFRunLoopCommonModes);
        CGEventTapEnable(g_tiEventTap, true);
        g_tiIsTracking = true;
        NSLog(@"✅ Text input tracking active (AX trusted: %@)", AXIsProcessTrusted() ? @"yes" : @"no");
        return Napi::Boolean::New(env, true);
    } @catch (NSException *exception) {
        CleanupTextInputTracking();
        return Napi::Boolean::New(env, false);
    }
}

// ---- NAPI: stopTextInputTracking() -----------------------------------------
Napi::Value StopTextInputTracking(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    const bool wasTracking = g_tiIsTracking;
    CleanupTextInputTracking();
    return Napi::Boolean::New(env, wasTracking);
}

// ---- NAPI: drainTextInputEvents() ------------------------------------------
// → [{unixTimeMs, x, y, keys, textTarget, caret?:{x,y,width,height}, field?:{x,y,width,height}}]
// Koordinatlar global (sol üst köşe orijinli, nokta); caret.x/y caret'in merkezi.
Napi::Value DrainTextInputEvents(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    std::vector<TextInputRecord> events;
    {
        std::lock_guard<std::mutex> lock(g_tiMutex);
        events.swap(g_tiEvents);
    }
    Napi::Array out = Napi::Array::New(env, events.size());
    for (size_t i = 0; i < events.size(); i += 1) {
        const TextInputRecord &e = events[i];
        Napi::Object item = Napi::Object::New(env);
        item.Set("unixTimeMs", Napi::Number::New(env, e.unixMs));
        item.Set("x", Napi::Number::New(env, e.mouseX));
        item.Set("y", Napi::Number::New(env, e.mouseY));
        item.Set("keys", Napi::Number::New(env, e.keys));
        if (e.textTarget < 0) item.Set("textTarget", env.Null());
        else item.Set("textTarget", Napi::Boolean::New(env, e.textTarget == 1));
        if (e.hasCaret) {
            Napi::Object caret = Napi::Object::New(env);
            caret.Set("x", Napi::Number::New(env, e.caretX));
            caret.Set("y", Napi::Number::New(env, e.caretY));
            caret.Set("width", Napi::Number::New(env, e.caretW));
            caret.Set("height", Napi::Number::New(env, e.caretH));
            item.Set("caret", caret);
        }
        if (e.hasField) {
            Napi::Object field = Napi::Object::New(env);
            field.Set("x", Napi::Number::New(env, e.fieldX));
            field.Set("y", Napi::Number::New(env, e.fieldY));
            field.Set("width", Napi::Number::New(env, e.fieldW));
            field.Set("height", Napi::Number::New(env, e.fieldH));
            item.Set("field", field);
        }
        out.Set(static_cast<uint32_t>(i), item);
    }
    return out;
}

// ---- NAPI: getTextInputTrackingStatus() ------------------------------------
Napi::Value GetTextInputTrackingStatus(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    Napi::Object status = Napi::Object::New(env);
    std::lock_guard<std::mutex> lock(g_tiMutex);
    status.Set("isTracking", Napi::Boolean::New(env, g_tiIsTracking));
    status.Set("buffered", Napi::Number::New(env, (double)g_tiEvents.size()));
    status.Set("dropped", Napi::Number::New(env, (double)g_tiDropped));
    status.Set("accessibilityTrusted", Napi::Boolean::New(env, AXIsProcessTrusted()));
    return status;
}

Napi::Object InitTextInputTracker(Napi::Env env, Napi::Object exports) {
    exports.Set("startTextInputTracking", Napi::Function::New(env, StartTextInputTracking));
    exports.Set("stopTextInputTracking", Napi::Function::New(env, StopTextInputTracking));
    exports.Set("drainTextInputEvents", Napi::Function::New(env, DrainTextInputEvents));
    exports.Set("getTextInputTrackingStatus", Napi::Function::New(env, GetTextInputTrackingStatus));
    return exports;
}

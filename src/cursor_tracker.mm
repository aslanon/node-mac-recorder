#import <napi.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <Accessibility/Accessibility.h>
#import <dispatch/dispatch.h>
#import "logging.h"
#include <vector>
#include <math.h>

#ifndef kAXHitTestParameterizedAttribute
#define kAXHitTestParameterizedAttribute CFSTR("AXHitTest")
#endif

// Private CoreGraphics API for cursor detection
#include <dlfcn.h>

typedef int (*CGSCurrentCursorSeed_t)(void);
typedef CFStringRef (*CGSCopyCurrentCursorName_t)(void);

static void *g_coreGraphicsHandle = NULL;
static void *g_skyLightHandle = NULL;
static dispatch_once_t g_coreGraphicsHandleInitToken;
static dispatch_once_t g_skyLightHandleInitToken;
static CGSCurrentCursorSeed_t CGSCurrentCursorSeed_func = NULL;
static CGSCopyCurrentCursorName_t CGSCopyCurrentCursorName_func = NULL;
static dispatch_once_t cgsSeedInitToken;
static dispatch_once_t cgsCursorNameInitToken;

static void* LoadCoreGraphicsHandle() {
    dispatch_once(&g_coreGraphicsHandleInitToken, ^{
        g_coreGraphicsHandle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
        if (!g_coreGraphicsHandle) {
            NSLog(@"⚠️  Failed to open CoreGraphics framework: %s", dlerror());
        }
    });
    return g_coreGraphicsHandle;
}

static void* LoadSkyLightHandle() {
    dispatch_once(&g_skyLightHandleInitToken, ^{
        g_skyLightHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (!g_skyLightHandle) {
            NSLog(@"⚠️  Failed to open SkyLight framework: %s", dlerror());
        }
    });
    return g_skyLightHandle;
}

static void initCGSCurrentCursorSeed() {
    dispatch_once(&cgsSeedInitToken, ^{
        void *handle = LoadCoreGraphicsHandle();
        if (handle) {
            CGSCurrentCursorSeed_func = (CGSCurrentCursorSeed_t)dlsym(handle, "CGSCurrentCursorSeed");
            if (!CGSCurrentCursorSeed_func) {
                NSLog(@"⚠️  Failed to load CGSCurrentCursorSeed: %s", dlerror());
            }
        }
    });
}

static void initCGSCursorNameFunc() {
    dispatch_once(&cgsCursorNameInitToken, ^{
        void *handle = LoadSkyLightHandle();
        if (!handle) {
            handle = LoadCoreGraphicsHandle();
        }
        if (handle) {
            const char *symbolCandidates[] = {
                "CGSCopyCurrentCursorName",
                "CGSCopyGlobalCursorName",
                "SLSCopyCurrentCursorName",
                "SLSCopyGlobalCursorName",
                "CGSCopyCurrentCursor",
                "SLSCopyCurrentCursor"
            };
            size_t candidateCount = sizeof(symbolCandidates) / sizeof(symbolCandidates[0]);
            for (size_t i = 0; i < candidateCount; ++i) {
                CGSCopyCurrentCursorName_func = (CGSCopyCurrentCursorName_t)dlsym(handle, symbolCandidates[i]);
                if (CGSCopyCurrentCursorName_func) {
                    break;
                }
            }
        }
        if (!CGSCopyCurrentCursorName_func) {
            NSLog(@"⚠️  Failed to load CGSCopyCurrentCursorName (CGS/SLS) symbol");
        }
    });
}

static int SafeCGSCurrentCursorSeed() {
    initCGSCurrentCursorSeed();
    if (CGSCurrentCursorSeed_func) {
        int seed = CGSCurrentCursorSeed_func();
        return seed;
    } else {
        static dispatch_once_t warnToken;
        dispatch_once(&warnToken, ^{
            NSLog(@"⚠️  CGSCurrentCursorSeed function not loaded!");
        });
    }
    return -1;
}

static NSString* CopyCurrentCursorNameFromCGS(void) {
    initCGSCursorNameFunc();
    if (!CGSCopyCurrentCursorName_func) {
        return nil;
    }
    CFStringRef cgsName = CGSCopyCurrentCursorName_func();
    if (!cgsName) {
        return nil;
    }
    NSString *name = [NSString stringWithString:(NSString *)cgsName];
    CFRelease(cgsName);
    return name;
}

// Global state for cursor tracking
static bool g_isCursorTracking = false;
static CFMachPortRef g_eventTap = NULL;
static CFRunLoopSourceRef g_runLoopSource = NULL;
static NSDate *g_trackingStartTime = nil;
static NSString *g_outputPath = nil;
static NSTimer *g_cursorTimer = nil;
static int g_debugCallbackCount = 0;
static NSFileHandle *g_fileHandle = nil;
static bool g_isFirstWrite = true;
static NSMutableDictionary<NSString*, NSString*> *g_cursorFingerprintMap = nil;
static NSMutableDictionary<NSValue*, NSString*> *g_cursorPointerCache = nil;
static NSMutableDictionary<NSString*, NSString*> *g_cursorNameMap = nil;
static dispatch_once_t g_cursorFingerprintInitToken;
static void LoadSystemCursorResourceFingerprints(void);
static void LoadCursorMappingOverrides(void);
static NSMutableDictionary<NSNumber*, NSString*> *g_seedOverrides = nil;

typedef NSCursor* (*CursorFactoryFunc)(id, SEL);
typedef NSString* (*CursorNameFunc)(id, SEL);

static uint64_t FNV1AHash(const unsigned char *data, size_t length) {
    const uint64_t kOffset = 1469598103934665603ULL;
    const uint64_t kPrime = 1099511628211ULL;
    uint64_t hash = kOffset;
    if (!data || length == 0) {
        return hash;
    }
    for (size_t i = 0; i < length; ++i) {
        hash ^= data[i];
        hash *= kPrime;
    }
    return hash;
}

static NSString* CursorImageFingerprintFromImage(NSImage *image, NSPoint hotspot) {
    if (!image) {
        return nil;
    }
    NSRect imageRect = NSMakeRect(0, 0, [image size].width, [image size].height);
    CGImageRef cgImage = [image CGImageForProposedRect:&imageRect context:nil hints:nil];
    if (!cgImage) {
        for (NSImageRep *rep in [image representations]) {
            if ([rep isKindOfClass:[NSBitmapImageRep class]]) {
                cgImage = [(NSBitmapImageRep *)rep CGImage];
                if (cgImage) {
                    break;
                }
            }
        }
    }

    if (!cgImage) {
        return nil;
    }

    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0) {
        return nil;
    }

    size_t bytesPerPixel = 4;
    size_t bytesPerRow = width * bytesPerPixel;
    size_t bufferSize = bytesPerRow * height;
    if (bufferSize == 0) {
        return nil;
    }

    std::vector<unsigned char> buffer(bufferSize);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) {
        return nil;
    }

    CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
    CGContextRef context = CGBitmapContextCreate(buffer.data(),
                                                 width,
                                                 height,
                                                 8,
                                                 bytesPerRow,
                                                 colorSpace,
                                                 bitmapInfo);
    CGColorSpaceRelease(colorSpace);

    if (!context) {
        return nil;
    }

    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);

    uint64_t hash = FNV1AHash(buffer.data(), buffer.size());

    double relX = width > 0 ? hotspot.x / (double)width : 0.0;
    double relY = height > 0 ? hotspot.y / (double)height : 0.0;

    return [NSString stringWithFormat:@"%zux%zu-%.4f-%.4f-%016llx",
            width,
            height,
            relX,
            relY,
            hash];
}

static NSString* CursorImageFingerprintUnsafe(NSCursor *cursor) {
    if (!cursor) {
        return nil;
    }
    return CursorImageFingerprintFromImage([cursor image], [cursor hotSpot]);
}

static NSString* CursorImageFingerprint(NSCursor *cursor) {
    if (!cursor) {
        return nil;
    }
    if ([NSThread isMainThread]) {
        return CursorImageFingerprintUnsafe(cursor);
    }

    __block NSString *fingerprint = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        fingerprint = CursorImageFingerprintUnsafe(cursor);
    });
    return fingerprint;
}

static NSString* CursorNameFromNSCursor(NSCursor *cursor) {
    if (!cursor) {
        return nil;
    }

    NSArray<NSString *> *selectorNames = @[
        @"_name",
        @"name",
        @"cursorName",
        @"_cursorName",
        @"identifier",
        @"_identifier",
        @"cursorIdentifier"
    ];

    for (NSString *selectorName in selectorNames) {
        SEL selector = NSSelectorFromString(selectorName);
        if (selector && [cursor respondsToSelector:selector]) {
            IMP imp = [cursor methodForSelector:selector];
            if (!imp) {
                continue;
            }
            CursorNameFunc func = (CursorNameFunc)imp;
            NSString *value = func(cursor, selector);
            if (value && [value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        }
    }

    NSArray<NSString *> *kvcKeys = @[ @"_name", @"name", @"cursorName", @"_cursorName", @"identifier", @"_identifier" ];
    for (NSString *key in kvcKeys) {
        @try {
            id value = [cursor valueForKey:key];
            if (value && [value isKindOfClass:[NSString class]] && [value length] > 0) {
                return (NSString *)value;
            }
        } @catch (NSException *exception) {
            // Ignore KVC exceptions
        }
    }
    return nil;
}

static NSString* NormalizeCursorName(NSString *name) {
    if (!name) {
        return nil;
    }
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [[trimmed stringByReplacingOccurrencesOfString:@"\n" withString:@" "] lowercaseString];
}

static NSCursor* CursorFromSelector(SEL selector) {
    if (!selector || ![NSCursor respondsToSelector:selector]) {
        return nil;
    }
    IMP imp = [NSCursor methodForSelector:selector];
    if (!imp) {
        return nil;
    }
    CursorFactoryFunc func = (CursorFactoryFunc)imp;
    return func([NSCursor class], selector);
}

static void AddStandardCursorFingerprint(NSCursor *cursor, NSString *cursorType) {
    if (!cursor || !cursorType) {
        return;
    }
    NSString *fingerprint = CursorImageFingerprintUnsafe(cursor);
    if (!fingerprint) {
        return;
    }
    [g_cursorFingerprintMap setObject:cursorType forKey:fingerprint];
}

static void AddCursorIfAvailable(SEL selector, NSString *cursorType) {
    if (!cursorType || !selector) {
        return;
    }
    NSCursor *cursor = CursorFromSelector(selector);
    if (cursor) {
        AddStandardCursorFingerprint(cursor, cursorType);
    }
}

static void AddCursorIfAvailableByName(NSString *selectorName, NSString *cursorType) {
    if (!selectorName) {
        return;
    }
    SEL selector = NSSelectorFromString(selectorName);
    AddCursorIfAvailable(selector, cursorType);
}

static void InitializeCursorFingerprintMap(void) {
    dispatch_once(&g_cursorFingerprintInitToken, ^{
        g_cursorFingerprintMap = [[NSMutableDictionary alloc] init];
        g_cursorPointerCache = [[NSMutableDictionary alloc] init];
        g_cursorNameMap = [[NSMutableDictionary alloc] init];

        void (^buildMap)(void) = ^{
            AddStandardCursorFingerprint([NSCursor arrowCursor], @"default");
            AddStandardCursorFingerprint([NSCursor pointingHandCursor], @"pointer");
            AddStandardCursorFingerprint([NSCursor IBeamCursor], @"text");
            if ([NSCursor respondsToSelector:@selector(IBeamCursorForVerticalLayout)]) {
                AddStandardCursorFingerprint([NSCursor IBeamCursorForVerticalLayout], @"text");
            }
            AddStandardCursorFingerprint([NSCursor crosshairCursor], @"crosshair");
            AddCursorIfAvailable(@selector(openHandCursor), @"grab");
            AddCursorIfAvailable(@selector(closedHandCursor), @"grabbing");
            AddCursorIfAvailable(@selector(operationNotAllowedCursor), @"not-allowed");
            AddCursorIfAvailable(@selector(contextualMenuCursor), @"context-menu");
            AddCursorIfAvailable(@selector(dragCopyCursor), @"copy");
            AddCursorIfAvailable(@selector(dragLinkCursor), @"alias");
            AddCursorIfAvailable(@selector(resizeLeftRightCursor), @"col-resize");
            AddCursorIfAvailable(@selector(resizeUpDownCursor), @"row-resize");
            AddCursorIfAvailableByName(@"resizeLeftCursor", @"w-resize");
            AddCursorIfAvailableByName(@"resizeRightCursor", @"e-resize");
            AddCursorIfAvailableByName(@"resizeUpCursor", @"n-resize");
            AddCursorIfAvailableByName(@"resizeDownCursor", @"s-resize");
            AddCursorIfAvailableByName(@"resizeNorthWestSouthEastCursor", @"nwse-resize");
            AddCursorIfAvailableByName(@"resizeNorthEastSouthWestCursor", @"nesw-resize");
            AddCursorIfAvailable(@selector(zoomInCursor), @"zoom-in");
            AddCursorIfAvailable(@selector(zoomOutCursor), @"zoom-out");
            AddCursorIfAvailable(@selector(columnResizeCursor), @"col-resize");
            AddCursorIfAvailable(@selector(rowResizeCursor), @"row-resize");

            LoadSystemCursorResourceFingerprints();
            LoadCursorMappingOverrides();
        };

        if ([NSThread isMainThread]) {
            buildMap();
        } else {
            dispatch_sync(dispatch_get_main_queue(), buildMap);
        }
    });
}

static NSString* LookupCursorTypeByFingerprint(NSCursor *cursor, NSString **outFingerprint) {
    if (!cursor) {
        return nil;
    }
    InitializeCursorFingerprintMap();

    NSValue *pointerKey = [NSValue valueWithPointer:(__bridge const void *)cursor];

    // DISABLED: Pointer cache causes stale cursor type detection
    // Since macOS may reuse the same NSCursor object for different contexts,
    // we need to check the actual cursor state every time for real-time accuracy
    // NSString *cachedType = [g_cursorPointerCache objectForKey:pointerKey];
    // if (cachedType) {
    //     return cachedType;
    // }

    NSString *fingerprint = CursorImageFingerprint(cursor);
    if (!fingerprint) {
        return nil;
    }

    if (outFingerprint) {
        *outFingerprint = fingerprint;
    }

    NSString *mappedType = [g_cursorFingerprintMap objectForKey:fingerprint];
    if (mappedType) {
        // DISABLED: Don't cache by pointer for real-time detection
        // if (pointerKey) {
        //     [g_cursorPointerCache setObject:mappedType forKey:pointerKey];
        // }
        return mappedType;
    }

    return nil;
}

static void CacheCursorFingerprint(NSCursor *cursor, NSString *cursorType, NSString *knownFingerprint) {
    if (!cursor || !cursorType || [cursorType length] == 0) {
        return;
    }
    InitializeCursorFingerprintMap();
    NSString *fingerprint = knownFingerprint;
    if (!fingerprint) {
        fingerprint = CursorImageFingerprint(cursor);
    }
    if (!fingerprint) {
        return;
    }
    // Only cache fingerprint mapping (image hash -> type), not pointer mapping
    if (![g_cursorFingerprintMap objectForKey:fingerprint]) {
        [g_cursorFingerprintMap setObject:cursorType forKey:fingerprint];
    }
    // DISABLED: Pointer cache for real-time detection
    // NSValue *pointerKey = [NSValue valueWithPointer:(__bridge const void *)cursor];
    // if (pointerKey && g_cursorPointerCache) {
    //     [g_cursorPointerCache setObject:cursorType forKey:pointerKey];
    // }
}

// Forward declaration
void cursorTimerCallback();
void writeToFile(NSDictionary *cursorData);
NSDictionary* getDisplayScalingInfo(CGPoint globalPoint);

// Timer helper class
@interface CursorTimerTarget : NSObject
- (void)timerCallback:(NSTimer *)timer;
@end

@implementation CursorTimerTarget
- (void)timerCallback:(NSTimer *)timer {
    cursorTimerCallback();
}
@end

static CursorTimerTarget *g_timerTarget = nil;

// Global cursor state tracking
static NSString *g_lastDetectedCursorType = nil;
static int g_cursorTypeCounter = 0;
static int g_lastCursorSeed = -1; // Track cursor seed for change detection
static BOOL g_hasLastCursorEvent = NO;
static CGPoint g_lastCursorLocation = {0, 0};
static NSString *g_lastCursorType = nil;
static NSString *g_lastCursorEventType = nil;

static inline BOOL StringsEqual(NSString *a, NSString *b) {
    if (a == b) {
        return YES;
    }
    if (!a || !b) {
        return NO;
    }
    return [a isEqualToString:b];
}

static void ResetCursorEventHistory(void) {
    g_hasLastCursorEvent = NO;
    g_lastCursorLocation = CGPointZero;
    if (g_lastCursorType) {
        [g_lastCursorType release];
        g_lastCursorType = nil;
    }
    if (g_lastCursorEventType) {
        [g_lastCursorEventType release];
        g_lastCursorEventType = nil;
    }
}

static BOOL ShouldEmitCursorEvent(CGPoint location, NSString *cursorType, NSString *eventType) {
    if (!g_hasLastCursorEvent) {
        return YES;
    }

    const CGFloat movementThreshold = 1.5; // Require ~2px change to treat as movement
    BOOL moved = fabs(location.x - g_lastCursorLocation.x) >= movementThreshold ||
                 fabs(location.y - g_lastCursorLocation.y) >= movementThreshold;
    BOOL eventChanged = !StringsEqual(eventType, g_lastCursorEventType);
    BOOL isMoveEvent = StringsEqual(eventType, @"move") || StringsEqual(eventType, @"drag");
    BOOL isClickEvent = StringsEqual(eventType, @"mousedown") ||
                        StringsEqual(eventType, @"mouseup") ||
                        StringsEqual(eventType, @"rightmousedown") ||
                        StringsEqual(eventType, @"rightmouseup");

    if (isMoveEvent) {
        return moved;
    }

    if (isClickEvent) {
        return eventChanged || moved;
    }

    // Fallback: only emit when something actually changed
    BOOL cursorChanged = !StringsEqual(cursorType, g_lastCursorType);
    return moved || cursorChanged || eventChanged;
}

static void RememberCursorEvent(CGPoint location, NSString *cursorType, NSString *eventType) {
    g_lastCursorLocation = location;
    if (g_lastCursorType != cursorType) {
        [g_lastCursorType release];
        g_lastCursorType = cursorType ? [cursorType copy] : nil;
    }
    if (g_lastCursorEventType != eventType) {
        [g_lastCursorEventType release];
        g_lastCursorEventType = eventType ? [eventType copy] : nil;
    }
    g_hasLastCursorEvent = YES;
}

static NSString* CopyAndReleaseCFString(CFStringRef value) {
    if (!value) {
        return nil;
    }
    NSString *result = [NSString stringWithString:(NSString *)value];
    CFRelease(value);
    return result;
}

static inline BOOL StringEqualsAny(NSString *value, NSArray<NSString *> *candidates) {
    if (!value) {
        return NO;
    }
    for (NSString *candidate in candidates) {
        if ([value isEqualToString:candidate]) {
            return YES;
        }
    }
    return NO;
}

static NSString* CopyAttributeString(AXUIElementRef element, CFStringRef attribute) {
    if (!element || !attribute) {
        return nil;
    }

    CFStringRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, attribute, (CFTypeRef *)&value);
    if (error == kAXErrorSuccess && value) {
        return CopyAndReleaseCFString(value);
    }

    if (value) {
        CFRelease(value);
    }
    return nil;
}

static BOOL CopyAttributeBoolean(AXUIElementRef element, CFStringRef attribute, BOOL *outValue) {
    if (!element || !attribute || !outValue) {
        return NO;
    }

    CFTypeRef rawValue = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, attribute, &rawValue);
    if (error != kAXErrorSuccess || !rawValue) {
        if (rawValue) {
            CFRelease(rawValue);
        }
        return NO;
    }

    BOOL result = NO;
    if (CFGetTypeID(rawValue) == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue((CFBooleanRef)rawValue);
    }

    CFRelease(rawValue);
    *outValue = result;
    return YES;
}

static __attribute__((unused)) BOOL ElementHasAction(AXUIElementRef element, CFStringRef action) {
    if (!element || !action) {
        return NO;
    }

    CFArrayRef actions = NULL;
    AXError error = AXUIElementCopyActionNames(element, &actions);
    if (error != kAXErrorSuccess || !actions) {
        return NO;
    }

    BOOL hasAction = NO;
    CFIndex count = CFArrayGetCount(actions);
    for (CFIndex i = 0; i < count; i++) {
        CFStringRef candidate = (CFStringRef)CFArrayGetValueAtIndex(actions, i);
        if (CFStringCompare(candidate, action, 0) == kCFCompareEqualTo) {
            hasAction = YES;
            break;
        }
    }
    CFRelease(actions);
    return hasAction;
}

static BOOL PointInsideElementFrame(AXUIElementRef element, CGPoint point) {
    if (!element) {
        return NO;
    }

    AXValueRef positionValue = NULL;
    AXValueRef sizeValue = NULL;

    AXError positionError = AXUIElementCopyAttributeValue(element, kAXPositionAttribute, (CFTypeRef *)&positionValue);
    AXError sizeError = AXUIElementCopyAttributeValue(element, kAXSizeAttribute, (CFTypeRef *)&sizeValue);

    if (positionError != kAXErrorSuccess || sizeError != kAXErrorSuccess || !positionValue || !sizeValue) {
        if (positionValue) CFRelease(positionValue);
        if (sizeValue) CFRelease(sizeValue);
        return NO;
    }

    CGPoint origin = CGPointZero;
    CGSize size = CGSizeZero;
    AXValueGetValue(positionValue, kAXValueTypeCGPoint, &origin);
    AXValueGetValue(sizeValue, kAXValueTypeCGSize, &size);

    CFRelease(positionValue);
    CFRelease(sizeValue);

    CGRect frame = CGRectMake(origin.x, origin.y, size.width, size.height);
    return CGRectContainsPoint(frame, point);
}

static NSString* CursorTypeForWindowBorder(AXUIElementRef element, CGPoint cursorPos) {
    AXValueRef positionValue = NULL;
    AXValueRef sizeValue = NULL;

    AXError positionError = AXUIElementCopyAttributeValue(element, kAXPositionAttribute, (CFTypeRef *)&positionValue);
    AXError sizeError = AXUIElementCopyAttributeValue(element, kAXSizeAttribute, (CFTypeRef *)&sizeValue);

    if (positionError != kAXErrorSuccess || sizeError != kAXErrorSuccess || !positionValue || !sizeValue) {
        if (positionValue) CFRelease(positionValue);
        if (sizeValue) CFRelease(sizeValue);
        return nil;
    }

    CGPoint windowOrigin = CGPointZero;
    CGSize windowSize = CGSizeZero;
    AXValueGetValue(positionValue, kAXValueTypeCGPoint, &windowOrigin);
    AXValueGetValue(sizeValue, kAXValueTypeCGSize, &windowSize);

    CFRelease(positionValue);
    CFRelease(sizeValue);

    CGFloat edge = 4.0;
    CGFloat x = cursorPos.x - windowOrigin.x;
    CGFloat y = cursorPos.y - windowOrigin.y;
    CGFloat w = windowSize.width;
    CGFloat h = windowSize.height;

    if (x < 0 || y < 0 || x > w || y > h) {
        return nil;
    }

    BOOL nearLeft = (x >= 0 && x <= edge);
    BOOL nearRight = (x >= w - edge && x <= w);
    BOOL nearTop = (y >= 0 && y <= edge);
    BOOL nearBottom = (y >= h - edge && y <= h);

    if ((nearLeft && nearTop) || (nearRight && nearBottom)) {
        return @"nwse-resize";
    }
    if ((nearRight && nearTop) || (nearLeft && nearBottom)) {
        return @"nesw-resize";
    }
    if (nearLeft || nearRight) {
        return @"col-resize";
    }
    if (nearTop || nearBottom) {
        return @"ns-resize";
    }

    return nil;
}

static NSString* CursorTypeFromAccessibilityElement(AXUIElementRef element, CGPoint cursorPos) {
    if (!element) {
        return nil;
    }

    NSString *role = CopyAttributeString(element, kAXRoleAttribute);
    NSString *subrole = CopyAttributeString(element, kAXSubroleAttribute);
    NSString *roleDescription = CopyAttributeString(element, kAXRoleDescriptionAttribute);

    BOOL isEditable = NO;
    CopyAttributeBoolean(element, CFSTR("AXEditable"), &isEditable);

    BOOL hasTextRole = StringEqualsAny(role, @[@"AXTextField",
                                               @"AXTextArea",
                                               @"AXTextView",
                                               @"AXTextEditor",
                                               @"AXSearchField"]);
    BOOL hasTextSubrole = StringEqualsAny(subrole, @[@"AXSecureTextField",
                                                     @"AXTextField",
                                                     @"AXTextArea",
                                                     @"AXSearchField",
                                                     @"AXTextEditor"]);

    if (hasTextRole || hasTextSubrole || isEditable) {
        return @"text";
    }

    // Leave progress/help to system cursor; don't force via AX

    if ([role isEqualToString:@"AXSplitter"]) {
        NSString *orientation = CopyAttributeString(element, CFSTR("AXOrientation"));
        if ([orientation isEqualToString:@"AXHorizontalOrientation"]) {
            return @"ns-resize";
        }
        if ([orientation isEqualToString:@"AXVerticalOrientation"]) {
            return @"col-resize";
        }
    }

    if ([role isEqualToString:@"AXWindow"]) {
        NSString *windowCursor = CursorTypeForWindowBorder(element, cursorPos);
        if (windowCursor) {
            return windowCursor;
        }
    }

    // Pointer (hand) only for actual links; buttons remain default arrow on macOS
    if (StringEqualsAny(role, @[@"AXLink"])) {
        return @"pointer";
    }
    if (StringEqualsAny(subrole, @[@"AXLink"])) {
        return @"pointer";
    }

    if (roleDescription) {
        NSString *lower = [roleDescription lowercaseString];
        if ([lower containsString:@"button"] ||
            [lower containsString:@"link"] ||
            [lower containsString:@"tab"]) {
            return @"pointer";
        }
    }

    // Actions alone do not imply pointer hand on macOS; ignore

    CFTypeRef urlValue = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXURLAttribute, &urlValue) == kAXErrorSuccess && urlValue) {
        CFRelease(urlValue);
        return @"pointer";
    }
    if (urlValue) {
        CFRelease(urlValue);
    }

    // Grab/open-hand often comes from system cursor; avoid forcing via AX

    // Zoom is rare; prefer system cursor unless explicitly needed
    
    return nil;
}

static AXUIElementRef CopyParent(AXUIElementRef element) {
    if (!element) return NULL;
    AXUIElementRef parent = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXParentAttribute, (CFTypeRef *)&parent) == kAXErrorSuccess && parent) {
        return parent; // retained
    }
    if (parent) CFRelease(parent);
    return NULL;
}

static NSString* CursorTypeFromElementOrAncestors(AXUIElementRef element, CGPoint cursorPos, int maxDepth) {
    AXUIElementRef current = element;
    int depth = 0;
    while (current && depth < maxDepth) {
        NSString *t = CursorTypeFromAccessibilityElement(current, cursorPos);
        if (t && [t length] > 0) {
            return t;
        }
        AXUIElementRef parent = CopyParent(current);
        if (current != element) CFRelease(current);
        current = parent;
        depth++;
    }
    if (current && current != element) CFRelease(current);
    return nil;
}

// Mouse button state tracking
static bool g_leftMouseDown = false;
static bool g_rightMouseDown = false;
static NSString *g_lastEventType = @"move";

// Accessibility tabanlı cursor tip tespiti
static NSString* detectCursorTypeUsingAccessibility(CGPoint cursorPos) {
    @autoreleasepool {
        AXUIElementRef systemWide = AXUIElementCreateSystemWide();
        if (!systemWide) {
            return nil;
        }

        NSString *cursorType = nil;

        AXUIElementRef elementAtPosition = NULL;
        AXError error = AXUIElementCopyElementAtPosition(systemWide, cursorPos.x, cursorPos.y, &elementAtPosition);
        if (error == kAXErrorSuccess && elementAtPosition) {
            cursorType = CursorTypeFromElementOrAncestors(elementAtPosition, cursorPos, 6);
            CFRelease(elementAtPosition);
        }

        if (!cursorType) {
            AXValueRef pointValue = AXValueCreate(kAXValueTypeCGPoint, &cursorPos);
            if (pointValue) {
                AXUIElementRef hitElement = NULL;
                AXError hitError = AXUIElementCopyParameterizedAttributeValue(systemWide, kAXHitTestParameterizedAttribute, pointValue, (CFTypeRef *)&hitElement);
                CFRelease(pointValue);
                if (hitError == kAXErrorSuccess && hitElement) {
                    cursorType = CursorTypeFromElementOrAncestors(hitElement, cursorPos, 6);
                    CFRelease(hitElement);
                }
            }
        }

        if (!cursorType) {
            AXUIElementRef focusedElement = NULL;
            if (AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute, (CFTypeRef *)&focusedElement) == kAXErrorSuccess && focusedElement) {
                if (PointInsideElementFrame(focusedElement, cursorPos)) {
                    cursorType = CursorTypeFromAccessibilityElement(focusedElement, cursorPos);
                }
                CFRelease(focusedElement);
            }
        }

        CFRelease(systemWide);
        return cursorType;
    }
}

static NSString* cursorTypeFromCursorName(NSString *value) {
    if (!value || [value length] == 0) {
        return nil;
    }

    NSString *normalized = [[value stringByReplacingOccurrencesOfString:@"_" withString:@"-"] lowercaseString];

    // Arrow cursor patterns
    if ([normalized containsString:@"arrow"] || [normalized containsString:@"default"]) {
        return @"default";
    }

    // Text cursor patterns
    if ([normalized containsString:@"ibeam"] ||
        [normalized containsString:@"insertion"] ||
        [normalized containsString:@"text"] ||
        [normalized containsString:@"edit"]) {
        return @"text";
    }

    // Hand cursors
    if ([normalized containsString:@"openhand"] || [normalized containsString:@"open-hand"]) {
        return @"grab";
    }
    if ([normalized containsString:@"closedhand"] || [normalized containsString:@"closed-hand"]) {
        return @"grabbing";
    }

    // Pointer cursor patterns
    if ([normalized containsString:@"pointing"] ||
        [normalized containsString:@"pointinghand"] ||
        ([normalized containsString:@"hand"] && ![normalized containsString:@"closed"] && ![normalized containsString:@"open"]) ||
        [normalized containsString:@"link"] ||
        [normalized containsString:@"button"]) {
        return @"pointer";
    }

    // Crosshair patterns
    if ([normalized containsString:@"crosshair"] || [normalized containsString:@"cross-hair"]) {
        return @"crosshair";
    }

    // Not allowed patterns
    if ([normalized containsString:@"not-allowed"] ||
        [normalized containsString:@"notallowed"] ||
        [normalized containsString:@"forbidden"] ||
        [normalized containsString:@"operation-not-allowed"]) {
        return @"not-allowed";
    }

    // Copy cursor patterns
    if ([normalized containsString:@"dragcopy"] ||
        [normalized containsString:@"drag-copy"] ||
        [normalized containsString:@"copy"]) {
        return @"copy";
    }

    // Alias cursor patterns
    if ([normalized containsString:@"draglink"] ||
        [normalized containsString:@"drag-link"] ||
        [normalized containsString:@"alias"]) {
        return @"alias";
    }

    // Context menu patterns
    if (([normalized containsString:@"context"] && [normalized containsString:@"menu"]) ||
        [normalized containsString:@"contextual-menu"]) {
        return @"context-menu";
    }

    // Zoom patterns
    if ([normalized containsString:@"zoom"]) {
        if ([normalized containsString:@"out"]) {
            return @"zoom-out";
        }
        return @"zoom-in";
    }

    // All-scroll pattern (move in all directions)
    if ([normalized containsString:@"all-scroll"] ||
        [normalized containsString:@"allscroll"] ||
        ([normalized containsString:@"move"] && [normalized containsString:@"all"]) ||
        [normalized containsString:@"omnidirectional"]) {
        return @"all-scroll";
    }

    // Resize cursor patterns - more comprehensive with Electron CSS names
    if ([normalized containsString:@"resize"] || [normalized containsString:@"size"]) {
        // Check for specific directional patterns first
        // North-East/South-West diagonal
        if ([normalized containsString:@"nesw"] ||
            ([normalized containsString:@"northeast"] && [normalized containsString:@"southwest"]) ||
            ([normalized containsString:@"ne"] && [normalized containsString:@"sw"])) {
            return @"nesw-resize";
        }

        // North-West/South-East diagonal
        if ([normalized containsString:@"nwse"] ||
            ([normalized containsString:@"northwest"] && [normalized containsString:@"southeast"]) ||
            ([normalized containsString:@"nw"] && [normalized containsString:@"se"])) {
            return @"nwse-resize";
        }

        // Generic diagonal patterns
        BOOL diagonalUp = [normalized containsString:@"diagonalup"] ||
                          [normalized containsString:@"diagonal-up"];
        BOOL diagonalDown = [normalized containsString:@"diagonaldown"] ||
                            [normalized containsString:@"diagonal-down"];

        // Horizontal resize (East-West)
        BOOL horizontal = [normalized containsString:@"ew-resize"] ||
                          [normalized containsString:@"ewresize"] ||
                          [normalized containsString:@"leftright"] ||
                          [normalized containsString:@"left-right"] ||
                          [normalized containsString:@"horizontal"] ||
                          ([normalized containsString:@"left"] && [normalized containsString:@"right"]) ||
                          [normalized containsString:@"col-resize"] ||
                          [normalized containsString:@"column"];

        // Vertical resize (North-South)
        BOOL vertical = [normalized containsString:@"ns-resize"] ||
                        [normalized containsString:@"nsresize"] ||
                        [normalized containsString:@"updown"] ||
                        [normalized containsString:@"up-down"] ||
                        [normalized containsString:@"vertical"] ||
                        ([normalized containsString:@"up"] && [normalized containsString:@"down"]) ||
                        [normalized containsString:@"row-resize"];

        if (diagonalUp) {
            return @"nesw-resize";
        }
        if (diagonalDown) {
            return @"nwse-resize";
        }
        if (horizontal) {
            return @"ew-resize"; // Use ew-resize as primary horizontal
        }
        if (vertical) {
            return @"ns-resize"; // Use ns-resize as primary vertical
        }

        // If contains "resize" but no specific direction, return generic resize
        // This catches window resize cursors
        return @"nwse-resize"; // Default to diagonal for generic resize
    }

    // Progress/wait patterns - Electron uses 'progress'
    if ([normalized containsString:@"wait"] ||
        [normalized containsString:@"busy"] ||
        [normalized containsString:@"progress"]) {
        return @"progress";
    }

    // Help pattern
    if ([normalized containsString:@"help"] || [normalized containsString:@"question"]) {
        return @"help";
    }

    return nil;
}

typedef struct {
    const char *cursorType;
    const char *resourceName;
} CursorResourceEntry;

static void AddCursorFingerprintFromResource(const CursorResourceEntry &entry) {
    if (!entry.cursorType || !entry.resourceName) {
        return;
    }

    NSString *cursorType = [NSString stringWithUTF8String:entry.cursorType];
    NSString *resourceName = [NSString stringWithUTF8String:entry.resourceName];
    if (!cursorType || !resourceName) {
        return;
    }

    NSString *basePath = [@"/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors" stringByAppendingPathComponent:resourceName];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *imageCandidates = @[ @"cursor_1only_.png", @"cursor.png", @"cursor.pdf" ];
    NSString *imagePath = nil;
    for (NSString *candidate in imageCandidates) {
        NSString *fullPath = [basePath stringByAppendingPathComponent:candidate];
        if ([fm fileExistsAtPath:fullPath]) {
            imagePath = fullPath;
            break;
        }
    }
    if (!imagePath) {
        return;
    }

    NSImage *image = [[[NSImage alloc] initWithContentsOfFile:imagePath] autorelease];
    if (!image) {
        return;
    }

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[basePath stringByAppendingPathComponent:@"info.plist"]];
    double hotx = [[info objectForKey:@"hotx"] doubleValue];
    double hoty = [[info objectForKey:@"hoty"] doubleValue];
    NSPoint hotspot = NSMakePoint(hotx, hoty);

    NSCursor *tempCursor = [[[NSCursor alloc] initWithImage:image hotSpot:hotspot] autorelease];
    if (!tempCursor) {
        return;
    }

    NSString *fingerprint = CursorImageFingerprintUnsafe(tempCursor);
    if (!fingerprint) {
        return;
    }

    if (![g_cursorFingerprintMap objectForKey:fingerprint]) {
        [g_cursorFingerprintMap setObject:cursorType forKey:fingerprint];
    }
}

static void LoadSystemCursorResourceFingerprints(void) {
    static const CursorResourceEntry kResourceEntries[] = {
        {"progress", "busybutclickable"},
        {"wait", "countinguphand"},
        {"wait", "countingdownhand"},
        {"wait", "countingupanddownhand"},
        {"context-menu", "contextualmenu"},
        {"copy", "copy"},
        {"alias", "makealias"},
        {"not-allowed", "notallowed"},
        {"no-drop", "notallowed"},
        {"help", "help"},
        {"cell", "cell"},
        {"crosshair", "cross"},
        {"grab", "openhand"},
        {"grabbing", "closedhand"},
        {"pointer", "pointinghand"},
        {"move", "move"},
        {"all-scroll", "move"},
        {"zoom-in", "zoomin"},
        {"zoom-out", "zoomout"},
        {"text", "ibeamhorizontal"},
        {"vertical-text", "ibeamvertical"},
        {"col-resize", "resizeleftright"},
        {"col-resize", "resizeeastwest"},
        {"row-resize", "resizeupdown"},
        {"row-resize", "resizenorthsouth"},
        {"ew-resize", "resizeeastwest"},
        {"ew-resize", "resizeleftright"},
        {"ns-resize", "resizenorthsouth"},
        {"ns-resize", "resizeupdown"},
        {"n-resize", "resizenorth"},
        {"s-resize", "resizesouth"},
        {"e-resize", "resizeeast"},
        {"w-resize", "resizewest"},
        {"ne-resize", "resizenortheast"},
        {"nw-resize", "resizenorthwest"},
        {"se-resize", "resizesoutheast"},
        {"sw-resize", "resizesouthwest"},
        {"nesw-resize", "resizenortheastsouthwest"},
        {"nwse-resize", "resizenorthwestsoutheast"}
    };

    size_t count = sizeof(kResourceEntries) / sizeof(kResourceEntries[0]);
    for (size_t i = 0; i < count; ++i) {
        AddCursorFingerprintFromResource(kResourceEntries[i]);
    }
}

static void RegisterCursorNameMapping(NSString *name, NSString *cursorType) {
    if (!name || !cursorType) {
        return;
    }
    NSString *normalized = NormalizeCursorName(name);
    if (!normalized || [normalized length] == 0) {
        return;
    }
    if (![g_cursorNameMap objectForKey:normalized]) {
        [g_cursorNameMap setObject:cursorType forKey:normalized];
    }
}

static void RegisterSeedMapping(NSNumber *seedValue, NSString *cursorType) {
    if (!seedValue || !cursorType) {
        return;
    }
    if (!g_seedOverrides) {
        g_seedOverrides = [[NSMutableDictionary alloc] init];
    }
    if (![g_seedOverrides objectForKey:seedValue]) {
        [g_seedOverrides setObject:cursorType forKey:seedValue];
    }
}

static NSString* FindCursorMappingFile(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    const char *envPath = getenv("MAC_RECORDER_CURSOR_MAP");
    if (envPath) {
        [candidates addObject:[NSString stringWithUTF8String:envPath]];
    }

    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    if (cwd) {
        [candidates addObject:[cwd stringByAppendingPathComponent:@"cursor-nscursor-mapping.json"]];
    }

    Dl_info info;
    if (dladdr((const void *)&FindCursorMappingFile, &info)) {
        if (info.dli_fname) {
            NSString *modulePath = [NSString stringWithUTF8String:info.dli_fname];
            NSString *moduleDir = [modulePath stringByDeletingLastPathComponent];
            if (moduleDir) {
                [candidates addObject:[moduleDir stringByAppendingPathComponent:@"cursor-nscursor-mapping.json"]];
                NSString *parent = [moduleDir stringByDeletingLastPathComponent];
                if (parent) {
                    [candidates addObject:[parent stringByAppendingPathComponent:@"cursor-nscursor-mapping.json"]];
                }
            }
        }
    }

    NSBundle *bundle = [NSBundle bundleForClass:[CursorTimerTarget class]];
    if (bundle) {
        NSString *resourcePath = [bundle resourcePath];
        if (resourcePath) {
            [candidates addObject:[resourcePath stringByAppendingPathComponent:@"cursor-nscursor-mapping.json"]];
        }
        NSString *bundlePath = [bundle bundlePath];
        if (bundlePath) {
            [candidates addObject:[bundlePath stringByAppendingPathComponent:@"cursor-nscursor-mapping.json"]];
        }
    }

    for (NSString *candidate in candidates) {
        if (candidate && [[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

static void LoadCursorMappingOverrides(void) {
    NSString *mappingPath = FindCursorMappingFile();
    if (!mappingPath) {
        return;
    }

    NSData *data = [NSData dataWithContentsOfFile:mappingPath];
    if (!data) {
        return;
    }

    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![json isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSDictionary *cursorMapping = json[@"cursorMapping"];
    if (![cursorMapping isKindOfClass:[NSDictionary class]]) {
        return;
    }

    [cursorMapping enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSString *cursorType = (NSString *)key;
        NSDictionary *entry = (NSDictionary *)obj;
        if (![cursorType isKindOfClass:[NSString class]] || ![entry isKindOfClass:[NSDictionary class]]) {
            return;
        }

        NSString *fingerprint = entry[@"fingerprint"];
        if ([fingerprint isKindOfClass:[NSString class]] && [fingerprint length] > 0) {
            if (![g_cursorFingerprintMap objectForKey:fingerprint]) {
                [g_cursorFingerprintMap setObject:cursorType forKey:fingerprint];
            }
        }

        NSString *privateName = entry[@"privateName"];
        if ([privateName isKindOfClass:[NSString class]] && [privateName length] > 0) {
            RegisterCursorNameMapping(privateName, cursorType);
        }

        NSNumber *seed = entry[@"seed"];
        if ([seed isKindOfClass:[NSNumber class]]) {
            RegisterSeedMapping(seed, cursorType);
        }
    }];
}

// Runtime seed mapping - built dynamically on first use
// Seeds change between app launches, so we build the mapping at runtime by querying NSCursor objects
// SAFETY: Protected with try-catch to prevent crashes in Electron environments
static BOOL g_enableSeedLearning = YES; // Runtime seed learning enabled with crash protection
static NSMutableDictionary<NSNumber*, NSString*> *g_seedToTypeMap = nil;
static dispatch_once_t g_seedMapInitToken;

static void buildRuntimeSeedMapping() {
    dispatch_once(&g_seedMapInitToken, ^{
        @try {
            @autoreleasepool {
                g_seedToTypeMap = [[NSMutableDictionary alloc] init];

                // Instead of trying to build mapping upfront (which crashes),
                // we'll build it lazily as we encounter cursors during actual usage
                // For now, just initialize the empty map

                NSLog(@"✅ Runtime seed mapping initialized (will build lazily)");
            }
        } @catch (NSException *exception) {
            NSLog(@"⚠️ Failed to initialize runtime seed mapping: %@", exception.reason);
            g_seedToTypeMap = nil;
        }
    });
}

// Add a cursor seed to the runtime mapping
// NOTE: We don't pass cursor object to avoid potential crashes - we only need seed and type
static void addCursorToSeedMap(NSString *detectedType, int seed) {
    // Safety: Check if learning is enabled
    if (!g_enableSeedLearning) return;

    if (seed <= 0 || !detectedType || [detectedType length] == 0) return;

    @try {
        @autoreleasepool {
            buildRuntimeSeedMapping(); // Ensure map is initialized

            // If initialization failed, don't proceed
            if (!g_seedToTypeMap) return;

            NSNumber *key = @(seed);

            // Only add if we don't have this seed yet
            if (![g_seedToTypeMap objectForKey:key]) {
                [g_seedToTypeMap setObject:detectedType forKey:key];
                // Always log new seed mappings for debugging
                NSLog(@"📝 Learned seed mapping: %d -> %@", seed, detectedType);
            }
        }
    } @catch (NSException *exception) {
        // Silently fail - don't crash the app for cursor learning
        NSLog(@"⚠️ Failed to add cursor seed mapping: %@", exception.reason);
    } @catch (...) {
        NSLog(@"⚠️ Failed to add cursor seed mapping (unknown exception)");
    }
}

static NSString* cursorTypeFromSeed(int seed) {
    if (seed > 0) {
        @try {
            @autoreleasepool {
                NSNumber *key = @(seed);
                NSString *override = [g_seedOverrides objectForKey:key];
                if (override) {
                    return override;
                }

                // Only check runtime mappings if learning is enabled
                if (g_enableSeedLearning) {
                    buildRuntimeSeedMapping();
                    if (g_seedToTypeMap) {
                        NSString *runtime = [g_seedToTypeMap objectForKey:key];
                        if (runtime) {
                            return runtime;
                        }
                    }
                }
            }
        } @catch (NSException *exception) {
            // Silently fail - don't crash for cursor lookup
            NSLog(@"⚠️ Exception in cursorTypeFromSeed: %@", exception.reason);
        } @catch (...) {
            NSLog(@"⚠️ Unknown exception in cursorTypeFromSeed");
        }
    }
    switch(seed) {
        case 741324: return @"auto";
        case 741336: return @"none";
        case 741338: return @"context-menu";
        case 741339: return @"pointer";
        case 741341: return @"progress";
        case 741343: return @"wait";
        case 741345: return @"cell";
        case 741347: return @"crosshair";
        case 741357: return @"text";
        case 741359: return @"vertical-text";
        case 741361: return @"alias";
        case 741362: return @"copy";
        case 741364: return @"move";
        case 741368: return @"no-drop";
        case 741370: return @"not-allowed";
        case 741381: return @"grab";
        case 741385: return @"grabbing";
        case 741389: return @"col-resize";
        case 741393: return @"row-resize";
        case 741397: return @"n-resize";
        case 741398: return @"e-resize";
        case 741409: return @"s-resize";
        case 741413: return @"w-resize";
        case 741417: return @"ne-resize";
        case 741418: return @"nw-resize";
        case 741420: return @"se-resize";
        case 741424: return @"sw-resize";
        case 741426: return @"ew-resize";
        case 741436: return @"ns-resize";
        case 741438: return @"nesw-resize";
        case 741442: return @"nwse-resize";
        case 741444: return @"zoom-in";
        case 741446: return @"zoom-out";
        default: return nil;
    }
}

// Image-based cursor detection using known patterns from mapping
static NSString* cursorTypeFromImageSignature(NSImage *image, NSPoint hotspot, NSCursor *cursor) {
    if (!image) {
        return nil;
    }

    NSSize size = [image size];
    CGFloat width = size.width;
    CGFloat height = size.height;
    CGFloat aspectRatio = width > 0 ? width / height : 0;
    CGFloat relativeX = width > 0 ? hotspot.x / width : 0;
    CGFloat relativeY = height > 0 ? hotspot.y / height : 0;

    // Tolerance for floating point comparison
    CGFloat tolerance = 0.05;
    CGFloat tightTolerance = 0.02; // For precise hotspot matching

    // Helper lambda for approximate comparison
    auto approx = [tolerance](CGFloat a, CGFloat b) -> BOOL {
        return fabs(a - b) < tolerance;
    };

    auto approxTight = [tightTolerance](CGFloat a, CGFloat b) -> BOOL {
        return fabs(a - b) < tightTolerance;
    };

    // Pattern matching based on cursor-nscursor-mapping.json

    // none: 1x1, ratio=1.0, hotspot=(0,0)
    if (approx(width, 1) && approx(height, 1)) {
        return @"none";
    }

    // text: 22x23, ratio=0.956, hotspot rel=(0.52, 0.48)
    if (approx(width, 22) && approx(height, 23) && approx(aspectRatio, 0.956)) {
        return @"text";
    }

    // vertical-text: 22x21, ratio=1.047, hotspot rel=(0.5, 0.476)
    if (approx(width, 22) && approx(height, 21) && approx(aspectRatio, 1.047)) {
        return @"vertical-text";
    }

    // pointer: 32x32, ratio=1.0, hotspot rel=(0.406, 0.25)
    if (approx(width, 32) && approx(height, 32) && approx(relativeY, 0.25)) {
        return @"pointer";
    }

    // grab/grabbing: 32x32, ratio=1.0, hotspot rel=(0.5, 0.531)
    // Distinguished by pointer equality
    if (approx(width, 32) && approx(height, 32) && approx(relativeY, 0.531)) {
        if (cursor) {
            if (cursor == [NSCursor closedHandCursor]) {
                return @"grabbing";
            }
            if (cursor == [NSCursor openHandCursor]) {
                return @"grab";
            }
        }
        return @"grab"; // Default to grab if can't distinguish
    }

    // 24x24 cursors: crosshair vs move/all-scroll
    // Distinguished by precise hotspot position
    if (approx(width, 24) && approx(height, 24)) {
        // crosshair: hotspot rel=(0.458, 0.458)
        if (approxTight(relativeX, 0.458) && approxTight(relativeY, 0.458)) {
            return @"crosshair";
        }
        // move/all-scroll: hotspot rel=(0.5, 0.5)
        if (approxTight(relativeX, 0.5) && approxTight(relativeY, 0.5)) {
            return @"move"; // or all-scroll, they're identical
        }
        // Fallback for 24x24
        return @"crosshair";
    }

    // help/cell: 18x18, ratio=1.0, hotspot rel=(0.5, 0.5)
    // NOTE: Cannot distinguish between help and cell by image alone
    if (approx(width, 18) && approx(height, 18)) {
        return @"cell"; // Default to cell for compatibility
    }

    // col-resize: 30x24, ratio=1.25, hotspot rel=(0.5, 0.5)
    if (approx(width, 30) && approx(height, 24) && approx(aspectRatio, 1.25)) {
        return @"col-resize";
    }

    // e-resize/w-resize/ew-resize: 24x18, ratio=1.333, hotspot rel=(0.5, 0.5)
    // Distinguish using pointer equality
    if (approx(width, 24) && approx(height, 18) && approx(aspectRatio, 1.333)) {
        if (cursor) {
            if ([NSCursor respondsToSelector:@selector(resizeLeftCursor)] &&
                cursor == [NSCursor resizeLeftCursor]) {
                return @"w-resize";
            }
            if ([NSCursor respondsToSelector:@selector(resizeRightCursor)] &&
                cursor == [NSCursor resizeRightCursor]) {
                return @"e-resize";
            }
            if ([NSCursor respondsToSelector:@selector(resizeLeftRightCursor)] &&
                cursor == [NSCursor resizeLeftRightCursor]) {
                return @"ew-resize";
            }
        }
        return @"ew-resize"; // Default to ew-resize
    }

    // row-resize: 24x28, ratio=0.857, hotspot rel=(0.5, 0.5)
    if (approx(width, 24) && approx(height, 28) && approx(aspectRatio, 0.857)) {
        return @"row-resize";
    }

    // n-resize/s-resize/ns-resize: 18x28, ratio=0.643, hotspot rel=(0.5, 0.5)
    // Distinguish using pointer equality
    if (approx(width, 18) && approx(height, 28) && approx(aspectRatio, 0.643)) {
        if (cursor) {
            if ([NSCursor respondsToSelector:@selector(resizeUpCursor)] &&
                cursor == [NSCursor resizeUpCursor]) {
                return @"n-resize";
            }
            if ([NSCursor respondsToSelector:@selector(resizeDownCursor)] &&
                cursor == [NSCursor resizeDownCursor]) {
                return @"s-resize";
            }
            if ([NSCursor respondsToSelector:@selector(resizeUpDownCursor)] &&
                cursor == [NSCursor resizeUpDownCursor]) {
                return @"ns-resize";
            }
        }
        return @"ns-resize"; // Default to ns-resize
    }

    // ne-resize/nw-resize/se-resize/sw-resize/nesw-resize/nwse-resize: 22x22, ratio=1.0, hotspot rel=(0.5, 0.5)
    if (approx(width, 22) && approx(height, 22)) {
        return @"nwse-resize"; // Default to nwse-resize for all diagonal cursors
    }

    // zoom-in/zoom-out: 28x26, ratio=1.077, hotspot rel=(0.428, 0.423)
    // NOTE: Cannot distinguish between zoom-in and zoom-out by image or pointer alone
    // They use the same image and there's no standard NSCursor for zoom
    if (approx(width, 28) && approx(height, 26) && approx(aspectRatio, 1.077)) {
        return @"zoom-in"; // Default to zoom-in (cannot distinguish from zoom-out)
    }

    // alias: 16x21, ratio=0.762, hotspot rel=(0.688, 0.143)
    if (approx(width, 16) && approx(height, 21) && approx(aspectRatio, 0.762)) {
        return @"alias";
    }

    // 28x40 cursors: default/auto vs context-menu/progress/wait/copy/no-drop/not-allowed
    // Distinguished by precise hotspot position and pointer equality
    if (approx(width, 28) && approx(height, 40) && approx(aspectRatio, 0.7)) {
        // auto/default: hotspot rel=(0.161, 0.1) - hotspot at (4.5, 4)
        if (approxTight(relativeX, 0.161) && approxTight(relativeY, 0.1)) {
            return @"default";
        }
        // context-menu/progress/wait/copy/no-drop/not-allowed: hotspot rel=(0.179, 0.125) - hotspot at (5, 5)
        if (approxTight(relativeX, 0.179) && approxTight(relativeY, 0.125)) {
            // Try pointer equality for standard cursors
            if (cursor) {
                if (cursor == [NSCursor contextualMenuCursor]) {
                    return @"context-menu";
                }
                if (cursor == [NSCursor dragCopyCursor]) {
                    return @"copy";
                }
                if (cursor == [NSCursor operationNotAllowedCursor]) {
                    return @"not-allowed";
                }
            }
            // NOTE: progress, wait, no-drop don't have standard NSCursor pointers
            // Return "progress" as default for this hotspot pattern (better than "default")
            // Let cursor name detection in caller distinguish between progress/wait
            return @"progress";
        }
        return @"default";
    }

    return nil;
}

static NSString* cursorTypeFromNSCursor(NSCursor *cursor) {
    if (!cursor) {
        return @"default";
    }

    // PRIORITY 1: Standard macOS cursor pointer equality (fastest and most reliable)
    if (cursor == [NSCursor arrowCursor]) {
        return @"default";
    }
    if (cursor == [NSCursor IBeamCursor]) {
        return @"text";
    }
    if ([NSCursor respondsToSelector:@selector(IBeamCursorForVerticalLayout)] &&
        cursor == [NSCursor IBeamCursorForVerticalLayout]) {
        return @"text";
    }
    if (cursor == [NSCursor pointingHandCursor]) {
        return @"pointer";
    }
    if (cursor == [NSCursor crosshairCursor]) {
        return @"crosshair";
    }
    if (cursor == [NSCursor openHandCursor]) {
        return @"grab";
    }
    if (cursor == [NSCursor closedHandCursor]) {
        return @"grabbing";
    }
    if (cursor == [NSCursor operationNotAllowedCursor]) {
        return @"not-allowed";
    }
    if (cursor == [NSCursor dragCopyCursor]) {
        return @"copy";
    }
    if (cursor == [NSCursor dragLinkCursor]) {
        return @"alias";
    }
    if (cursor == [NSCursor contextualMenuCursor]) {
        return @"context-menu";
    }

    // Resize cursors
    if ([NSCursor respondsToSelector:@selector(resizeLeftRightCursor)]) {
        if (cursor == [NSCursor resizeLeftRightCursor]) {
            return @"col-resize";
        }
    }
    if ([NSCursor respondsToSelector:@selector(resizeUpDownCursor)]) {
        if (cursor == [NSCursor resizeUpDownCursor]) {
            return @"row-resize";
        }
    }

    NSString *privateCursorName = CursorNameFromNSCursor(cursor);
    if (privateCursorName) {
        NSString *normalizedName = NormalizeCursorName(privateCursorName);
        NSString *mappedType = normalizedName ? [g_cursorNameMap objectForKey:normalizedName] : nil;
        if (mappedType) {
            CacheCursorFingerprint(cursor, mappedType, nil);
            return mappedType;
        }
        NSString *typeFromName = cursorTypeFromCursorName(privateCursorName);
        if (typeFromName) {
            RegisterCursorNameMapping(privateCursorName, typeFromName);
            CacheCursorFingerprint(cursor, typeFromName, nil);
            return typeFromName;
        }
    }

    NSString *fingerprintHint = nil;
    NSString *fingerprintMatch = LookupCursorTypeByFingerprint(cursor, &fingerprintHint);
    if (fingerprintMatch) {
        return fingerprintMatch;
    }

    // PRIORITY 2: Image-based detection (for browser custom cursors)
    NSImage *cursorImage = [cursor image];
    NSPoint hotspot = [cursor hotSpot];
    NSString *imageBasedType = cursorTypeFromImageSignature(cursorImage, hotspot, cursor);
    if (imageBasedType) {
        if (![imageBasedType isEqualToString:@"default"]) {
            CacheCursorFingerprint(cursor, imageBasedType, fingerprintHint);
        }
        return imageBasedType;
    }

    // PRIORITY 3: Name-based detection
    NSString *className = NSStringFromClass([cursor class]);
    NSString *derived = cursorTypeFromCursorName(className);
    if (derived) {
        if (![derived isEqualToString:@"default"]) {
            CacheCursorFingerprint(cursor, derived, fingerprintHint);
        }
        return derived;
    }

    // Default fallback
    return @"default";
}

static NSString* detectSystemCursorType(void) {
    InitializeCursorFingerprintMap();
    __block NSString *cursorType = nil;
    __block NSCursor *detectedCursor = nil;

    NSString *cgsName = CopyCurrentCursorNameFromCGS();
    if (cgsName && [cgsName length] > 0) {
        NSString *normalized = NormalizeCursorName(cgsName);
        NSString *mapped = normalized ? [g_cursorNameMap objectForKey:normalized] : nil;
        if (mapped) {
            return mapped;
        }
        NSString *derivedFromName = cursorTypeFromCursorName(cgsName);
        if (derivedFromName) {
            RegisterCursorNameMapping(cgsName, derivedFromName);
            return derivedFromName;
        }
    }

    int cursorSeed = SafeCGSCurrentCursorSeed();
    if (cursorSeed > 0) {
        NSString *seedType = cursorTypeFromSeed(cursorSeed);
        if (seedType) {
            return seedType;
        }
    }

    void (^fetchCursorBlock)(void) = ^{
        NSCursor *currentCursor = nil;

        // Try different methods to get current cursor
        if ([NSCursor respondsToSelector:@selector(currentSystemCursor)]) {
            currentCursor = [NSCursor currentSystemCursor];
        }

        if (!currentCursor) {
            currentCursor = [NSCursor currentCursor];
        }

        detectedCursor = currentCursor; // Save for seed learning

        if (currentCursor) {
            NSString *directType = cursorTypeFromNSCursor(currentCursor);
            NSString *fallbackType = directType;

            if (directType && ![directType isEqualToString:@"default"]) {
                cursorType = directType;
                return;
            }

            NSString *className = NSStringFromClass([currentCursor class]);
            NSString *description = [currentCursor description];
            // Use more direct cursor detection approach
            NSImage *cursorImage = [currentCursor image];
            NSPoint hotspot = [currentCursor hotSpot];
            NSSize imageSize = [cursorImage size];

            // ROBUST cursor detection - works with any cursor size
            CGFloat aspectRatio = imageSize.width / imageSize.height;
            CGFloat relativeHotspotX = hotspot.x / imageSize.width;
            CGFloat relativeHotspotY = hotspot.y / imageSize.height;
            BOOL fallbackDefaults = (fallbackType && [fallbackType isEqualToString:@"default"]);
            BOOL cursorNameSuggestsText = NO;
            if (className && ([className localizedCaseInsensitiveContainsString:@"ibeam"] ||
                              [className localizedCaseInsensitiveContainsString:@"text"])) {
                cursorNameSuggestsText = YES;
            }
            if (description && ([description localizedCaseInsensitiveContainsString:@"ibeam"] ||
                                 [description localizedCaseInsensitiveContainsString:@"text"])) {
                cursorNameSuggestsText = YES;
            }



            // UPDATED with real cursor data:
            // Arrow: 17x23 ratio=0.74 hotspot=(0.24,0.17)
            // Text: 9x18 ratio=0.50 hotspot=(0.44,0.50)
            // Pointer: 32x32 ratio=1.00 hotspot=(0.41,0.25)

            // 1. TEXT/I-BEAM CURSOR - narrow ratio, center hotspot
            if (aspectRatio >= 0.45 && aspectRatio <= 0.60 && // Narrow (0.50 typical)
                relativeHotspotX >= 0.35 && relativeHotspotX <= 0.55 && // Center X (0.44 typical)
                relativeHotspotY >= 0.40 && relativeHotspotY <= 0.60) { // Center Y (0.50 typical)
                BOOL directSaysText = (directType && [directType isEqualToString:@"text"]);
                if (cursorNameSuggestsText || directSaysText) {
                    cursorType = @"text";
                } else {
                    cursorType = fallbackType ?: @"default";
                }
            }
            // 2. ARROW CURSOR - medium ratio, top-left hotspot
            else if (aspectRatio >= 0.65 && aspectRatio <= 0.85 && // Medium (0.74 typical)
                     relativeHotspotX >= 0.15 && relativeHotspotX <= 0.35 && // Left side (0.24 typical)
                     relativeHotspotY >= 0.10 && relativeHotspotY <= 0.25) { // Top area (0.17 typical)
                cursorType = @"default";
            }
            // 3. POINTER CURSOR - square ratio, left-center hotspot
            else if (aspectRatio >= 0.90 && aspectRatio <= 1.10 && // Square (1.00 typical)
                     relativeHotspotX >= 0.30 && relativeHotspotX <= 0.50 && // Left-center (0.41 typical)
                     relativeHotspotY >= 0.15 && relativeHotspotY <= 0.35) { // Upper area (0.25 typical)
                cursorType = @"pointer";
            }
            else {
                // Try to use a different approach - cursor name introspection
                NSString *derived = cursorTypeFromNSCursor(currentCursor);
                if (derived && ![derived isEqualToString:@"default"]) {
                    cursorType = derived;
                    // NSLog(@"🎯 DERIVED FROM ANALYSIS: %@", cursorType);
                } else {
                    cursorType = fallbackType ?: @"default";
                    // NSLog(@"🎯 FALLBACK TO DEFAULT (will check AX)");
                }
            }

            if (cursorType && ![cursorType isEqualToString:@"default"]) {
                CacheCursorFingerprint(currentCursor, cursorType, nil);
            }
        } else {
            // NSLog(@"🖱️ No current cursor found");
            cursorType = @"default";
        }
    };

    if ([NSThread isMainThread]) {
        fetchCursorBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), fetchCursorBlock);
    }

    if (cursorType && ![cursorType isEqualToString:@"default"] && cursorSeed > 0) {
        addCursorToSeedMap(cursorType, cursorSeed);
    }

    return cursorType;
}

NSString* getCursorType() {
    @autoreleasepool {
        g_cursorTypeCounter++;

        // Get cursor position first
        BOOL hasCursorPosition = NO;
        CGPoint cursorPos = CGPointZero;

        CGEventRef event = CGEventCreate(NULL);
        if (event) {
            cursorPos = CGEventGetLocation(event);
            hasCursorPosition = YES;
            CFRelease(event);
        }

        if (!hasCursorPosition) {
            if ([NSThread isMainThread]) {
                cursorPos = [NSEvent mouseLocation];
                hasCursorPosition = YES;
            } else {
                __block CGPoint fallbackPos = CGPointZero;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    fallbackPos = [NSEvent mouseLocation];
                });
                cursorPos = fallbackPos;
                hasCursorPosition = YES;
            }
        }

        // Get seed and save to global variable for getCursorPosition()
        int currentSeed = SafeCGSCurrentCursorSeed();
        g_lastCursorSeed = currentSeed; // Save for getCursorPosition()

        // Use cursorTypeFromNSCursor for detection (pointer equality + image-based)
        // DO NOT use accessibility detection as it's unreliable and causes false positives
        NSString *systemCursorType = detectSystemCursorType();
        NSString *finalType = systemCursorType && [systemCursorType length] > 0 ? systemCursorType : @"default";

        // Only log when cursor type changes
        static NSString *lastLoggedType = nil;
        if (![finalType isEqualToString:lastLoggedType]) {
            if (currentSeed > 0) {
                NSLog(@"🎯 %@ (seed: %d)", finalType, currentSeed);
            } else {
                NSLog(@"🎯 %@", finalType);
            }
            lastLoggedType = [finalType copy];
        }
        return finalType;
    }
}

// Dosyaya yazma helper fonksiyonu
void writeToFile(NSDictionary *cursorData) {
    @autoreleasepool {
        if (!g_fileHandle || !cursorData) {
            return;
        }
        
        @try {
            NSError *error;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:cursorData
                                                               options:0
                                                                 error:&error];
            if (jsonData && !error) {
                NSString *jsonString = [[[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] autorelease];
                
                if (g_isFirstWrite) {
                    // İlk yazma - array başlat
                    [g_fileHandle writeData:[@"[" dataUsingEncoding:NSUTF8StringEncoding]];
                    [g_fileHandle writeData:[jsonString dataUsingEncoding:NSUTF8StringEncoding]];
                    g_isFirstWrite = false;
                } else {
                    // Sonraki yazmalar - virgül + json
                    [g_fileHandle writeData:[@"," dataUsingEncoding:NSUTF8StringEncoding]];
                    [g_fileHandle writeData:[jsonString dataUsingEncoding:NSUTF8StringEncoding]];
                }
                
                [g_fileHandle synchronizeFile];
            }
        } @catch (NSException *exception) {
            // Hata durumunda sessizce devam et
        }
    }
}

// Event callback for mouse events
CGEventRef eventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    @autoreleasepool {
        g_debugCallbackCount++; // Callback çağrıldığını say
        
        if (!g_isCursorTracking || !g_trackingStartTime || !g_fileHandle) {
            return event;
        }
        
        CGPoint rawLocation = CGEventGetLocation(event);
        
        // Coordinates are already in logical space; no additional scaling needed here.
        CGPoint location = rawLocation;
        NSDate *currentDate = [NSDate date];
        NSTimeInterval timestamp = [currentDate timeIntervalSinceDate:g_trackingStartTime] * 1000; // milliseconds
        NSTimeInterval unixTimeMs = [currentDate timeIntervalSince1970] * 1000; // unix timestamp in milliseconds
        NSString *cursorType = getCursorType();
        if (!cursorType) {
            cursorType = @"default";
        }
        // (already captured above)
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

        if (!ShouldEmitCursorEvent(location, cursorType, eventType)) {
            return event;
        }
        
        // Cursor data oluştur
        NSDictionary *cursorInfo = @{
            @"x": @((int)location.x),
            @"y": @((int)location.y),
            @"timestamp": @(timestamp),
            @"unixTimeMs": @(unixTimeMs),
            @"cursorType": cursorType,
            @"type": eventType
        };
        
        // Direkt dosyaya yaz
        writeToFile(cursorInfo);
        RememberCursorEvent(location, cursorType, eventType);
        
        return event;
    }
}

// Timer callback for periodic cursor position updates
void cursorTimerCallback() {
    @autoreleasepool {
        g_debugCallbackCount++; // Timer callback çağrıldığını say
        
        if (!g_isCursorTracking || !g_trackingStartTime || !g_fileHandle) {
            return;
        }
        
        // Get cursor position with DPR scaling correction
        CGEventRef event = CGEventCreate(NULL);
        CGPoint rawLocation = CGEventGetLocation(event);
        if (event) {
            CFRelease(event);
        }
        
        // Coordinates are already in logical space; no additional scaling needed here.
        CGPoint location = rawLocation;
        
        NSDate *currentDate = [NSDate date];
        NSTimeInterval timestamp = [currentDate timeIntervalSinceDate:g_trackingStartTime] * 1000; // milliseconds
        NSTimeInterval unixTimeMs = [currentDate timeIntervalSince1970] * 1000; // unix timestamp in milliseconds
        NSString *cursorType = getCursorType();
        if (!cursorType) {
            cursorType = @"default";
        }
        NSString *eventType = @"move";

        if (!ShouldEmitCursorEvent(location, cursorType, eventType)) {
            return;
        }
        
        // Cursor data oluştur
        NSDictionary *cursorInfo = @{
            @"x": @((int)location.x),
            @"y": @((int)location.y),
            @"timestamp": @(timestamp),
            @"unixTimeMs": @(unixTimeMs),
            @"cursorType": cursorType,
            @"type": eventType
        };
        
        // Direkt dosyaya yaz
        writeToFile(cursorInfo);
        RememberCursorEvent(location, cursorType, eventType);
    }
}

// Helper function to cleanup cursor tracking
void cleanupCursorTracking() {
    g_isCursorTracking = false;
    
    // Timer temizle
    if (g_cursorTimer) {
        [g_cursorTimer invalidate];
        g_cursorTimer = nil;
    }
    
    if (g_timerTarget) {
        [g_timerTarget autorelease];
        g_timerTarget = nil;
    }
    
    // Dosyayı önce kapat (en önemli işlem)
    if (g_fileHandle) {
        @try {
            if (g_isFirstWrite) {
                // Hiç veri yazılmamışsa boş array
                [g_fileHandle writeData:[@"[]" dataUsingEncoding:NSUTF8StringEncoding]];
            } else {
                // JSON array'i kapat
                [g_fileHandle writeData:[@"]" dataUsingEncoding:NSUTF8StringEncoding]];
            }
            [g_fileHandle synchronizeFile];
            [g_fileHandle closeFile];
        } @catch (NSException *exception) {
            // Dosya işlemi hata verirse sessizce devam et
        }
        g_fileHandle = nil;
    }
    
    // Event tap'i durdur (non-blocking)
    if (g_eventTap) {
        CGEventTapEnable(g_eventTap, false);
        g_eventTap = NULL; // CFRelease işlemini yapmıyoruz - system handle etsin
    }
    
    // Run loop source'unu kaldır (non-blocking)
    if (g_runLoopSource) {
        g_runLoopSource = NULL; // CFRelease işlemini yapmıyoruz
    }
    
    // Global değişkenleri sıfırla
    g_trackingStartTime = nil;
    g_outputPath = nil;
    g_debugCallbackCount = 0;
    g_lastDetectedCursorType = nil;
    g_cursorTypeCounter = 0;
    g_isFirstWrite = true;
    ResetCursorEventHistory();
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
        // Dosyayı oluştur ve aç
        g_outputPath = [NSString stringWithUTF8String:outputPath.c_str()];
        g_fileHandle = [[NSFileHandle fileHandleForWritingAtPath:g_outputPath] retain];
        
        if (!g_fileHandle) {
            // Dosya yoksa oluştur
            [[NSFileManager defaultManager] createFileAtPath:g_outputPath contents:nil attributes:nil];
            g_fileHandle = [[NSFileHandle fileHandleForWritingAtPath:g_outputPath] retain];
        }
        
        if (!g_fileHandle) {
            return Napi::Boolean::New(env, false);
        }
        
        // Dosyayı temizle (baştan başla)
        [g_fileHandle truncateFileAtOffset:0];
        g_isFirstWrite = true;
        
        g_trackingStartTime = [NSDate date];
        ResetCursorEventHistory();
        
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
        
        bool eventTapActive = false;
        g_eventTap = CGEventTapCreate(kCGSessionEventTap,
                                     kCGHeadInsertEventTap,
                                     kCGEventTapOptionListenOnly,
                                     eventMask,
                                     eventCallback,
                                     NULL);
        
        if (g_eventTap) {
            // Event tap başarılı - detaylı event tracking aktif
            g_runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_eventTap, 0);
            CFRunLoopAddSource(CFRunLoopGetMain(), g_runLoopSource, kCFRunLoopCommonModes);
            CGEventTapEnable(g_eventTap, true);
            eventTapActive = true;
            NSLog(@"✅ Cursor event tap active - event-driven tracking");
        } else {
            NSLog(@"⚠️  Failed to create cursor event tap; falling back to timer-based tracking (requires Accessibility permission)");
        }
        
        if (!eventTapActive) {
            // NSTimer fallback (main thread)
            g_timerTarget = [[CursorTimerTarget alloc] init];
            
            g_cursorTimer = [NSTimer timerWithTimeInterval:0.05 // 50ms (20 FPS)
                                                    target:g_timerTarget
                                                  selector:@selector(timerCallback:)
                                                  userInfo:nil
                                                   repeats:YES];
            
            // Main run loop'a ekle
            [[NSRunLoop mainRunLoop] addTimer:g_cursorTimer forMode:NSRunLoopCommonModes];
        }
        
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
        cleanupCursorTracking();
        return Napi::Boolean::New(env, true);
        
    } @catch (NSException *exception) {
        cleanupCursorTracking();
        return Napi::Boolean::New(env, false);
    }
}

// Helper function to get display scaling info for cursor coordinates
NSDictionary* getDisplayScalingInfo(CGPoint globalPoint) {
    @try {
        // Get all displays
        uint32_t displayCount;
        CGDirectDisplayID displayIDs[32];
        CGGetActiveDisplayList(32, displayIDs, &displayCount);

        // Find which display contains this point
        for (uint32_t i = 0; i < displayCount; i++) {
            CGDirectDisplayID displayID = displayIDs[i];
            CGRect displayBounds = CGDisplayBounds(displayID);

            BOOL isInBounds = (globalPoint.x >= displayBounds.origin.x &&
                              globalPoint.x < displayBounds.origin.x + displayBounds.size.width &&
                              globalPoint.y >= displayBounds.origin.y &&
                              globalPoint.y < displayBounds.origin.y + displayBounds.size.height);

            // Check if point is within this display
            if (isInBounds) {
                // Compute physical dimensions using pixel counts to avoid heavy APIs
                CGSize logicalSize = displayBounds.size;
                CGSize actualPhysicalSize = CGSizeMake(CGDisplayPixelsWide(displayID), CGDisplayPixelsHigh(displayID));
                CGSize reportedPhysicalSize = actualPhysicalSize;

                CGFloat scaleX = logicalSize.width > 0 ? actualPhysicalSize.width / logicalSize.width : 1.0;
                CGFloat scaleY = logicalSize.height > 0 ? actualPhysicalSize.height / logicalSize.height : 1.0;
                CGFloat scaleFactor = MAX(scaleX, scaleY);
                
                return @{
                    @"displayID": @(displayID),
                    @"logicalSize": [NSValue valueWithSize:NSMakeSize(logicalSize.width, logicalSize.height)],
                    @"physicalSize": [NSValue valueWithSize:NSMakeSize(actualPhysicalSize.width, actualPhysicalSize.height)],
                    @"scaleFactor": @(scaleFactor),
                    @"displayBounds": [NSValue valueWithRect:NSMakeRect(displayBounds.origin.x, displayBounds.origin.y, displayBounds.size.width, displayBounds.size.height)]
                };
            }
        }
        
        // Fallback to main display
        CGDirectDisplayID mainDisplay = CGMainDisplayID();
        CGRect displayBounds = CGDisplayBounds(mainDisplay);

        CGSize logicalSize = displayBounds.size;
        CGSize actualPhysicalSize = CGSizeMake(CGDisplayPixelsWide(mainDisplay), CGDisplayPixelsHigh(mainDisplay));
        CGFloat scaleFactor = 1.0;
        if (logicalSize.width > 0 && logicalSize.height > 0) {
            CGFloat scaleX = actualPhysicalSize.width / logicalSize.width;
            CGFloat scaleY = actualPhysicalSize.height / logicalSize.height;
            scaleFactor = MAX(scaleX, scaleY);
        }

        return @{
            @"displayID": @(mainDisplay),
            @"logicalSize": [NSValue valueWithSize:NSMakeSize(logicalSize.width, logicalSize.height)],
            @"physicalSize": [NSValue valueWithSize:NSMakeSize(actualPhysicalSize.width, actualPhysicalSize.height)],
            @"scaleFactor": @(scaleFactor),
            @"displayBounds": [NSValue valueWithRect:NSMakeRect(displayBounds.origin.x, displayBounds.origin.y, displayBounds.size.width, displayBounds.size.height)]
        };
    } @catch (NSException *exception) {
        return nil;
    }
}

// NAPI Function: Get Current Cursor Position
Napi::Value GetCursorPosition(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        // Get raw cursor position (may be scaled on Retina displays)
        CGEventRef event = CGEventCreate(NULL);
        CGPoint rawLocation = CGEventGetLocation(event);
        if (event) {
            CFRelease(event);
        }
        
        CGPoint logicalLocation = rawLocation;

        NSString *cursorType = getCursorType();
        
        // Mouse button state'ini kontrol et
        bool currentLeftMouseDown = CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft);
        bool currentRightMouseDown = CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonRight);
        
        NSString *eventType = @"move";
        
        // Mouse button state değişikliklerini tespit et
        if (currentLeftMouseDown && !g_leftMouseDown) {
            eventType = @"mousedown";
            g_lastEventType = @"mousedown";
        } else if (!currentLeftMouseDown && g_leftMouseDown) {
            eventType = @"mouseup";
            g_lastEventType = @"mouseup";
        } else if (currentRightMouseDown && !g_rightMouseDown) {
            eventType = @"rightmousedown";
            g_lastEventType = @"rightmousedown";
        } else if (!currentRightMouseDown && g_rightMouseDown) {
            eventType = @"rightmouseup";
            g_lastEventType = @"rightmouseup";
        } else {
            eventType = @"move";
            g_lastEventType = @"move";
        }
        
        // State'i güncelle
        g_leftMouseDown = currentLeftMouseDown;
        g_rightMouseDown = currentRightMouseDown;
        
        Napi::Object result = Napi::Object::New(env);
        result.Set("x", Napi::Number::New(env, (int)logicalLocation.x));
        result.Set("y", Napi::Number::New(env, (int)logicalLocation.y));
        result.Set("cursorType", Napi::String::New(env, [cursorType UTF8String]));
        result.Set("eventType", Napi::String::New(env, [eventType UTF8String]));

        // Add cursor seed (from global variable set by getCursorType())
        result.Set("seed", Napi::Number::New(env, g_lastCursorSeed));

        // Basic display info
        NSDictionary *scalingInfo = getDisplayScalingInfo(rawLocation);
        if (scalingInfo) {
            CGFloat scaleFactor = [[scalingInfo objectForKey:@"scaleFactor"] doubleValue];
            result.Set("scaleFactor", Napi::Number::New(env, scaleFactor));
        }

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
    result.Set("hasEventTap", Napi::Boolean::New(env, g_eventTap != NULL));
    result.Set("hasRunLoopSource", Napi::Boolean::New(env, g_runLoopSource != NULL));
    result.Set("hasFileHandle", Napi::Boolean::New(env, g_fileHandle != NULL));
    result.Set("hasTimer", Napi::Boolean::New(env, g_cursorTimer != NULL));
    result.Set("debugCallbackCount", Napi::Number::New(env, g_debugCallbackCount));
    result.Set("cursorTypeCounter", Napi::Number::New(env, g_cursorTypeCounter));

    return result;
}

// NAPI Function: Get Detailed Cursor Debug Info
Napi::Value GetCursorDebugInfo(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    @try {
        __block Napi::Object result = Napi::Object::New(env);

        void (^debugBlock)(void) = ^{
            NSCursor *currentCursor = nil;

            if ([NSCursor respondsToSelector:@selector(currentSystemCursor)]) {
                currentCursor = [NSCursor currentSystemCursor];
            }
            if (!currentCursor) {
                currentCursor = [NSCursor currentCursor];
            }

            if (currentCursor) {
                NSString *className = NSStringFromClass([currentCursor class]);
                NSString *description = [currentCursor description];
                NSImage *cursorImage = [currentCursor image];
                NSPoint hotspot = [currentCursor hotSpot];
                NSSize imageSize = [cursorImage size];
                NSString *privateName = CursorNameFromNSCursor(currentCursor);
                NSString *fingerprint = CursorImageFingerprintUnsafe(currentCursor);

                CGFloat aspectRatio = imageSize.width > 0 ? imageSize.width / imageSize.height : 0;
                CGFloat relativeHotspotX = imageSize.width > 0 ? hotspot.x / imageSize.width : 0;
                CGFloat relativeHotspotY = imageSize.height > 0 ? hotspot.y / imageSize.height : 0;

                // Cursor identity - pointer address, hash, and seed
                uintptr_t cursorPointer = (uintptr_t)currentCursor;
                NSUInteger cursorHash = [currentCursor hash];
                int cursorSeed = SafeCGSCurrentCursorSeed();

                // Basic info
                result.Set("className", Napi::String::New(env, [className UTF8String]));
                result.Set("description", Napi::String::New(env, [description UTF8String]));
                if (privateName) {
                    result.Set("privateName", Napi::String::New(env, [privateName UTF8String]));
                } else {
                    result.Set("privateName", env.Null());
                }
                result.Set("pointerAddress", Napi::Number::New(env, cursorPointer));
                result.Set("hash", Napi::Number::New(env, cursorHash));
                result.Set("seed", Napi::Number::New(env, cursorSeed));
                if (fingerprint) {
                    result.Set("fingerprint", Napi::String::New(env, [fingerprint UTF8String]));
                } else {
                    result.Set("fingerprint", env.Null());
                }

                // Image info
                Napi::Object imageInfo = Napi::Object::New(env);
                imageInfo.Set("width", Napi::Number::New(env, imageSize.width));
                imageInfo.Set("height", Napi::Number::New(env, imageSize.height));
                imageInfo.Set("aspectRatio", Napi::Number::New(env, aspectRatio));
                result.Set("image", imageInfo);

                // Hotspot info
                Napi::Object hotspotInfo = Napi::Object::New(env);
                hotspotInfo.Set("x", Napi::Number::New(env, hotspot.x));
                hotspotInfo.Set("y", Napi::Number::New(env, hotspot.y));
                hotspotInfo.Set("relativeX", Napi::Number::New(env, relativeHotspotX));
                hotspotInfo.Set("relativeY", Napi::Number::New(env, relativeHotspotY));
                result.Set("hotspot", hotspotInfo);

                // Detection results
                NSString *directType = cursorTypeFromNSCursor(currentCursor);
                NSString *systemType = detectSystemCursorType();

                result.Set("directDetection", Napi::String::New(env, [directType UTF8String]));
                result.Set("systemDetection", Napi::String::New(env, [systemType UTF8String]));

                // Get cursor position and AX detection
                CGEventRef event = CGEventCreate(NULL);
                if (event) {
                    CGPoint cursorPos = CGEventGetLocation(event);
                    CFRelease(event);

                    NSString *axType = detectCursorTypeUsingAccessibility(cursorPos);
                    if (axType) {
                        result.Set("axDetection", Napi::String::New(env, [axType UTF8String]));
                    } else {
                        result.Set("axDetection", env.Null());
                    }

                    NSString *finalType = getCursorType();
                    result.Set("finalType", Napi::String::New(env, [finalType UTF8String]));
                }
            } else {
                result.Set("error", Napi::String::New(env, "No cursor found"));
            }
        };

        if ([NSThread isMainThread]) {
            debugBlock();
        } else {
            dispatch_sync(dispatch_get_main_queue(), debugBlock);
        }

        return result;
    } @catch (NSException *exception) {
        Napi::Object errorResult = Napi::Object::New(env);
        errorResult.Set("error", Napi::String::New(env, [[exception description] UTF8String]));
        return errorResult;
    }
}

// Export functions
Napi::Object InitCursorTracker(Napi::Env env, Napi::Object exports) {
    exports.Set("startCursorTracking", Napi::Function::New(env, StartCursorTracking));
    exports.Set("stopCursorTracking", Napi::Function::New(env, StopCursorTracking));
    exports.Set("getCursorPosition", Napi::Function::New(env, GetCursorPosition));
    exports.Set("getCursorTrackingStatus", Napi::Function::New(env, GetCursorTrackingStatus));
    exports.Set("getCursorDebugInfo", Napi::Function::New(env, GetCursorDebugInfo));

    return exports;
} 

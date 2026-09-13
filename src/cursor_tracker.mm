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
                "SLSCopyGlobalCursorName"
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
    if (CFGetTypeID(cgsName) != CFStringGetTypeID()) {
        CFRelease(cgsName);
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
static NSMutableDictionary<NSString*, NSString*> *g_cursorNameMap = nil;
static dispatch_once_t g_cursorFingerprintInitToken;
static void LoadSystemCursorResourceFingerprints(void);
static void LoadCursorMappingOverrides(void);

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

static NSString* CursorImageFingerprintFromCGImage(CGImageRef cgImage, NSPoint hotspot) {
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

// NSImage'in VARSAYILAN temsilinden fingerprint. Hangi temsilin seçildigi ekranin
// backing scale'ine bagli (Retina 2x vs harici 1x), bu yuzden calisma aninda
// uretilen deger ekran konfigurasyonuna gore degisebilir.
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

    return CursorImageFingerprintFromCGImage(cgImage, hotspot);
}

// Bir cursor imajinin TUM temsilleri icin fingerprint uretir.
// KRITIK: MacBook kapagi kapaliyken tek harici monitorde calisirken (clamshell)
// veya ekranlar arasi gecerken NSImage farkli bir temsil donduruyor; tek fingerprint
// kaydedilirse eslesme kayboluyor ve cursor tipi yanlis tespit ediliyordu.
// Tum temsilleri kaydedince calisma aninda hangisi secilirse secilsin eslesme tutar.
static NSArray<NSString *>* CursorImageFingerprintsAllReps(NSImage *image, NSPoint hotspot) {
    if (!image) {
        return @[];
    }

    NSMutableArray<NSString *> *fingerprints = [NSMutableArray array];

    NSString *defaultFingerprint = CursorImageFingerprintFromImage(image, hotspot);
    if (defaultFingerprint) {
        [fingerprints addObject:defaultFingerprint];
    }

    for (NSImageRep *rep in [image representations]) {
        CGImageRef repImage = NULL;
        if ([rep isKindOfClass:[NSBitmapImageRep class]]) {
            repImage = [(NSBitmapImageRep *)rep CGImage];
        } else {
            NSRect repRect = NSMakeRect(0, 0, [rep pixelsWide], [rep pixelsHigh]);
            if (repRect.size.width <= 0 || repRect.size.height <= 0) {
                repRect = NSMakeRect(0, 0, [rep size].width, [rep size].height);
            }
            repImage = [rep CGImageForProposedRect:&repRect context:nil hints:nil];
        }

        NSString *repFingerprint = CursorImageFingerprintFromCGImage(repImage, hotspot);
        if (repFingerprint && ![fingerprints containsObject:repFingerprint]) {
            [fingerprints addObject:repFingerprint];
        }
    }

    NSSize size = image.size;
    if (size.width > 0 && size.height > 0) {
        for (NSUInteger scale = 1; scale <= 2; scale++) {
            NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc]
                initWithBitmapDataPlanes:NULL pixelsWide:lround(size.width * scale)
                pixelsHigh:lround(size.height * scale) bitsPerSample:8 samplesPerPixel:4
                hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
                bytesPerRow:0 bitsPerPixel:0] autorelease];
            if (!bitmap) continue;
            bitmap.size = size;
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
            [image drawInRect:NSMakeRect(0, 0, size.width, size.height) fromRect:NSZeroRect
                operation:NSCompositingOperationCopy fraction:1.0];
            [NSGraphicsContext restoreGraphicsState];
            NSString *fingerprint = CursorImageFingerprintFromCGImage(bitmap.CGImage, hotspot);
            if (fingerprint && ![fingerprints containsObject:fingerprint]) {
                [fingerprints addObject:fingerprint];
            }
        }
    }

    return fingerprints;
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
            NSMethodSignature *signature = [cursor methodSignatureForSelector:selector];
            if (!signature || signature.methodReturnType[0] != '@') {
                continue;
            }
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
    // Tek bir temsil degil, tum temsiller kaydedilir -> ekran olcegi degisse bile
    // (clamshell / harici monitor) eslesme korunur.
    NSArray<NSString *> *fingerprints =
        CursorImageFingerprintsAllReps([cursor image], [cursor hotSpot]);
    for (NSString *fingerprint in fingerprints) {
        // Ilk kayit kazanir: ayni fingerprint birden fazla cursor'a denk gelirse
        // once eklenen (daha spesifik) tip korunur.
        if (![g_cursorFingerprintMap objectForKey:fingerprint]) {
            [g_cursorFingerprintMap setObject:cursorType forKey:fingerprint];
        }
    }
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

// Chromium and WebKit use CoreCursor for types with no public NSCursor factory.
// Ask AppKit to render these references, including the system's shadow; the raw
// HIServices PDF is not pixel-identical to the cursor returned by WindowServer.
// CoreCursor's enum is distinct from CGSCurrentCursorSeed (a change counter).
// https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/mac/CursorMac.mm
@interface MRSystemReferenceCursor : NSCursor {
    NSInteger _referenceType;
}
- (instancetype)initWithCoreType:(NSInteger)type;
@end

@implementation MRSystemReferenceCursor
- (instancetype)initWithCoreType:(NSInteger)type {
    self = [super init];
    if (self) _referenceType = type;
    return self;
}
- (NSInteger)_coreCursorType { return _referenceType; }
@end

static void AddCoreCursorFingerprints(void) {
    // This SPI is optional. Keep public factories and resource matching on
    // macOS versions where AppKit no longer exposes it.
    if (![NSCursor instancesRespondToSelector:NSSelectorFromString(@"_coreCursorType")]) return;
    NSDictionary<NSNumber *, NSString *> *types = @{
        @4: @"progress", @11: @"grabbing", @12: @"grab",
        @27: @"ew-resize", @28: @"ew-resize", @29: @"nesw-resize",
        @30: @"nesw-resize", @31: @"ns-resize", @32: @"ns-resize",
        @33: @"nwse-resize", @34: @"nwse-resize", @35: @"nwse-resize",
        @36: @"ns-resize", @37: @"nesw-resize", @38: @"ew-resize",
        @39: @"all-scroll", @40: @"help", @41: @"crosshair",
        @42: @"zoom-in", @43: @"zoom-out"
    };
    for (NSNumber *type in types) {
        @try {
            NSCursor *cursor = [[[MRSystemReferenceCursor alloc] initWithCoreType:type.integerValue] autorelease];
            AddStandardCursorFingerprint(cursor, types[type]);
        } @catch (NSException *exception) {
            MRLog(@"CoreCursor reference %@ unavailable: %@", type, exception.reason);
        }
    }
}

static void AddFrameResizeCursorFingerprints(void) {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 150000
    if (@available(macOS 15.0, *)) {
        const NSCursorFrameResizePosition positions[] = {
            NSCursorFrameResizePositionTop, NSCursorFrameResizePositionBottom,
            NSCursorFrameResizePositionLeft, NSCursorFrameResizePositionRight,
            NSCursorFrameResizePositionTopLeft, NSCursorFrameResizePositionBottomRight,
            NSCursorFrameResizePositionTopRight, NSCursorFrameResizePositionBottomLeft
        };
        NSArray<NSString *> *types = @[@"ns-resize", @"ns-resize", @"ew-resize", @"ew-resize",
            @"nwse-resize", @"nwse-resize", @"nesw-resize", @"nesw-resize"];
        for (NSUInteger direction = 1; direction <= 3; direction++) {
            AddStandardCursorFingerprint([NSCursor columnResizeCursorInDirections:(NSHorizontalDirections)direction], @"col-resize");
            AddStandardCursorFingerprint([NSCursor rowResizeCursorInDirections:(NSVerticalDirections)direction], @"row-resize");
            for (NSUInteger i = 0; i < sizeof(positions) / sizeof(positions[0]); i++) {
                AddStandardCursorFingerprint([NSCursor frameResizeCursorFromPosition:positions[i]
                    inDirections:(NSCursorFrameResizeDirections)direction], types[i]);
            }
        }
    }
#endif
}

static void InitializeCursorFingerprintMap(void) {
    dispatch_once(&g_cursorFingerprintInitToken, ^{
        g_cursorFingerprintMap = [[NSMutableDictionary alloc] init];
        g_cursorNameMap = [[NSMutableDictionary alloc] init];

        void (^buildMap)(void) = ^{
            // Node worker processes may not have initialized AppKit yet. Without
            // it arrow/I-beam images can be empty and stay absent from this map.
            [NSApplication sharedApplication];
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
            AddCursorIfAvailableByName(@"resizeLeftCursor", @"col-resize");
            AddCursorIfAvailableByName(@"resizeRightCursor", @"col-resize");
            AddCursorIfAvailableByName(@"resizeUpCursor", @"row-resize");
            AddCursorIfAvailableByName(@"resizeDownCursor", @"row-resize");
            AddCursorIfAvailableByName(@"resizeNorthWestSouthEastCursor", @"nwse-resize");
            AddCursorIfAvailableByName(@"resizeNorthEastSouthWestCursor", @"nesw-resize");
            AddCursorIfAvailable(@selector(zoomInCursor), @"zoom-in");
            AddCursorIfAvailable(@selector(zoomOutCursor), @"zoom-out");
            AddCursorIfAvailable(@selector(columnResizeCursor), @"col-resize");
            AddCursorIfAvailable(@selector(rowResizeCursor), @"row-resize");

            AddFrameResizeCursorFingerprints();
            AddCoreCursorFingerprints();
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

    NSString *fingerprint = CursorImageFingerprint(cursor);
    if (!fingerprint) {
        return nil;
    }

    if (outFingerprint) {
        *outFingerprint = fingerprint;
    }

    return [g_cursorFingerprintMap objectForKey:fingerprint];
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
    BOOL cursorChanged = !StringsEqual(cursorType, g_lastCursorType);
    BOOL isMoveEvent = StringsEqual(eventType, @"move") || StringsEqual(eventType, @"drag") || StringsEqual(eventType, @"rightdrag");
    BOOL isClickEvent = StringsEqual(eventType, @"mousedown") ||
                        StringsEqual(eventType, @"mouseup") ||
                        StringsEqual(eventType, @"rightmousedown") ||
                        StringsEqual(eventType, @"rightmouseup");

    if (isMoveEvent) {
        return moved || cursorChanged || eventChanged;
    }

    if (isClickEvent) {
        return eventChanged || moved || cursorChanged;
    }

    // Fallback: only emit when something actually changed
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

// Erisilebilirlik izni durumu (istem GOSTERMEDEN).
// NEDEN: izin yokken bile AX cagrilari yapiliyordu; macOS bunun uzerine
// "Erisilebilirlik" izin dialogunu aciyor ve bu fonksiyon kayit boyunca
// yuksek frekansta cagrildigi icin istem tekrar tekrar cikiyor. Durum
// saniyede bir tazelenir: kullanici izni verdigi anda yol kendiliginden
// devreye girer.
static bool accessibilityTrustedCached(void) {
    static CFAbsoluteTime lastCheck = 0;
    static bool trusted = false;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (lastCheck == 0 || now - lastCheck > 1.0) {
        trusted = AXIsProcessTrusted();
        lastCheck = now;
    }
    return trusted;
}

// Accessibility tabanlı cursor tip tespiti
static NSString* detectCursorTypeUsingAccessibility(CGPoint cursorPos) {
    @autoreleasepool {
        if (!accessibilityTrustedCached()) {
            return nil;
        }

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
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return nil;
    NSString *name = NormalizeCursorName(value);
    // Treat separators uniformly, without letting "text" match "context" or
    // "link" consume dragLink before the alias rule.
    NSString *compact = [[name componentsSeparatedByCharactersInSet:
        [[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@""];
    if ([compact hasSuffix:@"cursor"]) compact = [compact substringToIndex:compact.length - 6];

    if ([compact containsString:@"resize"]) {
        if ([compact containsString:@"column"] || [compact isEqualToString:@"colresize"]) return @"col-resize";
        if ([compact containsString:@"row"]) return @"row-resize";
        NSString *direction = [compact stringByReplacingOccurrencesOfString:@"resize" withString:@""];
        if ([direction hasPrefix:@"frame"]) direction = [direction substringFromIndex:5];
        if (StringEqualsAny(direction, @[@"nesw", @"ne", @"sw", @"northeast", @"southwest",
            @"northeastsouthwest", @"topright", @"bottomleft", @"diagonalup"])) return @"nesw-resize";
        if (StringEqualsAny(direction, @[@"nwse", @"nw", @"se", @"northwest", @"southeast",
            @"northwestsoutheast", @"topleft", @"bottomright", @"diagonaldown"])) return @"nwse-resize";
        if (StringEqualsAny(direction, @[@"ew", @"e", @"w", @"east", @"west", @"eastwest",
            @"left", @"right", @"leftright", @"horizontal"])) return @"ew-resize";
        if (StringEqualsAny(direction, @[@"ns", @"n", @"s", @"north", @"south", @"northsouth",
            @"up", @"down", @"updown", @"top", @"bottom", @"vertical"])) return @"ns-resize";
        return nil; // A name without an axis cannot identify a diagonal.
    }
    if ([compact containsString:@"contextualmenu"] || [compact containsString:@"contextmenu"]) return @"context-menu";
    if ([compact containsString:@"draglink"] || [compact containsString:@"alias"]) return @"alias";
    if ([compact containsString:@"copy"]) return @"copy";
    if ([compact containsString:@"notallowed"] || [compact containsString:@"nodrop"]) return @"not-allowed";
    if ([compact containsString:@"closedhand"] || [compact isEqualToString:@"grabbing"]) return @"grabbing";
    if ([compact containsString:@"openhand"] || [compact isEqualToString:@"grab"]) return @"grab";
    if ([compact containsString:@"pointinghand"] || StringEqualsAny(compact, @[@"pointer", @"hand", @"link"])) return @"pointer";
    if ([compact containsString:@"ibeam"] || [compact containsString:@"insertion"] ||
        StringEqualsAny(compact, @[@"text", @"verticaltext"])) return @"text";
    if ([compact containsString:@"zoomout"]) return @"zoom-out";
    if ([compact containsString:@"zoomin"]) return @"zoom-in";
    if (StringEqualsAny(compact, @[@"move", @"allscroll", @"moveall", @"omnidirectional"])) return @"all-scroll";
    if ([compact containsString:@"crosshair"] || StringEqualsAny(compact, @[@"cross", @"cell"])) return @"crosshair";
    if ([compact containsString:@"wait"] || [compact containsString:@"busy"] || [compact containsString:@"progress"]) return @"progress";
    if ([compact containsString:@"help"]) return @"help";
    if (StringEqualsAny(compact, @[@"arrow", @"default", @"auto", @"none"])) return @"default";
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
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[basePath stringByAppendingPathComponent:@"info.plist"]];
    double hotx = [[info objectForKey:@"hotx"] doubleValue];
    double hoty = [[info objectForKey:@"hoty"] doubleValue];
    NSPoint hotspot = NSMakePoint(hotx, hoty);

    // PNG and PDF versions can differ (notably help). Both are used by apps.
    for (NSString *candidate in imageCandidates) {
        NSString *imagePath = [basePath stringByAppendingPathComponent:candidate];
        if (![fm fileExistsAtPath:imagePath]) continue;
        NSImage *image = [[[NSImage alloc] initWithContentsOfFile:imagePath] autorelease];
        if (!image) continue;
        NSCursor *cursor = [[[NSCursor alloc] initWithImage:image hotSpot:hotspot] autorelease];
        AddStandardCursorFingerprint(cursor, cursorType);
    }
}

static void LoadSystemCursorResourceFingerprints(void) {
    static const CursorResourceEntry kResourceEntries[] = {
        {"progress", "busybutclickable"},
        {"wait", "countinguphand"},
        {"wait", "countingdownhand"},
        {"wait", "countingupandownhand"},
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
        {"col-resize", "resizeleft"},
        {"col-resize", "resizeright"},
        {"row-resize", "resizeup"},
        {"row-resize", "resizedown"},
        {"col-resize", "resizeleftright"},
        {"col-resize", "resizeeastwest"},
        {"row-resize", "resizeupdown"},
        {"ns-resize", "resizenorthsouth"},
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

        // Cursor seeds are change counters, not stable cursor identities.
        // Old calibration files may contain them; only image/name entries apply.
    }];
}

static NSString* cursorTypeFromNSCursor(NSCursor *cursor) {
    if (!cursor) return @"default";
    InitializeCursorFingerprintMap();

    // Image evidence is authoritative. currentSystemCursor returns detached
    // NSCursor objects, so pointer identity and image dimensions cannot identify
    // the shape (opposite diagonals and zoom +/- share the same dimensions).
    NSString *fingerprintType = LookupCursorTypeByFingerprint(cursor, NULL);
    if (fingerprintType) return fingerprintType;

    // Some standard cursors have lazily populated images in headless Node hosts.
    if (cursor == [NSCursor arrowCursor]) return @"default";
    if (cursor == [NSCursor IBeamCursor] || cursor == [NSCursor IBeamCursorForVerticalLayout]) return @"text";

    NSString *name = CursorNameFromNSCursor(cursor);
    NSString *mapped = name ? [g_cursorNameMap objectForKey:NormalizeCursorName(name)] : nil;
    return mapped ?: cursorTypeFromCursorName(name) ?: @"default";
}

static NSString* detectSystemCursorType(void) {
    InitializeCursorFingerprintMap();
    __block NSString *cursorType = nil;
    void (^fetchCursorBlock)(void) = ^{
        NSCursor *cursor = nil;
        if ([NSCursor respondsToSelector:@selector(currentSystemCursor)]) {
            cursor = [NSCursor currentSystemCursor];
        }
        if (cursor && cursor.image.size.width > 0 && cursor.image.size.height > 0) {
            cursorType = cursorTypeFromNSCursor(cursor);
            return;
        }
        NSString *name = CopyCurrentCursorNameFromCGS();
        NSString *mapped = name ? [g_cursorNameMap objectForKey:NormalizeCursorName(name)] : nil;
        cursorType = mapped ?: cursorTypeFromCursorName(name);
        // currentCursor belongs to this process. It must never replace another
        // application's system cursor while the recorder runs in the background.
        if (!cursorType && NSApp.isActive) {
            cursorType = cursorTypeFromNSCursor([NSCursor currentCursor]);
        }
    };
    if ([NSThread isMainThread]) {
        fetchCursorBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), fetchCursorBlock);
    }
    return cursorType ?: @"default";
}

// Desktop'ta SVG karşılığı olmayan cursor tiplerini desteklenen tiplere normalize et
static NSString* normalizeCursorTypeForDesktop(NSString *cursorType) {
    if (!cursorType || [cursorType length] == 0) {
        return @"default";
    }

    // Desteklenen tipler — desktop/public/cursor/default/ dizinindeki SVG'lere karşılık gelir
    static NSSet *supportedTypes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        supportedTypes = [[NSSet alloc] initWithArray:@[
            @"default", @"pointer", @"grabbing", @"text", @"grab",
            @"alias", @"copy", @"not-allowed", @"help", @"progress",
            @"crosshair", @"all-scroll", @"zoom-in", @"zoom-out",
            @"row-resize", @"col-resize", @"ns-resize",
            @"nwse-resize", @"nesw-resize"
        ]];
    });

    if ([supportedTypes containsObject:cursorType]) {
        return cursorType;
    }

    // Normalize edilmemiş tipleri en yakın desteklenen tipe eşle
    if ([cursorType isEqualToString:@"auto"] || [cursorType isEqualToString:@"none"] ||
        [cursorType isEqualToString:@"context-menu"]) {
        return @"default";
    }
    if ([cursorType isEqualToString:@"wait"]) {
        return @"progress";
    }
    if ([cursorType isEqualToString:@"cell"]) {
        return @"crosshair";
    }
    if ([cursorType isEqualToString:@"vertical-text"]) {
        return @"text";
    }
    if ([cursorType isEqualToString:@"move"]) {
        return @"all-scroll";
    }
    if ([cursorType isEqualToString:@"no-drop"]) {
        return @"not-allowed";
    }
    // Yönlü resize → iki yönlü resize
    if ([cursorType isEqualToString:@"ew-resize"] ||
        [cursorType isEqualToString:@"e-resize"] ||
        [cursorType isEqualToString:@"w-resize"]) {
        return @"col-resize";
    }
    if ([cursorType isEqualToString:@"n-resize"] ||
        [cursorType isEqualToString:@"s-resize"]) {
        return @"ns-resize";
    }
    if ([cursorType isEqualToString:@"ne-resize"] ||
        [cursorType isEqualToString:@"sw-resize"]) {
        return @"nesw-resize";
    }
    if ([cursorType isEqualToString:@"nw-resize"] ||
        [cursorType isEqualToString:@"se-resize"]) {
        return @"nwse-resize";
    }

    return @"default";
}

NSString* getCursorType() {
    @autoreleasepool {
        g_cursorTypeCounter++;

        // Position is sampled by the caller; cursor type detection does not use it.
        // Get seed and save to global variable for getCursorPosition()
        int currentSeed = SafeCGSCurrentCursorSeed();
        g_lastCursorSeed = currentSeed; // Save for getCursorPosition()

        // Use cursorTypeFromNSCursor for detection (pointer equality + image-based)
        // DO NOT use accessibility detection as it's unreliable and causes false positives
        NSString *systemCursorType = detectSystemCursorType();
        NSString *rawType = systemCursorType && [systemCursorType length] > 0 ? systemCursorType : @"default";

        // Desktop SVG'lerine uyumlu tipe normalize et
        NSString *finalType = normalizeCursorTypeForDesktop(rawType);

        // Only log when cursor type changes
        static NSString *lastLoggedType = nil;
        if (![finalType isEqualToString:lastLoggedType]) {
            if (currentSeed > 0) {
                NSLog(@"🎯 %@ (seed: %d)", finalType, currentSeed);
            } else {
                NSLog(@"🎯 %@", finalType);
            }
            [lastLoggedType release];
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

        // Mouse button state polling — event tap olmadığında click/drag tespiti
        bool currentLeftMouseDown = CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft);
        bool currentRightMouseDown = CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonRight);

        NSString *eventType = @"move";

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
        } else if (currentLeftMouseDown) {
            eventType = @"drag";
            g_lastEventType = @"drag";
        } else if (currentRightMouseDown) {
            eventType = @"rightdrag";
            g_lastEventType = @"rightdrag";
        } else {
            eventType = @"move";
            g_lastEventType = @"move";
        }

        g_leftMouseDown = currentLeftMouseDown;
        g_rightMouseDown = currentRightMouseDown;

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
    @autoreleasepool {
    Napi::Env env = info.Env();
    // Recording already has display-relative geometry. Public callers retain
    // the full result unless they explicitly opt out of the display query.
    const bool includeDisplayInfo = !(info.Length() > 0 && info[0].IsBoolean() && !info[0].As<Napi::Boolean>().Value());
    
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
            // Sol tuş basıldı (geçiş: up → down)
            eventType = @"mousedown";
            g_lastEventType = @"mousedown";
        } else if (!currentLeftMouseDown && g_leftMouseDown) {
            // Sol tuş bırakıldı (geçiş: down → up)
            eventType = @"mouseup";
            g_lastEventType = @"mouseup";
        } else if (currentRightMouseDown && !g_rightMouseDown) {
            // Sağ tuş basıldı
            eventType = @"rightmousedown";
            g_lastEventType = @"rightmousedown";
        } else if (!currentRightMouseDown && g_rightMouseDown) {
            // Sağ tuş bırakıldı
            eventType = @"rightmouseup";
            g_lastEventType = @"rightmouseup";
        } else if (currentLeftMouseDown) {
            // Sol tuş basılı tutuluyor — sürükleme
            eventType = @"drag";
            g_lastEventType = @"drag";
        } else if (currentRightMouseDown) {
            // Sağ tuş basılı tutuluyor
            eventType = @"rightdrag";
            g_lastEventType = @"rightdrag";
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
        NSDictionary *scalingInfo = includeDisplayInfo ? getDisplayScalingInfo(rawLocation) : nil;
        if (scalingInfo) {
            CGFloat scaleFactor = [[scalingInfo objectForKey:@"scaleFactor"] doubleValue];
            result.Set("scaleFactor", Napi::Number::New(env, scaleFactor));
        }

        return result;
        
    } @catch (NSException *exception) {
        return env.Null();
    }
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

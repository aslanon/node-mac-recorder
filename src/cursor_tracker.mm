#import <napi.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <Accessibility/Accessibility.h>
#import <dispatch/dispatch.h>

#ifndef kAXHitTestParameterizedAttribute
#define kAXHitTestParameterizedAttribute CFSTR("AXHitTest")
#endif

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

static BOOL ElementHasAction(AXUIElementRef element, CFStringRef action) {
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

    if (StringEqualsAny(role, @[@"AXTextField", @"AXTextArea", @"AXSearchField"])) {
        return @"text";
    }

    if (StringEqualsAny(subrole, @[@"AXSecureTextField", @"AXTextField"])) {
        return @"text";
    }

    BOOL isEditable = NO;
    if (CopyAttributeBoolean(element, CFSTR("AXEditable"), &isEditable) && isEditable) {
        return @"text";
    }

    BOOL supportsSelection = NO;
    if (CopyAttributeBoolean(element, CFSTR("AXSupportsTextSelection"), &supportsSelection) && supportsSelection) {
        return @"text";
    }

    CFTypeRef valueAttribute = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXValueAttribute, &valueAttribute) == kAXErrorSuccess && valueAttribute) {
        CFTypeID typeId = CFGetTypeID(valueAttribute);
        if (typeId == CFAttributedStringGetTypeID() || typeId == CFStringGetTypeID()) {
            CFRelease(valueAttribute);
            return @"text";
        }
        CFRelease(valueAttribute);
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
        if ([lower containsString:@"text"] ||
            [lower containsString:@"editor"] ||
            [lower containsString:@"document"]) {
            return @"text";
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

    if ([normalized containsString:@"arrow"]) {
        return @"default";
    }
    if ([normalized containsString:@"ibeam"] ||
        [normalized containsString:@"insertion"] ||
        [normalized containsString:@"text"]) {
        return @"text";
    }
    if ([normalized containsString:@"openhand"]) {
        return @"grab";
    }
    if ([normalized containsString:@"closedhand"]) {
        return @"grabbing";
    }
    if ([normalized containsString:@"pointing"] ||
        ([normalized containsString:@"hand"] && ![normalized containsString:@"closed"])) {
        return @"pointer";
    }
    if ([normalized containsString:@"crosshair"]) {
        return @"crosshair";
    }
    if ([normalized containsString:@"not-allowed"] ||
        [normalized containsString:@"notallowed"] ||
        [normalized containsString:@"forbidden"]) {
        return @"not-allowed";
    }
    if ([normalized containsString:@"dragcopy"] || [normalized containsString:@"copy"]) {
        return @"copy";
    }
    if ([normalized containsString:@"draglink"] || [normalized containsString:@"alias"]) {
        return @"alias";
    }
    if ([normalized containsString:@"context"] && [normalized containsString:@"menu"]) {
        return @"context-menu";
    }
    if ([normalized containsString:@"zoom"]) {
        if ([normalized containsString:@"out"]) {
            return @"zoom-out";
        }
        return @"zoom-in";
    }
    if ([normalized containsString:@"resize"] || [normalized containsString:@"size"]) {
        BOOL diagonalUp = [normalized containsString:@"diagonalup"] || [normalized containsString:@"nesw"];
        BOOL diagonalDown = [normalized containsString:@"diagonaldown"] || [normalized containsString:@"nwse"];
        BOOL horizontal = [normalized containsString:@"leftright"] ||
                          [normalized containsString:@"horizontal"] ||
                          ([normalized containsString:@"left"] && [normalized containsString:@"right"]);
        BOOL vertical = [normalized containsString:@"updown"] ||
                        [normalized containsString:@"vertical"] ||
                        ([normalized containsString:@"up"] && [normalized containsString:@"down"]);

        if (diagonalUp) {
            return @"nesw-resize";
        }
        if (diagonalDown) {
            return @"nwse-resize";
        }
        if (vertical) {
            return @"ns-resize";
        }
        if (horizontal) {
            return @"col-resize";
        }
    }

    return nil;
}

static NSString* cursorTypeFromNSCursor(NSCursor *cursor) {
    if (!cursor) {
        return nil;
    }

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
    if ([NSCursor respondsToSelector:@selector(resizeLeftRightCursor)] &&
        (cursor == [NSCursor resizeLeftRightCursor] ||
         cursor == [NSCursor resizeLeftCursor] ||
         cursor == [NSCursor resizeRightCursor])) {
        return @"col-resize";
    }
    if ([NSCursor respondsToSelector:@selector(resizeUpDownCursor)] &&
        (cursor == [NSCursor resizeUpDownCursor] ||
         cursor == [NSCursor resizeUpCursor] ||
         cursor == [NSCursor resizeDownCursor])) {
        return @"ns-resize";
    }
    if ([NSCursor respondsToSelector:@selector(disappearingItemCursor)] &&
        cursor == [NSCursor disappearingItemCursor]) {
        return @"default";
    }

    NSString *derived = cursorTypeFromCursorName(NSStringFromClass([cursor class]));
    if (derived) {
        return derived;
    }

    derived = cursorTypeFromCursorName([cursor description]);
    if (derived) {
        return derived;
    }

    return nil;
}

static NSString* detectSystemCursorType(void) {
    __block NSString *cursorType = nil;

    void (^fetchCursorBlock)(void) = ^{
        NSCursor *currentCursor = nil;
        if ([NSCursor respondsToSelector:@selector(currentSystemCursor)]) {
            currentCursor = [NSCursor currentSystemCursor];
        }
        if (!currentCursor) {
            currentCursor = [NSCursor currentCursor];
        }

        NSString *derivedType = cursorTypeFromNSCursor(currentCursor);
        if (derivedType) {
            cursorType = derivedType;
        } else if (currentCursor) {
            cursorType = @"default";
        }

        NSLog(@"🎯 SYSTEM CURSOR TYPE: %@", cursorType ? cursorType : @"(nil)");
    };

    if ([NSThread isMainThread]) {
        fetchCursorBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), fetchCursorBlock);
    }

    return cursorType;
}

NSString* getCursorType() {
    @autoreleasepool {
        g_cursorTypeCounter++;

        NSString *systemCursorType = detectSystemCursorType();

        NSString *axCursorType = nil;
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

        if (hasCursorPosition) {
            axCursorType = detectCursorTypeUsingAccessibility(cursorPos);
        }

        NSString *finalType = nil;
        if (axCursorType && ![axCursorType isEqualToString:@"default"]) {
            finalType = axCursorType;
        } else if (systemCursorType && [systemCursorType length] > 0) {
            // Prefer the system cursor when accessibility reports a generic value.
            finalType = systemCursorType;
        } else if (axCursorType && [axCursorType length] > 0) {
            finalType = axCursorType;
        } else {
            finalType = @"default";
        }

        NSLog(@"🎯 FINAL CURSOR TYPE: %@", finalType);
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
        // Debug fields: capture raw AX and system cursor types
        NSString *axTypeDbg = detectCursorTypeUsingAccessibility(location);
        NSString *sysTypeDbg = detectSystemCursorType();
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
        
        // Cursor data oluştur
        NSDictionary *cursorInfo = @{
            @"x": @((int)location.x),
            @"y": @((int)location.y),
            @"timestamp": @(timestamp),
            @"unixTimeMs": @(unixTimeMs),
            @"cursorType": cursorType,
            @"type": eventType,
            @"axCursorType": axTypeDbg ? axTypeDbg : @"",
            @"systemCursorType": sysTypeDbg ? sysTypeDbg : @""
        };
        
        // Direkt dosyaya yaz
        writeToFile(cursorInfo);
        
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
        // Debug fields: capture raw AX and system cursor types
        NSString *axTypeDbg = detectCursorTypeUsingAccessibility(location);
        NSString *sysTypeDbg = detectSystemCursorType();
        
        // Cursor data oluştur
        NSDictionary *cursorInfo = @{
            @"x": @((int)location.x),
            @"y": @((int)location.y),
            @"timestamp": @(timestamp),
            @"unixTimeMs": @(unixTimeMs),
            @"cursorType": cursorType,
            @"type": @"move",
            @"axCursorType": axTypeDbg ? axTypeDbg : @"",
            @"systemCursorType": sysTypeDbg ? sysTypeDbg : @""
        };
        
        // Direkt dosyaya yaz
        writeToFile(cursorInfo);
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
            CFRunLoopAddSource(CFRunLoopGetMain(), g_runLoopSource, kCFRunLoopCommonModes);
            CGEventTapEnable(g_eventTap, true);
        }
        
        // NSTimer kullan (main thread'de çalışır)
        g_timerTarget = [[CursorTimerTarget alloc] init];
        
        g_cursorTimer = [NSTimer timerWithTimeInterval:0.05 // 50ms (20 FPS)
                                                target:g_timerTarget
                                              selector:@selector(timerCallback:)
                                              userInfo:nil
                                               repeats:YES];
        
        // Main run loop'a ekle
        [[NSRunLoop mainRunLoop] addTimer:g_cursorTimer forMode:NSRunLoopCommonModes];
        
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
            
            NSLog(@"🔍 Display %u: bounds(%.0f,%.0f %.0fx%.0f), cursor(%.0f,%.0f)", 
                  displayID, displayBounds.origin.x, displayBounds.origin.y, 
                  displayBounds.size.width, displayBounds.size.height,
                  globalPoint.x, globalPoint.y);
            
            // CRITICAL FIX: Manual bounds check for better coordinate system compatibility
            BOOL isInBounds = (globalPoint.x >= displayBounds.origin.x && 
                              globalPoint.x < displayBounds.origin.x + displayBounds.size.width &&
                              globalPoint.y >= displayBounds.origin.y && 
                              globalPoint.y < displayBounds.origin.y + displayBounds.size.height);
            
            NSLog(@"🔍 Manual bounds check: %s", isInBounds ? "INSIDE" : "OUTSIDE");
            
            // Check if point is within this display
            if (isInBounds) {
                // CRITICAL FIX: Get REAL physical dimensions using multiple detection methods
                // Method 1: CGDisplayCreateImage (may be scaled on some systems)
                CGImageRef testImage = CGDisplayCreateImage(displayID);
                CGSize imageSize = CGSizeMake(CGImageGetWidth(testImage), CGImageGetHeight(testImage));
                CGImageRelease(testImage);
                
                // Method 2: Native display mode detection for true physical resolution
                CGSize actualPhysicalSize = imageSize;
                CFArrayRef displayModes = CGDisplayCopyAllDisplayModes(displayID, NULL);
                if (displayModes) {
                    CFIndex modeCount = CFArrayGetCount(displayModes);
                    CGSize maxResolution = CGSizeMake(0, 0);
                    
                    // Find the highest resolution mode (native resolution)
                    for (CFIndex i = 0; i < modeCount; i++) {
                        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(displayModes, i);
                        CGSize modeSize = CGSizeMake(CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode));
                        
                        if (modeSize.width > maxResolution.width || 
                            (modeSize.width == maxResolution.width && modeSize.height > maxResolution.height)) {
                            maxResolution = modeSize;
                        }
                    }
                    
                    // Use the max resolution if it's significantly higher than image size
                    if (maxResolution.width > imageSize.width * 1.5 || maxResolution.height > imageSize.height * 1.5) {
                        actualPhysicalSize = maxResolution;
                        NSLog(@"🔍 Using display mode detection: %.0fx%.0f (was %.0fx%.0f)", 
                              maxResolution.width, maxResolution.height, imageSize.width, imageSize.height);
                    } else {
                        actualPhysicalSize = imageSize;
                        NSLog(@"🔍 Using image size detection: %.0fx%.0f", imageSize.width, imageSize.height);
                    }
                    
                    CFRelease(displayModes);
                } else {
                    actualPhysicalSize = imageSize;
                }
                
                CGSize logicalSize = displayBounds.size;
                CGSize reportedPhysicalSize = CGSizeMake(CGDisplayPixelsWide(displayID), CGDisplayPixelsHigh(displayID));
                
                NSLog(@"🔍 REAL scaling info:");
                NSLog(@"   Logical: %.0fx%.0f", logicalSize.width, logicalSize.height);
                NSLog(@"   Reported physical: %.0fx%.0f", reportedPhysicalSize.width, reportedPhysicalSize.height);
                NSLog(@"   ACTUAL physical: %.0fx%.0f", actualPhysicalSize.width, actualPhysicalSize.height);
                
                CGFloat scaleX = actualPhysicalSize.width / logicalSize.width;
                CGFloat scaleY = actualPhysicalSize.height / logicalSize.height;
                CGFloat scaleFactor = MAX(scaleX, scaleY);
                
                NSLog(@"🔍 REAL scale factors: X=%.2f, Y=%.2f, Final=%.2f", scaleX, scaleY, scaleFactor);
                
                return @{
                    @"displayID": @(displayID),
                    @"logicalSize": [NSValue valueWithSize:NSMakeSize(logicalSize.width, logicalSize.height)],
                    @"physicalSize": [NSValue valueWithSize:NSMakeSize(actualPhysicalSize.width, actualPhysicalSize.height)],
                    @"scaleFactor": @(scaleFactor),
                    @"displayBounds": [NSValue valueWithRect:NSMakeRect(displayBounds.origin.x, displayBounds.origin.y, displayBounds.size.width, displayBounds.size.height)]
                };
            }
        }
        
        // Fallback to main display with REAL physical dimensions
        CGDirectDisplayID mainDisplay = CGMainDisplayID();
        CGRect displayBounds = CGDisplayBounds(mainDisplay);
        
        // Get REAL physical dimensions using multiple detection methods
        CGImageRef testImage = CGDisplayCreateImage(mainDisplay);
        CGSize imageSize = CGSizeMake(CGImageGetWidth(testImage), CGImageGetHeight(testImage));
        CGImageRelease(testImage);
        
        // Try display mode detection for true native resolution
        CGSize actualPhysicalSize = imageSize;
        CFArrayRef displayModes = CGDisplayCopyAllDisplayModes(mainDisplay, NULL);
        if (displayModes) {
            CFIndex modeCount = CFArrayGetCount(displayModes);
            CGSize maxResolution = CGSizeMake(0, 0);
            
            for (CFIndex i = 0; i < modeCount; i++) {
                CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(displayModes, i);
                CGSize modeSize = CGSizeMake(CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode));
                
                if (modeSize.width > maxResolution.width || 
                    (modeSize.width == maxResolution.width && modeSize.height > maxResolution.height)) {
                    maxResolution = modeSize;
                }
            }
            
            if (maxResolution.width > imageSize.width * 1.5 || maxResolution.height > imageSize.height * 1.5) {
                actualPhysicalSize = maxResolution;
            }
            
            CFRelease(displayModes);
        }
        
        CGSize logicalSize = displayBounds.size;
        CGFloat scaleFactor = MAX(actualPhysicalSize.width / logicalSize.width, actualPhysicalSize.height / logicalSize.height);
        
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
        
        // Get display scaling information
        NSDictionary *scalingInfo = getDisplayScalingInfo(rawLocation);
        CGPoint logicalLocation = rawLocation;
        // CGEventGetLocation already returns logical coordinates; additional scaling happens in JS layer.

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
        
        // Add scaling info for coordinate transformation
        if (scalingInfo) {
            CGFloat scaleFactor = [[scalingInfo objectForKey:@"scaleFactor"] doubleValue];
            NSSize logicalSize = [[scalingInfo objectForKey:@"logicalSize"] sizeValue];
            NSSize physicalSize = [[scalingInfo objectForKey:@"physicalSize"] sizeValue];
            NSRect displayBounds = [[scalingInfo objectForKey:@"displayBounds"] rectValue];
            
            result.Set("scaleFactor", Napi::Number::New(env, scaleFactor));
            result.Set("rawX", Napi::Number::New(env, (int)rawLocation.x));
            result.Set("rawY", Napi::Number::New(env, (int)rawLocation.y));
            
            // Add display dimension info for JS coordinate transformation
            Napi::Object displayInfo = Napi::Object::New(env);
            displayInfo.Set("logicalWidth", Napi::Number::New(env, logicalSize.width));
            displayInfo.Set("logicalHeight", Napi::Number::New(env, logicalSize.height));
            displayInfo.Set("physicalWidth", Napi::Number::New(env, physicalSize.width));
            displayInfo.Set("physicalHeight", Napi::Number::New(env, physicalSize.height));
            displayInfo.Set("displayX", Napi::Number::New(env, displayBounds.origin.x));
            displayInfo.Set("displayY", Napi::Number::New(env, displayBounds.origin.y));
            
            result.Set("displayInfo", displayInfo);
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

// Export functions
Napi::Object InitCursorTracker(Napi::Env env, Napi::Object exports) {
    exports.Set("startCursorTracking", Napi::Function::New(env, StartCursorTracking));
    exports.Set("stopCursorTracking", Napi::Function::New(env, StopCursorTracking));
    exports.Set("getCursorPosition", Napi::Function::New(env, GetCursorPosition));
    exports.Set("getCursorTrackingStatus", Napi::Function::New(env, GetCursorTrackingStatus));
    
    return exports;
} 

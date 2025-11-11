#import <napi.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <Accessibility/Accessibility.h>
#import <dispatch/dispatch.h>
#import "logging.h"

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
        // Diagonal resize cursors
        BOOL diagonalUp = [normalized containsString:@"diagonalup"] ||
                          [normalized containsString:@"diagonal-up"] ||
                          [normalized containsString:@"nesw"];
        BOOL diagonalDown = [normalized containsString:@"diagonaldown"] ||
                            [normalized containsString:@"diagonal-down"] ||
                            [normalized containsString:@"nwse"];

        // Horizontal and vertical resize (Electron CSS names)
        BOOL horizontal = [normalized containsString:@"leftright"] ||
                          [normalized containsString:@"left-right"] ||
                          [normalized containsString:@"horizontal"] ||
                          ([normalized containsString:@"left"] && [normalized containsString:@"right"]) ||
                          [normalized containsString:@"col"] ||
                          [normalized containsString:@"column"] ||
                          [normalized containsString:@"ew"]; // east-west

        BOOL vertical = [normalized containsString:@"updown"] ||
                        [normalized containsString:@"up-down"] ||
                        [normalized containsString:@"vertical"] ||
                        ([normalized containsString:@"up"] && [normalized containsString:@"down"]) ||
                        [normalized containsString:@"row"] ||
                        [normalized containsString:@"ns"]; // north-south

        if (diagonalUp) {
            return @"nesw-resize";
        }
        if (diagonalDown) {
            return @"nwse-resize";
        }
        if (vertical) {
            return @"row-resize"; // Changed from ns-resize to match Electron
        }
        if (horizontal) {
            return @"col-resize";
        }

        // Generic resize fallback
        return @"default";
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

static NSString* cursorTypeFromNSCursor(NSCursor *cursor) {
    if (!cursor) {
        return @"default";
    }

    // PRIORITY: Standard macOS cursor pointer equality (most reliable)
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
        return @"pointer"; // Electron uses 'pointer' for context menu
    }

    // Resize cursors - improved detection with Electron CSS cursor names
    if ([NSCursor respondsToSelector:@selector(resizeLeftRightCursor)]) {
        if (cursor == [NSCursor resizeLeftRightCursor]) {
            return @"col-resize"; // ew-resize
        }
    }
    if ([NSCursor respondsToSelector:@selector(resizeLeftCursor)]) {
        if (cursor == [NSCursor resizeLeftCursor]) {
            return @"col-resize";
        }
    }
    if ([NSCursor respondsToSelector:@selector(resizeRightCursor)]) {
        if (cursor == [NSCursor resizeRightCursor]) {
            return @"col-resize";
        }
    }
    if ([NSCursor respondsToSelector:@selector(resizeUpDownCursor)]) {
        if (cursor == [NSCursor resizeUpDownCursor]) {
            return @"row-resize"; // Changed from ns-resize to match Electron
        }
    }
    if ([NSCursor respondsToSelector:@selector(resizeUpCursor)]) {
        if (cursor == [NSCursor resizeUpCursor]) {
            return @"row-resize"; // Changed from ns-resize
        }
    }
    if ([NSCursor respondsToSelector:@selector(resizeDownCursor)]) {
        if (cursor == [NSCursor resizeDownCursor]) {
            return @"row-resize"; // Changed from ns-resize
        }
    }

    if ([NSCursor respondsToSelector:@selector(disappearingItemCursor)] &&
        cursor == [NSCursor disappearingItemCursor]) {
        return @"default";
    }

    // Try to get class name and description for debugging
    NSString *className = NSStringFromClass([cursor class]);
    NSString *description = [cursor description];

    // Debug: Check for pointer cursor patterns
    if (className && ([className containsString:@"pointing"] || [className containsString:@"Hand"])) {
        NSLog(@"🔍 POINTER CLASS: %@", className);
        return @"pointer";
    }
    if (description && ([description containsString:@"pointing"] || [description containsString:@"hand"])) {
        NSLog(@"🔍 POINTER DESC: %@", description);
        return @"pointer";
    }

    // Try name-based detection
    NSString *derived = cursorTypeFromCursorName(className);
    if (derived) {
        return derived;
    }

    derived = cursorTypeFromCursorName(description);
    if (derived) {
        return derived;
    }

    // Default fallback
    return @"default";
}

static NSString* detectSystemCursorType(void) {
    __block NSString *cursorType = nil;

    void (^fetchCursorBlock)(void) = ^{
        NSCursor *currentCursor = nil;

        // Try different methods to get current cursor
        if ([NSCursor respondsToSelector:@selector(currentSystemCursor)]) {
            currentCursor = [NSCursor currentSystemCursor];
        }

        if (!currentCursor) {
            currentCursor = [NSCursor currentCursor];
        }

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

        // Try multiple detection methods
        NSString *systemCursorType = detectSystemCursorType();
        NSString *axCursorType = nil;

        if (hasCursorPosition) {
            axCursorType = detectCursorTypeUsingAccessibility(cursorPos);
        }

        NSString *finalType = @"default";


        // SYSTEM CURSOR PRIORITY - trust visual state over accessibility
        if (systemCursorType && [systemCursorType length] > 0) {
            // ALWAYS use system cursor when available - it reflects visual state
            finalType = systemCursorType;

            // Special cases: allow AX to override when system reports default but AX has richer info
            if ([systemCursorType isEqualToString:@"default"] && axCursorType && [axCursorType length] > 0) {
                BOOL axIsResize = [axCursorType containsString:@"resize"];
                BOOL axIsText = [axCursorType isEqualToString:@"text"] || [axCursorType containsString:@"text"];
                BOOL axIsPointer = [axCursorType isEqualToString:@"pointer"];
                if (axIsResize || axIsText || axIsPointer) {
                    finalType = axCursorType;
                }
            }
        }
        // Only if system completely fails, use AX
        else if (axCursorType && [axCursorType length] > 0) {
            finalType = axCursorType;
        }
        else {
            finalType = @"default";
        }

        // Only log when cursor type changes
        static NSString *lastLoggedType = nil;
        if (![finalType isEqualToString:lastLoggedType]) {
            NSLog(@"🎯 %@", finalType);
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
            @"type": eventType
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
        
        // Cursor data oluştur
        NSDictionary *cursorInfo = @{
            @"x": @((int)location.x),
            @"y": @((int)location.y),
            @"timestamp": @(timestamp),
            @"unixTimeMs": @(unixTimeMs),
            @"cursorType": cursorType,
            @"type": @"move"
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

// Export functions
Napi::Object InitCursorTracker(Napi::Env env, Napi::Object exports) {
    exports.Set("startCursorTracking", Napi::Function::New(env, StartCursorTracking));
    exports.Set("stopCursorTracking", Napi::Function::New(env, StopCursorTracking));
    exports.Set("getCursorPosition", Napi::Function::New(env, GetCursorPosition));
    exports.Set("getCursorTrackingStatus", Napi::Function::New(env, GetCursorTrackingStatus));
    
    return exports;
} 

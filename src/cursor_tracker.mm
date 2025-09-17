#import <napi.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <Accessibility/Accessibility.h>

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

// Mouse button state tracking
static bool g_leftMouseDown = false;
static bool g_rightMouseDown = false;
static NSString *g_lastEventType = @"move";

// Event tap callback
static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    return event;
}

// Cursor type detection helper - sistem genelindeki cursor type'ı al
NSString* getCursorType() {
    @autoreleasepool {
        g_cursorTypeCounter++;
        
        @try {
            // ACCESSIBILITY API BASED CURSOR DETECTION
            // Determine cursor type based on the UI element under the cursor

            CGPoint cursorPos = CGEventGetLocation(CGEventCreate(NULL));
            AXUIElementRef systemWide = AXUIElementCreateSystemWide();
            AXUIElementRef elementAtPosition = NULL;
            AXError error = AXUIElementCopyElementAtPosition(systemWide, cursorPos.x, cursorPos.y, &elementAtPosition);

            NSString *cursorType = @"default"; // Default fallback

            if (error == kAXErrorSuccess && elementAtPosition) {
                CFStringRef role = NULL;
                error = AXUIElementCopyAttributeValue(elementAtPosition, kAXRoleAttribute, (CFTypeRef*)&role);

                if (error == kAXErrorSuccess && role) {
                    NSString *elementRole = (__bridge_transfer NSString*)role;
                    NSLog(@"🎯 ELEMENT ROLE: %@", elementRole);

                    // TEXT CURSORS
                    if ([elementRole isEqualToString:@"AXTextField"] ||
                        [elementRole isEqualToString:@"AXTextArea"] ||
                        [elementRole isEqualToString:@"AXStaticText"] ||
                        [elementRole isEqualToString:@"AXSearchField"]) {
                        cursorType = @"text";
                    }
                    // POINTER CURSORS (clickable elements)
                    else if ([elementRole isEqualToString:@"AXLink"] ||
                             [elementRole isEqualToString:@"AXButton"] ||
                             [elementRole isEqualToString:@"AXMenuItem"] ||
                             [elementRole isEqualToString:@"AXRadioButton"] ||
                             [elementRole isEqualToString:@"AXCheckBox"] ||
                             [elementRole isEqualToString:@"AXPopUpButton"] ||
                             [elementRole isEqualToString:@"AXTab"]) {
                        cursorType = @"pointer";
                    }
                    // GRAB CURSORS (draggable elements)
                    else if ([elementRole isEqualToString:@"AXImage"] ||
                             [elementRole isEqualToString:@"AXGroup"]) {
                        // Check if element is draggable
                        CFBooleanRef draggable = NULL;
                        error = AXUIElementCopyAttributeValue(elementAtPosition, CFSTR("AXMovable"), (CFTypeRef*)&draggable);
                        if (error == kAXErrorSuccess && draggable && CFBooleanGetValue(draggable)) {
                            cursorType = @"grab";
                        } else {
                            cursorType = @"default";
                        }
                    }
                    // PROGRESS CURSORS (loading/busy elements)
                    else if ([elementRole isEqualToString:@"AXProgressIndicator"] ||
                             [elementRole isEqualToString:@"AXBusyIndicator"]) {
                        cursorType = @"progress";
                    }
                    // HELP CURSORS (help buttons/tooltips)
                    else if ([elementRole isEqualToString:@"AXHelpTag"] ||
                             [elementRole isEqualToString:@"AXTooltip"]) {
                        cursorType = @"help";
                    }
                    // RESIZE CURSORS
                    else if ([elementRole isEqualToString:@"AXSplitter"]) {
                        // Get splitter orientation to determine resize direction
                        CFStringRef orientation = NULL;
                        error = AXUIElementCopyAttributeValue(elementAtPosition, CFSTR("AXOrientation"), (CFTypeRef*)&orientation);
                        if (error == kAXErrorSuccess && orientation) {
                            NSString *orientationStr = (__bridge_transfer NSString*)orientation;
                            if ([orientationStr isEqualToString:@"AXHorizontalOrientation"]) {
                                cursorType = @"row-resize"; // vertical splitter -> row resize
                            } else {
                                cursorType = @"col-resize"; // horizontal splitter -> col resize
                            }
                        } else {
                            cursorType = @"col-resize"; // default
                        }
                    }
                    // SCROLL CURSORS - sadece gerçek scroll kontrollerinde
                    else if ([elementRole isEqualToString:@"AXScrollBar"]) {
                        // Check orientation for scroll direction
                        CFStringRef orientation = NULL;
                        error = AXUIElementCopyAttributeValue(elementAtPosition, CFSTR("AXOrientation"), (CFTypeRef*)&orientation);
                        if (error == kAXErrorSuccess && orientation) {
                            NSString *orientationStr = (__bridge_transfer NSString*)orientation;
                            if ([orientationStr isEqualToString:@"AXVerticalOrientation"]) {
                                cursorType = @"ns-resize"; // vertical scrollbar
                            } else {
                                cursorType = @"col-resize"; // horizontal scrollbar
                            }
                        } else {
                            cursorType = @"default"; // fallback to default
                        }
                    }
                    // AXScrollArea için sadece belirli durumlarda all-scroll, çoğunlukla default
                    else if ([elementRole isEqualToString:@"AXScrollArea"]) {
                        // ScrollArea genellikle default olmalı, sadece özel durumlar için all-scroll
                        cursorType = @"default";
                    }
                    // CROSSHAIR CURSORS (drawing/selection tools)
                    else if ([elementRole isEqualToString:@"AXCanvas"] ||
                             [elementRole isEqualToString:@"AXDrawingArea"]) {
                        cursorType = @"crosshair";
                    }
                    // ZOOM CURSORS (zoom controls)
                    else if ([elementRole isEqualToString:@"AXZoomButton"]) {
                        cursorType = @"zoom-in";
                    }
                    // NOT-ALLOWED CURSORS (disabled elements)
                    else if ([elementRole isEqualToString:@"AXStaticText"] ||
                             [elementRole isEqualToString:@"AXGroup"]) {
                        // Check if element is disabled/readonly
                        CFBooleanRef enabled = NULL;
                        error = AXUIElementCopyAttributeValue(elementAtPosition, kAXEnabledAttribute, (CFTypeRef*)&enabled);
                        if (error == kAXErrorSuccess && enabled && !CFBooleanGetValue(enabled)) {
                            cursorType = @"not-allowed";
                        }
                    }
                    // WINDOW BORDER RESIZE - sadece pencere kenarlarında
                    else if ([elementRole isEqualToString:@"AXWindow"]) {
                        // Check window attributes to see if it's resizable
                        CFBooleanRef resizable = NULL;
                        AXError resizableError = AXUIElementCopyAttributeValue(elementAtPosition, CFSTR("AXResizeButton"), (CFTypeRef*)&resizable);

                        // Sadece resize edilebilir pencereler için cursor değişimi
                        if (resizableError == kAXErrorSuccess || true) { // AXResizeButton bulunamazsa da devam et
                            CFTypeRef position = NULL;
                            CFTypeRef size = NULL;
                            error = AXUIElementCopyAttributeValue(elementAtPosition, kAXPositionAttribute, &position);
                            AXError sizeError = AXUIElementCopyAttributeValue(elementAtPosition, kAXSizeAttribute, &size);

                            if (error == kAXErrorSuccess && sizeError == kAXErrorSuccess && position && size) {
                                CGPoint windowPos;
                                CGSize windowSize;
                                AXValueGetValue((AXValueRef)position, kAXValueTypeCGPoint, &windowPos);
                                AXValueGetValue((AXValueRef)size, kAXValueTypeCGSize, &windowSize);

                                CGFloat x = cursorPos.x - windowPos.x;
                                CGFloat y = cursorPos.y - windowPos.y;
                                CGFloat w = windowSize.width;
                                CGFloat h = windowSize.height;
                                CGFloat edge = 3.0; // Daha küçük edge detection (3px)

                                // Sadece çok kenar köşelerde resize cursor'ı göster
                                BOOL isOnBorder = NO;

                                // Corner resize detection - çok dar alanda
                                if ((x <= edge && y <= edge) || (x >= w-edge && y >= h-edge)) {
                                    cursorType = @"nwse-resize";
                                    isOnBorder = YES;
                                }
                                else if ((x >= w-edge && y <= edge) || (x <= edge && y >= h-edge)) {
                                    cursorType = @"nesw-resize";
                                    isOnBorder = YES;
                                }
                                // Edge resize detection - sadece çok kenarlarda
                                else if ((x <= edge || x >= w-edge) && y > edge && y < h-edge) {
                                    cursorType = @"col-resize";
                                    isOnBorder = YES;
                                }
                                else if ((y <= edge || y >= h-edge) && x > edge && x < w-edge) {
                                    cursorType = @"row-resize";
                                    isOnBorder = YES;
                                }

                                // Eğer border'da değilse default
                                if (!isOnBorder) {
                                    cursorType = @"default";
                                }

                                if (position) CFRelease(position);
                                if (size) CFRelease(size);
                            } else {
                                cursorType = @"default";
                            }
                        } else {
                            cursorType = @"default";
                        }
                    }
                    // HER DURUM İÇİN DEFAULT FALLBACK
                    else {
                        // Bilinmeyen elementler için her zaman default
                        cursorType = @"default";
                    }

                    // Check subroles for additional context
                    CFStringRef subrole = NULL;
                    error = AXUIElementCopyAttributeValue(elementAtPosition, kAXSubroleAttribute, (CFTypeRef*)&subrole);
                    if (error == kAXErrorSuccess && subrole) {
                        NSString *elementSubrole = (__bridge_transfer NSString*)subrole;
                        NSLog(@"🎯 ELEMENT SUBROLE: %@", elementSubrole);

                        // Subrole override'ları - sadece çok spesifik durumlar için
                        if ([elementSubrole isEqualToString:@"AXCloseButton"] ||
                            [elementSubrole isEqualToString:@"AXMinimizeButton"] ||
                            [elementSubrole isEqualToString:@"AXZoomButton"] ||
                            [elementSubrole isEqualToString:@"AXToolbarButton"]) {
                            cursorType = @"pointer";
                        }
                        // Copy/alias subroles - sadece bu durumlar için override
                        else if ([elementSubrole isEqualToString:@"AXFileDrop"] ||
                                 [elementSubrole isEqualToString:@"AXDropTarget"]) {
                            cursorType = @"copy";
                        }
                        // Alias/shortcut subroles
                        else if ([elementSubrole isEqualToString:@"AXAlias"] ||
                                 [elementSubrole isEqualToString:@"AXShortcut"]) {
                            cursorType = @"alias";
                        }
                        // Grabbing state (being dragged) - sadece gerçek drag sırasında
                        else if ([elementSubrole isEqualToString:@"AXDragging"] ||
                                 [elementSubrole isEqualToString:@"AXMoving"]) {
                            cursorType = @"grabbing";
                        }
                        // Zoom controls - sadece spesifik zoom butonları için
                        else if ([elementSubrole isEqualToString:@"AXZoomIn"]) {
                            cursorType = @"zoom-in";
                        }
                        else if ([elementSubrole isEqualToString:@"AXZoomOut"]) {
                            cursorType = @"zoom-out";
                        }
                        // Subrole'dan bir şey bulamazsa role-based cursor'ı koruyoruz
                    }
                }

                CFRelease(elementAtPosition);
            }

            if (systemWide) {
                CFRelease(systemWide);
            }

            // Son güvence - eğer cursorType hala nil veya geçersizse default'a çevir
            if (!cursorType || [cursorType length] == 0) {
                cursorType = @"default";
            }

            NSLog(@"🎯 FINAL CURSOR TYPE: %@", cursorType);
            return cursorType;
            
        } @catch (NSException *exception) {
            NSLog(@"Error in getCursorType: %@", exception);
            return @"default";
        }
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
        
        // Apply DPR scaling correction for Retina displays
        NSDictionary *scalingInfo = getDisplayScalingInfo(rawLocation);
        CGPoint location = rawLocation;
        
        if (scalingInfo) {
            CGFloat scaleFactor = [[scalingInfo objectForKey:@"scaleFactor"] doubleValue];
            NSRect displayBounds = [[scalingInfo objectForKey:@"displayBounds"] rectValue];
            
            // Keep logical coordinates - no scaling needed here
            location = rawLocation;
        }
        NSDate *currentDate = [NSDate date];
        NSTimeInterval timestamp = [currentDate timeIntervalSinceDate:g_trackingStartTime] * 1000; // milliseconds
        NSTimeInterval unixTimeMs = [currentDate timeIntervalSince1970] * 1000; // unix timestamp in milliseconds
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
        
        // Apply DPR scaling correction for Retina displays
        NSDictionary *scalingInfo = getDisplayScalingInfo(rawLocation);
        CGPoint location = rawLocation;
        
        if (scalingInfo) {
            CGFloat scaleFactor = [[scalingInfo objectForKey:@"scaleFactor"] doubleValue];
            NSRect displayBounds = [[scalingInfo objectForKey:@"displayBounds"] rectValue];
            
            // Keep logical coordinates - no scaling needed here
            location = rawLocation;
        }
        
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
        
        if (scalingInfo) {
            CGFloat scaleFactor = [[scalingInfo objectForKey:@"scaleFactor"] doubleValue];
            NSRect displayBounds = [[scalingInfo objectForKey:@"displayBounds"] rectValue];
            
            // CGEventGetLocation returns LOGICAL coordinates (correct for JS layer)
            // Keep logical coordinates - transformation happens in JS layer
            logicalLocation = rawLocation;
        }
        
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
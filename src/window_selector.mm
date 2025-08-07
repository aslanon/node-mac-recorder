#import <napi.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <Accessibility/Accessibility.h>

// Global state for window selection
static bool g_isWindowSelecting = false;
static NSWindow *g_overlayWindow = nil;
static NSView *g_overlayView = nil;
static NSButton *g_selectButton = nil;
static NSTimer *g_trackingTimer = nil;
static NSDictionary *g_selectedWindowInfo = nil;
static NSMutableArray *g_allWindows = nil;
static NSDictionary *g_currentWindowUnderCursor = nil;
static bool g_bringToFrontEnabled = true; // Default enabled

// Forward declarations
void cleanupWindowSelector();
void updateOverlay();
NSDictionary* getWindowUnderCursor(CGPoint point);
NSArray* getAllSelectableWindows();
bool bringWindowToFront(int windowId);

// Custom overlay view class
@interface WindowSelectorOverlayView : NSView
@property (nonatomic, strong) NSDictionary *windowInfo;
@end

@implementation WindowSelectorOverlayView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [[NSColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:0.6] CGColor];
        self.layer.borderColor = [[NSColor colorWithRed:0.0 green:0.4 blue:0.8 alpha:0.9] CGColor];
        self.layer.borderWidth = 5.0;
        self.layer.cornerRadius = 8.0;
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    if (!self.windowInfo) return;
    
    // Background with transparency
    [[NSColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:0.6] setFill];
    NSRectFill(dirtyRect);
    
    // Border
    [[NSColor colorWithRed:0.0 green:0.4 blue:0.8 alpha:0.9] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8 yRadius:8];
    [border setLineWidth:3.0];
    [border stroke];
    
    // Window info text
    NSString *windowTitle = [self.windowInfo objectForKey:@"title"] ?: @"Unknown Window";
    NSString *appName = [self.windowInfo objectForKey:@"appName"] ?: @"Unknown App";
    NSString *infoText = [NSString stringWithFormat:@"%@\n%@", appName, windowTitle];
    
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentCenter];
    
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:21 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: style,
        NSStrokeColorAttributeName: [NSColor blackColor],
        NSStrokeWidthAttributeName: @(-2.0)
    };
    
    NSRect textRect = NSMakeRect(10, self.bounds.size.height - 90, self.bounds.size.width - 20, 80);
    [infoText drawInRect:textRect withAttributes:attributes];
}

@end

// Button action handler and timer target
@interface WindowSelectorDelegate : NSObject
- (void)selectButtonClicked:(id)sender;
- (void)timerUpdate:(NSTimer *)timer;
@end

@implementation WindowSelectorDelegate
- (void)selectButtonClicked:(id)sender {
    if (g_currentWindowUnderCursor) {
        g_selectedWindowInfo = [g_currentWindowUnderCursor retain];
        cleanupWindowSelector();
    }
}

- (void)timerUpdate:(NSTimer *)timer {
    updateOverlay();
}
@end

static WindowSelectorDelegate *g_delegate = nil;

// Bring window to front using Accessibility API
bool bringWindowToFront(int windowId) {
    @autoreleasepool {
        @try {
            // Method 1: Using Accessibility API (most reliable)
            AXUIElementRef systemWide = AXUIElementCreateSystemWide();
            if (!systemWide) return false;
            
            CFArrayRef windowList = NULL;
            AXError error = AXUIElementCopyAttributeValue(systemWide, kAXWindowsAttribute, (CFTypeRef*)&windowList);
            
            if (error == kAXErrorSuccess && windowList) {
                CFIndex windowCount = CFArrayGetCount(windowList);
                
                for (CFIndex i = 0; i < windowCount; i++) {
                    AXUIElementRef windowElement = (AXUIElementRef)CFArrayGetValueAtIndex(windowList, i);
                    
                    // Get window ID by comparing with CGWindowList
                    // Since _AXUIElementGetWindow is not available, we'll use app PID approach
                    pid_t windowPid;
                    error = AXUIElementGetPid(windowElement, &windowPid);
                    
                    if (error == kAXErrorSuccess) {
                        // Get window info for this PID from CGWindowList
                        CFArrayRef cgWindowList = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
                        if (cgWindowList) {
                            NSArray *windowArray = (__bridge NSArray *)cgWindowList;
                            
                            for (NSDictionary *windowInfo in windowArray) {
                                NSNumber *cgWindowId = [windowInfo objectForKey:(NSString *)kCGWindowNumber];
                                NSNumber *processId = [windowInfo objectForKey:(NSString *)kCGWindowOwnerPID];
                                
                                if ([cgWindowId intValue] == windowId && [processId intValue] == windowPid) {
                                    // Found the window, bring it to front
                                    NSLog(@"🔝 BRINGING TO FRONT: Window ID %d (PID: %d)", windowId, windowPid);
                                    
                                    // Method 1: Raise specific window (not the whole app)
                                    error = AXUIElementPerformAction(windowElement, kAXRaiseAction);
                                    if (error == kAXErrorSuccess) {
                                        NSLog(@"   ✅ Specific window raised successfully");
                                    } else {
                                        NSLog(@"   ⚠️ Raise action failed: %d", error);
                                    }
                                    
                                    // Method 2: Focus specific window (not main window)
                                    error = AXUIElementSetAttributeValue(windowElement, kAXFocusedAttribute, kCFBooleanTrue);
                                    if (error == kAXErrorSuccess) {
                                        NSLog(@"   ✅ Specific window focused");
                                    } else {
                                        NSLog(@"   ⚠️ Focus failed: %d", error);
                                    }
                                    
                                    CFRelease(cgWindowList);
                                    CFRelease(windowList);
                                    CFRelease(systemWide);
                                    return true;
                                }
                            }
                            CFRelease(cgWindowList);
                        }
                    }
                }
                CFRelease(windowList);
            }
            
            CFRelease(systemWide);
            
            // Method 2: Light activation fallback (minimal app activation)
            NSLog(@"   🔄 Trying minimal activation for window %d", windowId);
            
            // Get window info to find the process
            CFArrayRef cgWindowList = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
            if (cgWindowList) {
                NSArray *windowArray = (__bridge NSArray *)cgWindowList;
                
                for (NSDictionary *windowInfo in windowArray) {
                    NSNumber *cgWindowId = [windowInfo objectForKey:(NSString *)kCGWindowNumber];
                    if ([cgWindowId intValue] == windowId) {
                        // Get process ID
                        NSNumber *processId = [windowInfo objectForKey:(NSString *)kCGWindowOwnerPID];
                        if (processId) {
                            // Light activation - only bring app to front, don't activate all windows
                            NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:[processId intValue]];
                            if (app) {
                                // Use NSApplicationActivateIgnoringOtherApps only (no NSApplicationActivateAllWindows)
                                [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
                                NSLog(@"   ✅ App minimally activated: PID %d (specific window should be frontmost)", [processId intValue]);
                                CFRelease(cgWindowList);
                                return true;
                            }
                        }
                        break;
                    }
                }
                CFRelease(cgWindowList);
            }
            
            return false;
            
        } @catch (NSException *exception) {
            NSLog(@"❌ Error bringing window to front: %@", exception);
            return false;
        }
    }
}

// Get all selectable windows
NSArray* getAllSelectableWindows() {
    @autoreleasepool {
        NSMutableArray *windows = [NSMutableArray array];
        
        // Get all windows using CGWindowListCopyWindowInfo
        CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
        
        if (windowList) {
            NSArray *windowArray = (__bridge NSArray *)windowList;
            
            for (NSDictionary *windowInfo in windowArray) {
                NSString *windowOwner = [windowInfo objectForKey:(NSString *)kCGWindowOwnerName];
                NSString *windowName = [windowInfo objectForKey:(NSString *)kCGWindowName];
                NSNumber *windowId = [windowInfo objectForKey:(NSString *)kCGWindowNumber];
                NSNumber *windowLayer = [windowInfo objectForKey:(NSString *)kCGWindowLayer];
                NSDictionary *bounds = [windowInfo objectForKey:(NSString *)kCGWindowBounds];
                
                // Skip system windows, dock, menu bar, etc.
                if ([windowLayer intValue] != 0) continue; // Only normal windows
                if (!windowOwner || [windowOwner length] == 0) continue;
                if ([windowOwner isEqualToString:@"WindowServer"]) continue;
                if ([windowOwner isEqualToString:@"Dock"]) continue;
                
                // Extract bounds
                int x = [[bounds objectForKey:@"X"] intValue];
                int y = [[bounds objectForKey:@"Y"] intValue];
                int width = [[bounds objectForKey:@"Width"] intValue];
                int height = [[bounds objectForKey:@"Height"] intValue];
                
                // Skip too small windows
                if (width < 50 || height < 50) continue;
                
                NSDictionary *window = @{
                    @"id": windowId ?: @(0),
                    @"title": windowName ?: @"Untitled",
                    @"appName": windowOwner,
                    @"x": @(x),
                    @"y": @(y),
                    @"width": @(width),
                    @"height": @(height)
                };
                
                [windows addObject:window];
            }
            
            CFRelease(windowList);
        }
        
        return [windows copy];
    }
}

// Get window under cursor point
NSDictionary* getWindowUnderCursor(CGPoint point) {
    @autoreleasepool {
        if (!g_allWindows) return nil;
        
        // Find window that contains the cursor point
        for (NSDictionary *window in g_allWindows) {
            int x = [[window objectForKey:@"x"] intValue];
            int y = [[window objectForKey:@"y"] intValue];
            int width = [[window objectForKey:@"width"] intValue];
            int height = [[window objectForKey:@"height"] intValue];
            
            if (point.x >= x && point.x <= x + width &&
                point.y >= y && point.y <= y + height) {
                return window;
            }
        }
        
        return nil;
    }
}

// Update overlay to highlight window under cursor
void updateOverlay() {
    @autoreleasepool {
        if (!g_isWindowSelecting || !g_overlayWindow) return;
        
        // Get current cursor position
        NSPoint mouseLocation = [NSEvent mouseLocation];
        // Convert from NSEvent coordinates (bottom-left) to CGWindow coordinates (top-left)
        NSScreen *mainScreen = [NSScreen mainScreen];
        CGFloat screenHeight = [mainScreen frame].size.height;
        CGPoint globalPoint = CGPointMake(mouseLocation.x, screenHeight - mouseLocation.y);
        
        // Find window under cursor
        NSDictionary *windowUnderCursor = getWindowUnderCursor(globalPoint);
        
        if (windowUnderCursor && ![windowUnderCursor isEqualToDictionary:g_currentWindowUnderCursor]) {
            // Update current window
            [g_currentWindowUnderCursor release];
            g_currentWindowUnderCursor = [windowUnderCursor retain];
            
            // Update overlay position and size
            int x = [[windowUnderCursor objectForKey:@"x"] intValue];
            int y = [[windowUnderCursor objectForKey:@"y"] intValue];
            int width = [[windowUnderCursor objectForKey:@"width"] intValue];
            int height = [[windowUnderCursor objectForKey:@"height"] intValue];
            
            // Convert coordinates from CGWindow (top-left) to NSWindow (bottom-left)
            NSScreen *mainScreen = [NSScreen mainScreen];
            CGFloat screenHeight = [mainScreen frame].size.height;
            CGFloat adjustedY = screenHeight - y - height;
            
            NSRect overlayFrame = NSMakeRect(x, adjustedY, width, height);
            
            NSString *windowTitle = [windowUnderCursor objectForKey:@"title"] ?: @"Untitled";
            NSString *appName = [windowUnderCursor objectForKey:@"appName"] ?: @"Unknown";
            
            NSLog(@"🎯 WINDOW DETECTED: %@ - \"%@\"", appName, windowTitle);
            NSLog(@"   📍 Position: (%d, %d)  📏 Size: %d × %d", x, y, width, height);
            NSLog(@"   🖥️  NSRect: (%.0f, %.0f, %.0f, %.0f)  🔝 Level: %ld", 
                  overlayFrame.origin.x, overlayFrame.origin.y, 
                  overlayFrame.size.width, overlayFrame.size.height,
                  [g_overlayWindow level]);
            
            // Bring window to front if enabled
            if (g_bringToFrontEnabled) {
                int windowId = [[windowUnderCursor objectForKey:@"id"] intValue];
                if (windowId > 0) {
                    bool success = bringWindowToFront(windowId);
                    if (!success) {
                        NSLog(@"   ⚠️ Failed to bring window to front");
                    }
                }
            }
            [g_overlayWindow setFrame:overlayFrame display:YES];
            
            // Update overlay view window info
            [(WindowSelectorOverlayView *)g_overlayView setWindowInfo:windowUnderCursor];
            [g_overlayView setNeedsDisplay:YES];
            
            // Position select button in center
            if (g_selectButton) {
                NSSize buttonSize = [g_selectButton frame].size;
                NSPoint buttonCenter = NSMakePoint(
                    (width - buttonSize.width) / 2,
                    (height - buttonSize.height) / 2
                );
                [g_selectButton setFrameOrigin:buttonCenter];
            }
            
            [g_overlayWindow orderFront:nil];
            [g_overlayWindow makeKeyAndOrderFront:nil];
            
            NSLog(@"   ✅ Overlay Status: Level=%ld, Alpha=%.1f, Visible=%s, Frame Set=YES", 
                  [g_overlayWindow level], [g_overlayWindow alphaValue], 
                  [g_overlayWindow isVisible] ? "YES" : "NO");
        } else if (!windowUnderCursor && g_currentWindowUnderCursor) {
            // No window under cursor, hide overlay
            NSString *leftWindowTitle = [g_currentWindowUnderCursor objectForKey:@"title"] ?: @"Untitled";
            NSString *leftAppName = [g_currentWindowUnderCursor objectForKey:@"appName"] ?: @"Unknown";
            
            NSLog(@"🚪 WINDOW LEFT: %@ - \"%@\"", leftAppName, leftWindowTitle);
            
            [g_overlayWindow orderOut:nil];
            [g_currentWindowUnderCursor release];
            g_currentWindowUnderCursor = nil;
        }
    }
}

// Cleanup function
void cleanupWindowSelector() {
    g_isWindowSelecting = false;
    
    // Stop tracking timer
    if (g_trackingTimer) {
        [g_trackingTimer invalidate];
        g_trackingTimer = nil;
    }
    
    // Close overlay window
    if (g_overlayWindow) {
        [g_overlayWindow close];
        g_overlayWindow = nil;
        g_overlayView = nil;
        g_selectButton = nil;
    }
    
    // Clean up delegate
    if (g_delegate) {
        [g_delegate release];
        g_delegate = nil;
    }
    
    // Clean up data
    if (g_allWindows) {
        [g_allWindows release];
        g_allWindows = nil;
    }
    
    if (g_currentWindowUnderCursor) {
        [g_currentWindowUnderCursor release];
        g_currentWindowUnderCursor = nil;
    }
}

// NAPI Function: Start Window Selection
Napi::Value StartWindowSelection(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (g_isWindowSelecting) {
        Napi::TypeError::New(env, "Window selection already in progress").ThrowAsJavaScriptException();
        return env.Null();
    }
    
    @try {
        // Get all windows
        g_allWindows = [getAllSelectableWindows() retain];
        
        if (!g_allWindows || [g_allWindows count] == 0) {
            Napi::Error::New(env, "No selectable windows found").ThrowAsJavaScriptException();
            return env.Null();
        }
        
        // Create overlay window (initially hidden)
        NSRect initialFrame = NSMakeRect(0, 0, 100, 100);
        g_overlayWindow = [[NSWindow alloc] initWithContentRect:initialFrame
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
        
        [g_overlayWindow setLevel:CGWindowLevelForKey(kCGMaximumWindowLevelKey)]; // Absolute highest level
        [g_overlayWindow setOpaque:NO];
        [g_overlayWindow setBackgroundColor:[NSColor clearColor]];
        [g_overlayWindow setIgnoresMouseEvents:NO];
        [g_overlayWindow setAcceptsMouseMovedEvents:YES];
        [g_overlayWindow setHasShadow:NO];
        [g_overlayWindow setAlphaValue:1.0];
        [g_overlayWindow setCollectionBehavior:NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorCanJoinAllSpaces];
        
        // Create overlay view
        g_overlayView = [[WindowSelectorOverlayView alloc] initWithFrame:initialFrame];
        [g_overlayWindow setContentView:g_overlayView];
        
        // Create select button with blue theme
        g_selectButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 140, 50)];
        [g_selectButton setTitle:@"Select Window"];
        [g_selectButton setButtonType:NSButtonTypeMomentaryPushIn];
        [g_selectButton setBezelStyle:NSBezelStyleRounded];
        [g_selectButton setFont:[NSFont systemFontOfSize:16 weight:NSFontWeightSemibold]];
        
        // Blue themed button styling
        [g_selectButton setWantsLayer:YES];
        [g_selectButton.layer setBackgroundColor:[[NSColor colorWithRed:0.0 green:0.4 blue:0.8 alpha:0.9] CGColor]];
        [g_selectButton.layer setCornerRadius:8.0];
        [g_selectButton.layer setBorderColor:[[NSColor colorWithRed:0.0 green:0.3 blue:0.7 alpha:1.0] CGColor]];
        [g_selectButton.layer setBorderWidth:2.0];
        [g_selectButton setContentTintColor:[NSColor whiteColor]];
        
        // Add shadow for better visibility
        [g_selectButton.layer setShadowColor:[[NSColor blackColor] CGColor]];
        [g_selectButton.layer setShadowOffset:NSMakeSize(0, -2)];
        [g_selectButton.layer setShadowRadius:4.0];
        [g_selectButton.layer setShadowOpacity:0.3];
        
        // Create delegate for button action and timer
        g_delegate = [[WindowSelectorDelegate alloc] init];
        [g_selectButton setTarget:g_delegate];
        [g_selectButton setAction:@selector(selectButtonClicked:)];
        
        [g_overlayView addSubview:g_selectButton];
        
        // Timer approach doesn't work well with Node.js
        // Instead, we'll use JavaScript polling via getWindowSelectionStatus
        // The JS side will call this function repeatedly to trigger overlay updates
        g_trackingTimer = nil; // No timer for now
        
        g_isWindowSelecting = true;
        g_selectedWindowInfo = nil;
        
        return Napi::Boolean::New(env, true);
        
    } @catch (NSException *exception) {
        cleanupWindowSelector();
        Napi::Error::New(env, [[exception reason] UTF8String]).ThrowAsJavaScriptException();
        return env.Null();
    }
}

// NAPI Function: Stop Window Selection
Napi::Value StopWindowSelection(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (!g_isWindowSelecting) {
        return Napi::Boolean::New(env, false);
    }
    
    cleanupWindowSelector();
    return Napi::Boolean::New(env, true);
}

// NAPI Function: Get Selected Window Info
Napi::Value GetSelectedWindowInfo(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (!g_selectedWindowInfo) {
        return env.Null();
    }
    
    @try {
        Napi::Object result = Napi::Object::New(env);
        result.Set("id", Napi::Number::New(env, [[g_selectedWindowInfo objectForKey:@"id"] intValue]));
        result.Set("title", Napi::String::New(env, [[g_selectedWindowInfo objectForKey:@"title"] UTF8String]));
        result.Set("appName", Napi::String::New(env, [[g_selectedWindowInfo objectForKey:@"appName"] UTF8String]));
        result.Set("x", Napi::Number::New(env, [[g_selectedWindowInfo objectForKey:@"x"] intValue]));
        result.Set("y", Napi::Number::New(env, [[g_selectedWindowInfo objectForKey:@"y"] intValue]));
        result.Set("width", Napi::Number::New(env, [[g_selectedWindowInfo objectForKey:@"width"] intValue]));
        result.Set("height", Napi::Number::New(env, [[g_selectedWindowInfo objectForKey:@"height"] intValue]));
        
        // Determine which screen this window is on
        int x = [[g_selectedWindowInfo objectForKey:@"x"] intValue];
        int y = [[g_selectedWindowInfo objectForKey:@"y"] intValue];
        int width = [[g_selectedWindowInfo objectForKey:@"width"] intValue];
        int height = [[g_selectedWindowInfo objectForKey:@"height"] intValue];
        
        NSLog(@"🎯 WINDOW SELECTED: %@ - \"%@\"", 
              [g_selectedWindowInfo objectForKey:@"appName"],
              [g_selectedWindowInfo objectForKey:@"title"]);
        NSLog(@"   📊 Details: ID=%@, Pos=(%d,%d), Size=%dx%d", 
              [g_selectedWindowInfo objectForKey:@"id"], x, y, width, height);
        
        // Get all screens
        NSArray *screens = [NSScreen screens];
        NSScreen *windowScreen = nil;
        NSScreen *mainScreen = [NSScreen mainScreen];
        
        for (NSScreen *screen in screens) {
            NSRect screenFrame = [screen frame];
            
            // Convert window coordinates to screen-relative
            if (x >= screenFrame.origin.x && 
                x < screenFrame.origin.x + screenFrame.size.width &&
                y >= screenFrame.origin.y && 
                y < screenFrame.origin.y + screenFrame.size.height) {
                windowScreen = screen;
                break;
            }
        }
        
        if (!windowScreen) {
            windowScreen = mainScreen;
        }
        
        // Add screen information
        NSRect screenFrame = [windowScreen frame];
        result.Set("screenId", Napi::Number::New(env, [[windowScreen deviceDescription] objectForKey:@"NSScreenNumber"] ? 
            [[[windowScreen deviceDescription] objectForKey:@"NSScreenNumber"] intValue] : 0));
        result.Set("screenX", Napi::Number::New(env, (int)screenFrame.origin.x));
        result.Set("screenY", Napi::Number::New(env, (int)screenFrame.origin.y));
        result.Set("screenWidth", Napi::Number::New(env, (int)screenFrame.size.width));
        result.Set("screenHeight", Napi::Number::New(env, (int)screenFrame.size.height));
        
        // Clear selected window info after reading
        [g_selectedWindowInfo release];
        g_selectedWindowInfo = nil;
        
        return result;
        
    } @catch (NSException *exception) {
        return env.Null();
    }
}

// NAPI Function: Bring Window To Front
Napi::Value BringWindowToFront(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (info.Length() < 1) {
        Napi::TypeError::New(env, "Window ID required").ThrowAsJavaScriptException();
        return env.Null();
    }
    
    int windowId = info[0].As<Napi::Number>().Int32Value();
    
    @try {
        bool success = bringWindowToFront(windowId);
        return Napi::Boolean::New(env, success);
        
    } @catch (NSException *exception) {
        return Napi::Boolean::New(env, false);
    }
}

// NAPI Function: Enable/Disable Auto Bring To Front
Napi::Value SetBringToFrontEnabled(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (info.Length() < 1) {
        Napi::TypeError::New(env, "Boolean value required").ThrowAsJavaScriptException();
        return env.Null();
    }
    
    bool enabled = info[0].As<Napi::Boolean>();
    g_bringToFrontEnabled = enabled;
    
    NSLog(@"🔄 Auto bring-to-front: %s", enabled ? "ENABLED" : "DISABLED");
    
    return Napi::Boolean::New(env, true);
}

// NAPI Function: Get Window Selection Status
Napi::Value GetWindowSelectionStatus(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    // Update overlay each time status is requested (JavaScript polling approach)
    if (g_isWindowSelecting) {
        updateOverlay();
    }
    
    Napi::Object result = Napi::Object::New(env);
    result.Set("isSelecting", Napi::Boolean::New(env, g_isWindowSelecting));
    result.Set("hasSelectedWindow", Napi::Boolean::New(env, g_selectedWindowInfo != nil));
    result.Set("windowCount", Napi::Number::New(env, g_allWindows ? [g_allWindows count] : 0));
    result.Set("hasOverlay", Napi::Boolean::New(env, g_overlayWindow != nil));
    
    if (g_currentWindowUnderCursor) {
        Napi::Object currentWindow = Napi::Object::New(env);
        currentWindow.Set("id", Napi::Number::New(env, [[g_currentWindowUnderCursor objectForKey:@"id"] intValue]));
        currentWindow.Set("title", Napi::String::New(env, [[g_currentWindowUnderCursor objectForKey:@"title"] UTF8String]));
        currentWindow.Set("appName", Napi::String::New(env, [[g_currentWindowUnderCursor objectForKey:@"appName"] UTF8String]));
        currentWindow.Set("x", Napi::Number::New(env, [[g_currentWindowUnderCursor objectForKey:@"x"] intValue]));
        currentWindow.Set("y", Napi::Number::New(env, [[g_currentWindowUnderCursor objectForKey:@"y"] intValue]));
        currentWindow.Set("width", Napi::Number::New(env, [[g_currentWindowUnderCursor objectForKey:@"width"] intValue]));
        currentWindow.Set("height", Napi::Number::New(env, [[g_currentWindowUnderCursor objectForKey:@"height"] intValue]));
        result.Set("currentWindow", currentWindow);
    }
    
    return result;
}

// Export functions
Napi::Object InitWindowSelector(Napi::Env env, Napi::Object exports) {
    exports.Set("startWindowSelection", Napi::Function::New(env, StartWindowSelection));
    exports.Set("stopWindowSelection", Napi::Function::New(env, StopWindowSelection));
    exports.Set("getSelectedWindowInfo", Napi::Function::New(env, GetSelectedWindowInfo));
    exports.Set("getWindowSelectionStatus", Napi::Function::New(env, GetWindowSelectionStatus));
    exports.Set("bringWindowToFront", Napi::Function::New(env, BringWindowToFront));
    exports.Set("setBringToFrontEnabled", Napi::Function::New(env, SetBringToFrontEnabled));
    
    return exports;
}
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

// Recording preview overlay state
static NSWindow *g_recordingPreviewWindow = nil;
static NSView *g_recordingPreviewView = nil;
static NSDictionary *g_recordingWindowInfo = nil;

// Screen selection overlay state
static bool g_isScreenSelecting = false;
static NSMutableArray *g_screenOverlayWindows = nil;
static NSDictionary *g_selectedScreenInfo = nil;
static NSArray *g_allScreens = nil;
static id g_screenKeyEventMonitor = nil;

// Forward declarations
void cleanupWindowSelector();
void updateOverlay();
NSDictionary* getWindowUnderCursor(CGPoint point);
NSArray* getAllSelectableWindows();
bool bringWindowToFront(int windowId);
void cleanupRecordingPreview();
bool showRecordingPreview(NSDictionary *windowInfo);
bool hideRecordingPreview();
void cleanupScreenSelector();
bool startScreenSelection();
bool stopScreenSelection();
NSDictionary* getSelectedScreenInfo();
bool showScreenRecordingPreview(NSDictionary *screenInfo);
bool hideScreenRecordingPreview();

// Custom overlay view class
@interface WindowSelectorOverlayView : NSView
@property (nonatomic, strong) NSDictionary *windowInfo;
@end

@implementation WindowSelectorOverlayView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [[NSColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:0.45] CGColor];
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
    [[NSColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:0.45] setFill];
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

// Recording preview overlay view - full screen with cutout
@interface RecordingPreviewView : NSView
@property (nonatomic, strong) NSDictionary *recordingWindowInfo;
@end

@implementation RecordingPreviewView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [[NSColor clearColor] CGColor];
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    if (!self.recordingWindowInfo) {
        // No window info, fill with semi-transparent black
        [[NSColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.5] setFill];
        NSRectFill(dirtyRect);
        return;
    }
    
    // Get window coordinates
    int windowX = [[self.recordingWindowInfo objectForKey:@"x"] intValue];
    int windowY = [[self.recordingWindowInfo objectForKey:@"y"] intValue];
    int windowWidth = [[self.recordingWindowInfo objectForKey:@"width"] intValue];
    int windowHeight = [[self.recordingWindowInfo objectForKey:@"height"] intValue];
    
    // Convert from CGWindow coordinates (top-left) to NSView coordinates (bottom-left)
    NSScreen *mainScreen = [NSScreen mainScreen];
    CGFloat screenHeight = [mainScreen frame].size.height;
    CGFloat convertedY = screenHeight - windowY - windowHeight;
    
    NSRect windowRect = NSMakeRect(windowX, convertedY, windowWidth, windowHeight);
    
    // Create a path that covers the entire view but excludes the window area
    NSBezierPath *maskPath = [NSBezierPath bezierPathWithRect:self.bounds];
    NSBezierPath *windowPath = [NSBezierPath bezierPathWithRect:windowRect];
    [maskPath appendBezierPath:windowPath];
    [maskPath setWindingRule:NSWindingRuleEvenOdd]; // Creates hole effect
    
    // Fill with semi-transparent black, excluding window area
    [[NSColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.5] setFill];
    [maskPath fill];
}

@end

// Screen selection overlay view
@interface ScreenSelectorOverlayView : NSView
@property (nonatomic, strong) NSDictionary *screenInfo;
@end

@implementation ScreenSelectorOverlayView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [[NSColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:0.45] CGColor];
        self.layer.borderColor = [[NSColor colorWithRed:0.0 green:0.4 blue:0.8 alpha:0.9] CGColor];
        self.layer.borderWidth = 5.0;
        self.layer.cornerRadius = 8.0;
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    if (!self.screenInfo) return;
    
    // Background with transparency
    [[NSColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:0.45] setFill];
    NSRectFill(dirtyRect);
    
    // Border
    [[NSColor colorWithRed:0.0 green:0.4 blue:0.8 alpha:0.9] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8 yRadius:8];
    [border setLineWidth:3.0];
    [border stroke];
    
    // Screen info text
    NSString *screenName = [self.screenInfo objectForKey:@"name"] ?: @"Unknown Screen";
    NSString *resolution = [self.screenInfo objectForKey:@"resolution"] ?: @"Unknown Resolution";
    NSString *infoText = [NSString stringWithFormat:@"%@\n%@", screenName, resolution];
    
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
- (void)screenSelectButtonClicked:(id)sender;
- (void)timerUpdate:(NSTimer *)timer;
@end

@implementation WindowSelectorDelegate
- (void)selectButtonClicked:(id)sender {
    if (g_currentWindowUnderCursor) {
        g_selectedWindowInfo = [g_currentWindowUnderCursor retain];
        cleanupWindowSelector();
    }
}

- (void)screenSelectButtonClicked:(id)sender {
    NSButton *button = (NSButton *)sender;
    NSInteger screenIndex = [button tag];
    
    // Get screen info from global array using button tag
    if (g_allScreens && screenIndex >= 0 && screenIndex < [g_allScreens count]) {
        NSDictionary *screenInfo = [g_allScreens objectAtIndex:screenIndex];
        g_selectedScreenInfo = [screenInfo retain];
        
        NSLog(@"🖥️ SCREEN BUTTON CLICKED: %@ (%@)", 
              [screenInfo objectForKey:@"name"],
              [screenInfo objectForKey:@"resolution"]);
        
        cleanupScreenSelector();
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
            
            // Clamp overlay to screen bounds to avoid partial off-screen issues
            NSRect screenFrame = [mainScreen frame];
            CGFloat clampedX = MAX(screenFrame.origin.x, MIN(x, screenFrame.origin.x + screenFrame.size.width - width));
            CGFloat clampedY = MAX(screenFrame.origin.y, MIN(adjustedY, screenFrame.origin.y + screenFrame.size.height - height));
            CGFloat clampedWidth = MIN(width, screenFrame.size.width - (clampedX - screenFrame.origin.x));
            CGFloat clampedHeight = MIN(height, screenFrame.size.height - (clampedY - screenFrame.origin.y));
            
            NSRect overlayFrame = NSMakeRect(clampedX, clampedY, clampedWidth, clampedHeight);
            
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

// Recording preview functions
void cleanupRecordingPreview() {
    if (g_recordingPreviewWindow) {
        [g_recordingPreviewWindow close];
        g_recordingPreviewWindow = nil;
        g_recordingPreviewView = nil;
    }
    
    if (g_recordingWindowInfo) {
        [g_recordingWindowInfo release];
        g_recordingWindowInfo = nil;
    }
}

bool showRecordingPreview(NSDictionary *windowInfo) {
    @try {
        // Clean up any existing preview
        cleanupRecordingPreview();
        
        if (!windowInfo) return false;
        
        // Store window info
        g_recordingWindowInfo = [windowInfo retain];
        
        // Get main screen bounds for full screen overlay
        NSScreen *mainScreen = [NSScreen mainScreen];
        NSRect screenFrame = [mainScreen frame];
        
        // Create full-screen overlay window
        g_recordingPreviewWindow = [[NSWindow alloc] initWithContentRect:screenFrame
                                                              styleMask:NSWindowStyleMaskBorderless
                                                                backing:NSBackingStoreBuffered
                                                                  defer:NO];
        
        [g_recordingPreviewWindow setLevel:CGWindowLevelForKey(kCGOverlayWindowLevelKey)]; // High level but below selection
        [g_recordingPreviewWindow setOpaque:NO];
        [g_recordingPreviewWindow setBackgroundColor:[NSColor clearColor]];
        [g_recordingPreviewWindow setIgnoresMouseEvents:YES]; // Don't interfere with user interaction
        [g_recordingPreviewWindow setAcceptsMouseMovedEvents:NO];
        [g_recordingPreviewWindow setHasShadow:NO];
        [g_recordingPreviewWindow setAlphaValue:1.0];
        [g_recordingPreviewWindow setCollectionBehavior:NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorCanJoinAllSpaces];
        
        // Create preview view
        g_recordingPreviewView = [[RecordingPreviewView alloc] initWithFrame:screenFrame];
        [(RecordingPreviewView *)g_recordingPreviewView setRecordingWindowInfo:windowInfo];
        [g_recordingPreviewWindow setContentView:g_recordingPreviewView];
        
        // Show the preview
        [g_recordingPreviewWindow orderFront:nil];
        [g_recordingPreviewWindow makeKeyAndOrderFront:nil];
        
        NSLog(@"🎬 RECORDING PREVIEW: Showing overlay for %@ - \"%@\"", 
              [windowInfo objectForKey:@"appName"],
              [windowInfo objectForKey:@"title"]);
        
        return true;
        
    } @catch (NSException *exception) {
        NSLog(@"❌ Error showing recording preview: %@", exception);
        cleanupRecordingPreview();
        return false;
    }
}

bool hideRecordingPreview() {
    @try {
        if (g_recordingPreviewWindow) {
            NSLog(@"🎬 RECORDING PREVIEW: Hiding overlay");
            cleanupRecordingPreview();
            return true;
        }
        return false;
        
    } @catch (NSException *exception) {
        NSLog(@"❌ Error hiding recording preview: %@", exception);
        return false;
    }
}

// Screen selection functions
void cleanupScreenSelector() {
    g_isScreenSelecting = false;
    
    // Remove key event monitor
    if (g_screenKeyEventMonitor) {
        [NSEvent removeMonitor:g_screenKeyEventMonitor];
        g_screenKeyEventMonitor = nil;
    }
    
    // Close all screen overlay windows
    if (g_screenOverlayWindows) {
        for (NSWindow *overlayWindow in g_screenOverlayWindows) {
            [overlayWindow close];
        }
        [g_screenOverlayWindows release];
        g_screenOverlayWindows = nil;
    }
    
    // Clean up screen data
    if (g_allScreens) {
        [g_allScreens release];
        g_allScreens = nil;
    }
}

bool startScreenSelection() {
    @try {
        if (g_isScreenSelecting) return false;
        
        // Get all available screens
        NSArray *screens = [NSScreen screens];
        if (!screens || [screens count] == 0) return false;
        
        // Create screen info array
        NSMutableArray *screenInfoArray = [[NSMutableArray alloc] init];
        g_screenOverlayWindows = [[NSMutableArray alloc] init];
        
        for (NSInteger i = 0; i < [screens count]; i++) {
            NSScreen *screen = [screens objectAtIndex:i];
            NSRect screenFrame = [screen frame];
            
            // Create screen info dictionary
            NSMutableDictionary *screenInfo = [[NSMutableDictionary alloc] init];
            [screenInfo setObject:[NSNumber numberWithInteger:i] forKey:@"id"];
            [screenInfo setObject:[NSString stringWithFormat:@"Display %ld", (long)(i + 1)] forKey:@"name"];
            [screenInfo setObject:[NSNumber numberWithInt:(int)screenFrame.origin.x] forKey:@"x"];
            [screenInfo setObject:[NSNumber numberWithInt:(int)screenFrame.origin.y] forKey:@"y"];
            [screenInfo setObject:[NSNumber numberWithInt:(int)screenFrame.size.width] forKey:@"width"];
            [screenInfo setObject:[NSNumber numberWithInt:(int)screenFrame.size.height] forKey:@"height"];
            [screenInfo setObject:[NSString stringWithFormat:@"%.0fx%.0f", screenFrame.size.width, screenFrame.size.height] forKey:@"resolution"];
            [screenInfo setObject:[NSNumber numberWithBool:(i == 0)] forKey:@"isPrimary"]; // First screen is primary
            [screenInfoArray addObject:screenInfo];
            
            // Create overlay window for this screen (FULL screen including menu bar)
            NSWindow *overlayWindow = [[NSWindow alloc] initWithContentRect:screenFrame
                                                                  styleMask:NSWindowStyleMaskBorderless
                                                                    backing:NSBackingStoreBuffered
                                                                      defer:NO
                                                                      screen:screen];
            
            [overlayWindow setLevel:CGWindowLevelForKey(kCGMaximumWindowLevelKey)];
            [overlayWindow setOpaque:NO];
            [overlayWindow setBackgroundColor:[NSColor clearColor]];
            [overlayWindow setIgnoresMouseEvents:NO];
            [overlayWindow setAcceptsMouseMovedEvents:YES];
            [overlayWindow setHasShadow:NO];
            [overlayWindow setAlphaValue:1.0];
            [overlayWindow setCollectionBehavior:NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorCanJoinAllSpaces];
            
            // Create overlay view
            ScreenSelectorOverlayView *overlayView = [[ScreenSelectorOverlayView alloc] initWithFrame:screenFrame];
            [overlayView setScreenInfo:screenInfo];
            [overlayWindow setContentView:overlayView];
            
            // Create select button
            NSButton *selectButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 180, 60)];
            [selectButton setTitle:@"Start Record"];
            [selectButton setButtonType:NSButtonTypeMomentaryPushIn];
            [selectButton setBezelStyle:NSBezelStyleRounded];
            [selectButton setFont:[NSFont systemFontOfSize:16 weight:NSFontWeightSemibold]];
            [selectButton setTag:i]; // Set screen index as tag
            
            // Blue background with white text
            [selectButton setWantsLayer:YES];
            [selectButton.layer setBackgroundColor:[[NSColor colorWithRed:0.0 green:0.4 blue:0.8 alpha:0.9] CGColor]];
            [selectButton.layer setCornerRadius:8.0];
            [selectButton.layer setBorderColor:[[NSColor colorWithRed:0.0 green:0.3 blue:0.7 alpha:1.0] CGColor]];
            [selectButton.layer setBorderWidth:2.0];
            
            // White text color
            NSMutableAttributedString *titleString = [[NSMutableAttributedString alloc] 
                initWithString:[selectButton title]];
            [titleString addAttribute:NSForegroundColorAttributeName 
                                value:[NSColor whiteColor] 
                                range:NSMakeRange(0, [titleString length])];
            [selectButton setAttributedTitle:titleString];
            
            // Add shadow for better visibility
            [selectButton.layer setShadowColor:[[NSColor blackColor] CGColor]];
            [selectButton.layer setShadowOffset:NSMakeSize(0, -2)];
            [selectButton.layer setShadowRadius:4.0];
            [selectButton.layer setShadowOpacity:0.3];
            
            // Set button target and action (reuse global delegate)
            if (!g_delegate) {
                g_delegate = [[WindowSelectorDelegate alloc] init];
            }
            [selectButton setTarget:g_delegate];
            [selectButton setAction:@selector(screenSelectButtonClicked:)];
            
            // Position button in center of screen
            NSPoint buttonCenter = NSMakePoint(
                (screenFrame.size.width - [selectButton frame].size.width) / 2,
                (screenFrame.size.height - [selectButton frame].size.height) / 2
            );
            [selectButton setFrameOrigin:buttonCenter];
            
            [overlayView addSubview:selectButton];
            [overlayWindow orderFront:nil];
            [overlayWindow makeKeyAndOrderFront:nil];
            
            [g_screenOverlayWindows addObject:overlayWindow];
            [screenInfo release];
        }
        
        g_allScreens = [screenInfoArray retain];
        [screenInfoArray release];
        g_isScreenSelecting = true;
        
        // Add ESC key event monitor to cancel selection
        g_screenKeyEventMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                                          handler:^(NSEvent *event) {
            if ([event keyCode] == 53) { // ESC key
                NSLog(@"🖥️ SCREEN SELECTION: ESC pressed - cancelling selection");
                cleanupScreenSelector();
            }
        }];
        
        NSLog(@"🖥️ SCREEN SELECTION: Started with %lu screens (ESC to cancel)", (unsigned long)[screens count]);
        
        return true;
        
    } @catch (NSException *exception) {
        NSLog(@"❌ Error starting screen selection: %@", exception);
        cleanupScreenSelector();
        return false;
    }
}

bool stopScreenSelection() {
    @try {
        if (!g_isScreenSelecting) return false;
        
        cleanupScreenSelector();
        NSLog(@"🖥️ SCREEN SELECTION: Stopped");
        return true;
        
    } @catch (NSException *exception) {
        NSLog(@"❌ Error stopping screen selection: %@", exception);
        return false;
    }
}

NSDictionary* getSelectedScreenInfo() {
    if (!g_selectedScreenInfo) return nil;
    
    NSDictionary *result = [g_selectedScreenInfo retain];
    [g_selectedScreenInfo release];
    g_selectedScreenInfo = nil;
    
    return [result autorelease];
}

bool showScreenRecordingPreview(NSDictionary *screenInfo) {
    @try {
        // Clean up any existing preview
        cleanupRecordingPreview();
        
        if (!screenInfo) return false;
        
        // For screen recording preview, we show all OTHER screens as black overlay
        // and keep the selected screen transparent
        NSArray *screens = [NSScreen screens];
        if (!screens || [screens count] == 0) return false;
        
        int selectedScreenId = [[screenInfo objectForKey:@"id"] intValue];
        
        // Create overlay for each screen except the selected one
        for (NSInteger i = 0; i < [screens count]; i++) {
            if (i == selectedScreenId) continue; // Skip selected screen
            
            NSScreen *screen = [screens objectAtIndex:i];
            NSRect screenFrame = [screen frame];
            
            // Create full-screen black overlay for non-selected screens
            NSWindow *overlayWindow = [[NSWindow alloc] initWithContentRect:screenFrame
                                                                  styleMask:NSWindowStyleMaskBorderless
                                                                    backing:NSBackingStoreBuffered
                                                                      defer:NO
                                                                      screen:screen];
            
            [overlayWindow setLevel:CGWindowLevelForKey(kCGOverlayWindowLevelKey)];
            [overlayWindow setOpaque:NO];
            [overlayWindow setBackgroundColor:[NSColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.5]];
            [overlayWindow setIgnoresMouseEvents:YES];
            [overlayWindow setAcceptsMouseMovedEvents:NO];
            [overlayWindow setHasShadow:NO];
            [overlayWindow setAlphaValue:1.0];
            [overlayWindow setCollectionBehavior:NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorCanJoinAllSpaces];
            
            [overlayWindow orderFront:nil];
            [overlayWindow makeKeyAndOrderFront:nil];
            
            // Store for cleanup (reuse recording preview window variable)
            if (!g_recordingPreviewWindow) {
                g_recordingPreviewWindow = overlayWindow;
            }
        }
        
        NSLog(@"🎬 SCREEN RECORDING PREVIEW: Showing overlay for Screen %d", selectedScreenId);
        
        return true;
        
    } @catch (NSException *exception) {
        NSLog(@"❌ Error showing screen recording preview: %@", exception);
        return false;
    }
}

bool hideScreenRecordingPreview() {
    return hideRecordingPreview(); // Reuse existing function
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
        g_selectButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 160, 60)];
        [g_selectButton setTitle:@"Start Record"];
        [g_selectButton setButtonType:NSButtonTypeMomentaryPushIn];
        [g_selectButton setBezelStyle:NSBezelStyleRounded];
        [g_selectButton setFont:[NSFont systemFontOfSize:16 weight:NSFontWeightSemibold]];
        
        // Blue background with white text
        [g_selectButton setWantsLayer:YES];
        [g_selectButton.layer setBackgroundColor:[[NSColor colorWithRed:0.0 green:0.4 blue:0.8 alpha:0.9] CGColor]];
        [g_selectButton.layer setCornerRadius:8.0];
        [g_selectButton.layer setBorderColor:[[NSColor colorWithRed:0.0 green:0.3 blue:0.7 alpha:1.0] CGColor]];
        [g_selectButton.layer setBorderWidth:2.0];
        
        // White text color
        NSMutableAttributedString *titleString = [[NSMutableAttributedString alloc] 
            initWithString:[g_selectButton title]];
        [titleString addAttribute:NSForegroundColorAttributeName 
                            value:[NSColor whiteColor] 
                            range:NSMakeRange(0, [titleString length])];
        [g_selectButton setAttributedTitle:titleString];
        
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

// NAPI Function: Show Recording Preview
Napi::Value ShowRecordingPreview(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (info.Length() < 1) {
        Napi::TypeError::New(env, "Window info object required").ThrowAsJavaScriptException();
        return env.Null();
    }
    
    if (!info[0].IsObject()) {
        Napi::TypeError::New(env, "Window info must be an object").ThrowAsJavaScriptException();
        return env.Null();
    }
    
    @try {
        Napi::Object windowInfoObj = info[0].As<Napi::Object>();
        
        // Convert NAPI object to NSDictionary
        NSMutableDictionary *windowInfo = [[NSMutableDictionary alloc] init];
        
        if (windowInfoObj.Has("id")) {
            [windowInfo setObject:[NSNumber numberWithInt:windowInfoObj.Get("id").As<Napi::Number>().Int32Value()] forKey:@"id"];
        }
        if (windowInfoObj.Has("title")) {
            [windowInfo setObject:[NSString stringWithUTF8String:windowInfoObj.Get("title").As<Napi::String>().Utf8Value().c_str()] forKey:@"title"];
        }
        if (windowInfoObj.Has("appName")) {
            [windowInfo setObject:[NSString stringWithUTF8String:windowInfoObj.Get("appName").As<Napi::String>().Utf8Value().c_str()] forKey:@"appName"];
        }
        if (windowInfoObj.Has("x")) {
            [windowInfo setObject:[NSNumber numberWithInt:windowInfoObj.Get("x").As<Napi::Number>().Int32Value()] forKey:@"x"];
        }
        if (windowInfoObj.Has("y")) {
            [windowInfo setObject:[NSNumber numberWithInt:windowInfoObj.Get("y").As<Napi::Number>().Int32Value()] forKey:@"y"];
        }
        if (windowInfoObj.Has("width")) {
            [windowInfo setObject:[NSNumber numberWithInt:windowInfoObj.Get("width").As<Napi::Number>().Int32Value()] forKey:@"width"];
        }
        if (windowInfoObj.Has("height")) {
            [windowInfo setObject:[NSNumber numberWithInt:windowInfoObj.Get("height").As<Napi::Number>().Int32Value()] forKey:@"height"];
        }
        
        bool success = showRecordingPreview(windowInfo);
        [windowInfo release];
        
        return Napi::Boolean::New(env, success);
        
    } @catch (NSException *exception) {
        return Napi::Boolean::New(env, false);
    }
}

// NAPI Function: Hide Recording Preview
Napi::Value HideRecordingPreview(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        bool success = hideRecordingPreview();
        return Napi::Boolean::New(env, success);
        
    } @catch (NSException *exception) {
        return Napi::Boolean::New(env, false);
    }
}

// NAPI Function: Start Screen Selection
Napi::Value StartScreenSelection(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        bool success = startScreenSelection();
        return Napi::Boolean::New(env, success);
        
    } @catch (NSException *exception) {
        return Napi::Boolean::New(env, false);
    }
}

// NAPI Function: Stop Screen Selection
Napi::Value StopScreenSelection(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        bool success = stopScreenSelection();
        return Napi::Boolean::New(env, success);
        
    } @catch (NSException *exception) {
        return Napi::Boolean::New(env, false);
    }
}

// NAPI Function: Get Selected Screen Info
Napi::Value GetSelectedScreenInfo(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        NSDictionary *screenInfo = getSelectedScreenInfo();
        if (!screenInfo) {
            return env.Null();
        }
        
        Napi::Object result = Napi::Object::New(env);
        result.Set("id", Napi::Number::New(env, [[screenInfo objectForKey:@"id"] intValue]));
        result.Set("name", Napi::String::New(env, [[screenInfo objectForKey:@"name"] UTF8String]));
        result.Set("x", Napi::Number::New(env, [[screenInfo objectForKey:@"x"] intValue]));
        result.Set("y", Napi::Number::New(env, [[screenInfo objectForKey:@"y"] intValue]));
        result.Set("width", Napi::Number::New(env, [[screenInfo objectForKey:@"width"] intValue]));
        result.Set("height", Napi::Number::New(env, [[screenInfo objectForKey:@"height"] intValue]));
        result.Set("resolution", Napi::String::New(env, [[screenInfo objectForKey:@"resolution"] UTF8String]));
        result.Set("isPrimary", Napi::Boolean::New(env, [[screenInfo objectForKey:@"isPrimary"] boolValue]));
        
        NSLog(@"🖥️ SCREEN SELECTED: %@ (%@)", 
              [screenInfo objectForKey:@"name"],
              [screenInfo objectForKey:@"resolution"]);
        
        return result;
        
    } @catch (NSException *exception) {
        return env.Null();
    }
}

// NAPI Function: Show Screen Recording Preview
Napi::Value ShowScreenRecordingPreview(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (info.Length() < 1) {
        Napi::TypeError::New(env, "Screen info object required").ThrowAsJavaScriptException();
        return env.Null();
    }
    
    if (!info[0].IsObject()) {
        Napi::TypeError::New(env, "Screen info must be an object").ThrowAsJavaScriptException();
        return env.Null();
    }
    
    @try {
        Napi::Object screenInfoObj = info[0].As<Napi::Object>();
        
        // Convert NAPI object to NSDictionary
        NSMutableDictionary *screenInfo = [[NSMutableDictionary alloc] init];
        
        if (screenInfoObj.Has("id")) {
            [screenInfo setObject:[NSNumber numberWithInt:screenInfoObj.Get("id").As<Napi::Number>().Int32Value()] forKey:@"id"];
        }
        if (screenInfoObj.Has("name")) {
            [screenInfo setObject:[NSString stringWithUTF8String:screenInfoObj.Get("name").As<Napi::String>().Utf8Value().c_str()] forKey:@"name"];
        }
        if (screenInfoObj.Has("resolution")) {
            [screenInfo setObject:[NSString stringWithUTF8String:screenInfoObj.Get("resolution").As<Napi::String>().Utf8Value().c_str()] forKey:@"resolution"];
        }
        if (screenInfoObj.Has("x")) {
            [screenInfo setObject:[NSNumber numberWithInt:screenInfoObj.Get("x").As<Napi::Number>().Int32Value()] forKey:@"x"];
        }
        if (screenInfoObj.Has("y")) {
            [screenInfo setObject:[NSNumber numberWithInt:screenInfoObj.Get("y").As<Napi::Number>().Int32Value()] forKey:@"y"];
        }
        if (screenInfoObj.Has("width")) {
            [screenInfo setObject:[NSNumber numberWithInt:screenInfoObj.Get("width").As<Napi::Number>().Int32Value()] forKey:@"width"];
        }
        if (screenInfoObj.Has("height")) {
            [screenInfo setObject:[NSNumber numberWithInt:screenInfoObj.Get("height").As<Napi::Number>().Int32Value()] forKey:@"height"];
        }
        
        bool success = showScreenRecordingPreview(screenInfo);
        [screenInfo release];
        
        return Napi::Boolean::New(env, success);
        
    } @catch (NSException *exception) {
        return Napi::Boolean::New(env, false);
    }
}

// NAPI Function: Hide Screen Recording Preview
Napi::Value HideScreenRecordingPreview(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        bool success = hideScreenRecordingPreview();
        return Napi::Boolean::New(env, success);
        
    } @catch (NSException *exception) {
        return Napi::Boolean::New(env, false);
    }
}

// Export functions
Napi::Object InitWindowSelector(Napi::Env env, Napi::Object exports) {
    exports.Set("startWindowSelection", Napi::Function::New(env, StartWindowSelection));
    exports.Set("stopWindowSelection", Napi::Function::New(env, StopWindowSelection));
    exports.Set("getSelectedWindowInfo", Napi::Function::New(env, GetSelectedWindowInfo));
    exports.Set("getWindowSelectionStatus", Napi::Function::New(env, GetWindowSelectionStatus));
    exports.Set("bringWindowToFront", Napi::Function::New(env, BringWindowToFront));
    exports.Set("setBringToFrontEnabled", Napi::Function::New(env, SetBringToFrontEnabled));
    exports.Set("showRecordingPreview", Napi::Function::New(env, ShowRecordingPreview));
    exports.Set("hideRecordingPreview", Napi::Function::New(env, HideRecordingPreview));
    exports.Set("startScreenSelection", Napi::Function::New(env, StartScreenSelection));
    exports.Set("stopScreenSelection", Napi::Function::New(env, StopScreenSelection));
    exports.Set("getSelectedScreenInfo", Napi::Function::New(env, GetSelectedScreenInfo));
    exports.Set("showScreenRecordingPreview", Napi::Function::New(env, ShowScreenRecordingPreview));
    exports.Set("hideScreenRecordingPreview", Napi::Function::New(env, HideScreenRecordingPreview));
    
    return exports;
}
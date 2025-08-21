#import <napi.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <Accessibility/Accessibility.h>
#import <QuartzCore/QuartzCore.h>

// Global state for window selection
static bool g_isWindowSelecting = false;
static NSWindow *g_overlayWindow = nil;
static NSView *g_overlayView = nil;
static NSButton *g_selectButton = nil;
static NSTimer *g_trackingTimer = nil;
static NSDictionary *g_selectedWindowInfo = nil;
static NSMutableArray *g_allWindows = nil;
static NSDictionary *g_currentWindowUnderCursor = nil;
static bool g_bringToFrontEnabled = false; // Default disabled for overlay-only highlighting
static bool g_hasToggledWindow = false; // Track if any window is currently toggled
static id g_windowKeyEventMonitor = nil;

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
static NSTimer *g_screenTrackingTimer = nil;
static NSInteger g_currentActiveScreenIndex = -1;

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
void updateScreenOverlays();

// Custom overlay view class
@interface WindowSelectorOverlayView : NSView
@property (nonatomic, strong) NSDictionary *windowInfo;
@property (nonatomic) BOOL isActiveWindow;
@property (nonatomic) BOOL isToggled;
@end

@implementation WindowSelectorOverlayView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        // Use layer for background instead of custom drawing
        self.wantsLayer = YES;
        self.isActiveWindow = YES; // Default to active for current window under mouse
        
        // Set purple background with border using layer
        [self updateAppearance];
        
        // Window selector overlay view created
    }
    return self;
}

- (void)updateAppearance {
    if (self.isToggled) {
        // Toggled window: same background, thick border with darker version of fill color
        self.layer.backgroundColor = [[NSColor colorWithRed:0.6 green:0.4 blue:0.9 alpha:0.4] CGColor];
        self.layer.borderColor = [[NSColor colorWithRed:0.45 green:0.25 blue:0.75 alpha:0.9] CGColor]; // Darker purple
        self.layer.borderWidth = 3.0;
    } else if (self.isActiveWindow) {
        // Active window: brighter background, thin white border
        self.layer.backgroundColor = [[NSColor colorWithRed:0.6 green:0.4 blue:0.9 alpha:0.4] CGColor];
        self.layer.borderColor = [[NSColor whiteColor] CGColor];
        self.layer.borderWidth = 1.0;
    } else {
        // Inactive window: dimmer background, thin white border
        self.layer.backgroundColor = [[NSColor colorWithRed:0.4 green:0.2 blue:0.6 alpha:0.25] CGColor];
        self.layer.borderColor = [[NSColor whiteColor] CGColor];
        self.layer.borderWidth = 1.0;
    }
    
    self.layer.cornerRadius = 8.0;
    self.layer.masksToBounds = YES;
    self.layer.shadowOpacity = 0.0;
    self.layer.shadowRadius = 0.0;
    self.layer.shadowOffset = NSMakeSize(0, 0);
}

- (void)setIsActiveWindow:(BOOL)isActiveWindow {
    if (_isActiveWindow != isActiveWindow) {
        _isActiveWindow = isActiveWindow;
        [self updateAppearance];
    }
}

- (void)setIsToggled:(BOOL)isToggled {
    if (_isToggled != isToggled) {
        _isToggled = isToggled;
        [self updateAppearance];
    }
}

// Handle mouse clicks for toggle functionality
- (void)mouseDown:(NSEvent *)event {
    [super mouseDown:event];
    
    // Toggle the window state
    self.isToggled = !self.isToggled;
    
    // Update global toggle state
    g_hasToggledWindow = self.isToggled;
    
    // Bring window to front if toggled
    if (self.isToggled && self.windowInfo) {
        int windowId = [[self.windowInfo objectForKey:@"id"] intValue];
        if (windowId > 0) {
            bringWindowToFront(windowId);
            NSLog(@"🔄 TOGGLED: Window brought to front - %@", [self.windowInfo objectForKey:@"title"]);
        }
    }
    
    NSLog(@"🎯 Global toggle state: %s", g_hasToggledWindow ? "HAS_TOGGLED" : "NO_TOGGLE");
}

// Layer-based approach, no custom drawing needed

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
        // Ensure no borders or decorations
        self.layer.borderWidth = 0.0;
        self.layer.cornerRadius = 8.0;
        self.layer.masksToBounds = YES;
        self.layer.shadowOpacity = 0.0;
        self.layer.shadowRadius = 0.0;
        self.layer.shadowOffset = NSMakeSize(0, 0);
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
@property (nonatomic) BOOL isActiveScreen;
@end

@implementation ScreenSelectorOverlayView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [[NSColor clearColor] CGColor];
        // Ensure no borders or decorations
        self.layer.borderWidth = 0.0;
        self.layer.cornerRadius = 8.0;
        self.layer.masksToBounds = YES;
        self.layer.shadowOpacity = 0.0;
        self.layer.shadowRadius = 0.0;
        self.layer.shadowOffset = NSMakeSize(0, 0);
        self.isActiveScreen = NO;
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    if (!self.screenInfo) return;
    
    // Background with transparency - purple tone varies by active state
    if (self.isActiveScreen) {
        // Active screen: brighter, more opaque
        [[NSColor colorWithRed:0.6 green:0.4 blue:0.9 alpha:0.4] setFill];
    } else {
        // Inactive screen: dimmer, less opaque
        [[NSColor colorWithRed:0.4 green:0.2 blue:0.6 alpha:0.25] setFill];
    }
    NSRectFill(self.bounds);
    
    // No border for clean look
}

@end

// Button action handler and timer target
@interface WindowSelectorDelegate : NSObject
- (void)selectButtonClicked:(id)sender;
- (void)screenSelectButtonClicked:(id)sender;
- (void)cancelButtonClicked:(id)sender;
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
        
        NSLog(@"🖥️ SCREEN SELECTED: %@ (ID: %@)", 
              [screenInfo objectForKey:@"name"],
              [screenInfo objectForKey:@"id"]);
        
        cleanupScreenSelector();
    }
}

- (void)cancelButtonClicked:(id)sender {
    NSLog(@"🚫 CANCEL BUTTON CLICKED: Selection cancelled");
    // Clean up without selecting anything
    if (g_isScreenSelecting) {
        cleanupScreenSelector();
    } else {
        cleanupWindowSelector();
    }
}

- (void)timerUpdate:(NSTimer *)timer {
    updateOverlay();
}

- (void)screenTimerUpdate:(NSTimer *)timer {
    updateScreenOverlays();
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
        
        // Decide which window to track (cursor or toggled)
        NSDictionary *targetWindow = nil;
        
        if (g_hasToggledWindow && g_currentWindowUnderCursor) {
            // Use current toggled window, but get fresh position data
            int windowId = [[g_currentWindowUnderCursor objectForKey:@"id"] intValue];
            NSArray *allWindows = getAllSelectableWindows();
            targetWindow = allWindows != nil ? 
                [[allWindows filteredArrayUsingPredicate:
                    [NSPredicate predicateWithFormat:@"id == %d", windowId]] firstObject] : nil;
            
            if (!targetWindow) {
                NSLog(@"⚠️ Toggled window no longer exists - resetting toggle");
                g_hasToggledWindow = false;
                targetWindow = windowUnderCursor;
            }
        } else {
            targetWindow = windowUnderCursor;
        }
        
        if (targetWindow) {
            // Update current window if different or if we need fresh position data
            BOOL shouldUpdate = !g_currentWindowUnderCursor ||
                              ![targetWindow isEqualToDictionary:g_currentWindowUnderCursor] ||
                              g_hasToggledWindow; // Always update position for toggled windows
            
            if (shouldUpdate && !g_hasToggledWindow) {
                // Only switch windows if not toggled
                [g_currentWindowUnderCursor release];
                g_currentWindowUnderCursor = [targetWindow retain];
            } else if (g_hasToggledWindow) {
                // Update position data for toggled window
                [g_currentWindowUnderCursor release];
                g_currentWindowUnderCursor = [targetWindow retain];
            }
            
            // Update overlay position and size with fresh data
            int x = [[targetWindow objectForKey:@"x"] intValue];
            int y = [[targetWindow objectForKey:@"y"] intValue];
            int width = [[targetWindow objectForKey:@"width"] intValue];
            int height = [[targetWindow objectForKey:@"height"] intValue];
            
            // Find which screen contains the window center
            NSArray *screens = [NSScreen screens];
            NSScreen *windowScreen = nil;
            CGFloat windowCenterX = x + width / 2;
            CGFloat windowCenterY = y + height / 2;
            
            for (NSScreen *screen in screens) {
                NSRect screenFrame = [screen frame];
                // Convert screen frame to CGWindow coordinates
                CGFloat screenTop = screenFrame.origin.y + screenFrame.size.height;
                CGFloat screenBottom = screenFrame.origin.y;
                CGFloat screenLeft = screenFrame.origin.x;
                CGFloat screenRight = screenFrame.origin.x + screenFrame.size.width;
                
                if (windowCenterX >= screenLeft && windowCenterX <= screenRight &&
                    windowCenterY >= screenBottom && windowCenterY <= screenTop) {
                    windowScreen = screen;
                    break;
                }
            }
            
            // Use main screen if no specific screen found
            if (!windowScreen) windowScreen = [NSScreen mainScreen];
            
            // Convert coordinates from CGWindow (top-left) to NSWindow (bottom-left) for the specific screen
            NSRect screenFrame = [windowScreen frame];
            CGFloat screenHeight = screenFrame.size.height;
            CGFloat adjustedY = screenHeight - y - height;
            
            // Window coordinates are in global space, overlay frame should be screen-relative
            // Keep X coordinate as-is (already in global space which is what we want)
            // Only convert Y from top-left to bottom-left coordinate system
            NSRect overlayFrame = NSMakeRect(x, adjustedY, width, height);
            
            NSString *windowTitle = [targetWindow objectForKey:@"title"] ?: @"Untitled";
            NSString *appName = [targetWindow objectForKey:@"appName"] ?: @"Unknown";
            
            NSLog(@"🎯 WINDOW DETECTED: %@ - \"%@\"", appName, windowTitle);
            NSLog(@"   📍 Position: (%d, %d)  📏 Size: %d × %d", x, y, width, height);
            NSLog(@"   🖥️  NSRect: (%.0f, %.0f, %.0f, %.0f)  🔝 Level: %ld", 
                  overlayFrame.origin.x, overlayFrame.origin.y, 
                  overlayFrame.size.width, overlayFrame.size.height,
                  [g_overlayWindow level]);
            
            // Bring window to front if enabled
            if (g_bringToFrontEnabled) {
                int windowId = [[targetWindow objectForKey:@"id"] intValue];
                if (windowId > 0) {
                    bool success = bringWindowToFront(windowId);
                    if (!success) {
                        NSLog(@"   ⚠️ Failed to bring window to front");
                    }
                }
            }
            
            // Ensure overlay is on the correct screen
            [g_overlayWindow setFrame:overlayFrame display:YES];
            
            // Update overlay view window info
            [(WindowSelectorOverlayView *)g_overlayView setWindowInfo:targetWindow];
            
            // Only reset toggle state when switching to a different window (not for position updates)
            if (shouldUpdate && !g_hasToggledWindow) {
                [(WindowSelectorOverlayView *)g_overlayView setIsToggled:NO];
                g_hasToggledWindow = NO; // Reset global toggle state when switching windows
            }
            
            // Add/update info label above button
            NSTextField *infoLabel = nil;
            for (NSView *subview in [g_overlayWindow.contentView subviews]) {
                if ([subview isKindOfClass:[NSTextField class]]) {
                    infoLabel = (NSTextField*)subview;
                    break;
                }
            }
            
            if (!infoLabel) {
                infoLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, width - 40, 60)];
                [infoLabel setEditable:NO];
                [infoLabel setSelectable:NO];
                [infoLabel setBezeled:NO];
                [infoLabel setDrawsBackground:NO];
                [infoLabel setAlignment:NSTextAlignmentCenter];
                [infoLabel setFont:[NSFont systemFontOfSize:18 weight:NSFontWeightMedium]];
                [infoLabel setTextColor:[NSColor whiteColor]];
                
                // Force no borders on info label
                [infoLabel setWantsLayer:YES];
                infoLabel.layer.borderWidth = 0.0;
                infoLabel.layer.borderColor = [[NSColor clearColor] CGColor];
                infoLabel.layer.cornerRadius = 0.0;
                infoLabel.layer.masksToBounds = YES;
                
                [g_overlayWindow.contentView addSubview:infoLabel];
            }
            
            // Add/update app icon
            NSImageView *appIconView = nil;
            for (NSView *subview in [g_overlayWindow.contentView subviews]) {
                if ([subview isKindOfClass:[NSImageView class]]) {
                    appIconView = (NSImageView*)subview;
                    break;
                }
            }
            
            if (!appIconView) {
                appIconView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 96, 96)];
                [appIconView setImageScaling:NSImageScaleProportionallyUpOrDown];
                [appIconView setWantsLayer:YES];
                [appIconView.layer setCornerRadius:8.0];
                [appIconView.layer setMasksToBounds:YES];
                [appIconView.layer setBackgroundColor:[[NSColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.3] CGColor]]; // Debug background
                
                // Force no borders on app icon view
                appIconView.layer.borderWidth = 0.0;
                appIconView.layer.borderColor = [[NSColor clearColor] CGColor];
                appIconView.layer.shadowOpacity = 0.0;
                appIconView.layer.shadowRadius = 0.0;
                appIconView.layer.shadowOffset = NSMakeSize(0, 0);
                
                [g_overlayWindow.contentView addSubview:appIconView];
                NSLog(@"🖼️ Created app icon view at frame: (%.0f, %.0f, %.0f, %.0f)", 
                      appIconView.frame.origin.x, appIconView.frame.origin.y, 
                      appIconView.frame.size.width, appIconView.frame.size.height);
            }
            
            // Get app icon using NSWorkspace
            NSString *iconAppName = [windowUnderCursor objectForKey:@"appName"] ?: @"Unknown";
            NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
            NSArray *runningApps = [workspace runningApplications];
            NSImage *appIcon = nil;
            
            for (NSRunningApplication *app in runningApps) {
                if ([[app localizedName] isEqualToString:iconAppName] || [[app bundleIdentifier] containsString:iconAppName]) {
                    appIcon = [app icon];
                    break;
                }
            }
            
            // Fallback to generic app icon if not found
            if (!appIcon) {
                appIcon = [workspace iconForFileType:NSFileTypeForHFSTypeCode(kGenericApplicationIcon)];
                NSLog(@"⚠️ Using fallback icon for app: %@", iconAppName);
            } else {
                NSLog(@"✅ Found app icon for: %@", iconAppName);
            }
            
            [appIconView setImage:appIcon];
            NSLog(@"🖼️ Set icon image, size: %.0fx%.0f", [appIcon size].width, [appIcon size].height);
            
            // Update label text
            NSString *labelWindowTitle = [windowUnderCursor objectForKey:@"title"] ?: @"Unknown Window";
            NSString *labelAppName = [windowUnderCursor objectForKey:@"appName"] ?: @"Unknown App";
            [infoLabel setStringValue:[NSString stringWithFormat:@"%@\n%@", labelAppName, labelWindowTitle]];
            
            // Position buttons - Start Record in center, Cancel below it
            if (g_selectButton) {
                NSSize buttonSize = [g_selectButton frame].size;
                NSPoint buttonCenter = NSMakePoint(
                    (width - buttonSize.width) / 2,
                    (height - buttonSize.height) / 2 + 15  // Slightly above center
                );
                [g_selectButton setFrameOrigin:buttonCenter];
                
                // Position app icon above text label
                NSPoint iconCenter = NSMakePoint(
                    (width - 96) / 2,  // Center horizontally (icon is 96px wide)
                    buttonCenter.y + buttonSize.height + 60 + 10  // Above label + text height + margin
                );
                [appIconView setFrameOrigin:iconCenter];
                NSLog(@"🎯 Positioning app icon at: (%.0f, %.0f) for window size: (%.0f, %.0f)", 
                      iconCenter.x, iconCenter.y, (float)width, (float)height);
                
                // Add fast horizontal floating animation after positioning
                [appIconView.layer removeAnimationForKey:@"floatAnimationX"];
                [appIconView.layer removeAnimationForKey:@"floatAnimationY"];
                
                // Faster horizontal float animation only
                CABasicAnimation *floatAnimationX = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
                floatAnimationX.fromValue = @(-4.0);
                floatAnimationX.toValue = @(4.0);
                floatAnimationX.duration = 1.0; // Much faster animation
                floatAnimationX.repeatCount = HUGE_VALF;
                floatAnimationX.autoreverses = YES;
                floatAnimationX.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                [appIconView.layer addAnimation:floatAnimationX forKey:@"floatAnimationX"];
                
                // Position info label at overlay center, above button
                NSPoint labelCenter = NSMakePoint(
                    (width - [infoLabel frame].size.width) / 2,  // Center horizontally
                    buttonCenter.y + buttonSize.height + 10  // 10px above button, below icon
                );
                [infoLabel setFrameOrigin:labelCenter];
                
                // Position cancel button below the main button
                NSButton *cancelButton = nil;
                for (NSView *subview in [g_overlayWindow.contentView subviews]) {
                    if ([subview isKindOfClass:[NSButton class]] && 
                        [[(NSButton*)subview title] isEqualToString:@"Cancel"]) {
                        cancelButton = (NSButton*)subview;
                        break;
                    }
                }
                
                if (cancelButton) {
                    NSSize cancelButtonSize = [cancelButton frame].size;
                    NSPoint cancelButtonCenter = NSMakePoint(
                        (width - cancelButtonSize.width) / 2,
                        buttonCenter.y - buttonSize.height - 20  // 20px below main button
                    );
                    [cancelButton setFrameOrigin:cancelButtonCenter];
                }
            }
            
            [g_overlayWindow orderFront:nil];
            [g_overlayWindow makeKeyAndOrderFront:nil];
            
            // Ensure subviews (except overlay view itself) have no borders after positioning
            for (NSView *subview in [g_overlayWindow.contentView subviews]) {
                // Skip the main overlay view - it handles its own borders
                if ([subview isKindOfClass:[WindowSelectorOverlayView class]]) continue;
                
                if ([subview respondsToSelector:@selector(setWantsLayer:)]) {
                    [subview setWantsLayer:YES];
                    if (subview.layer) {
                        subview.layer.borderWidth = 0.0;
                        subview.layer.borderColor = [[NSColor clearColor] CGColor];
                        subview.layer.masksToBounds = YES;
                        subview.layer.shadowOpacity = 0.0;
                        subview.layer.shadowRadius = 0.0;
                        subview.layer.shadowOffset = NSMakeSize(0, 0);
                    }
                }
            }
            
            NSLog(@"   ✅ Overlay Status: Level=%ld, Alpha=%.1f, Visible=%s, Frame Set=YES", 
                  [g_overlayWindow level], [g_overlayWindow alphaValue], 
                  [g_overlayWindow isVisible] ? "YES" : "NO");
        } else if (!targetWindow && g_currentWindowUnderCursor && !g_hasToggledWindow) {
            // No window under cursor and no toggle active, hide overlay
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
    g_hasToggledWindow = false; // Reset toggle state
    
    // Stop tracking timer
    if (g_trackingTimer) {
        [g_trackingTimer invalidate];
        g_trackingTimer = nil;
    }
    
    // Remove key event monitor
    if (g_windowKeyEventMonitor) {
        [NSEvent removeMonitor:g_windowKeyEventMonitor];
        g_windowKeyEventMonitor = nil;
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
        
        // Remove any default window decorations and borders
        [g_recordingPreviewWindow setTitlebarAppearsTransparent:YES];
        [g_recordingPreviewWindow setTitleVisibility:NSWindowTitleHidden];
        [g_recordingPreviewWindow setMovable:NO];
        [g_recordingPreviewWindow setMovableByWindowBackground:NO];
        
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

// Update screen overlays based on mouse position
void updateScreenOverlays() {
    @autoreleasepool {
        if (!g_isScreenSelecting || !g_screenOverlayWindows || !g_allScreens) return;
        
        // Get current mouse position
        NSPoint mouseLocation = [NSEvent mouseLocation];
        // Convert from NSEvent coordinates (bottom-left) to screen coordinates
        NSArray *screens = [NSScreen screens];
        NSScreen *mouseScreen = nil;
        NSInteger mouseScreenIndex = -1;
        
        // Find which screen contains the mouse
        for (NSInteger i = 0; i < [screens count]; i++) {
            NSScreen *screen = [screens objectAtIndex:i];
            NSRect screenFrame = [screen frame];
            
            if (NSPointInRect(mouseLocation, screenFrame)) {
                mouseScreen = screen;
                mouseScreenIndex = i;
                break;
            }
        }
        
        // If mouse screen changed, update overlays
        if (mouseScreenIndex != g_currentActiveScreenIndex) {
            g_currentActiveScreenIndex = mouseScreenIndex;
            
            // Update all screen overlays
            for (NSInteger i = 0; i < [g_screenOverlayWindows count] && i < [screens count]; i++) {
                NSWindow *overlayWindow = [g_screenOverlayWindows objectAtIndex:i];
                ScreenSelectorOverlayView *overlayView = (ScreenSelectorOverlayView *)[overlayWindow contentView];
                
                // Update overlay appearance based on whether it's the active screen
                bool isActiveScreen = (i == mouseScreenIndex);
                
                // Update overlay state and appearance
                [overlayView setIsActiveScreen:isActiveScreen];
                [overlayView setNeedsDisplay:YES];
                
                // Update UI elements based on active state
                for (NSView *subview in [overlayView subviews]) {
                    if ([subview isKindOfClass:[NSButton class]]) {
                        NSButton *button = (NSButton *)subview;
                        if ([button.title isEqualToString:@"Start Record"]) {
                            if (isActiveScreen) {
                                // Active screen: bright, prominent button with new RGB color
                                [button.layer setBackgroundColor:[[NSColor colorWithRed:77.0/255.0 green:30.0/255.0 blue:231.0/255.0 alpha:1.0] CGColor]];
                                [button setAlphaValue:1.0];
                            } else {
                                // Inactive screen: dimmer button with new RGB color
                                [button.layer setBackgroundColor:[[NSColor colorWithRed:77.0/255.0 green:30.0/255.0 blue:231.0/255.0 alpha:0.6] CGColor]];
                                [button setAlphaValue:0.7];
                            }
                        }
                    }
                    if ([subview isKindOfClass:[NSTextField class]]) {
                        NSTextField *label = (NSTextField *)subview;
                        if (isActiveScreen) {
                            [label setTextColor:[NSColor whiteColor]];
                            [label setAlphaValue:1.0];
                        } else {
                            [label setTextColor:[NSColor colorWithWhite:0.8 alpha:0.8]];
                            [label setAlphaValue:0.7];
                        }
                    }
                    if ([subview isKindOfClass:[NSImageView class]]) {
                        NSImageView *imageView = (NSImageView *)subview;
                        if (isActiveScreen) {
                            [imageView setAlphaValue:1.0];
                        } else {
                            [imageView setAlphaValue:0.6];
                        }
                    }
                }
                
                // Log active screen changes for debugging (optional)
                if (isActiveScreen) {
                    NSLog(@"🖥️ Active screen: Display %ld", (long)(i + 1));
                }
                
                // Ensure ALL overlays are visible, but active one is on top
                [overlayWindow orderFront:nil];
                if (isActiveScreen) {
                    [overlayWindow makeKeyAndOrderFront:nil];
                } else {
                    [overlayWindow orderFront:nil]; // Keep inactive screens visible too
                }
            }
        }
    }
}

// Screen selection functions
void cleanupScreenSelector() {
    g_isScreenSelecting = false;
    
    // Stop screen tracking timer
    if (g_screenTrackingTimer) {
        [g_screenTrackingTimer invalidate];
        g_screenTrackingTimer = nil;
    }
    
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
    
    // Reset active screen tracking
    g_currentActiveScreenIndex = -1;
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
        
        // Get real display IDs like MacRecorder does
        CGDirectDisplayID activeDisplays[32];
        uint32_t displayCount;
        CGError err = CGGetActiveDisplayList(32, activeDisplays, &displayCount);
        
        if (err != kCGErrorSuccess) {
            NSLog(@"❌ Failed to get active display list: %d", err);
            return false;
        }

        for (NSInteger i = 0; i < [screens count]; i++) {
            NSScreen *screen = [screens objectAtIndex:i];
            NSRect screenFrame = [screen frame];
            
            // Get the real CGDirectDisplayID for this screen by matching frame
            CGDirectDisplayID displayID = 0;
            
            // Find matching display by comparing bounds
            for (uint32_t j = 0; j < displayCount; j++) {
                CGDirectDisplayID candidateID = activeDisplays[j];
                CGRect displayBounds = CGDisplayBounds(candidateID);
                
                // Compare screen frame with display bounds
                if (fabs(screenFrame.origin.x - displayBounds.origin.x) < 1.0 &&
                    fabs(screenFrame.origin.y - displayBounds.origin.y) < 1.0 &&
                    fabs(screenFrame.size.width - displayBounds.size.width) < 1.0 &&
                    fabs(screenFrame.size.height - displayBounds.size.height) < 1.0) {
                    displayID = candidateID;
                    // Screen matched to display ID
                    break;
                }
            }
            
            // Fallback: use array index if no match found
            if (displayID == 0 && i < displayCount) {
                displayID = activeDisplays[i];
                // Used fallback display ID
            } else if (displayID == 0) {
                NSLog(@"❌ Screen %ld could not get Display ID", (long)i);
            }
            
            // Create screen info dictionary with real display ID
            NSMutableDictionary *screenInfo = [[NSMutableDictionary alloc] init];
            [screenInfo setObject:[NSNumber numberWithUnsignedInt:displayID] forKey:@"id"]; // Real display ID
            [screenInfo setObject:[NSString stringWithFormat:@"Display %ld", (long)(i + 1)] forKey:@"name"];
            [screenInfo setObject:[NSNumber numberWithInt:(int)screenFrame.origin.x] forKey:@"x"];
            [screenInfo setObject:[NSNumber numberWithInt:(int)screenFrame.origin.y] forKey:@"y"];
            [screenInfo setObject:[NSNumber numberWithInt:(int)screenFrame.size.width] forKey:@"width"];
            [screenInfo setObject:[NSNumber numberWithInt:(int)screenFrame.size.height] forKey:@"height"];
            [screenInfo setObject:[NSString stringWithFormat:@"%.0fx%.0f", screenFrame.size.width, screenFrame.size.height] forKey:@"resolution"];
            [screenInfo setObject:[NSNumber numberWithBool:(displayID == CGMainDisplayID())] forKey:@"isPrimary"]; // Real primary check
            [screenInfoArray addObject:screenInfo];
            
            // Create overlay window for this screen (FULL screen including menu bar)
            // For secondary screens, don't specify screen parameter to avoid issues
            NSWindow *overlayWindow;
            if (i == 0) {
                // Primary screen - use screen parameter
                overlayWindow = [[NSWindow alloc] initWithContentRect:screenFrame
                                                            styleMask:NSWindowStyleMaskBorderless
                                                              backing:NSBackingStoreBuffered
                                                                defer:NO
                                                               screen:screen];
            } else {
                // Secondary screens - create without screen param, set frame manually
                overlayWindow = [[NSWindow alloc] initWithContentRect:screenFrame
                                                            styleMask:NSWindowStyleMaskBorderless
                                                              backing:NSBackingStoreBuffered
                                                                defer:NO];
                // Force specific positioning for secondary screen
                [overlayWindow setFrameOrigin:screenFrame.origin];
            }
            
            // Window created for specific screen
            
            // Use maximum level to match g_overlayWindow
            [overlayWindow setLevel:CGWindowLevelForKey(kCGMaximumWindowLevelKey)];
            [overlayWindow setOpaque:NO];
            [overlayWindow setBackgroundColor:[NSColor clearColor]];
            [overlayWindow setIgnoresMouseEvents:NO];
            [overlayWindow setAcceptsMouseMovedEvents:YES];
            [overlayWindow setHasShadow:NO];
            [overlayWindow setAlphaValue:1.0];
            // Ensure window appears on all spaces and stays put - match g_overlayWindow
            [overlayWindow setCollectionBehavior:NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorCanJoinAllSpaces];
            
            // Remove any default window decorations and borders
            [overlayWindow setTitlebarAppearsTransparent:YES];
            [overlayWindow setTitleVisibility:NSWindowTitleHidden];
            [overlayWindow setMovable:NO];
            [overlayWindow setMovableByWindowBackground:NO];
            
            // Force remove all borders and decorations
            [overlayWindow setHasShadow:NO];
            [overlayWindow setOpaque:NO];
            [overlayWindow setBackgroundColor:[NSColor clearColor]];
            
            // Create overlay view
            ScreenSelectorOverlayView *overlayView = [[ScreenSelectorOverlayView alloc] initWithFrame:screenFrame];
            [overlayView setScreenInfo:screenInfo];
            [overlayWindow setContentView:overlayView];
            
            // Note: NSWindow doesn't have setWantsLayer method, only NSView does
            
            // Create select button with more padding
            NSButton *selectButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 200, 60)];
            [selectButton setTitle:@"Start Record"];
            [selectButton setButtonType:NSButtonTypeMomentaryPushIn];
            [selectButton setBordered:NO];
            [selectButton setFont:[NSFont systemFontOfSize:16 weight:NSFontWeightRegular]];
            [selectButton setTag:i]; // Set screen index as tag
            
            // Modern button styling with new RGB color
            [selectButton setWantsLayer:YES];
            [selectButton.layer setBackgroundColor:[[NSColor colorWithRed:77.0/255.0 green:30.0/255.0 blue:231.0/255.0 alpha:0.95] CGColor]];
            [selectButton.layer setCornerRadius:8.0];
            [selectButton.layer setBorderWidth:0.0];
            
            // Remove all button borders and decorations
            [selectButton.layer setShadowOpacity:0.0];
            [selectButton.layer setShadowRadius:0.0];
            [selectButton.layer setShadowOffset:NSMakeSize(0, 0)];
            [selectButton.layer setMasksToBounds:YES];
            
            // Clean white text - normal weight
            [selectButton setFont:[NSFont systemFontOfSize:16 weight:NSFontWeightRegular]];
            [selectButton setTitle:@"Start Record"];
            NSMutableAttributedString *titleString = [[NSMutableAttributedString alloc] 
                initWithString:[selectButton title]];
            [titleString addAttribute:NSForegroundColorAttributeName 
                                value:[NSColor whiteColor] 
                                range:NSMakeRange(0, [titleString length])];
            [selectButton setAttributedTitle:titleString];
            
            // Clean button - no shadows or highlights
            
            // Set button target and action (reuse global delegate)
            if (!g_delegate) {
                g_delegate = [[WindowSelectorDelegate alloc] init];
            }
            [selectButton setTarget:g_delegate];
            [selectButton setAction:@selector(screenSelectButtonClicked:)];
            
            // Remove focus ring and other default button behaviors
            [selectButton setFocusRingType:NSFocusRingTypeNone];
            [selectButton setShowsBorderOnlyWhileMouseInside:NO];
            
            // Create cancel button for screen selection
            NSButton *screenCancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 120, 40)];
            [screenCancelButton setTitle:@"Cancel"];
            [screenCancelButton setButtonType:NSButtonTypeMomentaryPushIn];
            [screenCancelButton setBordered:NO];
            [screenCancelButton setFont:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium]];
            
            // Modern cancel button styling - darker gray, clean
            [screenCancelButton setWantsLayer:YES];
            [screenCancelButton.layer setBackgroundColor:[[NSColor colorWithRed:0.35 green:0.35 blue:0.4 alpha:0.9] CGColor]];
            [screenCancelButton.layer setCornerRadius:8.0];
            [screenCancelButton.layer setBorderWidth:0.0];
            
            // Remove all button borders and decorations
            [screenCancelButton.layer setShadowOpacity:0.0];
            [screenCancelButton.layer setShadowRadius:0.0];
            [screenCancelButton.layer setShadowOffset:NSMakeSize(0, 0)];
            [screenCancelButton.layer setMasksToBounds:YES];
            
            // Clean white text for cancel button
            [screenCancelButton setFont:[NSFont systemFontOfSize:15 weight:NSFontWeightRegular]];
            NSMutableAttributedString *screenCancelTitleString = [[NSMutableAttributedString alloc] 
                initWithString:[screenCancelButton title]];
            [screenCancelTitleString addAttribute:NSForegroundColorAttributeName 
                                value:[NSColor whiteColor] 
                                range:NSMakeRange(0, [screenCancelTitleString length])];
            [screenCancelButton setAttributedTitle:screenCancelTitleString];
            
            [screenCancelButton setTarget:g_delegate];
            [screenCancelButton setAction:@selector(cancelButtonClicked:)];
            
            // Remove focus ring and other default button behaviors
            [screenCancelButton setFocusRingType:NSFocusRingTypeNone];
            [screenCancelButton setShowsBorderOnlyWhileMouseInside:NO];
            
            // Create info label for screen
            NSTextField *screenInfoLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, screenFrame.size.width - 40, 60)];
            [screenInfoLabel setEditable:NO];
            [screenInfoLabel setSelectable:NO];
            [screenInfoLabel setBezeled:NO];
            [screenInfoLabel setDrawsBackground:NO];
            [screenInfoLabel setAlignment:NSTextAlignmentCenter];
            [screenInfoLabel setFont:[NSFont systemFontOfSize:20 weight:NSFontWeightMedium]];
            [screenInfoLabel setTextColor:[NSColor whiteColor]];
            
            // Create screen icon (display icon)
            NSImageView *screenIconView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 96, 96)];
            [screenIconView setImageScaling:NSImageScaleProportionallyUpOrDown];
            [screenIconView setWantsLayer:YES];
            [screenIconView.layer setCornerRadius:8.0];
            [screenIconView.layer setMasksToBounds:YES];
            
            // Set display icon
            NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
            NSImage *displayIcon = [workspace iconForFileType:NSFileTypeForHFSTypeCode(kComputerIcon)];
            [screenIconView setImage:displayIcon];
            
            // Set screen info text
            NSString *screenName = [screenInfo objectForKey:@"name"] ?: @"Unknown Screen";
            NSString *resolution = [screenInfo objectForKey:@"resolution"] ?: @"Unknown Resolution";
            [screenInfoLabel setStringValue:[NSString stringWithFormat:@"%@\n%@", screenName, resolution]];
            
            // Position buttons - Start Record in center, Cancel below it
            NSPoint buttonCenter = NSMakePoint(
                (screenFrame.size.width - [selectButton frame].size.width) / 2,
                (screenFrame.size.height - [selectButton frame].size.height) / 2 + 15  // Slightly above center
            );
            [selectButton setFrameOrigin:buttonCenter];
            
            // Position screen icon above text label
            NSPoint iconCenter = NSMakePoint(
                (screenFrame.size.width - 96) / 2,  // Center horizontally (icon is 96px wide)
                buttonCenter.y + [selectButton frame].size.height + 60 + 10  // Above label + text height + margin
            );
            [screenIconView setFrameOrigin:iconCenter];
            
            // Add fast horizontal floating animation to screen icon
            CABasicAnimation *screenFloatAnimationX = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
            screenFloatAnimationX.fromValue = @(-4.0);
            screenFloatAnimationX.toValue = @(4.0);
            screenFloatAnimationX.duration = 1.2; // Much faster animation
            screenFloatAnimationX.repeatCount = HUGE_VALF;
            screenFloatAnimationX.autoreverses = YES;
            screenFloatAnimationX.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [screenIconView.layer addAnimation:screenFloatAnimationX forKey:@"floatAnimationX"];
            
            // Position info label at screen center, above button
            NSPoint labelCenter = NSMakePoint(
                (screenFrame.size.width - [screenInfoLabel frame].size.width) / 2,  // Center horizontally
                buttonCenter.y + [selectButton frame].size.height + 10  // 10px above button, below icon
            );
            [screenInfoLabel setFrameOrigin:labelCenter];
            
            NSPoint cancelButtonCenter = NSMakePoint(
                (screenFrame.size.width - [screenCancelButton frame].size.width) / 2,
                buttonCenter.y - [selectButton frame].size.height - 20  // 20px below main button
            );
            [screenCancelButton setFrameOrigin:cancelButtonCenter];
            
            [overlayView addSubview:screenIconView];
            [overlayView addSubview:screenInfoLabel];
            [overlayView addSubview:selectButton];
            [overlayView addSubview:screenCancelButton];
            
            // Ensure window frame is correct for this screen
            [overlayWindow setFrame:screenFrame display:YES animate:NO];
            
            // Show overlay - different strategy for secondary screens
            if (i == 0) {
                // Primary screen
                [overlayWindow makeKeyAndOrderFront:nil];
                // Primary screen overlay shown
            } else {
                // Secondary screens - more aggressive approach
                [overlayWindow orderFront:nil];
                [overlayWindow makeKeyAndOrderFront:nil]; // Try makeKey too
                [overlayWindow setLevel:CGWindowLevelForKey(kCGMaximumWindowLevelKey)]; // Match g_overlayWindow level
                
                // Secondary screen overlay shown
                
                // Double-check with delayed re-show
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [overlayWindow orderFront:nil];
                    [overlayWindow makeKeyAndOrderFront:nil];
                });
            }
            
            // Additional visibility settings
            [overlayWindow setAlphaValue:1.0];
            [overlayWindow setIsVisible:YES];
            
            // Overlay window is now ready and visible
            
            [g_screenOverlayWindows addObject:overlayWindow];
            [screenInfo release];
        }
        
        g_allScreens = [screenInfoArray retain];
        [screenInfoArray release];
        g_isScreenSelecting = true;
        g_currentActiveScreenIndex = -1;
        
        // Add ESC key event monitor to cancel selection
        g_screenKeyEventMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                                          handler:^(NSEvent *event) {
            if ([event keyCode] == 53) { // ESC key
                NSLog(@"🖥️ SCREEN SELECTION: ESC pressed - cancelling selection");
                cleanupScreenSelector();
            }
        }];
        
        // Start screen tracking timer to update overlays based on mouse position
        if (!g_delegate) {
            g_delegate = [[WindowSelectorDelegate alloc] init];
        }
        g_screenTrackingTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 // 20 FPS
                                                                target:g_delegate
                                                              selector:@selector(screenTimerUpdate:)
                                                              userInfo:nil
                                                               repeats:YES];
        
        // Initial update to set correct highlighting
        updateScreenOverlays();
        
        NSLog(@"🖥️ SCREEN SELECTION: Started with %lu screens (ESC to cancel)", (unsigned long)[screens count]);
        NSLog(@"🖥️ SCREEN TRACKING: Timer started for overlay updates");
        
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
            
            [overlayWindow setLevel:CGWindowLevelForKey(kCGMaximumWindowLevelKey)];
            [overlayWindow setOpaque:NO];
            [overlayWindow setBackgroundColor:[NSColor clearColor]];
            [overlayWindow setIgnoresMouseEvents:NO];
            [overlayWindow setAcceptsMouseMovedEvents:YES];
            [overlayWindow setHasShadow:NO];
            // no border
            [overlayWindow setStyleMask:NSWindowStyleMaskBorderless];
            [overlayWindow setAlphaValue:1.0];
            [overlayWindow setCollectionBehavior:NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorCanJoinAllSpaces];
            

            // Force content view to have no borders
            overlayWindow.contentView.wantsLayer = YES;
            overlayWindow.contentView.layer.borderWidth = 0.0;
            overlayWindow.contentView.layer.borderColor = [[NSColor clearColor] CGColor];
            overlayWindow.contentView.layer.cornerRadius = 0.0;
            overlayWindow.contentView.layer.masksToBounds = YES;

            // Remove any default window decorations and borders
            [overlayWindow setTitlebarAppearsTransparent:YES];
            [overlayWindow setTitleVisibility:NSWindowTitleHidden];
            [overlayWindow setMovable:NO];
            [overlayWindow setMovableByWindowBackground:NO];
            
            // Force remove all borders and decorations
            [overlayWindow setHasShadow:NO];
            [overlayWindow setOpaque:NO];
            [overlayWindow setBackgroundColor:[NSColor clearColor]];


            [overlayWindow orderFront:nil];
            [overlayWindow makeKeyAndOrderFront:nil];
            
            // Note: NSWindow doesn't have setWantsLayer method, only NSView does
            
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
        
        // Force completely borderless appearance
        [g_overlayWindow setStyleMask:NSWindowStyleMaskBorderless];
        
        [g_overlayWindow setLevel:CGWindowLevelForKey(kCGMaximumWindowLevelKey)]; // Absolute highest level
        [g_overlayWindow setOpaque:NO];
        [g_overlayWindow setBackgroundColor:[NSColor clearColor]];
        [g_overlayWindow setIgnoresMouseEvents:NO];
        [g_overlayWindow setAcceptsMouseMovedEvents:YES];
        [g_overlayWindow setHasShadow:NO];
        [g_overlayWindow setAlphaValue:1.0];
        [g_overlayWindow setCollectionBehavior:NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorCanJoinAllSpaces];
        
        // Remove any default window decorations and borders
        [g_overlayWindow setTitlebarAppearsTransparent:YES];
        [g_overlayWindow setTitleVisibility:NSWindowTitleHidden];
        [g_overlayWindow setMovable:NO];
        [g_overlayWindow setMovableByWindowBackground:NO];
        
        // Force remove all borders and decorations
        [g_overlayWindow setHasShadow:NO];
        [g_overlayWindow setOpaque:NO];
        [g_overlayWindow setBackgroundColor:[NSColor clearColor]];
        
        // Create overlay view
        g_overlayView = [[WindowSelectorOverlayView alloc] initWithFrame:initialFrame];
        [g_overlayWindow setContentView:g_overlayView];
        
        // Note: NSWindow doesn't have setWantsLayer method, only NSView does
        
        // Force content view to have no borders
        g_overlayWindow.contentView.wantsLayer = YES;
        g_overlayWindow.contentView.layer.borderWidth = 0.0;
        g_overlayWindow.contentView.layer.borderColor = [[NSColor clearColor] CGColor];
        g_overlayWindow.contentView.layer.cornerRadius = 0.0;
        g_overlayWindow.contentView.layer.masksToBounds = YES;
        
        // Additional window styling to ensure no borders or decorations
        [g_overlayWindow setMovable:NO];
        [g_overlayWindow setMovableByWindowBackground:NO];
        
        // Create select button with purple theme
        g_selectButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 200, 60)];
        [g_selectButton setTitle:@"Start Record"];
        [g_selectButton setButtonType:NSButtonTypeMomentaryPushIn];
        [g_selectButton setBordered:NO];
        [g_selectButton setFont:[NSFont systemFontOfSize:16 weight:NSFontWeightRegular]];
        
        // Modern button styling with new RGB color
        [g_selectButton setWantsLayer:YES];
        [g_selectButton.layer setBackgroundColor:[[NSColor colorWithRed:77.0/255.0 green:30.0/255.0 blue:231.0/255.0 alpha:0.95] CGColor]];
        [g_selectButton.layer setCornerRadius:8.0];
        [g_selectButton.layer setBorderWidth:0.0];
        
        // Remove all button borders and decorations
        [g_selectButton.layer setShadowOpacity:0.0];
        [g_selectButton.layer setShadowRadius:0.0];
        [g_selectButton.layer setShadowOffset:NSMakeSize(0, 0)];
        [g_selectButton.layer setMasksToBounds:YES];
        [g_selectButton.layer setBorderWidth:0.0];
        [g_selectButton.layer setBorderColor:[[NSColor clearColor] CGColor]];
        
        // Clean white text - normal weight
        NSMutableAttributedString *titleString = [[NSMutableAttributedString alloc] 
            initWithString:[g_selectButton title]];
        [titleString addAttribute:NSForegroundColorAttributeName 
                            value:[NSColor whiteColor] 
                            range:NSMakeRange(0, [titleString length])];
        [g_selectButton setAttributedTitle:titleString];
        
        // Create delegate for button action and timer
        g_delegate = [[WindowSelectorDelegate alloc] init];
        [g_selectButton setTarget:g_delegate];
        [g_selectButton setAction:@selector(selectButtonClicked:)];
        
        // Remove focus ring and other default button behaviors
        [g_selectButton setFocusRingType:NSFocusRingTypeNone];
        [g_selectButton setShowsBorderOnlyWhileMouseInside:NO];
        
        // Add select button directly to window (not view) for proper layering
        [g_overlayWindow.contentView addSubview:g_selectButton];
        
        // Create cancel button
        NSButton *cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 120, 40)];
        [cancelButton setTitle:@"Cancel"];
        [cancelButton setButtonType:NSButtonTypeMomentaryPushIn];
        [cancelButton setBordered:NO];
        [cancelButton setFont:[NSFont systemFontOfSize:14 weight:NSFontWeightRegular]];
        
        // Modern cancel button styling - darker gray, clean
        [cancelButton setWantsLayer:YES];
        [cancelButton.layer setBackgroundColor:[[NSColor colorWithRed:0.35 green:0.35 blue:0.4 alpha:0.9] CGColor]];
        [cancelButton.layer setCornerRadius:8.0];
        [cancelButton.layer setBorderWidth:0.0];
        
        // Remove all button borders and decorations
        [cancelButton.layer setShadowOpacity:0.0];
        [cancelButton.layer setShadowRadius:0.0];
        [cancelButton.layer setShadowOffset:NSMakeSize(0, 0)];
        [cancelButton.layer setMasksToBounds:YES];
        [cancelButton.layer setBorderWidth:0.0];
        [cancelButton.layer setBorderColor:[[NSColor clearColor] CGColor]];
        
        // Clean white text for cancel button
        NSMutableAttributedString *cancelTitleString = [[NSMutableAttributedString alloc] 
            initWithString:[cancelButton title]];
        [cancelTitleString addAttribute:NSForegroundColorAttributeName 
                            value:[NSColor whiteColor] 
                            range:NSMakeRange(0, [cancelTitleString length])];
        [cancelButton setAttributedTitle:cancelTitleString];
        
        [cancelButton setTarget:g_delegate];
        [cancelButton setAction:@selector(cancelButtonClicked:)];
        
        // Remove focus ring and other default button behaviors
        [cancelButton setFocusRingType:NSFocusRingTypeNone];
        [cancelButton setShowsBorderOnlyWhileMouseInside:NO];
        
        // Add cancel button to window
        [g_overlayWindow.contentView addSubview:cancelButton];
        
        // Force subviews (except overlay view itself) to have no borders
        for (NSView *subview in [g_overlayWindow.contentView subviews]) {
            // Skip the main overlay view - it handles its own borders
            if ([subview isKindOfClass:[WindowSelectorOverlayView class]]) continue;
            
            if ([subview respondsToSelector:@selector(setWantsLayer:)]) {
                [subview setWantsLayer:YES];
                if (subview.layer) {
                    subview.layer.borderWidth = 0.0;
                    subview.layer.borderColor = [[NSColor clearColor] CGColor];
                    subview.layer.masksToBounds = YES;
                    subview.layer.shadowOpacity = 0.0;
                    subview.layer.shadowRadius = 0.0;
                    subview.layer.shadowOffset = NSMakeSize(0, 0);
                }
            }
        }
        
        // Cancel button reference will be found dynamically in positioning code
        
        // Start tracking timer for real-time window detection
        if (!g_delegate) {
            g_delegate = [[WindowSelectorDelegate alloc] init];
        }
        g_trackingTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 // 20 FPS
                                                          target:g_delegate
                                                        selector:@selector(timerUpdate:)
                                                        userInfo:nil
                                                         repeats:YES];
        
        // Add ESC key event monitor to cancel selection
        g_windowKeyEventMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                                      handler:^(NSEvent *event) {
            if ([event keyCode] == 53) { // ESC key
                NSLog(@"🪟 WINDOW SELECTION: ESC pressed - cancelling selection");
                cleanupWindowSelector();
            }
        }];
        
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
        // Original CGWindow coordinates
        result.Set("x", Napi::Number::New(env, [[g_selectedWindowInfo objectForKey:@"x"] intValue]));
        result.Set("y", Napi::Number::New(env, [[g_selectedWindowInfo objectForKey:@"y"] intValue]));
        result.Set("width", Napi::Number::New(env, [[g_selectedWindowInfo objectForKey:@"width"] intValue]));
        result.Set("height", Napi::Number::New(env, [[g_selectedWindowInfo objectForKey:@"height"] intValue]));
        
        // Add overlay coordinates for direct use in recording
        // These are the exact coordinates used by the recording preview overlay
        int windowX = [[g_selectedWindowInfo objectForKey:@"x"] intValue];
        int windowY = [[g_selectedWindowInfo objectForKey:@"y"] intValue];
        int windowWidth = [[g_selectedWindowInfo objectForKey:@"width"] intValue];
        int windowHeight = [[g_selectedWindowInfo objectForKey:@"height"] intValue];
        
        result.Set("overlayX", Napi::Number::New(env, windowX));
        result.Set("overlayY", Napi::Number::New(env, windowY));
        result.Set("overlayWidth", Napi::Number::New(env, windowWidth));
        result.Set("overlayHeight", Napi::Number::New(env, windowHeight));
        
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
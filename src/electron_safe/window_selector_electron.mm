#import <napi.h>
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

// Thread-safe window selection for Electron
static dispatch_queue_t g_windowQueue = nil;

static void initializeWindowQueue() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_windowQueue = dispatch_queue_create("com.macrecorder.windows.electron", DISPATCH_QUEUE_SERIAL);
    });
}

// NAPI Function: Get Windows (Electron-safe)
Napi::Value GetWindowsElectronSafe(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        initializeWindowQueue();
        
        __block NSArray *windows = nil;
        
        dispatch_sync(g_windowQueue, ^{
            @try {
                NSMutableArray *windowList = [NSMutableArray array];
                
                if (@available(macOS 12.3, *)) {
                    // Use ScreenCaptureKit for modern macOS
                    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
                    
                    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
                        if (!error && content) {
                            for (SCWindow *window in content.windows) {
                                // Filter out system and small windows
                                if (window.frame.size.width < 50 || window.frame.size.height < 50) continue;
                                if (!window.title || window.title.length == 0) continue;
                                
                                NSString *appName = window.owningApplication.applicationName ?: @"Unknown";
                                
                                // Skip Electron windows (our overlay) and system windows
                                if ([appName containsString:@"Electron"] || 
                                    [appName containsString:@"node"] ||
                                    [appName containsString:@"WindowServer"] ||
                                    [appName containsString:@"Dock"]) continue;
                                
                                NSDictionary *windowInfo = @{
                                    @"id": @(window.windowID),
                                    @"name": window.title,
                                    @"appName": appName,
                                    @"bundleId": window.owningApplication.bundleIdentifier ?: @"",
                                    @"x": @((int)window.frame.origin.x),
                                    @"y": @((int)window.frame.origin.y),
                                    @"width": @((int)window.frame.size.width),
                                    @"height": @((int)window.frame.size.height),
                                    @"isOnScreen": @(window.isOnScreen),
                                    @"windowLayer": @(window.windowLayer)
                                };
                                
                                [windowList addObject:windowInfo];
                            }
                        }
                        dispatch_semaphore_signal(semaphore);
                    }];
                    
                    // Wait for completion with timeout
                    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
                    dispatch_semaphore_wait(semaphore, timeout);
                    
                } else {
                    // Fallback for older macOS versions using CGWindowListCopyWindowInfo
                    CFArrayRef windowListInfo = CGWindowListCopyWindowInfo(
                        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                        kCGNullWindowID
                    );
                    
                    if (windowListInfo) {
                        CFIndex count = CFArrayGetCount(windowListInfo);
                        
                        for (CFIndex i = 0; i < count; i++) {
                            CFDictionaryRef windowDict = (CFDictionaryRef)CFArrayGetValueAtIndex(windowListInfo, i);
                            
                            // Get window properties
                            CFNumberRef windowIDRef = (CFNumberRef)CFDictionaryGetValue(windowDict, kCGWindowNumber);
                            CFStringRef windowName = (CFStringRef)CFDictionaryGetValue(windowDict, kCGWindowName);
                            CFStringRef ownerName = (CFStringRef)CFDictionaryGetValue(windowDict, kCGWindowOwnerName);
                            CFDictionaryRef boundsDict = (CFDictionaryRef)CFDictionaryGetValue(windowDict, kCGWindowBounds);
                            
                            if (!windowIDRef || !ownerName) continue;
                            
                            uint32_t windowID;
                            CFNumberGetValue(windowIDRef, kCFNumberSInt32Type, &windowID);
                            
                            NSString *appName = (__bridge NSString*)ownerName;
                            NSString *windowTitle = windowName ? (__bridge NSString*)windowName : @"";
                            
                            // Skip Electron windows and system windows
                            if ([appName containsString:@"Electron"] || 
                                [appName containsString:@"node"] ||
                                [appName containsString:@"WindowServer"] ||
                                [appName containsString:@"Dock"]) continue;
                            
                            // Get window bounds
                            CGRect bounds = CGRectZero;
                            if (boundsDict) {
                                CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds);
                            }
                            
                            // Filter small windows
                            if (bounds.size.width < 50 || bounds.size.height < 50) continue;
                            
                            NSDictionary *windowInfo = @{
                                @"id": @(windowID),
                                @"name": windowTitle,
                                @"appName": appName,
                                @"bundleId": @"",
                                @"x": @((int)bounds.origin.x),
                                @"y": @((int)bounds.origin.y),
                                @"width": @((int)bounds.size.width),
                                @"height": @((int)bounds.size.height),
                                @"isOnScreen": @YES,
                                @"windowLayer": @0
                            };
                            
                            [windowList addObject:windowInfo];
                        }
                        
                        CFRelease(windowListInfo);
                    }
                }
                
                windows = [windowList copy];
                
            } @catch (NSException *e) {
                NSLog(@"❌ Exception getting windows: %@", e.reason);
                windows = @[];
            }
        });
        
        Napi::Array result = Napi::Array::New(env, windows ? windows.count : 0);
        
        if (windows) {
            for (NSUInteger i = 0; i < windows.count; i++) {
                NSDictionary *window = windows[i];
                Napi::Object windowObj = Napi::Object::New(env);
                
                windowObj.Set("id", Napi::Number::New(env, [window[@"id"] unsignedIntValue]));
                windowObj.Set("name", Napi::String::New(env, [window[@"name"] UTF8String]));
                windowObj.Set("appName", Napi::String::New(env, [window[@"appName"] UTF8String]));
                windowObj.Set("bundleId", Napi::String::New(env, [window[@"bundleId"] UTF8String]));
                windowObj.Set("x", Napi::Number::New(env, [window[@"x"] intValue]));
                windowObj.Set("y", Napi::Number::New(env, [window[@"y"] intValue]));
                windowObj.Set("width", Napi::Number::New(env, [window[@"width"] intValue]));
                windowObj.Set("height", Napi::Number::New(env, [window[@"height"] intValue]));
                windowObj.Set("isOnScreen", Napi::Boolean::New(env, [window[@"isOnScreen"] boolValue]));
                windowObj.Set("windowLayer", Napi::Number::New(env, [window[@"windowLayer"] intValue]));
                
                result.Set(i, windowObj);
            }
        }
        
        return result;
        
    } @catch (NSException *e) {
        NSLog(@"❌ Fatal exception in GetWindowsElectronSafe: %@", e.reason);
        Napi::Error::New(env, "Failed to get windows").ThrowAsJavaScriptException();
        return env.Null();
    }
}

// NAPI Function: Get Window Thumbnail (Electron-safe)
Napi::Value GetWindowThumbnailElectronSafe(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        if (info.Length() < 1) {
            Napi::TypeError::New(env, "Window ID required").ThrowAsJavaScriptException();
            return env.Null();
        }
        
        uint32_t windowID = info[0].As<Napi::Number>().Uint32Value();
        NSInteger maxWidth = 300;
        NSInteger maxHeight = 200;
        
        if (info.Length() > 1) {
            maxWidth = info[1].As<Napi::Number>().Int32Value();
        }
        if (info.Length() > 2) {
            maxHeight = info[2].As<Napi::Number>().Int32Value();
        }
        
        __block NSString *base64Result = nil;
        
        dispatch_sync(g_windowQueue, ^{
            @try {
                base64Result = [ElectronSafeScreenCapture getWindowThumbnailBase64:windowID 
                                                                           maxWidth:maxWidth 
                                                                          maxHeight:maxHeight];
            } @catch (NSException *e) {
                NSLog(@"❌ Exception getting window thumbnail: %@", e.reason);
            }
        });
        
        if (base64Result) {
            return Napi::String::New(env, [base64Result UTF8String]);
        } else {
            return env.Null();
        }
        
    } @catch (NSException *e) {
        NSLog(@"❌ Fatal exception in GetWindowThumbnailElectronSafe: %@", e.reason);
        Napi::Error::New(env, "Failed to get window thumbnail").ThrowAsJavaScriptException();
        return env.Null();
    }
}

// NAPI Function: Get Display Thumbnail (Electron-safe)
Napi::Value GetDisplayThumbnailElectronSafe(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        if (info.Length() < 1) {
            Napi::TypeError::New(env, "Display ID required").ThrowAsJavaScriptException();
            return env.Null();
        }
        
        CGDirectDisplayID displayID = info[0].As<Napi::Number>().Uint32Value();
        NSInteger maxWidth = 300;
        NSInteger maxHeight = 200;
        
        if (info.Length() > 1) {
            maxWidth = info[1].As<Napi::Number>().Int32Value();
        }
        if (info.Length() > 2) {
            maxHeight = info[2].As<Napi::Number>().Int32Value();
        }
        
        __block NSString *base64Result = nil;
        
        dispatch_sync(g_windowQueue, ^{
            @try {
                base64Result = [ElectronSafeScreenCapture getDisplayThumbnailBase64:displayID 
                                                                            maxWidth:maxWidth 
                                                                           maxHeight:maxHeight];
            } @catch (NSException *e) {
                NSLog(@"❌ Exception getting display thumbnail: %@", e.reason);
            }
        });
        
        if (base64Result) {
            return Napi::String::New(env, [base64Result UTF8String]);
        } else {
            return env.Null();
        }
        
    } @catch (NSException *e) {
        NSLog(@"❌ Fatal exception in GetDisplayThumbnailElectronSafe: %@", e.reason);
        Napi::Error::New(env, "Failed to get display thumbnail").ThrowAsJavaScriptException();
        return env.Null();
    }
}

// Initialize window selector module
Napi::Object InitWindowSelectorElectron(Napi::Env env, Napi::Object exports) {
    @try {
        initializeWindowQueue();
        
        exports.Set("getWindows", Napi::Function::New(env, GetWindowsElectronSafe));
        exports.Set("getWindowThumbnail", Napi::Function::New(env, GetWindowThumbnailElectronSafe));
        exports.Set("getDisplayThumbnail", Napi::Function::New(env, GetDisplayThumbnailElectronSafe));
        
        NSLog(@"✅ Electron-safe window selector initialized");
        return exports;
        
    } @catch (NSException *e) {
        NSLog(@"❌ Exception initializing window selector: %@", e.reason);
        return exports;
    }
}

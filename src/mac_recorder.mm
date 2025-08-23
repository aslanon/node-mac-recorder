#import <napi.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CoreAudio/CoreAudio.h>

// Import screen capture
#import "screen_capture.h"
#import "screen_capture_kit.h"

// Cursor tracker function declarations
Napi::Object InitCursorTracker(Napi::Env env, Napi::Object exports);

// Window selector function declarations  
Napi::Object InitWindowSelector(Napi::Env env, Napi::Object exports);

// Window selector overlay functions (external)
extern "C" void hideOverlays();
extern "C" void showOverlays();

@interface MacRecorderDelegate : NSObject <AVCaptureFileOutputRecordingDelegate>
@property (nonatomic, copy) void (^completionHandler)(NSURL *outputURL, NSError *error);
@end

@implementation MacRecorderDelegate
- (void)captureOutput:(AVCaptureFileOutput *)output
didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL
      fromConnections:(NSArray<AVCaptureConnection *> *)connections
                error:(NSError *)error {
    if (self.completionHandler) {
        self.completionHandler(outputFileURL, error);
    }
}
@end

// Global state for recording
static AVCaptureSession *g_captureSession = nil;
static AVCaptureMovieFileOutput *g_movieFileOutput = nil;
static AVCaptureScreenInput *g_screenInput = nil;
static AVCaptureDeviceInput *g_audioInput = nil;
static MacRecorderDelegate *g_delegate = nil;
static bool g_isRecording = false;

// Helper function to cleanup recording resources
void cleanupRecording() {
    // ScreenCaptureKit cleanup only
    if (@available(macOS 12.3, *)) {
        if ([ScreenCaptureKitRecorder isRecording]) {
            [ScreenCaptureKitRecorder stopRecording];
        }
    }
    g_isRecording = false;
}

// NAPI Function: Start Recording
Napi::Value StartRecording(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (info.Length() < 1) {
        Napi::TypeError::New(env, "Output path required").ThrowAsJavaScriptException();
        return env.Null();
    }
    
    if (g_isRecording) {
        return Napi::Boolean::New(env, false);
    }
    
    std::string outputPath = info[0].As<Napi::String>().Utf8Value();
    
    // Options parsing
    CGRect captureRect = CGRectNull;
    bool captureCursor = false; // Default olarak cursor gizli
    bool includeMicrophone = false; // Default olarak mikrofon kapalı
    bool includeSystemAudio = true; // Default olarak sistem sesi açık
    CGDirectDisplayID displayID = CGMainDisplayID(); // Default ana ekran
    NSString *audioDeviceId = nil; // Default audio device ID
    NSString *systemAudioDeviceId = nil; // System audio device ID
    
    if (info.Length() > 1 && info[1].IsObject()) {
        Napi::Object options = info[1].As<Napi::Object>();
        
        // Capture area
        if (options.Has("captureArea") && options.Get("captureArea").IsObject()) {
            Napi::Object rectObj = options.Get("captureArea").As<Napi::Object>();
            if (rectObj.Has("x") && rectObj.Has("y") && rectObj.Has("width") && rectObj.Has("height")) {
                captureRect = CGRectMake(
                    rectObj.Get("x").As<Napi::Number>().DoubleValue(),
                    rectObj.Get("y").As<Napi::Number>().DoubleValue(),
                    rectObj.Get("width").As<Napi::Number>().DoubleValue(),
                    rectObj.Get("height").As<Napi::Number>().DoubleValue()
                );
            }
        }
        
        // Capture cursor
        if (options.Has("captureCursor")) {
            captureCursor = options.Get("captureCursor").As<Napi::Boolean>();
        }
        
        // Microphone
        if (options.Has("includeMicrophone")) {
            includeMicrophone = options.Get("includeMicrophone").As<Napi::Boolean>();
        }
        
        // Audio device ID
        if (options.Has("audioDeviceId") && !options.Get("audioDeviceId").IsNull()) {
            std::string deviceId = options.Get("audioDeviceId").As<Napi::String>().Utf8Value();
            audioDeviceId = [NSString stringWithUTF8String:deviceId.c_str()];
        }
        
        // System audio
        if (options.Has("includeSystemAudio")) {
            includeSystemAudio = options.Get("includeSystemAudio").As<Napi::Boolean>();
        }
        
        // System audio device ID
        if (options.Has("systemAudioDeviceId") && !options.Get("systemAudioDeviceId").IsNull()) {
            std::string sysDeviceId = options.Get("systemAudioDeviceId").As<Napi::String>().Utf8Value();
            systemAudioDeviceId = [NSString stringWithUTF8String:sysDeviceId.c_str()];
        }
        
        // Display ID
        if (options.Has("displayId") && !options.Get("displayId").IsNull()) {
            double displayIdNum = options.Get("displayId").As<Napi::Number>().DoubleValue();
            
            // Use the display ID directly (not as an index)
            // The JavaScript layer passes the actual CGDirectDisplayID
            displayID = (CGDirectDisplayID)displayIdNum;
            
            // Verify that this display ID is valid
            uint32_t displayCount;
            CGGetActiveDisplayList(0, NULL, &displayCount);
            if (displayCount > 0) {
                CGDirectDisplayID *displays = (CGDirectDisplayID*)malloc(displayCount * sizeof(CGDirectDisplayID));
                CGGetActiveDisplayList(displayCount, displays, &displayCount);
                
                bool validDisplay = false;
                for (uint32_t i = 0; i < displayCount; i++) {
                    if (displays[i] == displayID) {
                        validDisplay = true;
                        break;
                    }
                }
                
                if (!validDisplay) {
                    // Fallback to main display if invalid ID provided
                    displayID = CGMainDisplayID();
                }
                
                free(displays);
            }
        }
        
        // Window ID için gelecekte kullanım (şimdilik captureArea ile hallediliyor)
        if (options.Has("windowId") && !options.Get("windowId").IsNull()) {
            // WindowId belirtilmiş ama captureArea JavaScript tarafında ayarlanıyor
            // Bu parametre gelecekte native level pencere seçimi için kullanılabilir
        }
    }
    
    @try {
        // Smart Recording Selection: ScreenCaptureKit vs Alternative
        NSLog(@"🎯 Smart Recording Engine Selection");
        
        // Detect Electron environment with multiple checks
        BOOL isElectron = (NSBundle.mainBundle.bundleIdentifier && 
                          [NSBundle.mainBundle.bundleIdentifier containsString:@"electron"]) ||
                         (NSProcessInfo.processInfo.processName && 
                          [NSProcessInfo.processInfo.processName containsString:@"Electron"]) ||
                         (NSProcessInfo.processInfo.environment[@"ELECTRON_RUN_AS_NODE"] != nil) ||
                         (NSBundle.mainBundle.bundlePath && 
                          [NSBundle.mainBundle.bundlePath containsString:@"Electron"]);
        
        if (isElectron) {
            NSLog(@"⚡ Electron environment detected - Using crash-safe recording method");
            NSLog(@"🛡️ ScreenCaptureKit disabled for Electron stability");
            
            // Return error for Electron - force use of external recording tools
            return Napi::Boolean::New(env, false);
        }
        
        // Non-Electron: Use ScreenCaptureKit
        if (@available(macOS 12.3, *)) {
            NSLog(@"✅ macOS 12.3+ detected - ScreenCaptureKit should be available");
            
            // Try ScreenCaptureKit with extensive safety measures
            @try {
                if ([ScreenCaptureKitRecorder isScreenCaptureKitAvailable]) {
                    NSLog(@"✅ ScreenCaptureKit availability check passed");
                    NSLog(@"🎯 Using ScreenCaptureKit - overlay windows will be automatically excluded");
                    
                    // Create configuration for ScreenCaptureKit
                NSMutableDictionary *sckConfig = [NSMutableDictionary dictionary];
                sckConfig[@"displayId"] = @(displayID);
                sckConfig[@"captureCursor"] = @(captureCursor);
                sckConfig[@"includeSystemAudio"] = @(includeSystemAudio);
                sckConfig[@"includeMicrophone"] = @(includeMicrophone);
                sckConfig[@"audioDeviceId"] = audioDeviceId;
                sckConfig[@"outputPath"] = [NSString stringWithUTF8String:outputPath.c_str()];
                
                if (!CGRectIsNull(captureRect)) {
                    sckConfig[@"captureRect"] = @{
                        @"x": @(captureRect.origin.x),
                        @"y": @(captureRect.origin.y),
                        @"width": @(captureRect.size.width),
                        @"height": @(captureRect.size.height)
                    };
                }
                
                    // Use ScreenCaptureKit with window exclusion and timeout protection
                    NSError *sckError = nil;
                    
                    // Set timeout for ScreenCaptureKit initialization
                    __block BOOL sckStarted = NO;
                    __block BOOL sckTimedOut = NO;
                    
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), 
                                  dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        if (!sckStarted && !g_isRecording) {
                            sckTimedOut = YES;
                            NSLog(@"⏰ ScreenCaptureKit initialization timeout (3s)");
                        }
                    });
                    
                    // Attempt to start ScreenCaptureKit with safety wrapper
                    @try {
                        if ([ScreenCaptureKitRecorder startRecordingWithConfiguration:sckConfig 
                                                                             delegate:g_delegate 
                                                                                error:&sckError]) {
                            
                            // ScreenCaptureKit başlatma başarılı - validation yapmıyoruz
                            sckStarted = YES;
                            NSLog(@"🎬 RECORDING METHOD: ScreenCaptureKit");
                            NSLog(@"✅ ScreenCaptureKit recording started successfully");
                            g_isRecording = true;
                            return Napi::Boolean::New(env, true);
                        } else {
                            NSLog(@"❌ ScreenCaptureKit failed to start");
                            NSLog(@"❌ Error: %@", sckError ? sckError.localizedDescription : @"Unknown error");
                        }
                    } @catch (NSException *sckException) {
                        NSLog(@"❌ Exception during ScreenCaptureKit startup: %@", sckException.reason);
                    }
                    
                    NSLog(@"⚠️ ScreenCaptureKit failed or unsafe - falling back to AVFoundation");
                    
                } else {
                    NSLog(@"❌ ScreenCaptureKit availability check failed");
                    NSLog(@"⚠️ Falling back to AVFoundation");
                }
            } @catch (NSException *availabilityException) {
                NSLog(@"❌ Exception during ScreenCaptureKit availability check: %@", availabilityException.reason);
                return Napi::Boolean::New(env, false);
            }
        } else {
            NSLog(@"❌ macOS version too old for ScreenCaptureKit (< 12.3) - Recording not supported");
            return Napi::Boolean::New(env, false);
        }
        
        // If we get here, ScreenCaptureKit failed completely
        NSLog(@"❌ ScreenCaptureKit failed to initialize - Recording not available");
        return Napi::Boolean::New(env, false);
        
    } @catch (NSException *exception) {
        cleanupRecording();
        return Napi::Boolean::New(env, false);
    }
}

// NAPI Function: Stop Recording
Napi::Value StopRecording(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    NSLog(@"📞 StopRecording native method called");
    
    // ScreenCaptureKit ONLY - No AVFoundation fallback
    if (@available(macOS 12.3, *)) {
        if ([ScreenCaptureKitRecorder isRecording]) {
            NSLog(@"🛑 Stopping ScreenCaptureKit recording");
            [ScreenCaptureKitRecorder stopRecording];
            g_isRecording = false;
            return Napi::Boolean::New(env, true);
        } else {
            NSLog(@"⚠️ ScreenCaptureKit not recording");
            g_isRecording = false;
            return Napi::Boolean::New(env, true);
        }
    } else {
        NSLog(@"❌ ScreenCaptureKit not available - cannot stop recording");
        return Napi::Boolean::New(env, false);
    }
}



// NAPI Function: Get Windows List
Napi::Value GetWindows(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    Napi::Array windowArray = Napi::Array::New(env);
    
    @try {
        // Get window list
        CFArrayRef windowList = CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID
        );
        
        if (!windowList) {
            return windowArray;
        }
        
        CFIndex windowCount = CFArrayGetCount(windowList);
        uint32_t arrayIndex = 0;
        
        for (CFIndex i = 0; i < windowCount; i++) {
            CFDictionaryRef window = (CFDictionaryRef)CFArrayGetValueAtIndex(windowList, i);
            
            // Get window ID
            CFNumberRef windowIDRef = (CFNumberRef)CFDictionaryGetValue(window, kCGWindowNumber);
            if (!windowIDRef) continue;
            
            uint32_t windowID;
            CFNumberGetValue(windowIDRef, kCFNumberSInt32Type, &windowID);
            
            // Get window name
            CFStringRef windowNameRef = (CFStringRef)CFDictionaryGetValue(window, kCGWindowName);
            std::string windowName = "";
            if (windowNameRef) {
                const char* windowNameCStr = CFStringGetCStringPtr(windowNameRef, kCFStringEncodingUTF8);
                if (windowNameCStr) {
                    windowName = std::string(windowNameCStr);
                } else {
                    // Fallback for non-ASCII characters
                    CFIndex length = CFStringGetLength(windowNameRef);
                    CFIndex maxSize = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
                    char* buffer = (char*)malloc(maxSize);
                    if (CFStringGetCString(windowNameRef, buffer, maxSize, kCFStringEncodingUTF8)) {
                        windowName = std::string(buffer);
                    }
                    free(buffer);
                }
            }
            
            // Get application name
            CFStringRef appNameRef = (CFStringRef)CFDictionaryGetValue(window, kCGWindowOwnerName);
            std::string appName = "";
            if (appNameRef) {
                const char* appNameCStr = CFStringGetCStringPtr(appNameRef, kCFStringEncodingUTF8);
                if (appNameCStr) {
                    appName = std::string(appNameCStr);
                } else {
                    CFIndex length = CFStringGetLength(appNameRef);
                    CFIndex maxSize = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
                    char* buffer = (char*)malloc(maxSize);
                    if (CFStringGetCString(appNameRef, buffer, maxSize, kCFStringEncodingUTF8)) {
                        appName = std::string(buffer);
                    }
                    free(buffer);
                }
            }
            
            // Get window bounds
            CFDictionaryRef boundsRef = (CFDictionaryRef)CFDictionaryGetValue(window, kCGWindowBounds);
            CGRect bounds = CGRectZero;
            if (boundsRef) {
                CGRectMakeWithDictionaryRepresentation(boundsRef, &bounds);
            }
            
            // Skip windows without name or very small windows
            if (windowName.empty() || bounds.size.width < 50 || bounds.size.height < 50) {
                continue;
            }
            
            // Create window object
            Napi::Object windowObj = Napi::Object::New(env);
            windowObj.Set("id", Napi::Number::New(env, windowID));
            windowObj.Set("name", Napi::String::New(env, windowName));
            windowObj.Set("appName", Napi::String::New(env, appName));
            windowObj.Set("x", Napi::Number::New(env, bounds.origin.x));
            windowObj.Set("y", Napi::Number::New(env, bounds.origin.y));
            windowObj.Set("width", Napi::Number::New(env, bounds.size.width));
            windowObj.Set("height", Napi::Number::New(env, bounds.size.height));
            
            windowArray.Set(arrayIndex++, windowObj);
        }
        
        CFRelease(windowList);
        return windowArray;
        
    } @catch (NSException *exception) {
        return windowArray;
    }
}

// NAPI Function: Get Audio Devices
Napi::Value GetAudioDevices(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        NSMutableArray *devices = [NSMutableArray array];
        
        // Get all audio devices
        NSArray *audioDevices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
        
        for (AVCaptureDevice *device in audioDevices) {
            [devices addObject:@{
                @"id": device.uniqueID,
                @"name": device.localizedName,
                @"manufacturer": device.manufacturer ?: @"Unknown",
                @"isDefault": @([device isEqual:[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio]])
            }];
        }
        
        // Convert to NAPI array
        Napi::Array result = Napi::Array::New(env, devices.count);
        for (NSUInteger i = 0; i < devices.count; i++) {
            NSDictionary *device = devices[i];
            Napi::Object deviceObj = Napi::Object::New(env);
            deviceObj.Set("id", Napi::String::New(env, [device[@"id"] UTF8String]));
            deviceObj.Set("name", Napi::String::New(env, [device[@"name"] UTF8String]));
            deviceObj.Set("manufacturer", Napi::String::New(env, [device[@"manufacturer"] UTF8String]));
            deviceObj.Set("isDefault", Napi::Boolean::New(env, [device[@"isDefault"] boolValue]));
            result[i] = deviceObj;
        }
        
        return result;
        
    } @catch (NSException *exception) {
        return Napi::Array::New(env, 0);
    }
}

// NAPI Function: Get Displays
Napi::Value GetDisplays(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        NSArray *displays = [ScreenCapture getAvailableDisplays];
        Napi::Array result = Napi::Array::New(env, displays.count);
        
        NSLog(@"Found %lu displays", (unsigned long)displays.count);
        
        for (NSUInteger i = 0; i < displays.count; i++) {
            NSDictionary *display = displays[i];
            NSLog(@"Display %lu: ID=%u, Name=%@, Size=%@x%@", 
                  (unsigned long)i,
                  [display[@"id"] unsignedIntValue],
                  display[@"name"],
                  display[@"width"],
                  display[@"height"]);
                  
            Napi::Object displayObj = Napi::Object::New(env);
            displayObj.Set("id", Napi::Number::New(env, [display[@"id"] unsignedIntValue]));
            displayObj.Set("name", Napi::String::New(env, [display[@"name"] UTF8String]));
            displayObj.Set("width", Napi::Number::New(env, [display[@"width"] doubleValue]));
            displayObj.Set("height", Napi::Number::New(env, [display[@"height"] doubleValue]));
            displayObj.Set("x", Napi::Number::New(env, [display[@"x"] doubleValue]));
            displayObj.Set("y", Napi::Number::New(env, [display[@"y"] doubleValue]));
            displayObj.Set("isPrimary", Napi::Boolean::New(env, [display[@"isPrimary"] boolValue]));
            result[i] = displayObj;
        }
        
        return result;
        
    } @catch (NSException *exception) {
        NSLog(@"Exception in GetDisplays: %@", exception);
        return Napi::Array::New(env, 0);
    }
}

// NAPI Function: Get Recording Status
Napi::Value GetRecordingStatus(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    return Napi::Boolean::New(env, g_isRecording);
}

// NAPI Function: Get Window Thumbnail
Napi::Value GetWindowThumbnail(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (info.Length() < 1) {
        Napi::TypeError::New(env, "Window ID is required").ThrowAsJavaScriptException();
        return env.Null();
    }
    
    uint32_t windowID = info[0].As<Napi::Number>().Uint32Value();
    
    // Optional parameters
    int maxWidth = 300;  // Default thumbnail width
    int maxHeight = 200; // Default thumbnail height
    
    if (info.Length() >= 2 && !info[1].IsNull()) {
        maxWidth = info[1].As<Napi::Number>().Int32Value();
    }
    if (info.Length() >= 3 && !info[2].IsNull()) {
        maxHeight = info[2].As<Napi::Number>().Int32Value();
    }
    
    @try {
        // Create window image
        CGImageRef windowImage = CGWindowListCreateImage(
            CGRectNull,
            kCGWindowListOptionIncludingWindow,
            windowID,
            kCGWindowImageBoundsIgnoreFraming | kCGWindowImageShouldBeOpaque
        );
        
        if (!windowImage) {
            return env.Null();
        }
        
        // Get original dimensions
        size_t originalWidth = CGImageGetWidth(windowImage);
        size_t originalHeight = CGImageGetHeight(windowImage);
        
        // Calculate scaled dimensions maintaining aspect ratio
        double scaleX = (double)maxWidth / originalWidth;
        double scaleY = (double)maxHeight / originalHeight;
        double scale = std::min(scaleX, scaleY);
        
        size_t thumbnailWidth = (size_t)(originalWidth * scale);
        size_t thumbnailHeight = (size_t)(originalHeight * scale);
        
        // Create scaled image
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(
            NULL,
            thumbnailWidth,
            thumbnailHeight,
            8,
            thumbnailWidth * 4,
            colorSpace,
            kCGImageAlphaPremultipliedLast
        );
        
        if (context) {
            CGContextDrawImage(context, CGRectMake(0, 0, thumbnailWidth, thumbnailHeight), windowImage);
            CGImageRef thumbnailImage = CGBitmapContextCreateImage(context);
            
            if (thumbnailImage) {
                // Convert to PNG data
                NSBitmapImageRep *imageRep = [[NSBitmapImageRep alloc] initWithCGImage:thumbnailImage];
                NSData *pngData = [imageRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                
                if (pngData) {
                    // Convert to Base64
                    NSString *base64String = [pngData base64EncodedStringWithOptions:0];
                    std::string base64Std = [base64String UTF8String];
                    
                    CGImageRelease(thumbnailImage);
                    CGContextRelease(context);
                    CGColorSpaceRelease(colorSpace);
                    CGImageRelease(windowImage);
                    
                    return Napi::String::New(env, base64Std);
                }
                
                CGImageRelease(thumbnailImage);
            }
            
            CGContextRelease(context);
        }
        
        CGColorSpaceRelease(colorSpace);
        CGImageRelease(windowImage);
        
        return env.Null();
        
    } @catch (NSException *exception) {
        return env.Null();
    }
}

// NAPI Function: Get Display Thumbnail
Napi::Value GetDisplayThumbnail(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (info.Length() < 1) {
        Napi::TypeError::New(env, "Display ID is required").ThrowAsJavaScriptException();
        return env.Null();
    }
    
    uint32_t displayID = info[0].As<Napi::Number>().Uint32Value();
    
    // Optional parameters
    int maxWidth = 300;  // Default thumbnail width
    int maxHeight = 200; // Default thumbnail height
    
    if (info.Length() >= 2 && !info[1].IsNull()) {
        maxWidth = info[1].As<Napi::Number>().Int32Value();
    }
    if (info.Length() >= 3 && !info[2].IsNull()) {
        maxHeight = info[2].As<Napi::Number>().Int32Value();
    }
    
    @try {
        // Verify display exists
        CGDirectDisplayID activeDisplays[32];
        uint32_t displayCount;
        CGError err = CGGetActiveDisplayList(32, activeDisplays, &displayCount);
        
        if (err != kCGErrorSuccess) {
            NSLog(@"Failed to get active display list: %d", err);
            return env.Null();
        }
        
        bool displayFound = false;
        for (uint32_t i = 0; i < displayCount; i++) {
            if (activeDisplays[i] == displayID) {
                displayFound = true;
                break;
            }
        }
        
        if (!displayFound) {
            NSLog(@"Display ID %u not found in active displays", displayID);
            return env.Null();
        }
        
        // Create display image
        CGImageRef displayImage = CGDisplayCreateImage(displayID);
        
        if (!displayImage) {
            NSLog(@"CGDisplayCreateImage failed for display ID: %u", displayID);
            return env.Null();
        }
        
        // Get original dimensions
        size_t originalWidth = CGImageGetWidth(displayImage);
        size_t originalHeight = CGImageGetHeight(displayImage);
        
        NSLog(@"Original dimensions: %zux%zu", originalWidth, originalHeight);
        
        // Calculate scaled dimensions maintaining aspect ratio
        double scaleX = (double)maxWidth / originalWidth;
        double scaleY = (double)maxHeight / originalHeight;
        double scale = std::min(scaleX, scaleY);
        
        size_t thumbnailWidth = (size_t)(originalWidth * scale);
        size_t thumbnailHeight = (size_t)(originalHeight * scale);
        
        NSLog(@"Thumbnail dimensions: %zux%zu (scale: %f)", thumbnailWidth, thumbnailHeight, scale);
        
        // Create scaled image
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(
            NULL,
            thumbnailWidth,
            thumbnailHeight,
            8,
            thumbnailWidth * 4,
            colorSpace,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
        );
        
        if (!context) {
            NSLog(@"Failed to create bitmap context");
            CGImageRelease(displayImage);
            CGColorSpaceRelease(colorSpace);
            return env.Null();
        }
        
        // Set interpolation quality for better scaling
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        
        // Draw the image
        CGContextDrawImage(context, CGRectMake(0, 0, thumbnailWidth, thumbnailHeight), displayImage);
        CGImageRef thumbnailImage = CGBitmapContextCreateImage(context);
        
        if (!thumbnailImage) {
            NSLog(@"Failed to create thumbnail image");
            CGContextRelease(context);
            CGImageRelease(displayImage);
            CGColorSpaceRelease(colorSpace);
            return env.Null();
        }
        
        // Convert to PNG data
        NSBitmapImageRep *imageRep = [[NSBitmapImageRep alloc] initWithCGImage:thumbnailImage];
        NSDictionary *properties = @{NSImageCompressionFactor: @0.8};
        NSData *pngData = [imageRep representationUsingType:NSBitmapImageFileTypePNG properties:properties];
        
        if (!pngData) {
            NSLog(@"Failed to convert image to PNG data");
            CGImageRelease(thumbnailImage);
            CGContextRelease(context);
            CGImageRelease(displayImage);
            CGColorSpaceRelease(colorSpace);
            return env.Null();
        }
        
        // Convert to Base64
        NSString *base64String = [pngData base64EncodedStringWithOptions:0];
        std::string base64Std = [base64String UTF8String];
        
        NSLog(@"Successfully created thumbnail with base64 length: %lu", (unsigned long)base64Std.length());
        
        // Cleanup
        CGImageRelease(thumbnailImage);
        CGContextRelease(context);
        CGColorSpaceRelease(colorSpace);
        CGImageRelease(displayImage);
        
        return Napi::String::New(env, base64Std);
        
    } @catch (NSException *exception) {
        NSLog(@"Exception in GetDisplayThumbnail: %@", exception);
        return env.Null();
    }
}

// NAPI Function: Check Permissions
Napi::Value CheckPermissions(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        // Check screen recording permission
        bool hasScreenPermission = true;
        
        if (@available(macOS 10.15, *)) {
            // Try to create a display stream to test permissions
            CGDisplayStreamRef stream = CGDisplayStreamCreate(
                CGMainDisplayID(), 
                1, 1, 
                kCVPixelFormatType_32BGRA, 
                nil, 
                ^(CGDisplayStreamFrameStatus status, uint64_t displayTime, IOSurfaceRef frameSurface, CGDisplayStreamUpdateRef updateRef) {
                    // Empty handler
                }
            );
            
            if (stream) {
                CFRelease(stream);
                hasScreenPermission = true;
            } else {
                hasScreenPermission = false;
            }
        }
        
        // Check audio permission
        bool hasAudioPermission = true;
        if (@available(macOS 10.14, *)) {
            AVAuthorizationStatus audioStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
            hasAudioPermission = (audioStatus == AVAuthorizationStatusAuthorized);
        }
        
        return Napi::Boolean::New(env, hasScreenPermission && hasAudioPermission);
        
    } @catch (NSException *exception) {
        return Napi::Boolean::New(env, false);
    }
}

// Initialize NAPI Module
Napi::Object Init(Napi::Env env, Napi::Object exports) {
    exports.Set(Napi::String::New(env, "startRecording"), Napi::Function::New(env, StartRecording));
    exports.Set(Napi::String::New(env, "stopRecording"), Napi::Function::New(env, StopRecording));

    exports.Set(Napi::String::New(env, "getAudioDevices"), Napi::Function::New(env, GetAudioDevices));
    exports.Set(Napi::String::New(env, "getDisplays"), Napi::Function::New(env, GetDisplays));
    exports.Set(Napi::String::New(env, "getWindows"), Napi::Function::New(env, GetWindows));
    exports.Set(Napi::String::New(env, "getRecordingStatus"), Napi::Function::New(env, GetRecordingStatus));
    exports.Set(Napi::String::New(env, "checkPermissions"), Napi::Function::New(env, CheckPermissions));
    
    // Thumbnail functions
    exports.Set(Napi::String::New(env, "getWindowThumbnail"), Napi::Function::New(env, GetWindowThumbnail));
    exports.Set(Napi::String::New(env, "getDisplayThumbnail"), Napi::Function::New(env, GetDisplayThumbnail));
    
    // Initialize cursor tracker
    InitCursorTracker(env, exports);
    
    // Initialize window selector
    InitWindowSelector(env, exports);
    
    return exports;
}

NODE_API_MODULE(mac_recorder, Init) 
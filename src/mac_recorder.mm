#import <napi.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
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

@interface MacRecorderDelegate : NSObject
@property (nonatomic, copy) void (^completionHandler)(NSURL *outputURL, NSError *error);
@end

@implementation MacRecorderDelegate
- (void)recordingDidStart {
    NSLog(@"[mac_recorder] ScreenCaptureKit recording started");
}
- (void)recordingDidFinish:(NSURL *)outputURL error:(NSError *)error {
    if (error) {
        NSLog(@"[mac_recorder] ScreenCaptureKit recording finished with error: %@", error.localizedDescription);
    } else {
        NSLog(@"[mac_recorder] ScreenCaptureKit recording finished OK → %@", outputURL.path);
    }
    if (self.completionHandler) {
        self.completionHandler(outputURL, error);
    }
}
@end

// Global state for recording
static MacRecorderDelegate *g_delegate = nil;
static bool g_isRecording = false;

// Helper function to cleanup recording resources
void cleanupRecording() {
    g_delegate = nil;
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
    NSLog(@"[mac_recorder] StartRecording: output=%@", [NSString stringWithUTF8String:outputPath.c_str()]);
    
    // Options parsing (shared)
    CGRect captureRect = CGRectNull;
    bool captureCursor = false; // Default olarak cursor gizli
    bool includeMicrophone = false; // Default olarak mikrofon kapalı
    bool includeSystemAudio = true; // Default olarak sistem sesi açık
    CGDirectDisplayID displayID = CGMainDisplayID(); // Default ana ekran
    NSString *audioDeviceId = nil; // Default audio device ID
    NSString *systemAudioDeviceId = nil; // System audio device ID
    bool forceUseSC = false;
    // Exclude options for ScreenCaptureKit (optional, backward compatible)
    NSMutableArray<NSString*> *excludedAppBundleIds = [NSMutableArray array];
    NSMutableArray<NSNumber*> *excludedPIDs = [NSMutableArray array];
    NSMutableArray<NSNumber*> *excludedWindowIds = [NSMutableArray array];
    bool autoExcludeSelf = false;
    
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

        // ScreenCaptureKit toggle (optional)
        if (options.Has("useScreenCaptureKit")) {
            forceUseSC = options.Get("useScreenCaptureKit").As<Napi::Boolean>();
        }

        // Exclusion lists (optional)
        if (options.Has("excludedAppBundleIds") && options.Get("excludedAppBundleIds").IsArray()) {
            Napi::Array arr = options.Get("excludedAppBundleIds").As<Napi::Array>();
            for (uint32_t i = 0; i < arr.Length(); i++) {
                if (!arr.Get(i).IsUndefined() && !arr.Get(i).IsNull()) {
                    std::string s = arr.Get(i).As<Napi::String>().Utf8Value();
                    [excludedAppBundleIds addObject:[NSString stringWithUTF8String:s.c_str()]];
                }
            }
        }
        if (options.Has("excludedPIDs") && options.Get("excludedPIDs").IsArray()) {
            Napi::Array arr = options.Get("excludedPIDs").As<Napi::Array>();
            for (uint32_t i = 0; i < arr.Length(); i++) {
                if (!arr.Get(i).IsUndefined() && !arr.Get(i).IsNull()) {
                    double v = arr.Get(i).As<Napi::Number>().DoubleValue();
                    [excludedPIDs addObject:@( (pid_t)v )];
                }
            }
        }
        if (options.Has("excludedWindowIds") && options.Get("excludedWindowIds").IsArray()) {
            Napi::Array arr = options.Get("excludedWindowIds").As<Napi::Array>();
            for (uint32_t i = 0; i < arr.Length(); i++) {
                if (!arr.Get(i).IsUndefined() && !arr.Get(i).IsNull()) {
                    double v = arr.Get(i).As<Napi::Number>().DoubleValue();
                    [excludedWindowIds addObject:@( (uint32_t)v )];
                }
            }
        }
        if (options.Has("autoExcludeSelf")) {
            autoExcludeSelf = options.Get("autoExcludeSelf").As<Napi::Boolean>();
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
        // Always prefer ScreenCaptureKit if available
        NSLog(@"[mac_recorder] Checking ScreenCaptureKit availability");
        if (@available(macOS 12.3, *)) {
            if ([ScreenCaptureKitRecorder isScreenCaptureKitAvailable]) {
            NSMutableDictionary *scConfig = [@{} mutableCopy];
            scConfig[@"displayId"] = @(displayID);
            if (!CGRectIsNull(captureRect)) {
                scConfig[@"captureArea"] = @{ @"x": @(captureRect.origin.x),
                                               @"y": @(captureRect.origin.y),
                                               @"width": @(captureRect.size.width),
                                               @"height": @(captureRect.size.height) };
            }
            scConfig[@"captureCursor"] = @(captureCursor);
            scConfig[@"includeMicrophone"] = @(includeMicrophone);
            scConfig[@"includeSystemAudio"] = @(includeSystemAudio);
            if (excludedAppBundleIds.count) scConfig[@"excludedAppBundleIds"] = excludedAppBundleIds;
            if (excludedPIDs.count) scConfig[@"excludedPIDs"] = excludedPIDs;
            if (excludedWindowIds.count) scConfig[@"excludedWindowIds"] = excludedWindowIds;
            // Auto exclude current app by PID if requested
            if (autoExcludeSelf) {
                pid_t pid = getpid();
                NSMutableArray *arr = [NSMutableArray arrayWithArray:scConfig[@"excludedPIDs"] ?: @[]];
                [arr addObject:@(pid)];
                scConfig[@"excludedPIDs"] = arr;
            }

            // Output path for SC
            std::string outputPathStr = info[0].As<Napi::String>().Utf8Value();
            scConfig[@"outputPath"] = [NSString stringWithUTF8String:outputPathStr.c_str()];

            NSError *scErr = nil;
            NSLog(@"[mac_recorder] Using ScreenCaptureKit path (displayId=%u)", displayID);
            
            // Create and set up delegate
            g_delegate = [[MacRecorderDelegate alloc] init];
            
            BOOL ok = [ScreenCaptureKitRecorder startRecordingWithConfiguration:scConfig delegate:g_delegate error:&scErr];
            if (ok) {
                g_isRecording = true;
                NSLog(@"[mac_recorder] ScreenCaptureKit startRecording → OK");
                return Napi::Boolean::New(env, true);
            }
            NSLog(@"[mac_recorder] ScreenCaptureKit startRecording → FAIL: %@", scErr.localizedDescription);
            cleanupRecording();
            return Napi::Boolean::New(env, false);
            }
        } else {
            NSLog(@"[mac_recorder] ScreenCaptureKit not available");
            cleanupRecording();
            return Napi::Boolean::New(env, false);
        }
        
    } @catch (NSException *exception) {
        cleanupRecording();
        return Napi::Boolean::New(env, false);
    }
}

// NAPI Function: Stop Recording
Napi::Value StopRecording(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (!g_isRecording) {
        return Napi::Boolean::New(env, false);
    }
    
    @try {
        NSLog(@"[mac_recorder] StopRecording called");
        
        // Stop ScreenCaptureKit recording
        NSLog(@"[mac_recorder] Stopping ScreenCaptureKit stream");
        if (@available(macOS 12.3, *)) {
            [ScreenCaptureKitRecorder stopRecording];
        }
        g_isRecording = false;
        cleanupRecording();
        NSLog(@"[mac_recorder] ScreenCaptureKit stopped");
        return Napi::Boolean::New(env, true);
        
    } @catch (NSException *exception) {
        cleanupRecording();
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
        
        // Use CoreAudio to get audio devices since we're removing AVFoundation
        AudioObjectPropertyAddress propertyAddress = {
            kAudioHardwarePropertyDevices,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        
        UInt32 dataSize = 0;
        OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize);
        if (status != noErr) {
            return Napi::Array::New(env, 0);
        }
        
        UInt32 deviceCount = dataSize / sizeof(AudioDeviceID);
        AudioDeviceID *audioDevices = (AudioDeviceID *)malloc(dataSize);
        
        status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize, audioDevices);
        if (status != noErr) {
            free(audioDevices);
            return Napi::Array::New(env, 0);
        }
        
        for (UInt32 i = 0; i < deviceCount; i++) {
            AudioDeviceID deviceID = audioDevices[i];
            
            // Check if device has input streams
            AudioObjectPropertyAddress streamsAddress = {
                kAudioDevicePropertyStreams,
                kAudioDevicePropertyScopeInput,
                kAudioObjectPropertyElementMain
            };
            
            UInt32 streamsSize = 0;
            status = AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, NULL, &streamsSize);
            if (status != noErr || streamsSize == 0) {
                continue; // Skip output-only devices
            }
            
            // Get device name
            AudioObjectPropertyAddress nameAddress = {
                kAudioDevicePropertyDeviceNameCFString,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            
            CFStringRef deviceNameRef = NULL;
            UInt32 nameSize = sizeof(CFStringRef);
            status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, NULL, &nameSize, &deviceNameRef);
            
            NSString *deviceName = @"Unknown Device";
            if (status == noErr && deviceNameRef) {
                deviceName = (__bridge NSString *)deviceNameRef;
            }
            
            // Get device UID
            AudioObjectPropertyAddress uidAddress = {
                kAudioDevicePropertyDeviceUID,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            
            CFStringRef deviceUIDRef = NULL;
            UInt32 uidSize = sizeof(CFStringRef);
            status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, NULL, &uidSize, &deviceUIDRef);
            
            NSString *deviceUID = [NSString stringWithFormat:@"%u", deviceID];
            if (status == noErr && deviceUIDRef) {
                deviceUID = (__bridge NSString *)deviceUIDRef;
            }
            
            // Check if this is the default input device
            AudioObjectPropertyAddress defaultAddress = {
                kAudioHardwarePropertyDefaultInputDevice,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            
            AudioDeviceID defaultDeviceID = kAudioDeviceUnknown;
            UInt32 defaultSize = sizeof(AudioDeviceID);
            AudioObjectGetPropertyData(kAudioObjectSystemObject, &defaultAddress, 0, NULL, &defaultSize, &defaultDeviceID);
            
            BOOL isDefault = (deviceID == defaultDeviceID);
            
            [devices addObject:@{
                @"id": deviceUID,
                @"name": deviceName,
                @"manufacturer": @"Unknown",
                @"isDefault": @(isDefault)
            }];
            
            if (deviceNameRef) CFRelease(deviceNameRef);
            if (deviceUIDRef) CFRelease(deviceUIDRef);
        }
        
        free(audioDevices);
        
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
        // Check screen recording permission using ScreenCaptureKit
        bool hasScreenPermission = true;
        
        if (@available(macOS 12.3, *)) {
            // Try to get shareable content to test ScreenCaptureKit permissions
            @try {
                SCShareableContent *content = [SCShareableContent currentShareableContent];
                hasScreenPermission = (content != nil && content.displays.count > 0);
            } @catch (NSException *exception) {
                hasScreenPermission = false;
            }
        } else {
            // Fallback for older macOS versions
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
        }
        
        // For audio permission, we'll use a simpler check since we're using CoreAudio
        bool hasAudioPermission = true;
        
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
    // ScreenCaptureKit availability (optional for clients)
    exports.Set(Napi::String::New(env, "isScreenCaptureKitAvailable"), Napi::Function::New(env, [](const Napi::CallbackInfo& info){
        Napi::Env env = info.Env();
        if (@available(macOS 12.3, *)) {
            bool available = [ScreenCaptureKitRecorder isScreenCaptureKitAvailable];
            return Napi::Boolean::New(env, available);
        }
        return Napi::Boolean::New(env, false);
    }));
    
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
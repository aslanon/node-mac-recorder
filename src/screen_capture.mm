<<<<<<< HEAD
=======
#import "screen_capture.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>
>>>>>>> screencapture
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>

@implementation ScreenCapture

+ (NSArray *)getAvailableDisplays {
    NSMutableArray *displays = [NSMutableArray array];
    
    uint32_t displayCount;
    CGGetActiveDisplayList(0, NULL, &displayCount);
    
    CGDirectDisplayID *displayList = (CGDirectDisplayID *)malloc(displayCount * sizeof(CGDirectDisplayID));
    CGGetActiveDisplayList(displayCount, displayList, &displayCount);
    
    // Get NSScreen list for consistent coordinate system
    NSArray<NSScreen *> *screens = [NSScreen screens];
    
    for (uint32_t i = 0; i < displayCount; i++) {
        CGDirectDisplayID displayID = displayList[i];
        
        // Find corresponding NSScreen for this display ID
        NSScreen *matchingScreen = nil;
        for (NSScreen *screen in screens) {
            // Match by display ID (requires screen.deviceDescription lookup)
            NSDictionary *deviceDescription = [screen deviceDescription];
            NSNumber *screenDisplayID = [deviceDescription objectForKey:@"NSScreenNumber"];
            if (screenDisplayID && [screenDisplayID unsignedIntValue] == displayID) {
                matchingScreen = screen;
                break;
            }
        }
        
        // Use NSScreen.frame if found, fallback to CGDisplayBounds
        CGRect bounds;
        if (matchingScreen) {
            NSRect screenFrame = [matchingScreen frame];
            bounds = CGRectMake(screenFrame.origin.x, screenFrame.origin.y, screenFrame.size.width, screenFrame.size.height);
        } else {
            bounds = CGDisplayBounds(displayID);
        }
        
        // Create display info dictionary
        NSDictionary *displayInfo = @{
            @"id": @(displayID),
            @"name": [NSString stringWithFormat:@"Display %d", i + 1],
            @"width": @(bounds.size.width),
            @"height": @(bounds.size.height),
            @"x": @(bounds.origin.x),
            @"y": @(bounds.origin.y),
            @"isPrimary": @(CGDisplayIsMain(displayID))
        };
        
        [displays addObject:displayInfo];
    }
    
    free(displayList);
    return [displays copy];
}

+ (BOOL)captureDisplay:(CGDirectDisplayID)displayID 
                toFile:(NSString *)filePath 
                  rect:(CGRect)rect
           includeCursor:(BOOL)includeCursor {
    
    CGImageRef screenshot = [self createScreenshotFromDisplay:displayID rect:rect];
    if (!screenshot) {
        return NO;
    }
    
    // Create image destination
    NSURL *fileURL = [NSURL fileURLWithPath:filePath];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)fileURL, 
<<<<<<< HEAD
        CFSTR("public.png"),
=======
        (__bridge CFStringRef)@"public.png", 
>>>>>>> screencapture
        1, 
        NULL
    );
    
    if (!destination) {
        CGImageRelease(screenshot);
        return NO;
    }
    
    // Add cursor if requested
    if (includeCursor) {
        // For simplicity, we'll just save the image without cursor compositing
        // Cursor compositing would require more complex image manipulation
    }
    
    // Write the image
    CGImageDestinationAddImage(destination, screenshot, NULL);
    BOOL success = CGImageDestinationFinalize(destination);
    
    // Cleanup
    CFRelease(destination);
    CGImageRelease(screenshot);
    
    return success;
}

+ (CGImageRef)createScreenshotFromDisplay:(CGDirectDisplayID)displayID 
                                     rect:(CGRect)rect {
<<<<<<< HEAD
    if (CGRectIsNull(rect)) {
        // Capture entire display
        return CGDisplayCreateImage(displayID);
    } else {
        // Capture specific rect
        return CGDisplayCreateImageForRect(displayID, rect);
=======
    if (CGRectIsNull(rect) || CGRectIsEmpty(rect)) {
        rect = CGDisplayBounds(displayID);
    }
    
    return CGDisplayCreateImageForRect(displayID, rect);
}

@end

// NAPI Functions for Legacy Fallback

// NAPI Function: Get Available Displays (Legacy)
Napi::Value GetAvailableDisplays(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    NSArray *displays = [ScreenCapture getAvailableDisplays];
    Napi::Array displaysArray = Napi::Array::New(env);
    
    for (NSUInteger i = 0; i < [displays count]; i++) {
        NSDictionary *displayInfo = displays[i];
        
        Napi::Object displayObj = Napi::Object::New(env);
        displayObj.Set("id", Napi::Number::New(env, [[displayInfo objectForKey:@"id"] unsignedIntValue]));
        displayObj.Set("name", Napi::String::New(env, [[displayInfo objectForKey:@"name"] UTF8String]));
        displayObj.Set("width", Napi::Number::New(env, [[displayInfo objectForKey:@"width"] doubleValue]));
        displayObj.Set("height", Napi::Number::New(env, [[displayInfo objectForKey:@"height"] doubleValue]));
        
        // Create frame object
        Napi::Object frameObj = Napi::Object::New(env);
        frameObj.Set("x", Napi::Number::New(env, [[displayInfo objectForKey:@"x"] doubleValue]));
        frameObj.Set("y", Napi::Number::New(env, [[displayInfo objectForKey:@"y"] doubleValue]));
        frameObj.Set("width", Napi::Number::New(env, [[displayInfo objectForKey:@"width"] doubleValue]));
        frameObj.Set("height", Napi::Number::New(env, [[displayInfo objectForKey:@"height"] doubleValue]));
        
        displayObj.Set("frame", frameObj);
        displayObj.Set("isPrimary", Napi::Boolean::New(env, [[displayInfo objectForKey:@"isPrimary"] boolValue]));
        
        displaysArray.Set(static_cast<uint32_t>(i), displayObj);
>>>>>>> screencapture
    }
    
    return displaysArray;
}

// NAPI Function: Get Window List (Legacy)
Napi::Value GetWindowList(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    // Get window list using CGWindowList
    CFArrayRef windowList = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, 
        kCGNullWindowID
    );
    
    if (!windowList) {
        return Napi::Array::New(env);
    }
    
    Napi::Array windowsArray = Napi::Array::New(env);
    CFIndex count = CFArrayGetCount(windowList);
    uint32_t index = 0;
    
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef windowInfo = (CFDictionaryRef)CFArrayGetValueAtIndex(windowList, i);
        
        // Get window ID
        CFNumberRef windowIDRef = (CFNumberRef)CFDictionaryGetValue(windowInfo, kCGWindowNumber);
        uint32_t windowID;
        CFNumberGetValue(windowIDRef, kCFNumberSInt32Type, &windowID);
        
        // Get window title
        CFStringRef windowTitleRef = (CFStringRef)CFDictionaryGetValue(windowInfo, kCGWindowName);
        std::string windowTitle = "";
        if (windowTitleRef) {
            const char *titleCStr = CFStringGetCStringPtr(windowTitleRef, kCFStringEncodingUTF8);
            if (titleCStr) {
                windowTitle = std::string(titleCStr);
            } else {
                // Fallback for when CFStringGetCStringPtr returns NULL
                CFIndex length = CFStringGetLength(windowTitleRef);
                CFIndex maxSize = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
                char *buffer = (char *)malloc(maxSize);
                if (CFStringGetCString(windowTitleRef, buffer, maxSize, kCFStringEncodingUTF8)) {
                    windowTitle = std::string(buffer);
                }
                free(buffer);
            }
        }
        
        // Get owner name
        CFStringRef ownerNameRef = (CFStringRef)CFDictionaryGetValue(windowInfo, kCGWindowOwnerName);
        std::string ownerName = "";
        if (ownerNameRef) {
            const char *ownerCStr = CFStringGetCStringPtr(ownerNameRef, kCFStringEncodingUTF8);
            if (ownerCStr) {
                ownerName = std::string(ownerCStr);
            } else {
                CFIndex length = CFStringGetLength(ownerNameRef);
                CFIndex maxSize = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
                char *buffer = (char *)malloc(maxSize);
                if (CFStringGetCString(ownerNameRef, buffer, maxSize, kCFStringEncodingUTF8)) {
                    ownerName = std::string(buffer);
                }
                free(buffer);
            }
        }
        
        // Get window bounds
        CFDictionaryRef boundsRef = (CFDictionaryRef)CFDictionaryGetValue(windowInfo, kCGWindowBounds);
        CGRect bounds = CGRectNull;
        if (boundsRef) {
            CGRectMakeWithDictionaryRepresentation(boundsRef, &bounds);
        }
        
        // Filter out small/invalid windows
        if (bounds.size.width > 50 && bounds.size.height > 50 && !windowTitle.empty()) {
            Napi::Object windowObj = Napi::Object::New(env);
            windowObj.Set("id", Napi::Number::New(env, windowID));
            windowObj.Set("title", Napi::String::New(env, windowTitle));
            windowObj.Set("ownerName", Napi::String::New(env, ownerName));
            
            // Create bounds object
            Napi::Object boundsObj = Napi::Object::New(env);
            boundsObj.Set("x", Napi::Number::New(env, bounds.origin.x));
            boundsObj.Set("y", Napi::Number::New(env, bounds.origin.y));
            boundsObj.Set("width", Napi::Number::New(env, bounds.size.width));
            boundsObj.Set("height", Napi::Number::New(env, bounds.size.height));
            
            windowObj.Set("bounds", boundsObj);
            
            windowsArray.Set(index++, windowObj);
        }
    }
    
    CFRelease(windowList);
    return windowsArray;
}
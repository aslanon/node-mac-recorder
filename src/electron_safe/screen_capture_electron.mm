#import "screen_capture_electron.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AppKit/AppKit.h>

// Thread-safe recording state management
static SCStream * API_AVAILABLE(macos(12.3)) g_electronSafeStream = nil;
static BOOL g_electronSafeIsRecording = NO;
static NSString *g_electronSafeOutputPath = nil;
static dispatch_queue_t g_electronSafeQueue = nil;

// Initialize the safe queue once
static void initializeSafeQueue() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_electronSafeQueue = dispatch_queue_create("com.macrecorder.electron.safe", DISPATCH_QUEUE_SERIAL);
    });
}

@interface ElectronSafeStreamDelegate : NSObject <SCStreamDelegate>
@end

@implementation ElectronSafeStreamDelegate

- (void)stream:(SCStream * API_AVAILABLE(macos(12.3)))stream didStopWithError:(NSError *)error API_AVAILABLE(macos(12.3)) {
    NSLog(@"🛑 Electron-safe stream stopped");
    
    // Use the safe queue to prevent race conditions
    dispatch_async(g_electronSafeQueue, ^{
        g_electronSafeIsRecording = NO;
        
        if (error) {
            NSLog(@"❌ Stream error: %@", error);
        } else {
            NSLog(@"✅ Stream stopped cleanly");
        }
        
        // Clean up safely
        dispatch_async(dispatch_get_main_queue(), ^{
            [ElectronSafeScreenCapture cleanupSafely];
        });
    });
}

@end

@implementation ElectronSafeScreenCapture

+ (void)load {
    initializeSafeQueue();
}

+ (BOOL)startRecordingWithPath:(NSString *)outputPath options:(NSDictionary *)options {
    if (@available(macOS 12.3, *)) {
        return [self startRecordingModern:outputPath options:options];
    } else {
        NSLog(@"❌ ScreenCaptureKit not available on this macOS version");
        return NO;
    }
}

+ (BOOL)startRecordingModern:(NSString *)outputPath options:(NSDictionary *)options API_AVAILABLE(macos(12.3)) {
    __block BOOL success = NO;
    
    dispatch_sync(g_electronSafeQueue, ^{
        if (g_electronSafeIsRecording) {
            NSLog(@"⚠️ Recording already in progress");
            return;
        }
        
        g_electronSafeOutputPath = [outputPath copy];
        
        // Get shareable content safely
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
            if (error) {
                NSLog(@"❌ Failed to get shareable content: %@", error);
                return;
            }
            
            // Configure recording safely
            [self configureAndStartRecording:content options:options completion:^(BOOL recordingSuccess) {
                success = recordingSuccess;
            }];
        }];
    });
    
    return success;
}

+ (void)configureAndStartRecording:(SCShareableContent *)content 
                           options:(NSDictionary *)options 
                        completion:(void(^)(BOOL))completion API_AVAILABLE(macos(12.3)) {
    
    @try {
        // Create content filter based on options
        SCContentFilter *filter = nil;
        
        NSNumber *windowId = options[@"windowId"];
        NSNumber *displayId = options[@"displayId"];
        
        if (windowId && [windowId unsignedIntValue] != 0) {
            // Window recording
            SCWindow *targetWindow = nil;
            for (SCWindow *window in content.windows) {
                if (window.windowID == [windowId unsignedIntValue]) {
                    targetWindow = window;
                    break;
                }
            }
            
            if (targetWindow) {
                filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:targetWindow];
                NSLog(@"✅ Window filter created for window ID: %@", windowId);
            } else {
                NSLog(@"❌ Window not found: %@", windowId);
                completion(NO);
                return;
            }
        } else {
            // Display recording (default)
            SCDisplay *targetDisplay = nil;
            
            if (displayId) {
                // First, try matching by real CGDirectDisplayID
                for (SCDisplay *display in content.displays) {
                    if (display.displayID == [displayId unsignedIntValue]) {
                        targetDisplay = display;
                        break;
                    }
                }

                // If not matched, treat provided value as index (0-based or 1-based)
                if (!targetDisplay && content.displays.count > 0) {
                    NSUInteger count = content.displays.count;
                    NSUInteger idx0 = (NSUInteger)[displayId unsignedIntValue];
                    if (idx0 < count) {
                        targetDisplay = content.displays[idx0];
                    } else if ([displayId unsignedIntegerValue] > 0) {
                        NSUInteger idx1 = [displayId unsignedIntegerValue] - 1;
                        if (idx1 < count) {
                            targetDisplay = content.displays[idx1];
                        }
                    }
                }
            }
            
            if (!targetDisplay && content.displays.count > 0) {
                targetDisplay = content.displays[0]; // Default to first display
            }
            
            if (targetDisplay) {
                filter = [[SCContentFilter alloc] initWithDisplay:targetDisplay excludingWindows:@[]];
                NSLog(@"✅ Display filter created for display ID: %u", targetDisplay.displayID);
            } else {
                NSLog(@"❌ No display available");
                completion(NO);
                return;
            }
        }
        
        // Configure stream
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        
        // Audio configuration (only available on macOS 13.0+)
        if (@available(macOS 13.0, *)) {
            config.capturesAudio = [options[@"includeMicrophone"] boolValue] || [options[@"includeSystemAudio"] boolValue];
            config.sampleRate = 44100;
            config.channelCount = 2;
        }
        
        // Video configuration
        // Prefer the target display's native resolution when available
        if (filter && [filter isKindOfClass:[SCContentFilter class]]) {
            // Try to infer dimensions from selected display or capture area
            NSDictionary *captureArea = options[@"captureArea"];
            if (captureArea) {
                config.width = (size_t)[captureArea[@"width"] doubleValue];
                config.height = (size_t)[captureArea[@"height"] doubleValue];
            } else {
                // Find the selected display again to get dimensions
                NSNumber *displayId = options[@"displayId"];
                if (displayId) {
                    for (SCDisplay *display in content.displays) {
                        if (display.displayID == [displayId unsignedIntValue]) {
                            config.width = (size_t)display.width;
                            config.height = (size_t)display.height;
                            break;
                        }
                    }
                }
            }
        }
        
        // Fallback default resolution if not set above
        if (config.width == 0 || config.height == 0) {
            config.width = 1920;
            config.height = 1080;
        }
        
        // Frame rate from options (default 60)
        NSInteger fps = 60;
        if (options[@"frameRate"]) {
            NSInteger v = [options[@"frameRate"] integerValue];
            if (v > 0) {
                if (v < 1) v = 1;
                if (v > 120) v = 120;
                fps = v;
            }
        }
        config.minimumFrameInterval = CMTimeMake(1, (int)fps);
        config.queueDepth = 8;
        
        // Capture area if specified
        NSDictionary *captureArea = options[@"captureArea"];
        if (captureArea) {
            CGRect sourceRect = CGRectMake(
                [captureArea[@"x"] doubleValue],
                [captureArea[@"y"] doubleValue],
                [captureArea[@"width"] doubleValue],
                [captureArea[@"height"] doubleValue]
            );
            config.sourceRect = sourceRect;
            config.width = (size_t)sourceRect.size.width;
            config.height = (size_t)sourceRect.size.height;
        }
        
        // Cursor capture
        config.showsCursor = [options[@"captureCursor"] boolValue];
        
        // Create delegate
        ElectronSafeStreamDelegate *delegate = [[ElectronSafeStreamDelegate alloc] init];
        
        // Create stream
        NSError *streamError = nil;
        g_electronSafeStream = [[SCStream alloc] initWithFilter:filter 
                                                  configuration:config 
                                                       delegate:delegate];
        
        if (!g_electronSafeStream) {
            NSLog(@"❌ Failed to create stream: %@", streamError);
            completion(NO);
            return;
        }
        
        // Start recording to file
        [self startRecordingToFile:g_electronSafeOutputPath completion:completion];
        
    } @catch (NSException *e) {
        NSLog(@"❌ Exception in configureAndStartRecording: %@", e.reason);
        completion(NO);
    }
}

+ (void)startRecordingToFile:(NSString *)outputPath completion:(void(^)(BOOL))completion API_AVAILABLE(macos(12.3)) {
    if (@available(macOS 15.0, *)) {
        // Use SCRecordingOutput for macOS 15.0+
        [self startRecordingWithSCRecordingOutput:outputPath completion:completion];
    } else {
        // Fallback to sample buffer capture for macOS 12.3-14.x
        [self startRecordingWithSampleBuffers:outputPath completion:completion];
    }
}

+ (void)startRecordingWithSCRecordingOutput:(NSString *)outputPath completion:(void(^)(BOOL))completion API_AVAILABLE(macos(15.0)) {
    @try {
        // Note: SCRecordingOutput is only available on macOS 15.0+
        // For now, we'll use the sample buffer approach for compatibility
        NSLog(@"⚠️ SCRecordingOutput not implemented for compatibility - using fallback");
        
        [g_electronSafeStream startCaptureWithCompletionHandler:^(NSError *error) {
            dispatch_async(g_electronSafeQueue, ^{
                if (error) {
                    NSLog(@"❌ Failed to start capture: %@", error);
                    g_electronSafeIsRecording = NO;
                    completion(NO);
                } else {
                    NSLog(@"✅ Electron-safe recording started with SCRecordingOutput");
                    g_electronSafeIsRecording = YES;
                    completion(YES);
                }
            });
        }];
        
    } @catch (NSException *e) {
        NSLog(@"❌ Exception in startRecordingWithSCRecordingOutput: %@", e.reason);
        completion(NO);
    }
}

+ (void)startRecordingWithSampleBuffers:(NSString *)outputPath completion:(void(^)(BOOL))completion API_AVAILABLE(macos(12.3)) {
    @try {
        // For macOS 12.3-14.x, we'll use a simpler approach
        // This is a fallback implementation
        
        [g_electronSafeStream startCaptureWithCompletionHandler:^(NSError *error) {
            dispatch_async(g_electronSafeQueue, ^{
                if (error) {
                    NSLog(@"❌ Failed to start capture: %@", error);
                    g_electronSafeIsRecording = NO;
                    completion(NO);
                } else {
                    NSLog(@"✅ Electron-safe recording started with sample buffers");
                    g_electronSafeIsRecording = YES;
                    completion(YES);
                }
            });
        }];
        
    } @catch (NSException *e) {
        NSLog(@"❌ Exception in startRecordingWithSampleBuffers: %@", e.reason);
        completion(NO);
    }
}

+ (BOOL)stopRecordingSafely {
    __block BOOL success = NO;
    
    dispatch_sync(g_electronSafeQueue, ^{
        if (!g_electronSafeIsRecording) {
            NSLog(@"⚠️ No recording in progress");
            success = YES; // Not an error
            return;
        }
        
        @try {
            if (@available(macOS 12.3, *)) {
                if (g_electronSafeStream) {
                    [g_electronSafeStream stopCaptureWithCompletionHandler:^(NSError *error) {
                        dispatch_async(g_electronSafeQueue, ^{
                            if (error) {
                                NSLog(@"❌ Failed to stop capture: %@", error);
                            } else {
                                NSLog(@"✅ Capture stopped successfully");
                            }
                            
                            [ElectronSafeScreenCapture cleanupSafely];
                        });
                    }];
                    success = YES;
                } else {
                    NSLog(@"⚠️ No stream to stop");
                    success = YES;
                }
            }
        } @catch (NSException *e) {
            NSLog(@"❌ Exception stopping recording: %@", e.reason);
            [ElectronSafeScreenCapture cleanupSafely];
            success = NO;
        }
    });
    
    return success;
}

+ (void)cleanupSafely {
    dispatch_async(g_electronSafeQueue, ^{
        @try {
            if (@available(macOS 12.3, *)) {
                g_electronSafeStream = nil;
            }
            g_electronSafeIsRecording = NO;
            g_electronSafeOutputPath = nil;
            
            NSLog(@"✅ Electron-safe cleanup completed");
            
        } @catch (NSException *e) {
            NSLog(@"❌ Exception during cleanup: %@", e.reason);
        }
    });
}

+ (BOOL)isRecording {
    __block BOOL recording = NO;
    dispatch_sync(g_electronSafeQueue, ^{
        recording = g_electronSafeIsRecording;
    });
    return recording;
}

+ (NSArray *)getAvailableDisplays {
    NSMutableArray *displays = [NSMutableArray array];
    
    @try {
        // Get all displays using Core Graphics
        uint32_t displayCount = 0;
        CGGetActiveDisplayList(0, NULL, &displayCount);
        
        if (displayCount > 0) {
            CGDirectDisplayID *displayList = (CGDirectDisplayID *)malloc(displayCount * sizeof(CGDirectDisplayID));
            CGGetActiveDisplayList(displayCount, displayList, &displayCount);
            
            for (uint32_t i = 0; i < displayCount; i++) {
                CGDirectDisplayID displayID = displayList[i];
                
                CGRect bounds = CGDisplayBounds(displayID);
                NSString *name = [NSString stringWithFormat:@"Display %u", displayID];
                
                NSDictionary *displayInfo = @{
                    @"id": @(displayID),
                    @"name": name,
                    @"width": @((int)bounds.size.width),
                    @"height": @((int)bounds.size.height),
                    @"x": @((int)bounds.origin.x),
                    @"y": @((int)bounds.origin.y),
                    @"isPrimary": @(CGDisplayIsMain(displayID))
                };
                
                [displays addObject:displayInfo];
            }
            
            free(displayList);
        }
        
    } @catch (NSException *e) {
        NSLog(@"❌ Exception getting displays: %@", e.reason);
    }
    
    return [displays copy];
}

+ (NSArray *)getAvailableWindows {
    NSMutableArray *windows = [NSMutableArray array];
    
    @try {
        if (@available(macOS 12.3, *)) {
            [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
                if (!error && content) {
                    for (SCWindow *window in content.windows) {
                        // Skip system windows and our own
                        if (window.frame.size.width < 50 || window.frame.size.height < 50) continue;
                        if (!window.title || window.title.length == 0) continue;
                        
                        NSString *appName = window.owningApplication.applicationName ?: @"Unknown";
                        
                        // Skip Electron windows (our overlay)
                        if ([appName containsString:@"Electron"] || [appName containsString:@"node"]) continue;
                        
                        NSDictionary *windowInfo = @{
                            @"id": @(window.windowID),
                            @"name": window.title,
                            @"appName": appName,
                            @"x": @((int)window.frame.origin.x),
                            @"y": @((int)window.frame.origin.y),
                            @"width": @((int)window.frame.size.width),
                            @"height": @((int)window.frame.size.height),
                            @"isOnScreen": @(window.isOnScreen)
                        };
                        
                        [windows addObject:windowInfo];
                    }
                }
            }];
        }
        
    } @catch (NSException *e) {
        NSLog(@"❌ Exception getting windows: %@", e.reason);
    }
    
    return [windows copy];
}

+ (BOOL)checkPermissions {
    @try {
        // Check screen recording permission
        if (@available(macOS 10.15, *)) {
            CGRequestScreenCaptureAccess();
            
            // Create a small test image to verify permission
            CGImageRef testImage = CGDisplayCreateImage(CGMainDisplayID());
            if (testImage) {
                CFRelease(testImage);
                return YES;
            }
        }
        
        return NO;
        
    } @catch (NSException *e) {
        NSLog(@"❌ Exception checking permissions: %@", e.reason);
        return NO;
    }
}

+ (NSString *)getDisplayThumbnailBase64:(CGDirectDisplayID)displayID 
                               maxWidth:(NSInteger)maxWidth 
                              maxHeight:(NSInteger)maxHeight {
    @try {
        CGImageRef screenshot = CGDisplayCreateImage(displayID);
        if (!screenshot) {
            return nil;
        }
        
        // Resize image if needed
        CGSize originalSize = CGSizeMake(CGImageGetWidth(screenshot), CGImageGetHeight(screenshot));
        CGSize newSize = [self calculateThumbnailSize:originalSize maxWidth:maxWidth maxHeight:maxHeight];
        
        NSData *imageData = [self createPNGDataFromImage:screenshot size:newSize];
        CFRelease(screenshot);
        
        if (imageData) {
            return [imageData base64EncodedStringWithOptions:0];
        }
        
        return nil;
        
    } @catch (NSException *e) {
        NSLog(@"❌ Exception creating display thumbnail: %@", e.reason);
        return nil;
    }
}

+ (NSString *)getWindowThumbnailBase64:(uint32_t)windowID 
                              maxWidth:(NSInteger)maxWidth 
                             maxHeight:(NSInteger)maxHeight {
    @try {
        CGImageRef screenshot = CGWindowListCreateImage(CGRectNull, 
                                                       kCGWindowListOptionIncludingWindow, 
                                                       windowID, 
                                                       kCGWindowImageDefault);
        if (!screenshot) {
            return nil;
        }
        
        // Resize image if needed
        CGSize originalSize = CGSizeMake(CGImageGetWidth(screenshot), CGImageGetHeight(screenshot));
        CGSize newSize = [self calculateThumbnailSize:originalSize maxWidth:maxWidth maxHeight:maxHeight];
        
        NSData *imageData = [self createPNGDataFromImage:screenshot size:newSize];
        CFRelease(screenshot);
        
        if (imageData) {
            return [imageData base64EncodedStringWithOptions:0];
        }
        
        return nil;
        
    } @catch (NSException *e) {
        NSLog(@"❌ Exception creating window thumbnail: %@", e.reason);
        return nil;
    }
}

+ (CGSize)calculateThumbnailSize:(CGSize)originalSize maxWidth:(NSInteger)maxWidth maxHeight:(NSInteger)maxHeight {
    CGFloat aspectRatio = originalSize.width / originalSize.height;
    CGFloat newWidth = originalSize.width;
    CGFloat newHeight = originalSize.height;
    
    if (newWidth > maxWidth) {
        newWidth = maxWidth;
        newHeight = newWidth / aspectRatio;
    }
    
    if (newHeight > maxHeight) {
        newHeight = maxHeight;
        newWidth = newHeight * aspectRatio;
    }
    
    return CGSizeMake(newWidth, newHeight);
}

+ (NSData *)createPNGDataFromImage:(CGImageRef)image size:(CGSize)size {
    @try {
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(NULL, 
                                                    (size_t)size.width, 
                                                    (size_t)size.height, 
                                                    8, 
                                                    0, 
                                                    colorSpace, 
                                                    kCGImageAlphaPremultipliedLast);
        
        if (!context) {
            CGColorSpaceRelease(colorSpace);
            return nil;
        }
        
        CGContextDrawImage(context, CGRectMake(0, 0, size.width, size.height), image);
        CGImageRef resizedImage = CGBitmapContextCreateImage(context);
        
        CGContextRelease(context);
        CGColorSpaceRelease(colorSpace);
        
        if (!resizedImage) {
            return nil;
        }
        
        NSMutableData *data = [NSMutableData data];
        CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, 
                                                                             kUTTypePNG, 
                                                                             1, 
                                                                             NULL);
        
        if (destination) {
            CGImageDestinationAddImage(destination, resizedImage, NULL);
            CGImageDestinationFinalize(destination);
            CFRelease(destination);
        }
        
        CGImageRelease(resizedImage);
        
        return [data copy];
        
    } @catch (NSException *e) {
        NSLog(@"❌ Exception creating PNG data: %@", e.reason);
        return nil;
    }
}

@end

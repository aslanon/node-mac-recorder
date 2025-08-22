#import "screen_capture_kit.h"

// Global state
static SCStream *g_stream = nil;
static id<SCStreamDelegate> g_streamDelegate = nil;
static BOOL g_isRecording = NO;

@interface ScreenCaptureKitRecorderDelegate : NSObject <SCStreamDelegate>
@property (nonatomic, copy) void (^completionHandler)(NSURL *outputURL, NSError *error);
@end

@implementation ScreenCaptureKitRecorderDelegate
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    NSLog(@"ScreenCaptureKit recording stopped with error: %@", error);
}
@end

@implementation ScreenCaptureKitRecorder

+ (BOOL)isScreenCaptureKitAvailable {
    if (@available(macOS 12.3, *)) {
        return YES;
    }
    return NO;
}

+ (BOOL)startRecordingWithConfiguration:(NSDictionary *)config 
                               delegate:(id)delegate 
                                  error:(NSError **)error {
    
    if (@available(macOS 12.3, *)) {
        @try {
            // Get current app PID to exclude overlay windows
            NSRunningApplication *currentApp = [NSRunningApplication currentApplication];
            pid_t currentPID = currentApp.processIdentifier;
            
            // Get all shareable content synchronously for immediate response
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            __block BOOL success = NO;
            __block NSError *contentError = nil;
            
            [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
                if (error) {
                    NSLog(@"Failed to get shareable content: %@", error);
                    contentError = error;
                    dispatch_semaphore_signal(semaphore);
                    return;
                }
                
                // Find display to record
                SCDisplay *targetDisplay = content.displays.firstObject; // Default to first display
                if (config[@"displayId"]) {
                    CGDirectDisplayID displayID = [config[@"displayId"] unsignedIntValue];
                    for (SCDisplay *display in content.displays) {
                        if (display.displayID == displayID) {
                            targetDisplay = display;
                            break;
                        }
                    }
                }
                
                // Get current app windows to exclude
                NSMutableArray *excludedWindows = [NSMutableArray array];
                for (SCWindow *window in content.windows) {
                    if (window.owningApplication.processID == currentPID) {
                        [excludedWindows addObject:window];
                        NSLog(@"🚫 Excluding overlay window: %@ (PID: %d)", window.title, currentPID);
                    }
                }
                
                // Create content filter - exclude current app windows
                SCContentFilter *filter = [[SCContentFilter alloc] 
                    initWithDisplay:targetDisplay 
                    excludingWindows:excludedWindows];
                
                // Create stream configuration
                SCStreamConfiguration *streamConfig = [[SCStreamConfiguration alloc] init];
                
                // Handle capture area if specified
                if (config[@"captureRect"]) {
                    NSDictionary *rect = config[@"captureRect"];
                    streamConfig.width = [rect[@"width"] integerValue];
                    streamConfig.height = [rect[@"height"] integerValue];
                    // Note: ScreenCaptureKit crop rect would need additional handling
                } else {
                    streamConfig.width = (NSInteger)targetDisplay.width;
                    streamConfig.height = (NSInteger)targetDisplay.height;
                }
                
                streamConfig.minimumFrameInterval = CMTimeMake(1, 60); // 60 FPS
                streamConfig.queueDepth = 5;
                streamConfig.showsCursor = [config[@"captureCursor"] boolValue];
                streamConfig.capturesAudio = [config[@"includeSystemAudio"] boolValue];
                
                // Create delegate
                g_streamDelegate = [[ScreenCaptureKitRecorderDelegate alloc] init];
                
                // Create and start stream
                g_stream = [[SCStream alloc] initWithFilter:filter 
                                              configuration:streamConfig 
                                                   delegate:g_streamDelegate];
                
                [g_stream startCaptureWithCompletionHandler:^(NSError *streamError) {
                    if (streamError) {
                        NSLog(@"❌ Failed to start ScreenCaptureKit recording: %@", streamError);
                        contentError = streamError;
                        g_isRecording = NO;
                    } else {
                        NSLog(@"✅ ScreenCaptureKit recording started successfully (excluding %lu overlay windows)", (unsigned long)excludedWindows.count);
                        g_isRecording = YES;
                        success = YES;
                    }
                    dispatch_semaphore_signal(semaphore);
                }];
            }];
            
            // Wait for completion (with timeout)
            dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
            if (dispatch_semaphore_wait(semaphore, timeout) == 0) {
                if (contentError && error) {
                    *error = contentError;
                }
                return success;
            } else {
                NSLog(@"⏰ ScreenCaptureKit initialization timeout");
                if (error) {
                    *error = [NSError errorWithDomain:@"ScreenCaptureKitError" 
                                                 code:-2 
                                             userInfo:@{NSLocalizedDescriptionKey: @"Initialization timeout"}];
                }
                return NO;
            }
            
        } @catch (NSException *exception) {
            NSLog(@"ScreenCaptureKit recording exception: %@", exception);
            if (error) {
                *error = [NSError errorWithDomain:@"ScreenCaptureKitError" 
                                             code:-1 
                                         userInfo:@{NSLocalizedDescriptionKey: exception.reason}];
            }
            return NO;
        }
    }
    
    return NO;
}

+ (void)stopRecording {
    if (@available(macOS 12.3, *)) {
        if (g_stream && g_isRecording) {
            [g_stream stopCaptureWithCompletionHandler:^(NSError *error) {
                if (error) {
                    NSLog(@"Error stopping ScreenCaptureKit recording: %@", error);
                } else {
                    NSLog(@"ScreenCaptureKit recording stopped successfully");
                }
                g_isRecording = NO;
                g_stream = nil;
                g_streamDelegate = nil;
            }];
        }
    }
}

+ (BOOL)isRecording {
    return g_isRecording;
}

@end
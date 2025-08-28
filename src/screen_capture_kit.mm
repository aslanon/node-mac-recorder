#import "screen_capture_kit.h"

// Pure ScreenCaptureKit implementation - NO AVFoundation
static SCStream * API_AVAILABLE(macos(12.3)) g_stream = nil;
static SCRecordingOutput * API_AVAILABLE(macos(15.0)) g_recordingOutput = nil;
static id<SCStreamDelegate> API_AVAILABLE(macos(12.3)) g_streamDelegate = nil;
static BOOL g_isRecording = NO;
static NSString *g_outputPath = nil;

@interface PureScreenCaptureDelegate : NSObject <SCStreamDelegate>
@end

@implementation PureScreenCaptureDelegate
- (void)stream:(SCStream * API_AVAILABLE(macos(12.3)))stream didStopWithError:(NSError *)error API_AVAILABLE(macos(12.3)) {
    NSLog(@"🛑 Pure ScreenCapture stream stopped");
    g_isRecording = NO;
    
    if (error) {
        NSLog(@"❌ Stream error: %@", error);
    } else {
        NSLog(@"✅ Stream stopped cleanly");
    }
    
    [ScreenCaptureKitRecorder finalizeRecording];
}
@end

@implementation ScreenCaptureKitRecorder

+ (BOOL)isScreenCaptureKitAvailable {
    if (@available(macOS 15.0, *)) {
        return [SCShareableContent class] != nil && [SCStream class] != nil && [SCRecordingOutput class] != nil;
    }
    return NO;
}

+ (BOOL)startRecordingWithConfiguration:(NSDictionary *)config delegate:(id)delegate error:(NSError **)error {
    if (g_isRecording) {
        NSLog(@"⚠️ Already recording");
        return NO;
    }
    
    g_outputPath = config[@"outputPath"];
    
    // Extract configuration options
    NSNumber *displayId = config[@"displayId"];
    NSNumber *windowId = config[@"windowId"];
    NSValue *captureAreaValue = config[@"captureArea"];
    NSNumber *captureCursor = config[@"captureCursor"];
    NSNumber *includeMicrophone = config[@"includeMicrophone"];
    NSNumber *includeSystemAudio = config[@"includeSystemAudio"];
    
    NSLog(@"🎬 Starting PURE ScreenCaptureKit recording (NO AVFoundation)");
    NSLog(@"🔧 Config: cursor=%@ mic=%@ system=%@ display=%@ window=%@", 
          captureCursor, includeMicrophone, includeSystemAudio, displayId, windowId);
    
    // Get shareable content
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *contentError) {
        if (contentError) {
            NSLog(@"❌ Content error: %@", contentError);
            return;
        }
        
        NSLog(@"✅ Got %lu displays, %lu windows for pure recording", 
              content.displays.count, content.windows.count);
        
        SCContentFilter *filter = nil;
        NSInteger recordingWidth = 0;
        NSInteger recordingHeight = 0;
        
        // WINDOW RECORDING
        if (windowId && [windowId integerValue] != 0) {
            SCRunningApplication *targetApp = nil;
            SCWindow *targetWindow = nil;
            
            for (SCWindow *window in content.windows) {
                if (window.windowID == [windowId unsignedIntValue]) {
                    targetWindow = window;
                    targetApp = window.owningApplication;
                    break;
                }
            }
            
            if (targetWindow && targetApp) {
                NSLog(@"🪟 Recording window: %@ (%ux%u)", 
                      targetWindow.title, (unsigned)targetWindow.frame.size.width, (unsigned)targetWindow.frame.size.height);
                filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:targetWindow];
                recordingWidth = (NSInteger)targetWindow.frame.size.width;
                recordingHeight = (NSInteger)targetWindow.frame.size.height;
            } else {
                NSLog(@"❌ Window ID %@ not found", windowId);
                return;
            }
        }
        // DISPLAY RECORDING
        else {
            SCDisplay *targetDisplay = nil;
            
            if (displayId && [displayId integerValue] != 0) {
                // Find specific display
                for (SCDisplay *display in content.displays) {
                    if (display.displayID == [displayId unsignedIntValue]) {
                        targetDisplay = display;
                        break;
                    }
                }
            } else {
                // Use first display
                targetDisplay = content.displays.firstObject;
            }
            
            if (!targetDisplay) {
                NSLog(@"❌ Display not found");
                return;
            }
            
            NSLog(@"🖥️ Recording display %u (%dx%d)", 
                  targetDisplay.displayID, (int)targetDisplay.width, (int)targetDisplay.height);
            filter = [[SCContentFilter alloc] initWithDisplay:targetDisplay excludingWindows:@[]];
            recordingWidth = targetDisplay.width;
            recordingHeight = targetDisplay.height;
        }
        
        // Configure stream with extracted options
        SCStreamConfiguration *streamConfig = [[SCStreamConfiguration alloc] init];
        streamConfig.width = recordingWidth;
        streamConfig.height = recordingHeight;
        streamConfig.minimumFrameInterval = CMTimeMake(1, 30); // 30 FPS
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA;
        streamConfig.scalesToFit = NO;
        
        // CURSOR SUPPORT
        BOOL shouldShowCursor = captureCursor ? [captureCursor boolValue] : YES;
        streamConfig.showsCursor = shouldShowCursor;
        
        NSLog(@"🎥 Pure ScreenCapture config: %ldx%ld @ 30fps, cursor=%d", 
              recordingWidth, recordingHeight, shouldShowCursor);
        
        // AUDIO SUPPORT - Configure stream audio settings
        BOOL shouldCaptureMic = includeMicrophone ? [includeMicrophone boolValue] : NO;
        BOOL shouldCaptureSystemAudio = includeSystemAudio ? [includeSystemAudio boolValue] : NO;
        
        if (@available(macOS 13.0, *)) {
            if (shouldCaptureMic || shouldCaptureSystemAudio) {
                streamConfig.capturesAudio = YES;
                streamConfig.sampleRate = 44100;
                streamConfig.channelCount = 2;
                NSLog(@"🎵 Audio enabled: mic=%d system=%d", shouldCaptureMic, shouldCaptureSystemAudio);
            } else {
                streamConfig.capturesAudio = NO;
                NSLog(@"🔇 Audio disabled");
            }
        }
        
        // Create pure ScreenCaptureKit recording output
        NSURL *outputURL = [NSURL fileURLWithPath:g_outputPath];
        if (@available(macOS 15.0, *)) {
            // Create recording output configuration
            SCRecordingOutputConfiguration *recordingConfig = [[SCRecordingOutputConfiguration alloc] init];
            recordingConfig.outputURL = outputURL;
            recordingConfig.videoCodecType = AVVideoCodecTypeH264;
            
            // Audio configuration - using available properties
            // Note: Specific audio routing handled by ScreenCaptureKit automatically
            
            // Create recording output with correct initializer
            g_recordingOutput = [[SCRecordingOutput alloc] initWithConfiguration:recordingConfig 
                                                                        delegate:nil];
            NSLog(@"🔧 Created SCRecordingOutput with audio config: mic=%d system=%d", 
                  shouldCaptureMic, shouldCaptureSystemAudio);
        }
        
        if (!g_recordingOutput) {
            NSLog(@"❌ Failed to create SCRecordingOutput");
            return;
        }
        
        NSLog(@"✅ Pure ScreenCaptureKit recording output created");
        
        // Create delegate
        g_streamDelegate = [[PureScreenCaptureDelegate alloc] init];
        
        // Create and configure stream
        g_stream = [[SCStream alloc] initWithFilter:filter configuration:streamConfig delegate:g_streamDelegate];
        
        if (!g_stream) {
            NSLog(@"❌ Failed to create pure stream");
            return;
        }
        
        // Add recording output directly to stream
        NSError *outputError = nil;
        BOOL outputAdded = NO;
        
        if (@available(macOS 15.0, *)) {
            outputAdded = [g_stream addRecordingOutput:g_recordingOutput error:&outputError];
        }
        
        if (!outputAdded || outputError) {
            NSLog(@"❌ Failed to add recording output: %@", outputError);
            return;
        }
        
        NSLog(@"✅ Pure recording output added to stream");
        
        // Start capture with recording
        [g_stream startCaptureWithCompletionHandler:^(NSError *startError) {
            if (startError) {
                NSLog(@"❌ Failed to start pure capture: %@", startError);
                g_isRecording = NO;
            } else {
                NSLog(@"🎉 PURE ScreenCaptureKit recording started successfully!");
                g_isRecording = YES;
            }
        }];
    }];
    
    return YES;
}

+ (void)stopRecording {
    if (!g_isRecording || !g_stream) {
        return;
    }
    
    NSLog(@"🛑 Stopping pure ScreenCaptureKit recording");
    
    [g_stream stopCaptureWithCompletionHandler:^(NSError *error) {
        if (error) {
            NSLog(@"❌ Stop error: %@", error);
        }
        NSLog(@"✅ Pure stream stopped");
        [ScreenCaptureKitRecorder finalizeRecording];
    }];
}

+ (BOOL)isRecording {
    return g_isRecording;
}

+ (BOOL)setupVideoWriter {
    // No setup needed - SCRecordingOutput handles everything
    return YES;
}

+ (void)finalizeRecording {
    NSLog(@"🎬 Finalizing pure ScreenCaptureKit recording");
    
    g_isRecording = NO;
    
    if (g_recordingOutput) {
        // SCRecordingOutput finalizes automatically
        NSLog(@"✅ Pure recording output finalized");
    }
    
    [ScreenCaptureKitRecorder cleanupVideoWriter];
}

+ (void)finalizeVideoWriter {
    // Alias for finalizeRecording to maintain compatibility
    [ScreenCaptureKitRecorder finalizeRecording];
}

+ (void)cleanupVideoWriter {
    g_stream = nil;
    g_recordingOutput = nil;
    g_streamDelegate = nil;
    g_isRecording = NO;
    g_outputPath = nil;
    
    NSLog(@"🧹 Pure ScreenCaptureKit cleanup complete");
}

@end
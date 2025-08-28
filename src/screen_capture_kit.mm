#import "screen_capture_kit.h"

// Pure ScreenCaptureKit implementation - NO AVFoundation
static SCStream * API_AVAILABLE(macos(12.3)) g_stream = nil;
static SCRecordingOutput * API_AVAILABLE(macos(15.0)) g_recordingOutput = nil;
static id<SCStreamDelegate> API_AVAILABLE(macos(12.3)) g_streamDelegate = nil;
static BOOL g_isRecording = NO;
static BOOL g_isCleaningUp = NO;  // Prevent recursive cleanup
static NSString *g_outputPath = nil;

@interface PureScreenCaptureDelegate : NSObject <SCStreamDelegate>
@end

@implementation PureScreenCaptureDelegate
- (void)stream:(SCStream * API_AVAILABLE(macos(12.3)))stream didStopWithError:(NSError *)error API_AVAILABLE(macos(12.3)) {
    NSLog(@"🛑 Pure ScreenCapture stream stopped");
    
    // Prevent recursive calls during cleanup
    if (g_isCleaningUp) {
        NSLog(@"⚠️ Already cleaning up, ignoring delegate callback");
        return;
    }
    
    g_isRecording = NO;
    
    if (error) {
        NSLog(@"❌ Stream error: %@", error);
    } else {
        NSLog(@"✅ Stream stopped cleanly");
    }
    
    // Use dispatch_async to prevent potential deadlocks in Electron
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_isCleaningUp) {  // Double-check before finalizing
            [ScreenCaptureKitRecorder finalizeRecording];
        }
    });
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
    @synchronized([ScreenCaptureKitRecorder class]) {
        if (g_isRecording || g_isCleaningUp) {
            NSLog(@"⚠️ Already recording or cleaning up (recording:%d cleaning:%d)", g_isRecording, g_isCleaningUp);
            return NO;
        }
        
        // Reset any stale state
        g_isCleaningUp = NO;
    }
    
    NSString *outputPath = config[@"outputPath"];
    if (!outputPath || [outputPath length] == 0) {
        NSLog(@"❌ Invalid output path provided");
        return NO;
    }
    g_outputPath = outputPath;
    
    // Extract configuration options
    NSNumber *displayId = config[@"displayId"];
    NSNumber *windowId = config[@"windowId"];
    NSDictionary *captureRect = config[@"captureRect"];
    NSNumber *captureCursor = config[@"captureCursor"];
    NSNumber *includeMicrophone = config[@"includeMicrophone"];
    NSNumber *includeSystemAudio = config[@"includeSystemAudio"];
    
    NSLog(@"🎬 Starting PURE ScreenCaptureKit recording (NO AVFoundation)");
    NSLog(@"🔧 Config: cursor=%@ mic=%@ system=%@ display=%@ window=%@ crop=%@", 
          captureCursor, includeMicrophone, includeSystemAudio, displayId, windowId, captureRect);
    
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
        
        // CROP AREA SUPPORT - Adjust dimensions and source rect
        if (captureRect && captureRect[@"width"] && captureRect[@"height"]) {
            CGFloat cropWidth = [captureRect[@"width"] doubleValue];
            CGFloat cropHeight = [captureRect[@"height"] doubleValue];
            
            if (cropWidth > 0 && cropHeight > 0) {
                NSLog(@"🔲 Crop area specified: %.0fx%.0f at (%.0f,%.0f)", 
                      cropWidth, cropHeight, 
                      [captureRect[@"x"] doubleValue], [captureRect[@"y"] doubleValue]);
                recordingWidth = (NSInteger)cropWidth;
                recordingHeight = (NSInteger)cropHeight;
            }
        }
        
        // Configure stream with extracted options
        SCStreamConfiguration *streamConfig = [[SCStreamConfiguration alloc] init];
        streamConfig.width = recordingWidth;
        streamConfig.height = recordingHeight;
        streamConfig.minimumFrameInterval = CMTimeMake(1, 30); // 30 FPS
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA;
        streamConfig.scalesToFit = NO;
        
        // Apply crop area using sourceRect
        if (captureRect && captureRect[@"x"] && captureRect[@"y"] && captureRect[@"width"] && captureRect[@"height"]) {
            CGFloat cropX = [captureRect[@"x"] doubleValue];
            CGFloat cropY = [captureRect[@"y"] doubleValue];
            CGFloat cropWidth = [captureRect[@"width"] doubleValue];
            CGFloat cropHeight = [captureRect[@"height"] doubleValue];
            
            if (cropWidth > 0 && cropHeight > 0) {
                CGRect sourceRect = CGRectMake(cropX, cropY, cropWidth, cropHeight);
                streamConfig.sourceRect = sourceRect;
                NSLog(@"✂️ Crop sourceRect applied: (%.0f,%.0f) %.0fx%.0f", cropX, cropY, cropWidth, cropHeight);
            }
        }
        
        // CURSOR SUPPORT
        BOOL shouldShowCursor = captureCursor ? [captureCursor boolValue] : YES;
        streamConfig.showsCursor = shouldShowCursor;
        
        NSLog(@"🎥 Pure ScreenCapture config: %ldx%ld @ 30fps, cursor=%d", 
              recordingWidth, recordingHeight, shouldShowCursor);
        
        // AUDIO SUPPORT - Enable only for system audio in Electron
        BOOL shouldCaptureMic = includeMicrophone ? [includeMicrophone boolValue] : NO;
        BOOL shouldCaptureSystemAudio = includeSystemAudio ? [includeSystemAudio boolValue] : NO;
        
        // Only enable system audio, mic causes crashes in Electron
        if (@available(macOS 13.0, *)) {
            if (shouldCaptureSystemAudio && !shouldCaptureMic) {
                streamConfig.capturesAudio = YES;
                streamConfig.sampleRate = 44100;
                streamConfig.channelCount = 2;
                NSLog(@"🎵 System audio only enabled (safe for Electron)");
            } else if (shouldCaptureMic) {
                NSLog(@"🚫 Microphone audio disabled in Electron for stability");
                streamConfig.capturesAudio = NO;
            } else {
                streamConfig.capturesAudio = NO;
                NSLog(@"🔇 Audio disabled");
            }
        } else {
            streamConfig.capturesAudio = NO;
            NSLog(@"🔇 Audio disabled (macOS < 13.0)");
        }
        
        // Create pure ScreenCaptureKit recording output
        // Use local copy to prevent race conditions
        NSString *safeOutputPath = outputPath;  // Local variable from outer scope
        if (!safeOutputPath || [safeOutputPath length] == 0) {
            NSLog(@"❌ Output path is nil or empty");
            return;
        }
        
        NSURL *outputURL = [NSURL fileURLWithPath:safeOutputPath];
        if (!outputURL) {
            NSLog(@"❌ Failed to create output URL from path: %@", safeOutputPath);
            return;
        }
        
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
            if (shouldCaptureSystemAudio && !shouldCaptureMic) {
                NSLog(@"🔧 Created SCRecordingOutput with system audio only");
            } else {
                NSLog(@"🔧 Created SCRecordingOutput (audio disabled)");
            }
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
    if (!g_isRecording || !g_stream || g_isCleaningUp) {
        NSLog(@"⚠️ Cannot stop: recording=%d stream=%@ cleaning=%d", g_isRecording, g_stream, g_isCleaningUp);
        return;
    }
    
    NSLog(@"🛑 Stopping pure ScreenCaptureKit recording");
    g_isCleaningUp = YES;
    
    // Store stream reference to prevent it from being deallocated
    SCStream *streamToStop = g_stream;
    
    [streamToStop stopCaptureWithCompletionHandler:^(NSError *error) {
        if (error) {
            NSLog(@"❌ Stop error: %@", error);
        }
        NSLog(@"✅ Pure stream stopped");
        
        // Finalize on main queue to prevent threading issues
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_isCleaningUp) {  // Only finalize if we initiated cleanup
                [ScreenCaptureKitRecorder finalizeRecording];
            }
        });
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
    @synchronized([ScreenCaptureKitRecorder class]) {
        if (g_isCleaningUp && g_isRecording == NO) {
            NSLog(@"⚠️ Already finalizing, skipping duplicate call");
            return;
        }
        
        NSLog(@"🎬 Finalizing pure ScreenCaptureKit recording");
        
        g_isRecording = NO;
        
        if (g_recordingOutput) {
            // SCRecordingOutput finalizes automatically
            NSLog(@"✅ Pure recording output finalized");
        }
        
        [ScreenCaptureKitRecorder cleanupVideoWriter];
    }
}

+ (void)finalizeVideoWriter {
    // Alias for finalizeRecording to maintain compatibility
    [ScreenCaptureKitRecorder finalizeRecording];
}

+ (void)cleanupVideoWriter {
    @synchronized([ScreenCaptureKitRecorder class]) {
        NSLog(@"🧹 Starting ScreenCaptureKit cleanup");
        
        // Clean up in proper order to prevent crashes
        if (g_stream) {
            g_stream = nil;
            NSLog(@"✅ Stream reference cleared");
        }
        
        if (g_recordingOutput) {
            g_recordingOutput = nil;
            NSLog(@"✅ Recording output reference cleared");
        }
        
        if (g_streamDelegate) {
            g_streamDelegate = nil;
            NSLog(@"✅ Stream delegate reference cleared");
        }
        
        g_isRecording = NO;
        g_isCleaningUp = NO;  // Reset cleanup flag
        g_outputPath = nil;
        
        NSLog(@"🧹 Pure ScreenCaptureKit cleanup complete");
    }
}

@end
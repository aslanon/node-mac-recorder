#import "screen_capture_kit.h"
#import "logging.h"

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
    MRLog(@"🛑 Pure ScreenCapture stream stopped");
    
    // Prevent recursive calls during cleanup
    if (g_isCleaningUp) {
        MRLog(@"⚠️ Already cleaning up, ignoring delegate callback");
        return;
    }
    
    g_isRecording = NO;
    
    if (error) {
        NSLog(@"❌ Stream error: %@", error);
    } else {
        MRLog(@"✅ Stream stopped cleanly");
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
        MRLog(@"⚠️ Already recording or cleaning up (recording:%d cleaning:%d)", g_isRecording, g_isCleaningUp);
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
    
    MRLog(@"🎬 Starting PURE ScreenCaptureKit recording (NO AVFoundation)");
    MRLog(@"🔧 Config: cursor=%@ mic=%@ system=%@ display=%@ window=%@ crop=%@", 
          captureCursor, includeMicrophone, includeSystemAudio, displayId, windowId, captureRect);
    
    // CRITICAL DEBUG: Log EXACT audio parameter values
    MRLog(@"🔍 AUDIO DEBUG: includeMicrophone type=%@ value=%d", [includeMicrophone class], [includeMicrophone boolValue]);
    MRLog(@"🔍 AUDIO DEBUG: includeSystemAudio type=%@ value=%d", [includeSystemAudio class], [includeSystemAudio boolValue]);
    
    // Get shareable content
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *contentError) {
        if (contentError) {
            NSLog(@"❌ Content error: %@", contentError);
            return;
        }
        
        MRLog(@"✅ Got %lu displays, %lu windows for pure recording", 
              content.displays.count, content.windows.count);
        
        // CRITICAL DEBUG: List all available displays in ScreenCaptureKit
        MRLog(@"🔍 ScreenCaptureKit available displays:");
        for (SCDisplay *display in content.displays) {
            MRLog(@"   Display ID=%u, Size=%dx%d, Frame=(%.0f,%.0f,%.0fx%.0f)", 
                  display.displayID, (int)display.width, (int)display.height,
                  display.frame.origin.x, display.frame.origin.y,
                  display.frame.size.width, display.frame.size.height);
        }
        
        SCContentFilter *filter = nil;
        NSInteger recordingWidth = 0;
        NSInteger recordingHeight = 0;
        SCDisplay *targetDisplay = nil;  // Move to shared scope
        
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
                MRLog(@"🪟 Recording window: %@ (%ux%u)", 
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
            
            if (displayId && [displayId integerValue] != 0) {
                // Find specific display
                MRLog(@"🎯 Looking for display ID=%@ in ScreenCaptureKit list", displayId);
                for (SCDisplay *display in content.displays) {
                    MRLog(@"   Checking display ID=%u vs requested=%u", display.displayID, [displayId unsignedIntValue]);
                    if (display.displayID == [displayId unsignedIntValue]) {
                        targetDisplay = display;
                        MRLog(@"✅ FOUND matching display ID=%u", display.displayID);
                        break;
                    }
                }
                
                if (!targetDisplay) {
                    NSLog(@"❌ Display ID=%@ NOT FOUND in ScreenCaptureKit - using first display as fallback", displayId);
                    targetDisplay = content.displays.firstObject;
                }
            } else {
                // Use first display
                targetDisplay = content.displays.firstObject;
            }
            
            if (!targetDisplay) {
                NSLog(@"❌ Display not found");
                return;
            }
            
            MRLog(@"🖥️ Recording display %u (%dx%d)", 
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
                MRLog(@"🔲 Crop area specified: %.0fx%.0f at (%.0f,%.0f)", 
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
        
        // Apply crop area using sourceRect - CONVERT GLOBAL TO DISPLAY-RELATIVE COORDINATES
        if (captureRect && captureRect[@"x"] && captureRect[@"y"] && captureRect[@"width"] && captureRect[@"height"]) {
            CGFloat globalX = [captureRect[@"x"] doubleValue];
            CGFloat globalY = [captureRect[@"y"] doubleValue];
            CGFloat cropWidth = [captureRect[@"width"] doubleValue];
            CGFloat cropHeight = [captureRect[@"height"] doubleValue];
            
            if (cropWidth > 0 && cropHeight > 0 && targetDisplay) {
                // Convert global coordinates to display-relative coordinates
                CGRect displayBounds = targetDisplay.frame;
                CGFloat displayRelativeX = globalX - displayBounds.origin.x;
                CGFloat displayRelativeY = globalY - displayBounds.origin.y;
                
                MRLog(@"🌐 Global coords: (%.0f,%.0f) on Display ID=%u", globalX, globalY, targetDisplay.displayID);
                MRLog(@"🖥️ Display bounds: (%.0f,%.0f,%.0fx%.0f)", 
                      displayBounds.origin.x, displayBounds.origin.y, 
                      displayBounds.size.width, displayBounds.size.height);
                MRLog(@"📍 Display-relative: (%.0f,%.0f) -> SourceRect", displayRelativeX, displayRelativeY);
                
                // Validate coordinates are within display bounds
                if (displayRelativeX >= 0 && displayRelativeY >= 0 && 
                    displayRelativeX + cropWidth <= displayBounds.size.width &&
                    displayRelativeY + cropHeight <= displayBounds.size.height) {
                    
                    CGRect sourceRect = CGRectMake(displayRelativeX, displayRelativeY, cropWidth, cropHeight);
                    streamConfig.sourceRect = sourceRect;
                    MRLog(@"✂️ Crop sourceRect applied: (%.0f,%.0f) %.0fx%.0f (display-relative)", 
                          displayRelativeX, displayRelativeY, cropWidth, cropHeight);
                } else {
                    NSLog(@"❌ Crop coordinates out of display bounds - skipping crop");
                    MRLog(@"   Relative: (%.0f,%.0f) size:(%.0fx%.0f) vs display:(%.0fx%.0f)",
                          displayRelativeX, displayRelativeY, cropWidth, cropHeight,
                          displayBounds.size.width, displayBounds.size.height);
                }
            }
        }
        
        // CURSOR SUPPORT
        BOOL shouldShowCursor = captureCursor ? [captureCursor boolValue] : YES;
        streamConfig.showsCursor = shouldShowCursor;
        
        MRLog(@"🎥 Pure ScreenCapture config: %ldx%ld @ 30fps, cursor=%d", 
              recordingWidth, recordingHeight, shouldShowCursor);
        
        // AUDIO SUPPORT - Enable both microphone and system audio
        MRLog(@"🔍 AUDIO PROCESSING: includeMicrophone=%@ includeSystemAudio=%@", includeMicrophone, includeSystemAudio);
        BOOL shouldCaptureMic = includeMicrophone ? [includeMicrophone boolValue] : NO;
        BOOL shouldCaptureSystemAudio = includeSystemAudio ? [includeSystemAudio boolValue] : NO;
        MRLog(@"🔍 AUDIO COMPUTED: shouldCaptureMic=%d shouldCaptureSystemAudio=%d", shouldCaptureMic, shouldCaptureSystemAudio);
        
        // Enable audio if either microphone or system audio is requested
        if (@available(macOS 13.0, *)) {
            if (shouldCaptureMic || shouldCaptureSystemAudio) {
                streamConfig.capturesAudio = YES;
                streamConfig.sampleRate = 44100;
                streamConfig.channelCount = 2;
                
                if (shouldCaptureMic && shouldCaptureSystemAudio) {
                    MRLog(@"🎵 Both microphone and system audio enabled");
                } else if (shouldCaptureMic) {
                    MRLog(@"🎤 Microphone audio enabled");
                } else {
                    MRLog(@"🔊 System audio enabled");
                }
            } else {
                streamConfig.capturesAudio = NO;
                MRLog(@"🔇 Audio disabled");
            }
        } else {
            streamConfig.capturesAudio = NO;
            MRLog(@"🔇 Audio disabled (macOS < 13.0)");
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
            if (shouldCaptureMic && shouldCaptureSystemAudio) {
                NSLog(@"🔧 Created SCRecordingOutput with microphone and system audio");
            } else if (shouldCaptureMic) {
                NSLog(@"🔧 Created SCRecordingOutput with microphone audio");
            } else if (shouldCaptureSystemAudio) {
                NSLog(@"🔧 Created SCRecordingOutput with system audio");
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
        
        MRLog(@"✅ Pure recording output added to stream");
        
        // Start capture with recording
        [g_stream startCaptureWithCompletionHandler:^(NSError *startError) {
            if (startError) {
                NSLog(@"❌ Failed to start pure capture: %@", startError);
                g_isRecording = NO;
            } else {
                MRLog(@"🎉 PURE ScreenCaptureKit recording started successfully!");
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
    
    MRLog(@"🛑 Stopping pure ScreenCaptureKit recording");
    
    // Store stream reference to prevent it from being deallocated
    SCStream *streamToStop = g_stream;
    
    [streamToStop stopCaptureWithCompletionHandler:^(NSError *error) {
        if (error) {
            NSLog(@"❌ Stop error: %@", error);
        }
        MRLog(@"✅ Pure stream stopped");
        
        // Immediately reset recording state to allow new recordings
        g_isRecording = NO;
        
        // Finalize on main queue to prevent threading issues
        dispatch_async(dispatch_get_main_queue(), ^{
            [ScreenCaptureKitRecorder cleanupVideoWriter];
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
        MRLog(@"🎬 Finalizing pure ScreenCaptureKit recording");
        
        // Set cleanup flag now that we're actually cleaning up
        g_isCleaningUp = YES;
        g_isRecording = NO;
        
        if (g_recordingOutput) {
            // SCRecordingOutput finalizes automatically
            MRLog(@"✅ Pure recording output finalized");
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
        MRLog(@"🧹 Starting ScreenCaptureKit cleanup");
        
        // Clean up in proper order to prevent crashes
        if (g_stream) {
            g_stream = nil;
            MRLog(@"✅ Stream reference cleared");
        }
        
        if (g_recordingOutput) {
            g_recordingOutput = nil;
            MRLog(@"✅ Recording output reference cleared");
        }
        
        if (g_streamDelegate) {
            g_streamDelegate = nil;
            MRLog(@"✅ Stream delegate reference cleared");
        }
        
        g_isRecording = NO;
        g_isCleaningUp = NO;  // Reset cleanup flag
        g_outputPath = nil;
        
        MRLog(@"🧹 Pure ScreenCaptureKit cleanup complete");
    }
}

@end

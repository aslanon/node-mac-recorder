#import "screen_capture_kit.h"

// Global state
static SCStream *g_stream = nil;
static id<SCStreamDelegate> g_streamDelegate = nil;
static id<SCStreamOutput> g_streamOutput = nil;
static BOOL g_isRecording = NO;
// Simple image sequence approach for debugging
static NSMutableArray<NSString *> *g_imageFrames = nil;
static NSString *g_outputVideoPath = nil;
static NSInteger g_frameCount = 0;
static BOOL g_sessionStarted = NO;

@interface ScreenCaptureKitRecorderDelegate : NSObject <SCStreamDelegate>
@property (nonatomic, copy) void (^completionHandler)(NSURL *outputURL, NSError *error);
@end

@interface ScreenCaptureKitStreamOutput : NSObject <SCStreamOutput>
@end

@implementation ScreenCaptureKitRecorderDelegate
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    NSLog(@"ScreenCaptureKit recording stopped with error: %@", error);
    
    // Finalize video file (delegate version)
    if (g_assetWriter && g_assetWriter.status == AVAssetWriterStatusWriting) {
        NSLog(@"🔄 Starting video finalization in delegate");
        [g_videoWriterInput markAsFinished];
        if (g_audioWriterInput) {
            [g_audioWriterInput markAsFinished];
        }
        
        // Use asynchronous finishWriting with completion handler
        [g_assetWriter finishWritingWithCompletionHandler:^{
            if (g_assetWriter.status == AVAssetWriterStatusCompleted) {
                NSLog(@"✅ ScreenCaptureKit video file finalized in delegate: %@", g_outputPath);
            } else {
                NSLog(@"❌ ScreenCaptureKit video finalization failed in delegate: %@", g_assetWriter.error);
            }
        }];
        
        // Cleanup in delegate
        g_assetWriter = nil;
        g_videoWriterInput = nil;
        g_audioWriterInput = nil;
        g_outputPath = nil;
        g_sessionStarted = NO;
    }
}
@end

@implementation ScreenCaptureKitStreamOutput
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (!g_assetWriter) {
        return;
    }
    
    // Start session on first sample with proper validation
    if (!g_sessionStarted && g_assetWriter.status == AVAssetWriterStatusWriting) {
        CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        if (CMTIME_IS_VALID(presentationTime) && !CMTIME_IS_INDEFINITE(presentationTime)) {
            [g_assetWriter startSessionAtSourceTime:presentationTime];
            g_sessionStarted = YES;
            NSLog(@"📽️ ScreenCaptureKit video session started at time: %lld/%d", presentationTime.value, presentationTime.timescale);
        } else {
            // Use zero time if presentation time is invalid
            [g_assetWriter startSessionAtSourceTime:kCMTimeZero];
            g_sessionStarted = YES;
            NSLog(@"📽️ ScreenCaptureKit video session started at kCMTimeZero (invalid source time)");
        }
    }
    
    if (g_assetWriter.status != AVAssetWriterStatusWriting) {
        return;
    }
    
    switch (type) {
        case SCStreamOutputTypeScreen:
            if (g_videoWriterInput && g_videoWriterInput.isReadyForMoreMediaData) {
                // Validate sample buffer and timing
                CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
                CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
                
                if (formatDesc && CMTIME_IS_VALID(presentationTime)) {
                    CMMediaType mediaType = CMFormatDescriptionGetMediaType(formatDesc);
                    if (mediaType == kCMMediaType_Video) {
                        // Log sample buffer format details
                        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc);
                        FourCharCode codecType = CMFormatDescriptionGetMediaSubType(formatDesc);
                        NSString *codecString = [NSString stringWithFormat:@"%c%c%c%c",
                                                (codecType >> 24) & 0xFF,
                                                (codecType >> 16) & 0xFF, 
                                                (codecType >> 8) & 0xFF,
                                                codecType & 0xFF];
                        // Log first sample only to reduce noise
                        static BOOL firstSampleLogged = NO;
                        if (!firstSampleLogged) {
                            NSLog(@"📹 ScreenCaptureKit sample: %dx%d, codec: %@ (0x%x)", 
                                  dimensions.width, dimensions.height, codecString, (unsigned int)codecType);
                            firstSampleLogged = YES;
                        }
                        
                        // Direct sample buffer appending with ultra-minimal settings
                        if (g_videoWriterInput.isReadyForMoreMediaData) {
                            BOOL success = [g_videoWriterInput appendSampleBuffer:sampleBuffer];
                            if (!success) {
                                NSLog(@"❌ Failed to append sample buffer: %@", g_assetWriter.error);
                            }
                        } else {
                            NSLog(@"❌ Video writer input not ready");
                        }
                    }
                } else {
                    NSLog(@"❌ Invalid sample buffer - formatDesc:%@ presentationTime valid:%d", 
                          formatDesc, CMTIME_IS_VALID(presentationTime));
                }
            }
            break;
        case SCStreamOutputTypeAudio:
            if (g_audioWriterInput && g_audioWriterInput.isReadyForMoreMediaData) {
                BOOL success = [g_audioWriterInput appendSampleBuffer:sampleBuffer];
                if (!success) {
                    NSLog(@"❌ Failed to append audio sample: %@", g_assetWriter.error);
                }
            }
            break;
        case SCStreamOutputTypeMicrophone:
            if (g_audioWriterInput && g_audioWriterInput.isReadyForMoreMediaData) {
                BOOL success = [g_audioWriterInput appendSampleBuffer:sampleBuffer];
                if (!success) {
                    NSLog(@"❌ Failed to append microphone sample: %@", g_assetWriter.error);
                }
            }
            break;
    }
}
@end

@implementation ScreenCaptureKitRecorder

+ (BOOL)isScreenCaptureKitAvailable {
    // ScreenCaptureKit etkinleştir - video dosyası sorunu çözülecek
    
    if (@available(macOS 12.3, *)) {
        NSLog(@"🔍 ScreenCaptureKit availability check - macOS 12.3+ confirmed");
        
        // Try to access ScreenCaptureKit classes to verify they're actually available
        @try {
            Class scStreamClass = NSClassFromString(@"SCStream");
            Class scContentFilterClass = NSClassFromString(@"SCContentFilter");
            Class scShareableContentClass = NSClassFromString(@"SCShareableContent");
            
            if (scStreamClass && scContentFilterClass && scShareableContentClass) {
                NSLog(@"✅ ScreenCaptureKit classes are available");
                return YES;
            } else {
                NSLog(@"❌ ScreenCaptureKit classes not found");
                NSLog(@"   SCStream: %@", scStreamClass ? @"✅" : @"❌");
                NSLog(@"   SCContentFilter: %@", scContentFilterClass ? @"✅" : @"❌");
                NSLog(@"   SCShareableContent: %@", scShareableContentClass ? @"✅" : @"❌");
                return NO;
            }
        } @catch (NSException *exception) {
            NSLog(@"❌ Exception checking ScreenCaptureKit classes: %@", exception.reason);
            return NO;
        }
    }
    NSLog(@"❌ macOS version < 12.3 - ScreenCaptureKit not available");
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
                
                // TEMPORARILY DISABLED: Window exclusion for testing
                NSMutableArray *excludedWindows = [NSMutableArray array];
                NSMutableArray *excludedApps = [NSMutableArray array];
                
                NSLog(@"🎯 Window exclusion re-enabled with working video format");
                
                // Exclude current Node.js process windows (overlay selectors)
                for (SCWindow *window in content.windows) {
                    if (window.owningApplication.processID == currentPID) {
                        [excludedWindows addObject:window];
                        NSLog(@"🚫 Excluding Node.js overlay window: %@ (PID: %d)", window.title, currentPID);
                    }
                }
                
                // Also exclude Electron app and high-level overlay windows
                for (SCWindow *window in content.windows) {
                    NSString *appName = window.owningApplication.applicationName;
                    NSString *windowTitle = window.title ? window.title : @"<No Title>";
                    
                    // Comprehensive Electron window detection
                    BOOL shouldExclude = NO;
                    
                    // Check app name patterns
                    if ([appName containsString:@"Electron"] || 
                        [appName isEqualToString:@"electron"] ||
                        [appName isEqualToString:@"Electron Helper"]) {
                        shouldExclude = YES;
                    }
                    
                    // Check window title patterns
                    if ([windowTitle containsString:@"Electron"] ||
                        [windowTitle containsString:@"camera"] ||
                        [windowTitle containsString:@"Camera"] ||
                        [windowTitle containsString:@"overlay"] ||
                        [windowTitle containsString:@"Overlay"]) {
                        shouldExclude = YES;
                    }
                    
                    // Check window properties (transparent, always on top windows)
                    if (window.windowLayer > 100) { // High window levels (like alwaysOnTop)
                        shouldExclude = YES;
                        NSLog(@"📋 High-level window detected: '%@' (Level: %ld)", windowTitle, (long)window.windowLayer);
                    }
                    
                    if (shouldExclude) {
                        [excludedWindows addObject:window];
                        NSLog(@"🚫 Excluding window: '%@' from %@ (PID: %d, Level: %ld)", 
                              windowTitle, appName, window.owningApplication.processID, (long)window.windowLayer);
                    }
                }
                
                NSLog(@"📊 Total windows to exclude: %lu", (unsigned long)excludedWindows.count);
                
                // Create content filter - exclude overlay windows from recording
                SCContentFilter *filter = [[SCContentFilter alloc] 
                    initWithDisplay:targetDisplay 
                    excludingWindows:excludedWindows];
                NSLog(@"🎯 Using window-level exclusion for overlay prevention");
                
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
                
                // Setup video writer
                g_outputPath = config[@"outputPath"];
                if (![self setupVideoWriterWithWidth:streamConfig.width 
                                               height:streamConfig.height 
                                         outputPath:g_outputPath 
                                      includeAudio:[config[@"includeSystemAudio"] boolValue] || [config[@"includeMicrophone"] boolValue]]) {
                    NSLog(@"❌ Failed to setup video writer");
                    contentError = [NSError errorWithDomain:@"ScreenCaptureKitError" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Video writer setup failed"}];
                    dispatch_semaphore_signal(semaphore);
                    return;
                }
                
                // Create delegate and output
                g_streamDelegate = [[ScreenCaptureKitRecorderDelegate alloc] init];
                g_streamOutput = [[ScreenCaptureKitStreamOutput alloc] init];
                
                // Create and start stream
                g_stream = [[SCStream alloc] initWithFilter:filter 
                                              configuration:streamConfig 
                                                   delegate:g_streamDelegate];
                
                // Add stream output using correct API
                NSError *outputError = nil;
                BOOL outputAdded = [g_stream addStreamOutput:g_streamOutput 
                                                        type:SCStreamOutputTypeScreen 
                                              sampleHandlerQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)
                                                           error:&outputError];
                if (!outputAdded) {
                    NSLog(@"❌ Failed to add screen output: %@", outputError);
                }
                
                if ([config[@"includeSystemAudio"] boolValue]) {
                    if (@available(macOS 13.0, *)) {
                        BOOL audioOutputAdded = [g_stream addStreamOutput:g_streamOutput 
                                                                     type:SCStreamOutputTypeAudio 
                                                           sampleHandlerQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)
                                                                        error:&outputError];
                        if (!audioOutputAdded) {
                            NSLog(@"❌ Failed to add audio output: %@", outputError);
                        }
                    }
                }
                
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
    NSLog(@"🛑 stopRecording called");
    if (@available(macOS 12.3, *)) {
        if (g_stream && g_isRecording) {
            NSLog(@"🛑 Calling stopCaptureWithCompletionHandler");
            [g_stream stopCaptureWithCompletionHandler:^(NSError *error) {
                NSLog(@"🛑 stopCaptureWithCompletionHandler callback invoked");
                if (error) {
                    NSLog(@"Error stopping ScreenCaptureKit recording: %@", error);
                } else {
                    NSLog(@"ScreenCaptureKit recording stopped successfully");
                }
                
                // Finalize video file immediately (sync)
                NSLog(@"🔍 Checking asset writer status for finalization");
                if (g_assetWriter) {
                    NSString *statusString = @"Unknown";
                    switch (g_assetWriter.status) {
                        case AVAssetWriterStatusUnknown: statusString = @"Unknown"; break;
                        case AVAssetWriterStatusWriting: statusString = @"Writing"; break;
                        case AVAssetWriterStatusCompleted: statusString = @"Completed"; break;
                        case AVAssetWriterStatusFailed: statusString = @"Failed"; break;
                        case AVAssetWriterStatusCancelled: statusString = @"Cancelled"; break;
                    }
                    NSLog(@"🔍 Asset writer status: %ld (%@)", (long)g_assetWriter.status, statusString);
                    if (g_assetWriter.status == AVAssetWriterStatusFailed) {
                        NSLog(@"❌ Asset writer failed with error: %@", g_assetWriter.error);
                    }
                    
                    if (g_assetWriter.status == AVAssetWriterStatusWriting) {
                        NSLog(@"🔄 Starting video finalization process");
                        [g_videoWriterInput markAsFinished];
                        if (g_audioWriterInput) {
                            [g_audioWriterInput markAsFinished];
                        }
                        
                        // Use asynchronous finishWriting with completion handler
                        [g_assetWriter finishWritingWithCompletionHandler:^{
                            if (g_assetWriter.status == AVAssetWriterStatusCompleted) {
                                NSLog(@"✅ ScreenCaptureKit video file finalized successfully: %@", g_outputPath);
                            } else {
                                NSLog(@"❌ ScreenCaptureKit video finalization failed: %@", g_assetWriter.error);
                            }
                        }];
                        
                        // Cleanup
                        g_assetWriter = nil;
                        g_videoWriterInput = nil;
                        g_audioWriterInput = nil;
                        g_outputPath = nil;
                        g_sessionStarted = NO;
                    } else {
                        NSLog(@"⚠️ Asset writer not in writing status: %ld", (long)g_assetWriter.status);
                    }
                } else {
                    NSLog(@"❌ No asset writer found for finalization");
                }
                
                g_isRecording = NO;
                g_stream = nil;
                g_streamDelegate = nil;
                g_streamOutput = nil;
            }];
        }
    }
}

+ (BOOL)isRecording {
    return g_isRecording;
}

+ (BOOL)setupVideoWriterWithWidth:(NSInteger)width 
                           height:(NSInteger)height 
                       outputPath:(NSString *)outputPath 
                     includeAudio:(BOOL)includeAudio {
    
    // Create asset writer with QuickTime format like AVFoundation
    NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
    NSError *error = nil;
    g_assetWriter = [[AVAssetWriter alloc] initWithURL:outputURL fileType:AVFileTypeMPEG4 error:&error];
    
    if (error || !g_assetWriter) {
        NSLog(@"❌ Failed to create asset writer: %@", error);
        return NO;
    }
    
    // Ultra-minimal H.264 video settings - no compression properties at all
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height)
    };
    
    g_videoWriterInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    g_videoWriterInput.expectsMediaDataInRealTime = YES;
    
    if (![g_assetWriter canAddInput:g_videoWriterInput]) {
        NSLog(@"❌ Cannot add video input to asset writer");
        return NO;
    }
    [g_assetWriter addInput:g_videoWriterInput];
    
    // No pixel buffer adaptor - use direct sample buffer approach
    NSLog(@"✅ Video input configured for direct sample buffer appending");
    
    // Audio writer input (if needed)
    if (includeAudio) {
        NSDictionary *audioSettings = @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVSampleRateKey: @(44100.0),
            AVNumberOfChannelsKey: @(2),
            AVEncoderBitRateKey: @(128000)
        };
        
        g_audioWriterInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
        g_audioWriterInput.expectsMediaDataInRealTime = YES;
        
        if ([g_assetWriter canAddInput:g_audioWriterInput]) {
            [g_assetWriter addInput:g_audioWriterInput];
        }
    }
    
    // Start writing (session will be started when first sample arrives)
    if (![g_assetWriter startWriting]) {
        NSLog(@"❌ Failed to start writing: %@", g_assetWriter.error);
        return NO;
    }
    
    g_sessionStarted = NO;  // Reset session flag
    NSLog(@"✅ ScreenCaptureKit video writer setup complete: %@", outputPath);
    
    return YES;
}

@end
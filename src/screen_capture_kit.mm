#import "screen_capture_kit.h"
#import <CoreImage/CoreImage.h>

static SCStream *g_stream = nil;
static id<SCStreamDelegate> g_streamDelegate = nil;
static id<SCStreamOutput> g_streamOutput = nil;
static BOOL g_isRecording = NO;

// Electron-safe direct writing approach
static AVAssetWriter *g_assetWriter = nil;
static AVAssetWriterInput *g_assetWriterInput = nil;
static AVAssetWriterInputPixelBufferAdaptor *g_pixelBufferAdaptor = nil;
static NSString *g_outputPath = nil;
static CMTime g_startTime;
static CMTime g_currentTime;
static BOOL g_writerStarted = NO;
static int g_frameNumber = 0;

@interface ElectronSafeDelegate : NSObject <SCStreamDelegate>
@end

@implementation ElectronSafeDelegate
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    NSLog(@"🛑 ScreenCaptureKit stream stopped in delegate");
    g_isRecording = NO;
    
    if (error) {
        NSLog(@"❌ Stream stopped with error: %@", error);
    } else {
        NSLog(@"✅ ScreenCaptureKit stream stopped successfully in delegate");
    }
    
    // Finalize video writer
    NSLog(@"🎬 Delegate calling finalizeVideoWriter...");
    [ScreenCaptureKitRecorder finalizeVideoWriter];
    NSLog(@"🎬 Delegate finished calling finalizeVideoWriter");
}
@end

@interface ElectronSafeOutput : NSObject <SCStreamOutput>
- (void)processSampleBufferSafely:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type;
@end

@implementation ElectronSafeOutput
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    // EXTREME SAFETY: Complete isolation with separate thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        @autoreleasepool {
            [self processSampleBufferSafely:sampleBuffer ofType:type];
        }
    });
}

- (void)processSampleBufferSafely:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    // ELECTRON CRASH PROTECTION: Multiple layers of safety
    if (!g_isRecording || !g_assetWriterInput) {
        NSLog(@"🔍 ProcessSampleBuffer: isRecording=%d, type=%d, writerInput=%p", g_isRecording, (int)type, g_assetWriterInput);
        return;
    }
    
    NSLog(@"🔍 ProcessSampleBuffer: Processing frame, type=%d (Screen=%d, Audio=%d)...", (int)type, (int)SCStreamOutputTypeScreen, (int)SCStreamOutputTypeAudio);
    
    // Process both screen and audio if available
    if (type == SCStreamOutputTypeAudio) {
        NSLog(@"🔊 Received audio sample buffer - skipping for video-only recording");
        return;
    }
    
    if (type != SCStreamOutputTypeScreen) {
        NSLog(@"⚠️ Unknown sample buffer type: %d", (int)type);
        return;
    }
    
    // SAFETY LAYER 1: Null checks
    if (!sampleBuffer || !CMSampleBufferIsValid(sampleBuffer)) {
        NSLog(@"❌ LAYER 1 FAIL: Invalid sample buffer");
        return;
    }
    NSLog(@"✅ LAYER 1 PASS: Sample buffer valid");
    
    // SAFETY LAYER 2: Try-catch with complete isolation
    @try {
        @autoreleasepool {
            // SAFETY LAYER 3: Initialize writer safely (only once)
            static BOOL initializationAttempted = NO;
            if (!g_writerStarted && !initializationAttempted && g_assetWriter && g_assetWriterInput) {
                initializationAttempted = YES;
                @try {
                    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
                    
                    // SAFETY CHECK: Ensure valid time
                    if (CMTIME_IS_VALID(presentationTime) && CMTIME_IS_NUMERIC(presentationTime)) {
                        g_startTime = presentationTime;
                        g_currentTime = g_startTime;
                        
                        // SAFETY LAYER 4: Writer state validation
                        if (g_assetWriter.status == AVAssetWriterStatusUnknown) {
                            [g_assetWriter startWriting];
                            [g_assetWriter startSessionAtSourceTime:g_startTime];
                            g_writerStarted = YES;
                            NSLog(@"✅ Ultra-safe ScreenCaptureKit writer started");
                        }
                    } else {
                        // Use current time if sample buffer time is invalid
                        NSLog(@"⚠️ Invalid sample buffer time, using current time");
                        g_startTime = CMTimeMakeWithSeconds(CACurrentMediaTime(), 600);
                        g_currentTime = g_startTime;
                        
                        if (g_assetWriter.status == AVAssetWriterStatusUnknown) {
                            [g_assetWriter startWriting];
                            [g_assetWriter startSessionAtSourceTime:g_startTime];
                            g_writerStarted = YES;
                            NSLog(@"✅ Ultra-safe ScreenCaptureKit writer started with current time");
                        }
                    }
                } @catch (NSException *writerException) {
                    NSLog(@"⚠️ Writer initialization failed safely: %@", writerException.reason);
                    return;
                }
            }
            
            // SAFETY LAYER 5: Frame processing with isolation
            if (!g_writerStarted || !g_assetWriterInput || !g_pixelBufferAdaptor) {
                NSLog(@"❌ LAYER 5 FAIL: writer=%d, input=%p, adaptor=%p", g_writerStarted, g_assetWriterInput, g_pixelBufferAdaptor);
                return;
            }
            NSLog(@"✅ LAYER 5 PASS: Writer components ready");
            
            // SAFETY LAYER 6: Higher frame rate for video
            static NSTimeInterval lastProcessTime = 0;
            NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
            if (currentTime - lastProcessTime < 0.033) { // Max 30 FPS
                NSLog(@"❌ LAYER 6 FAIL: Rate limited (%.3fs since last)", currentTime - lastProcessTime);
                return;
            }
            lastProcessTime = currentTime;
            NSLog(@"✅ LAYER 6 PASS: Rate limiting OK");
            
            // SAFETY LAYER 7: Input readiness check
            if (!g_assetWriterInput.isReadyForMoreMediaData) {
                NSLog(@"❌ LAYER 7 FAIL: Writer not ready for data");
                return;
            }
            NSLog(@"✅ LAYER 7 PASS: Writer ready for data");
            
            // SAFETY LAYER 8: Get pixel buffer from sample buffer
            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            BOOL createdDummyBuffer = NO;
            
            if (!pixelBuffer) {
                // Try alternative methods to get pixel buffer
                CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
                if (formatDesc) {
                    CMMediaType mediaType = CMFormatDescriptionGetMediaType(formatDesc);
                    NSLog(@"🔍 Sample buffer media type: %u (Video=%u)", (unsigned int)mediaType, (unsigned int)kCMMediaType_Video);
                    return; // Skip processing if no pixel buffer
                } else {
                    NSLog(@"❌ No pixel buffer and no format description - permissions issue");
                    
                    // Create a dummy pixel buffer using the pool from adaptor
                    CVPixelBufferRef dummyBuffer = NULL;
                    
                    // Try to get a pixel buffer from the adaptor's buffer pool
                    CVPixelBufferPoolRef bufferPool = g_pixelBufferAdaptor.pixelBufferPool;
                    if (bufferPool) {
                        CVReturn poolResult = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPool, &dummyBuffer);
                        if (poolResult == kCVReturnSuccess && dummyBuffer) {
                            pixelBuffer = dummyBuffer;
                            createdDummyBuffer = YES;
                            NSLog(@"✅ Created dummy buffer from adaptor pool");
                            
                            // Fill buffer with black pixels
                            CVPixelBufferLockBaseAddress(pixelBuffer, 0);
                            void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
                            size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
                            size_t height = CVPixelBufferGetHeight(pixelBuffer);
                            if (baseAddress) {
                                memset(baseAddress, 0, bytesPerRow * height);
                            }
                            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
                        } else {
                            NSLog(@"❌ Failed to create buffer from pool: %d", poolResult);
                        }
                    }
                    
                    // Fallback: create manual buffer if pool method failed
                    if (!dummyBuffer) {
                        CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, 
                                                            1920, 1080, 
                                                            kCVPixelFormatType_32BGRA, 
                                                            NULL, &dummyBuffer);
                        if (result == kCVReturnSuccess && dummyBuffer) {
                            pixelBuffer = dummyBuffer;
                            createdDummyBuffer = YES;
                            NSLog(@"✅ Created manual dummy buffer");
                            
                            // Fill buffer with black pixels
                            CVPixelBufferLockBaseAddress(pixelBuffer, 0);
                            void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
                            size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
                            size_t height = CVPixelBufferGetHeight(pixelBuffer);
                            if (baseAddress) {
                                memset(baseAddress, 0, bytesPerRow * height);
                            }
                            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
                        } else {
                            NSLog(@"❌ Failed to create dummy pixel buffer");
                            return;
                        }
                    }
                }
            }
            NSLog(@"✅ LAYER 8 PASS: Pixel buffer ready (dummy=%d)", createdDummyBuffer);
            
            // SAFETY LAYER 9: Dimension validation - flexible this time
            size_t width = CVPixelBufferGetWidth(pixelBuffer);
            size_t height = CVPixelBufferGetHeight(pixelBuffer);
            if (width == 0 || height == 0 || width > 4096 || height > 4096) {
                NSLog(@"❌ LAYER 9 FAIL: Invalid dimensions %zux%zu", width, height);
                return; // Skip only if clearly invalid
            }
            NSLog(@"✅ LAYER 9 PASS: Valid dimensions %zux%zu", width, height);
            
            // SAFETY LAYER 10: Time validation - use sequential timing
            g_frameNumber++;
            
            // Create sequential time stamps
            CMTime relativeTime = CMTimeMake(g_frameNumber, 30); // 30 FPS sequential
            
            if (!CMTIME_IS_VALID(relativeTime)) {
                return;
            }
            
            double seconds = CMTimeGetSeconds(relativeTime);
            if (seconds > 30.0) { // Max 30 seconds
                return;
            }
            
            // SAFETY LAYER 11: Append with complete exception handling
            @try {
                // Use pixel buffer directly - copy was causing errors
                NSLog(@"🔍 Attempting to append frame %d with time %.3fs", g_frameNumber, seconds);
                BOOL success = [g_pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:relativeTime];
                
                if (success) {
                    g_currentTime = relativeTime;
                    static int ultraSafeFrameCount = 0;
                    ultraSafeFrameCount++;
                    NSLog(@"✅ Frame %d appended successfully! (%.1fs)", ultraSafeFrameCount, seconds);
                } else {
                    NSLog(@"❌ Failed to append frame %d - adaptor rejected", g_frameNumber);
                }
            } @catch (NSException *appendException) {
                NSLog(@"🛡️ Append exception handled safely: %@", appendException.reason);
                // Continue gracefully - don't crash
            }
            
            // Cleanup dummy pixel buffer if we created one
            if (pixelBuffer && createdDummyBuffer) {
                CVPixelBufferRelease(pixelBuffer);
                NSLog(@"🧹 Released dummy pixel buffer");
            }
        }
    } @catch (NSException *outerException) {
        NSLog(@"🛡️ Outer exception handled: %@", outerException.reason);
        // Ultimate safety - graceful continue
    } @catch (...) {
        NSLog(@"🛡️ Unknown exception caught and handled safely");
        // Catch any C++ exceptions too
    }
}
@end

@implementation ScreenCaptureKitRecorder

+ (BOOL)isScreenCaptureKitAvailable {
    if (@available(macOS 12.3, *)) {
        return [SCShareableContent class] != nil && [SCStream class] != nil;
    }
    return NO;
}

+ (BOOL)startRecordingWithConfiguration:(NSDictionary *)config delegate:(id)delegate error:(NSError **)error {
    if (g_isRecording) {
        return NO;
    }
    
    g_outputPath = config[@"outputPath"];
    g_writerStarted = NO;
    g_frameNumber = 0; // Reset frame counter for new recording
    
    // Setup Electron-safe video writer
    [ScreenCaptureKitRecorder setupVideoWriter];
    
    NSLog(@"🎬 Starting Electron-safe ScreenCaptureKit recording");
    
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *contentError) {
        if (contentError) {
            NSLog(@"❌ Failed to get content: %@", contentError);
            return;
        }
        
        NSLog(@"✅ Got shareable content with %lu displays", (unsigned long)content.displays.count);
        
        if (content.displays.count == 0) {
            NSLog(@"❌ No displays available for recording");
            return;
        }
        
        // Get primary display
        SCDisplay *targetDisplay = content.displays.firstObject;
        if (!targetDisplay) {
            NSLog(@"❌ No target display found");
            return;
        }
        
        NSLog(@"🖥️ Using display: %@ (%dx%d)", @(targetDisplay.displayID), (int)targetDisplay.width, (int)targetDisplay.height);
        
        // Create content filter for entire display - NO exclusions
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:targetDisplay excludingWindows:@[]];
        NSLog(@"✅ Content filter created for display");
        
        // Stream configuration - fixed resolution to avoid permissions issues
        SCStreamConfiguration *streamConfig = [[SCStreamConfiguration alloc] init];
        streamConfig.width = 1920;
        streamConfig.height = 1080;
        streamConfig.minimumFrameInterval = CMTimeMake(1, 30); // 30 FPS
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA;
        streamConfig.showsCursor = YES;
        
        NSLog(@"🔧 Stream config: %zux%zu, pixelFormat=%u, FPS=30", streamConfig.width, streamConfig.height, (unsigned)streamConfig.pixelFormat);
        
        // Create Electron-safe delegates
        g_streamDelegate = [[ElectronSafeDelegate alloc] init];
        g_streamOutput = [[ElectronSafeOutput alloc] init];
        
        NSLog(@"🤝 Delegates created");
        
        // Create stream
        NSError *streamError = nil;
        g_stream = [[SCStream alloc] initWithFilter:filter configuration:streamConfig delegate:g_streamDelegate];
        
        if (!g_stream) {
            NSLog(@"❌ Failed to create stream");
            return;
        }
        
        NSLog(@"✅ Stream created successfully");
        
        // Add stream output with explicit error checking
        BOOL outputResult = [g_stream addStreamOutput:g_streamOutput
                                                 type:SCStreamOutputTypeScreen
                                   sampleHandlerQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)
                                                error:&streamError];
        
        if (!outputResult || streamError) {
            NSLog(@"❌ Failed to add stream output: %@", streamError);
            return;
        }
        
        NSLog(@"✅ Stream output added successfully");
        
        [g_stream startCaptureWithCompletionHandler:^(NSError *startError) {
            if (startError) {
                NSLog(@"❌ Failed to start capture: %@", startError);
                g_isRecording = NO;
            } else {
                NSLog(@"✅ Frame capture started successfully");
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
    
    NSLog(@"🛑 Stopping Electron-safe ScreenCaptureKit recording");
    
    [g_stream stopCaptureWithCompletionHandler:^(NSError *stopError) {
        if (stopError) {
            NSLog(@"❌ Stop error: %@", stopError);
        } else {
            NSLog(@"✅ ScreenCaptureKit stream stopped in completion handler");
        }
        
        // Finalize video since delegate might not be called
        NSLog(@"🎬 Completion handler calling finalizeVideoWriter...");
        [ScreenCaptureKitRecorder finalizeVideoWriter];
        NSLog(@"🎬 Completion handler finished calling finalizeVideoWriter");
    }];
}

+ (BOOL)isRecording {
    return g_isRecording;
}

+ (void)setupVideoWriter {
    if (g_assetWriter) {
        return; // Already setup
    }
    
    NSLog(@"🔧 Setting up Electron-safe video writer");
    
    NSURL *outputURL = [NSURL fileURLWithPath:g_outputPath];
    NSError *error = nil;
    
    g_assetWriter = [[AVAssetWriter alloc] initWithURL:outputURL fileType:AVFileTypeQuickTimeMovie error:&error];
    
    if (error || !g_assetWriter) {
        NSLog(@"❌ Failed to create asset writer: %@", error);
        return;
    }
    
    // Fixed video settings for compatibility
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @1920,
        AVVideoHeightKey: @1080,
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(1920 * 1080 * 2), // 2 bits per pixel
            AVVideoMaxKeyFrameIntervalKey: @30,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel
        }
    };
    
    g_assetWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    g_assetWriterInput.expectsMediaDataInRealTime = NO; // Safer for Electron
    
    // Pixel buffer attributes matching ScreenCaptureKit format
    NSDictionary *pixelBufferAttributes = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString*)kCVPixelBufferWidthKey: @1920,
        (NSString*)kCVPixelBufferHeightKey: @1080
    };
    
    g_pixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:g_assetWriterInput sourcePixelBufferAttributes:pixelBufferAttributes];
    
    if ([g_assetWriter canAddInput:g_assetWriterInput]) {
        [g_assetWriter addInput:g_assetWriterInput];
        NSLog(@"✅ Electron-safe video writer setup complete");
    } else {
        NSLog(@"❌ Failed to add input to asset writer");
    }
}

+ (void)finalizeVideoWriter {
    NSLog(@"🎬 Finalizing video writer - writer: %p, started: %d", g_assetWriter, g_writerStarted);
    
    if (!g_assetWriter || !g_writerStarted) {
        NSLog(@"⚠️ Video writer not started properly - writer: %p, started: %d", g_assetWriter, g_writerStarted);
        [ScreenCaptureKitRecorder cleanupVideoWriter];
        return;
    }
    
    NSLog(@"🎬 Marking input as finished and finalizing...");
    [g_assetWriterInput markAsFinished];
    
    [g_assetWriter finishWritingWithCompletionHandler:^{
        NSLog(@"🎬 Finalization completion handler called");
        if (g_assetWriter.status == AVAssetWriterStatusCompleted) {
            NSLog(@"✅ Video finalization successful: %@", g_outputPath);
        } else {
            NSLog(@"❌ Video finalization failed - status: %ld, error: %@", (long)g_assetWriter.status, g_assetWriter.error);
        }
        
        [ScreenCaptureKitRecorder cleanupVideoWriter];
    }];
    
    NSLog(@"🎬 Finalization request submitted, waiting for completion...");
}

+ (void)cleanupVideoWriter {
    g_assetWriter = nil;
    g_assetWriterInput = nil;
    g_pixelBufferAdaptor = nil;
    g_writerStarted = NO;
    g_frameNumber = 0; // Reset frame counter
    g_stream = nil;
    g_streamDelegate = nil;
    g_streamOutput = nil;
    
    NSLog(@"🧹 Video writer cleanup complete");
}

@end
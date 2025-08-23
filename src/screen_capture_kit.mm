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
    if (!g_isRecording || type != SCStreamOutputTypeScreen || !g_assetWriterInput) {
        return;
    }
    
    // SAFETY LAYER 1: Null checks
    if (!sampleBuffer || !CMSampleBufferIsValid(sampleBuffer)) {
        return;
    }
    
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
                        // Use zero time if sample buffer time is invalid
                        NSLog(@"⚠️ Invalid sample buffer time, using kCMTimeZero");
                        g_startTime = kCMTimeZero;
                        g_currentTime = g_startTime;
                        
                        if (g_assetWriter.status == AVAssetWriterStatusUnknown) {
                            [g_assetWriter startWriting];
                            [g_assetWriter startSessionAtSourceTime:kCMTimeZero];
                            g_writerStarted = YES;
                            NSLog(@"✅ Ultra-safe ScreenCaptureKit writer started with zero time");
                        }
                    }
                } @catch (NSException *writerException) {
                    NSLog(@"⚠️ Writer initialization failed safely: %@", writerException.reason);
                    return;
                }
            }
            
            // SAFETY LAYER 5: Frame processing with isolation
            if (!g_writerStarted || !g_assetWriterInput || !g_pixelBufferAdaptor) {
                return;
            }
            
            // SAFETY LAYER 6: Conservative rate limiting
            static NSTimeInterval lastProcessTime = 0;
            NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
            if (currentTime - lastProcessTime < 0.1) { // Max 10 FPS
                return;
            }
            lastProcessTime = currentTime;
            
            // SAFETY LAYER 7: Input readiness check
            if (!g_assetWriterInput.isReadyForMoreMediaData) {
                return;
            }
            
            // SAFETY LAYER 8: Pixel buffer validation
            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (!pixelBuffer) {
                return;
            }
            
            // SAFETY LAYER 9: Dimension validation - flexible this time
            size_t width = CVPixelBufferGetWidth(pixelBuffer);
            size_t height = CVPixelBufferGetHeight(pixelBuffer);
            if (width == 0 || height == 0 || width > 4096 || height > 4096) {
                return; // Skip only if clearly invalid
            }
            
            // SAFETY LAYER 10: Time validation
            CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            if (!CMTIME_IS_VALID(presentationTime)) {
                return;
            }
            
            CMTime relativeTime = CMTimeSubtract(presentationTime, g_startTime);
            if (!CMTIME_IS_VALID(relativeTime)) {
                return;
            }
            
            double seconds = CMTimeGetSeconds(relativeTime);
            if (seconds < 0 || seconds > 30.0) { // Allow longer recordings
                return;
            }
            
            // SAFETY LAYER 11: Append with complete exception handling
            @try {
                // Use pixel buffer directly - copy was causing errors
                BOOL success = [g_pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:relativeTime];
                
                if (success) {
                    g_currentTime = relativeTime;
                    static int ultraSafeFrameCount = 0;
                    ultraSafeFrameCount++;
                    if (ultraSafeFrameCount % 10 == 0) {
                        NSLog(@"🛡️ Ultra-safe: %d frames (%.1fs)", ultraSafeFrameCount, seconds);
                    }
                }
            } @catch (NSException *appendException) {
                NSLog(@"🛡️ Append exception handled safely: %@", appendException.reason);
                // Continue gracefully - don't crash
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
    
    // Setup Electron-safe video writer
    [ScreenCaptureKitRecorder setupVideoWriter];
    
    NSLog(@"🎬 Starting Electron-safe ScreenCaptureKit recording");
    
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *contentError) {
        if (contentError) {
            NSLog(@"❌ Failed to get content: %@", contentError);
            return;
        }
        
        // Get primary display
        SCDisplay *targetDisplay = content.displays.firstObject;
        
        // Simple content filter - no exclusions for now
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:targetDisplay excludingWindows:@[]];
        
        // Electron-optimized stream configuration (lower resource usage)
        SCStreamConfiguration *streamConfig = [[SCStreamConfiguration alloc] init];
        streamConfig.width = 1280;
        streamConfig.height = 720;
        streamConfig.minimumFrameInterval = CMTimeMake(1, 10); // 10 FPS for stability
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA;
        streamConfig.capturesAudio = NO; // Disable audio for simplicity
        streamConfig.excludesCurrentProcessAudio = YES;
        
        // Create Electron-safe delegates
        g_streamDelegate = [[ElectronSafeDelegate alloc] init];
        g_streamOutput = [[ElectronSafeOutput alloc] init];
        
        // Create stream
        g_stream = [[SCStream alloc] initWithFilter:filter configuration:streamConfig delegate:g_streamDelegate];
        
        [g_stream addStreamOutput:g_streamOutput
                             type:SCStreamOutputTypeScreen
               sampleHandlerQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)
                            error:nil];
        
        [g_stream startCaptureWithCompletionHandler:^(NSError *startError) {
            if (startError) {
                NSLog(@"❌ Failed to start capture: %@", startError);
            } else {
                NSLog(@"✅ Frame capture started");
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
    
    // Ultra-conservative Electron video settings
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @1280,
        AVVideoHeightKey: @720,
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(1280 * 720 * 1), // Lower bitrate
            AVVideoMaxKeyFrameIntervalKey: @10,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel
        }
    };
    
    g_assetWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    g_assetWriterInput.expectsMediaDataInRealTime = NO; // Safer for Electron
    
    // Pixel buffer attributes matching ScreenCaptureKit format
    NSDictionary *pixelBufferAttributes = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString*)kCVPixelBufferWidthKey: @1280,
        (NSString*)kCVPixelBufferHeightKey: @720
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
    g_stream = nil;
    g_streamDelegate = nil;
    g_streamOutput = nil;
    
    NSLog(@"🧹 Video writer cleanup complete");
}

@end
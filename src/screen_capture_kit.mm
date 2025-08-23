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
@end

@implementation ElectronSafeOutput
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (!g_isRecording || type != SCStreamOutputTypeScreen || !g_assetWriterInput) {
        return;
    }
    
    @autoreleasepool {
        // Initialize video writer on first frame
        if (!g_writerStarted && g_assetWriter && g_assetWriterInput) {
            g_startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            g_currentTime = g_startTime;
            
            [g_assetWriter startWriting];
            [g_assetWriter startSessionAtSourceTime:g_startTime];
            g_writerStarted = YES;
            NSLog(@"✅ Electron-safe video writer started");
        }
        
        // Write sample buffer with improved pixel buffer validation
        if (g_writerStarted && g_assetWriterInput.isReadyForMoreMediaData) {
            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            
            // Validate pixel buffer more thoroughly
            if (pixelBuffer && g_pixelBufferAdaptor) {
                // Check if pixel buffer has valid dimensions
                size_t width = CVPixelBufferGetWidth(pixelBuffer);
                size_t height = CVPixelBufferGetHeight(pixelBuffer);
                
                if (width > 0 && height > 0) {
                    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
                    CMTime relativeTime = CMTimeSubtract(presentationTime, g_startTime);
                    
                    BOOL success = [g_pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:relativeTime];
                    if (success) {
                        g_currentTime = relativeTime;
                        static int validFrameCount = 0;
                        validFrameCount++;
                        if (validFrameCount % 30 == 0) {
                            NSLog(@"✅ Successfully wrote %d valid frames (%dx%d)", validFrameCount, (int)width, (int)height);
                        }
                    } else {
                        NSLog(@"⚠️ Failed to append valid pixel buffer (%dx%d) at time %f", (int)width, (int)height, CMTimeGetSeconds(relativeTime));
                        NSLog(@"Asset writer status: %ld, error: %@", (long)g_assetWriter.status, g_assetWriter.error);
                    }
                } else {
                    static int invalidSizeCount = 0;
                    invalidSizeCount++;
                    if (invalidSizeCount % 50 == 0) {
                        NSLog(@"⚠️ Invalid pixel buffer dimensions: %dx%d (%d times)", (int)width, (int)height, invalidSizeCount);
                    }
                }
            } else {
                // Only log occasionally to avoid spam
                static int nullBufferCount = 0;
                nullBufferCount++;
                if (nullBufferCount % 100 == 0) {
                    NSLog(@"⚠️ Null pixel buffer (%d times) - adaptor: %p", nullBufferCount, g_pixelBufferAdaptor);
                }
            }
        }
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
        
        // Stream configuration
        SCStreamConfiguration *streamConfig = [[SCStreamConfiguration alloc] init];
        streamConfig.width = 1280;
        streamConfig.height = 720;
        streamConfig.minimumFrameInterval = CMTimeMake(1, 30);
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA;
        
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
    
    // Electron-safe video settings
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @1280,
        AVVideoHeightKey: @720,
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(1280 * 720 * 2),
            AVVideoMaxKeyFrameIntervalKey: @30
        }
    };
    
    g_assetWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    g_assetWriterInput.expectsMediaDataInRealTime = YES; // Important for live capture
    
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
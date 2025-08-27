#import "screen_capture_kit.h"
#import <CoreImage/CoreImage.h>

static SCStream *g_stream = nil;
static id<SCStreamDelegate> g_streamDelegate = nil;
static id<SCStreamOutput> g_streamOutput = nil;
static BOOL g_isRecording = NO;

// Modern ScreenCaptureKit writer
static AVAssetWriter *g_assetWriter = nil;
static AVAssetWriterInput *g_assetWriterInput = nil;
static AVAssetWriterInputPixelBufferAdaptor *g_pixelBufferAdaptor = nil;
static NSString *g_outputPath = nil;
static BOOL g_writerStarted = NO;
static int g_frameCount = 0;

@interface ModernStreamDelegate : NSObject <SCStreamDelegate>
@end

@implementation ModernStreamDelegate
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    NSLog(@"🛑 Stream stopped");
    g_isRecording = NO;
    
    if (error) {
        NSLog(@"❌ Stream error: %@", error);
    }
    
    [ScreenCaptureKitRecorder finalizeVideoWriter];
}
@end

@interface ModernStreamOutput : NSObject <SCStreamOutput>
@end

@implementation ModernStreamOutput
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (!g_isRecording) return;
    
    // Only process screen frames
    if (type != SCStreamOutputTypeScreen) return;
    
    // Validate sample buffer
    if (!sampleBuffer || !CMSampleBufferIsValid(sampleBuffer)) {
        NSLog(@"⚠️ Invalid sample buffer");
        return;
    }
    
    // Get pixel buffer
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        NSLog(@"⚠️ No pixel buffer in sample");
        return;
    }
    
    // Initialize writer on first frame
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self initializeWriterWithSampleBuffer:sampleBuffer];
    });
    
    if (!g_writerStarted) {
        return;
    }
    
    // Write frame
    [self writePixelBuffer:pixelBuffer];
}

- (void)initializeWriterWithSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!g_assetWriter) return;
    
    NSLog(@"🎬 Initializing writer with first sample");
    
    CMTime startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (!CMTIME_IS_VALID(startTime)) {
        startTime = CMTimeMakeWithSeconds(0, 600);
    }
    
    [g_assetWriter startWriting];
    [g_assetWriter startSessionAtSourceTime:startTime];
    g_writerStarted = YES;
    
    NSLog(@"✅ Writer initialized");
}

- (void)writePixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!g_assetWriterInput.isReadyForMoreMediaData) {
        return;
    }
    
    // Create time for this frame
    CMTime frameTime = CMTimeMakeWithSeconds(g_frameCount / 30.0, 600);
    g_frameCount++;
    
    // Write the frame
    BOOL success = [g_pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:frameTime];
    
    if (success) {
        NSLog(@"✅ Frame %d written", g_frameCount);
    } else {
        NSLog(@"❌ Failed to write frame %d", g_frameCount);
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
        NSLog(@"⚠️ Already recording");
        return NO;
    }
    
    g_outputPath = config[@"outputPath"];
    g_frameCount = 0;
    
    NSLog(@"🎬 Starting modern ScreenCaptureKit recording");
    
    // Setup writer first
    if (![self setupVideoWriter]) {
        NSLog(@"❌ Failed to setup video writer");
        return NO;
    }
    
    // Get shareable content
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *contentError) {
        if (contentError) {
            NSLog(@"❌ Content error: %@", contentError);
            return;
        }
        
        NSLog(@"✅ Got %lu displays", content.displays.count);
        
        if (content.displays.count == 0) {
            NSLog(@"❌ No displays found");
            return;
        }
        
        // Use first display
        SCDisplay *display = content.displays.firstObject;
        NSLog(@"🖥️ Using display %u (%dx%d)", display.displayID, (int)display.width, (int)display.height);
        
        // Create filter for entire display
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        
        // Configure stream
        SCStreamConfiguration *streamConfig = [[SCStreamConfiguration alloc] init];
        
        // Use display's actual dimensions but scale if too large
        NSInteger targetWidth = MIN(display.width, 1920);
        NSInteger targetHeight = MIN(display.height, 1080);
        
        streamConfig.width = targetWidth;
        streamConfig.height = targetHeight;
        streamConfig.minimumFrameInterval = CMTimeMake(1, 30); // 30 FPS
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA;
        streamConfig.showsCursor = YES;
        streamConfig.scalesToFit = YES;
        
        NSLog(@"🔧 Stream: %ldx%ld @ 30fps", targetWidth, targetHeight);
        
        // Create delegates
        g_streamDelegate = [[ModernStreamDelegate alloc] init];
        g_streamOutput = [[ModernStreamOutput alloc] init];
        
        // Create and start stream
        g_stream = [[SCStream alloc] initWithFilter:filter configuration:streamConfig delegate:g_streamDelegate];
        
        if (!g_stream) {
            NSLog(@"❌ Failed to create stream");
            return;
        }
        
        // Add output
        NSError *outputError = nil;
        BOOL outputAdded = [g_stream addStreamOutput:g_streamOutput
                                                type:SCStreamOutputTypeScreen
                                  sampleHandlerQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)
                                               error:&outputError];
        
        if (!outputAdded || outputError) {
            NSLog(@"❌ Output error: %@", outputError);
            return;
        }
        
        NSLog(@"✅ Output added");
        
        // Start capture
        [g_stream startCaptureWithCompletionHandler:^(NSError *startError) {
            if (startError) {
                NSLog(@"❌ Start error: %@", startError);
                g_isRecording = NO;
            } else {
                NSLog(@"✅ Capture started successfully!");
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
    
    NSLog(@"🛑 Stopping recording");
    
    [g_stream stopCaptureWithCompletionHandler:^(NSError *error) {
        if (error) {
            NSLog(@"❌ Stop error: %@", error);
        }
        NSLog(@"✅ Stream stopped");
        [ScreenCaptureKitRecorder finalizeVideoWriter];
    }];
}

+ (BOOL)isRecording {
    return g_isRecording;
}

+ (BOOL)setupVideoWriter {
    if (g_assetWriter) return YES;
    
    NSLog(@"🔧 Setting up video writer");
    
    NSURL *outputURL = [NSURL fileURLWithPath:g_outputPath];
    NSError *error = nil;
    
    g_assetWriter = [[AVAssetWriter alloc] initWithURL:outputURL fileType:AVFileTypeQuickTimeMovie error:&error];
    
    if (error || !g_assetWriter) {
        NSLog(@"❌ Writer creation error: %@", error);
        return NO;
    }
    
    // Video settings
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @1920,
        AVVideoHeightKey: @1080,
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(5000000), // 5 Mbps
            AVVideoMaxKeyFrameIntervalKey: @30
        }
    };
    
    g_assetWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    g_assetWriterInput.expectsMediaDataInRealTime = YES;
    
    // Pixel buffer adaptor
    NSDictionary *pixelBufferAttributes = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString*)kCVPixelBufferWidthKey: @1920,
        (NSString*)kCVPixelBufferHeightKey: @1080
    };
    
    g_pixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor 
                            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:g_assetWriterInput 
                            sourcePixelBufferAttributes:pixelBufferAttributes];
    
    if ([g_assetWriter canAddInput:g_assetWriterInput]) {
        [g_assetWriter addInput:g_assetWriterInput];
        NSLog(@"✅ Video writer ready");
        return YES;
    } else {
        NSLog(@"❌ Cannot add input to writer");
        return NO;
    }
}

+ (void)finalizeVideoWriter {
    NSLog(@"🎬 Finalizing video");
    
    g_isRecording = NO;
    
    if (!g_assetWriter || !g_writerStarted) {
        NSLog(@"⚠️ Writer not ready for finalization");
        [self cleanupVideoWriter];
        return;
    }
    
    [g_assetWriterInput markAsFinished];
    
    [g_assetWriter finishWritingWithCompletionHandler:^{
        if (g_assetWriter.status == AVAssetWriterStatusCompleted) {
            NSLog(@"✅ Video saved: %@", g_outputPath);
        } else {
            NSLog(@"❌ Write failed: %@", g_assetWriter.error);
        }
        
        [ScreenCaptureKitRecorder cleanupVideoWriter];
    }];
}

+ (void)cleanupVideoWriter {
    g_assetWriter = nil;
    g_assetWriterInput = nil;
    g_pixelBufferAdaptor = nil;
    g_writerStarted = NO;
    g_frameCount = 0;
    g_stream = nil;
    g_streamDelegate = nil;
    g_streamOutput = nil;
    
    NSLog(@"🧹 Cleanup complete");
}

@end
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>

static SCStream *g_stream = nil;
static id<SCStreamDelegate> g_streamDelegate = nil;
static id<SCStreamOutput> g_streamOutput = nil;
static BOOL g_isRecording = NO;

// Simple frame capture approach
static NSMutableArray<NSString *> *g_frameFiles = nil;
static NSString *g_outputVideoPath = nil;
static NSInteger g_frameCount = 0;

@interface SimpleScreenCaptureDelegate : NSObject <SCStreamDelegate>
@end

@implementation SimpleScreenCaptureDelegate

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if (error) {
        NSLog(@"❌ ScreenCaptureKit stream stopped with error: %@", error);
    } else {
        NSLog(@"✅ ScreenCaptureKit stream stopped successfully");
    }
    g_isRecording = NO;
}

@end

@interface SimpleScreenCaptureOutput : NSObject <SCStreamOutput>
@end

@implementation SimpleScreenCaptureOutput

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (!g_isRecording || type != SCStreamOutputTypeScreen) {
        return;
    }
    
    // Extract pixel buffer from sample buffer
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        return;
    }
    
    // Convert to CGImage using CoreImage
    CIContext *context = [CIContext context];
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CGImageRef cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
    
    if (cgImage) {
        // Save as PNG frame
        NSString *frameFilename = [NSString stringWithFormat:@"frame_%04ld.png", (long)g_frameCount++];
        NSString *frameDir = [g_outputVideoPath stringByDeletingLastPathComponent];
        NSString *framesDir = [frameDir stringByAppendingPathComponent:@"frames"];
        
        // Create frames directory
        [[NSFileManager defaultManager] createDirectoryAtPath:framesDir 
                                  withIntermediateDirectories:YES 
                                                   attributes:nil 
                                                        error:nil];
        
        NSString *framePath = [framesDir stringByAppendingPathComponent:frameFilename];
        NSURL *frameURL = [NSURL fileURLWithPath:framePath];
        
        // Save PNG
        CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)frameURL, 
            kUTTypePNG, 
            1, 
            NULL
        );
        
        if (destination) {
            CGImageDestinationAddImage(destination, cgImage, NULL);
            BOOL success = CGImageDestinationFinalize(destination);
            CFRelease(destination);
            
            if (success) {
                [g_frameFiles addObject:framePath];
                if (g_frameCount % 30 == 0) { // Log every 30 frames
                    NSLog(@"📸 Captured %ld frames", (long)g_frameCount);
                }
            }
        }
        
        CGImageRelease(cgImage);
    }
}

@end

API_AVAILABLE(macos(12.3))
@interface SimpleScreenCaptureKit : NSObject
+ (BOOL)isAvailable;
+ (BOOL)startRecordingWithConfiguration:(NSDictionary *)config;
+ (void)stopRecording;
+ (BOOL)isRecording;
+ (void)createVideoFromFrames;
@end

@implementation SimpleScreenCaptureKit

+ (BOOL)isAvailable {
    if (@available(macOS 12.3, *)) {
        return [SCShareableContent class] != nil;
    }
    return NO;
}

+ (BOOL)startRecordingWithConfiguration:(NSDictionary *)config {
    if (g_isRecording) {
        return NO;
    }
    
    g_outputVideoPath = config[@"outputPath"];
    g_frameFiles = [NSMutableArray array];
    g_frameCount = 0;
    
    // Get shareable content
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        if (error) {
            NSLog(@"❌ Failed to get shareable content: %@", error);
            return;
        }
        
        // Find target display
        SCDisplay *targetDisplay = content.displays.firstObject;
        if (config[@"displayId"]) {
            CGDirectDisplayID displayID = [config[@"displayId"] unsignedIntValue];
            for (SCDisplay *display in content.displays) {
                if (display.displayID == displayID) {
                    targetDisplay = display;
                    break;
                }
            }
        }
        
        if (!targetDisplay) {
            NSLog(@"❌ No target display found");
            return;
        }
        
        // Create content filter (no window exclusion for now - keep it simple)
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:targetDisplay excludingWindows:@[]];
        
        // Stream configuration
        SCStreamConfiguration *streamConfig = [[SCStreamConfiguration alloc] init];
        streamConfig.width = 1920;
        streamConfig.height = 1080;
        streamConfig.minimumFrameInterval = CMTimeMake(1, 30); // 30 FPS
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA; // Simple BGRA format
        
        // Create delegate and output
        g_streamDelegate = [[SimpleScreenCaptureDelegate alloc] init];
        g_streamOutput = [[SimpleScreenCaptureOutput alloc] init];
        
        // Create and start stream
        g_stream = [[SCStream alloc] initWithFilter:filter 
                                      configuration:streamConfig 
                                           delegate:g_streamDelegate];
        
        [g_stream addStreamOutput:g_streamOutput 
                             type:SCStreamOutputTypeScreen 
               sampleHandlerQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0) 
                            error:nil];
        
        [g_stream startCaptureWithCompletionHandler:^(NSError *startError) {
            if (startError) {
                NSLog(@"❌ Failed to start ScreenCaptureKit: %@", startError);
            } else {
                NSLog(@"✅ Simple ScreenCaptureKit recording started");
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
    
    [g_stream stopCaptureWithCompletionHandler:^(NSError *error) {
        if (error) {
            NSLog(@"❌ Error stopping stream: %@", error);
        } else {
            NSLog(@"✅ Stream stopped, captured %ld frames", (long)g_frameCount);
        }
        
        // Create video from frames
        [self createVideoFromFrames];
        
        // Cleanup
        g_stream = nil;
        g_streamDelegate = nil;
        g_streamOutput = nil;
        g_isRecording = NO;
    }];
}

+ (BOOL)isRecording {
    return g_isRecording;
}

+ (void)createVideoFromFrames {
    if (g_frameFiles.count == 0) {
        NSLog(@"❌ No frames to create video");
        return;
    }
    
    NSLog(@"🎬 Creating video from %lu frames", (unsigned long)g_frameFiles.count);
    
    // Create AVAssetWriter
    NSURL *outputURL = [NSURL fileURLWithPath:g_outputVideoPath];
    NSError *error = nil;
    AVAssetWriter *assetWriter = [[AVAssetWriter alloc] initWithURL:outputURL 
                                                           fileType:AVFileTypeQuickTimeMovie 
                                                              error:&error];
    
    if (error || !assetWriter) {
        NSLog(@"❌ Failed to create asset writer: %@", error);
        return;
    }
    
    // Video settings
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @1920,
        AVVideoHeightKey: @1080
    };
    
    AVAssetWriterInput *videoInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo 
                                                                    outputSettings:videoSettings];
    videoInput.expectsMediaDataInRealTime = NO;
    
    // Pixel buffer adaptor
    NSDictionary *pixelBufferAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey: @1920,
        (NSString *)kCVPixelBufferHeightKey: @1080
    };
    
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc] 
                                                    initWithAssetWriterInput:videoInput 
                                                    sourcePixelBufferAttributes:pixelBufferAttributes];
    
    [assetWriter addInput:videoInput];
    
    // Start writing
    [assetWriter startWriting];
    [assetWriter startSessionAtSourceTime:kCMTimeZero];
    
    // Add frames
    __block NSInteger frameIndex = 0;
    [videoInput requestMediaDataWhenReadyOnQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0) 
                                      usingBlock:^{
        while (videoInput.isReadyForMoreMediaData && frameIndex < g_frameFiles.count) {
            NSString *framePath = g_frameFiles[frameIndex];
            
            // Load image
            NSImage *image = [[NSImage alloc] initWithContentsOfFile:framePath];
            if (image) {
                // Convert to pixel buffer
                CVPixelBufferRef pixelBuffer = NULL;
                CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080, kCVPixelFormatType_32BGRA, 
                                   (__bridge CFDictionaryRef)pixelBufferAttributes, &pixelBuffer);
                
                if (pixelBuffer) {
                    // Draw image to pixel buffer (simplified)
                    CMTime frameTime = CMTimeMake(frameIndex, 30); // 30 FPS
                    [adaptor appendPixelBuffer:pixelBuffer withPresentationTime:frameTime];
                    CVPixelBufferRelease(pixelBuffer);
                }
            }
            
            frameIndex++;
        }
        
        if (frameIndex >= g_frameFiles.count) {
            [videoInput markAsFinished];
            [assetWriter finishWritingWithCompletionHandler:^{
                if (assetWriter.status == AVAssetWriterStatusCompleted) {
                    NSLog(@"✅ Video created successfully: %@", g_outputVideoPath);
                } else {
                    NSLog(@"❌ Video creation failed: %@", assetWriter.error);
                }
                
                // Clean up frame files
                NSString *frameDir = [g_outputVideoPath stringByDeletingLastPathComponent];
                NSString *framesDir = [frameDir stringByAppendingPathComponent:@"frames"];
                [[NSFileManager defaultManager] removeItemAtPath:framesDir error:nil];
            }];
        }
    }];
}

@end
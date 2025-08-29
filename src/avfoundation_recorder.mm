#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>
#include <string>

static AVAssetWriter *g_avWriter = nil;
static AVAssetWriterInput *g_avVideoInput = nil;
static AVAssetWriterInputPixelBufferAdaptor *g_avPixelBufferAdaptor = nil;
static dispatch_source_t g_avTimer = nil;
static CGDirectDisplayID g_avDisplayID = 0;
static CGRect g_avCaptureRect = CGRectZero;
static bool g_avIsRecording = false;
static int64_t g_avFrameNumber = 0;
static CMTime g_avStartTime;

// AVFoundation screen recording implementation
bool startAVFoundationRecording(const std::string& outputPath, 
                               CGDirectDisplayID displayID,
                               uint32_t windowID,
                               CGRect captureRect,
                               bool captureCursor,
                               bool includeMicrophone, 
                               bool includeSystemAudio,
                               NSString* audioDeviceId) {
    
    if (g_avIsRecording) {
        NSLog(@"❌ AVFoundation recording already in progress");
        return false;
    }
    
    @try {
        // Create output URL
        NSString *outputPathStr = [NSString stringWithUTF8String:outputPath.c_str()];
        NSURL *outputURL = [NSURL fileURLWithPath:outputPathStr];
        
        // Remove existing file
        [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
        
        // Create asset writer
        NSError *error = nil;
        g_avWriter = [[AVAssetWriter alloc] initWithURL:outputURL fileType:AVFileTypeQuickTimeMovie error:&error];
        if (!g_avWriter || error) {
            NSLog(@"❌ Failed to create AVAssetWriter: %@", error);
            return false;
        }
        
        // Get display dimensions
        CGRect displayBounds = CGDisplayBounds(displayID);
        CGSize recordingSize = captureRect.size.width > 0 ? captureRect.size : displayBounds.size;
        
        // Video settings
        NSDictionary *videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @((int)recordingSize.width),
            AVVideoHeightKey: @((int)recordingSize.height),
            AVVideoCompressionPropertiesKey: @{
                AVVideoAverageBitRateKey: @(recordingSize.width * recordingSize.height * 8),
                AVVideoMaxKeyFrameIntervalKey: @30
            }
        };
        
        // Create video input
        g_avVideoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
        g_avVideoInput.expectsMediaDataInRealTime = YES;
        
        // Create pixel buffer adaptor
        NSDictionary *pixelBufferAttributes = @{
            (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32ARGB),
            (NSString*)kCVPixelBufferWidthKey: @((int)recordingSize.width),
            (NSString*)kCVPixelBufferHeightKey: @((int)recordingSize.height),
            (NSString*)kCVPixelBufferCGImageCompatibilityKey: @YES,
            (NSString*)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
        };
        
        g_avPixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:g_avVideoInput sourcePixelBufferAttributes:pixelBufferAttributes];
        
        // Add input to writer
        if (![g_avWriter canAddInput:g_avVideoInput]) {
            NSLog(@"❌ Cannot add video input to AVAssetWriter");
            return false;
        }
        [g_avWriter addInput:g_avVideoInput];
        
        // Start writing
        if (![g_avWriter startWriting]) {
            NSLog(@"❌ Failed to start AVAssetWriter: %@", g_avWriter.error);
            return false;
        }
        
        g_avStartTime = CMTimeMakeWithSeconds(CACurrentMediaTime(), 600);
        [g_avWriter startSessionAtSourceTime:g_avStartTime];
        
        // Store recording parameters
        g_avDisplayID = displayID;
        g_avCaptureRect = captureRect;
        g_avFrameNumber = 0;
        
        // Start capture timer (15 FPS for compatibility)
        dispatch_queue_t captureQueue = dispatch_queue_create("AVFoundationCaptureQueue", DISPATCH_QUEUE_SERIAL);
        g_avTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, captureQueue);
        
        uint64_t interval = NSEC_PER_SEC / 15; // 15 FPS
        dispatch_source_set_timer(g_avTimer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 10);
        
        dispatch_source_set_event_handler(g_avTimer, ^{
            if (!g_avIsRecording) return;
            
            @autoreleasepool {
                // Capture screen
                CGImageRef screenImage = nil;
                if (CGRectIsEmpty(g_avCaptureRect)) {
                    screenImage = CGDisplayCreateImage(g_avDisplayID);
                } else {
                    CGImageRef fullScreen = CGDisplayCreateImage(g_avDisplayID);
                    if (fullScreen) {
                        screenImage = CGImageCreateWithImageInRect(fullScreen, g_avCaptureRect);
                        CGImageRelease(fullScreen);
                    }
                }
                
                if (!screenImage) return;
                
                // Convert to pixel buffer
                CVPixelBufferRef pixelBuffer = nil;
                CVReturn cvRet = CVPixelBufferPoolCreatePixelBuffer(NULL, g_avPixelBufferAdaptor.pixelBufferPool, &pixelBuffer);
                
                if (cvRet == kCVReturnSuccess && pixelBuffer) {
                    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
                    
                    void *pixelData = CVPixelBufferGetBaseAddress(pixelBuffer);
                    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
                    
                    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                    CGContextRef context = CGBitmapContextCreate(pixelData, 
                                                               CVPixelBufferGetWidth(pixelBuffer),
                                                               CVPixelBufferGetHeight(pixelBuffer), 
                                                               8, bytesPerRow, colorSpace,
                                                               kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
                    
                    if (context) {
                        CGContextDrawImage(context, CGRectMake(0, 0, CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer)), screenImage);
                        CGContextRelease(context);
                    }
                    CGColorSpaceRelease(colorSpace);
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
                    
                    // Write frame
                    if (g_avVideoInput.readyForMoreMediaData) {
                        CMTime frameTime = CMTimeAdd(g_avStartTime, CMTimeMakeWithSeconds(g_avFrameNumber / 15.0, 600));
                        [g_avPixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:frameTime];
                        g_avFrameNumber++;
                    }
                    
                    CVPixelBufferRelease(pixelBuffer);
                }
                
                CGImageRelease(screenImage);
            }
        });
        
        dispatch_resume(g_avTimer);
        g_avIsRecording = true;
        
        NSLog(@"🎥 AVFoundation recording started: %dx%d @ 15fps", 
              (int)recordingSize.width, (int)recordingSize.height);
        
        return true;
        
    } @catch (NSException *exception) {
        NSLog(@"❌ Exception in AVFoundation recording: %@", exception.reason);
        return false;
    }
}

bool stopAVFoundationRecording() {
    if (!g_avIsRecording) {
        return true;
    }
    
    g_avIsRecording = false;
    
    @try {
        // Stop timer
        if (g_avTimer) {
            dispatch_source_cancel(g_avTimer);
            g_avTimer = nil;
        }
        
        // Finish writing
        if (g_avVideoInput) {
            [g_avVideoInput markAsFinished];
        }
        
        if (g_avWriter && g_avWriter.status == AVAssetWriterStatusWriting) {
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            [g_avWriter finishWritingWithCompletionHandler:^{
                dispatch_semaphore_signal(semaphore);
            }];
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
        }
        
        // Cleanup
        g_avWriter = nil;
        g_avVideoInput = nil;
        g_avPixelBufferAdaptor = nil;
        g_avFrameNumber = 0;
        
        NSLog(@"✅ AVFoundation recording stopped");
        return true;
        
    } @catch (NSException *exception) {
        NSLog(@"❌ Exception stopping AVFoundation recording: %@", exception.reason);
        return false;
    }
}

bool isAVFoundationRecording() {
    return g_avIsRecording;
}
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
extern "C" bool startAVFoundationRecording(const std::string& outputPath, 
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
        NSLog(@"🎬 AVFoundation: Starting recording initialization");
        
        // Create output URL
        NSString *outputPathStr = [NSString stringWithUTF8String:outputPath.c_str()];
        NSURL *outputURL = [NSURL fileURLWithPath:outputPathStr];
        
        // Remove existing file
        NSError *removeError = nil;
        [[NSFileManager defaultManager] removeItemAtURL:outputURL error:&removeError];
        if (removeError && removeError.code != NSFileNoSuchFileError) {
            NSLog(@"⚠️ AVFoundation: Warning removing existing file: %@", removeError);
        }
        
        // Create asset writer
        NSError *error = nil;
        g_avWriter = [[AVAssetWriter alloc] initWithURL:outputURL fileType:AVFileTypeQuickTimeMovie error:&error];
        if (!g_avWriter || error) {
            NSLog(@"❌ AVFoundation: Failed to create AVAssetWriter: %@", error);
            return false;
        }
        
        // Get display dimensions
        CGRect displayBounds = CGDisplayBounds(displayID);
        CGSize recordingSize = captureRect.size.width > 0 ? captureRect.size : displayBounds.size;
        
        // Video settings with macOS compatibility
        NSString *codecKey;
        if (@available(macOS 10.13, *)) {
            codecKey = AVVideoCodecTypeH264;
        } else {
            // Fallback for older macOS versions
            codecKey = AVVideoCodecH264;
        }
        
        NSDictionary *videoSettings = @{
            AVVideoCodecKey: codecKey,
            AVVideoWidthKey: @((int)recordingSize.width),
            AVVideoHeightKey: @((int)recordingSize.height),
            AVVideoCompressionPropertiesKey: @{
                AVVideoAverageBitRateKey: @(recordingSize.width * recordingSize.height * 8),
                AVVideoMaxKeyFrameIntervalKey: @30
            }
        };
        
        NSLog(@"🔧 Using codec: %@", codecKey);
        
        // Create video input
        g_avVideoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
        g_avVideoInput.expectsMediaDataInRealTime = YES;
        
        // Create pixel buffer adaptor with compatibility
        OSType pixelFormat;
        if (@available(macOS 13.0, *)) {
            pixelFormat = kCVPixelFormatType_32ARGB;  // Modern format
        } else {
            pixelFormat = kCVPixelFormatType_32BGRA;  // Legacy compatibility
        }
        
        NSDictionary *pixelBufferAttributes = @{
            (NSString*)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
            (NSString*)kCVPixelBufferWidthKey: @((int)recordingSize.width),
            (NSString*)kCVPixelBufferHeightKey: @((int)recordingSize.height),
            (NSString*)kCVPixelBufferCGImageCompatibilityKey: @YES,
            (NSString*)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
        };
        
        NSLog(@"🔧 Using pixel format: %u", pixelFormat);
        
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
        
        // Start capture timer (10 FPS for Electron compatibility)
        dispatch_queue_t captureQueue = dispatch_queue_create("AVFoundationCaptureQueue", DISPATCH_QUEUE_SERIAL);
        g_avTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, captureQueue);
        
        if (!g_avTimer) {
            NSLog(@"❌ Failed to create dispatch timer");
            return false;
        }
        
        uint64_t interval = NSEC_PER_SEC / 10; // 10 FPS for Electron stability
        dispatch_source_set_timer(g_avTimer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 10);
        
        // Retain objects before passing to block to prevent deallocation
        AVAssetWriterInput *localVideoInput = g_avVideoInput;
        AVAssetWriterInputPixelBufferAdaptor *localPixelBufferAdaptor = g_avPixelBufferAdaptor;
        
        dispatch_source_set_event_handler(g_avTimer, ^{
            if (!g_avIsRecording) return;
            
            // Additional null checks for Electron safety
            if (!localVideoInput || !localPixelBufferAdaptor) {
                NSLog(@"⚠️ Video input or pixel buffer adaptor is nil, stopping recording");
                g_avIsRecording = false;
                return;
            }
            
            @autoreleasepool {
                @try {
                    // Capture screen with Electron-safe error handling
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
                    
                    if (!screenImage) {
                        NSLog(@"⚠️ Failed to capture screen image, skipping frame");
                        return;
                    }
                
                    // Convert to pixel buffer with Electron-safe error handling
                    CVPixelBufferRef pixelBuffer = nil;
                    CVReturn cvRet = CVPixelBufferPoolCreatePixelBuffer(NULL, localPixelBufferAdaptor.pixelBufferPool, &pixelBuffer);
                    
                    if (cvRet == kCVReturnSuccess && pixelBuffer) {
                        CVPixelBufferLockBaseAddress(pixelBuffer, 0);
                        
                        void *pixelData = CVPixelBufferGetBaseAddress(pixelBuffer);
                        if (!pixelData) {
                            NSLog(@"⚠️ Failed to get pixel buffer base address");
                            CVPixelBufferRelease(pixelBuffer);
                            CGImageRelease(screenImage);
                            return;
                        }
                        
                        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
                        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                        if (!colorSpace) {
                            NSLog(@"⚠️ Failed to create color space");
                            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
                            CVPixelBufferRelease(pixelBuffer);
                            CGImageRelease(screenImage);
                            return;
                        }
                        
                        // Match bitmap info to pixel format for compatibility
                        CGBitmapInfo bitmapInfo;
                        OSType currentPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
                        if (currentPixelFormat == kCVPixelFormatType_32ARGB) {
                            bitmapInfo = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big;
                        } else { // kCVPixelFormatType_32BGRA
                            bitmapInfo = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
                        }
                        
                        CGContextRef context = CGBitmapContextCreate(pixelData, 
                                                                   CVPixelBufferGetWidth(pixelBuffer),
                                                                   CVPixelBufferGetHeight(pixelBuffer), 
                                                                   8, bytesPerRow, colorSpace, bitmapInfo);
                        
                        if (context) {
                            CGContextDrawImage(context, CGRectMake(0, 0, CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer)), screenImage);
                            CGContextRelease(context);
                            
                            // Write frame only if input is ready
                            if (localVideoInput && localVideoInput.readyForMoreMediaData) {
                                CMTime frameTime = CMTimeAdd(g_avStartTime, CMTimeMakeWithSeconds(g_avFrameNumber / 10.0, 600));
                                BOOL appendSuccess = [localPixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:frameTime];
                                if (appendSuccess) {
                                    g_avFrameNumber++;
                                } else {
                                    NSLog(@"⚠️ Failed to append pixel buffer");
                                }
                            }
                        } else {
                            NSLog(@"⚠️ Failed to create bitmap context");
                        }
                        
                        CGColorSpaceRelease(colorSpace);
                        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
                        CVPixelBufferRelease(pixelBuffer);
                    } else {
                        NSLog(@"⚠️ Failed to create pixel buffer: %d", cvRet);
                    }
                    
                    CGImageRelease(screenImage);
                } @catch (NSException *exception) {
                    NSLog(@"❌ Exception in AVFoundation capture loop: %@", exception.reason);
                    g_avIsRecording = false; // Stop recording on exception to prevent crash
                }
            }
        });
        
        dispatch_resume(g_avTimer);
        g_avIsRecording = true;
        
        NSLog(@"🎥 AVFoundation recording started: %dx%d @ 10fps", 
              (int)recordingSize.width, (int)recordingSize.height);
        
        return true;
        
    } @catch (NSException *exception) {
        NSLog(@"❌ Exception in AVFoundation recording: %@", exception.reason);
        return false;
    }
}

extern "C" bool stopAVFoundationRecording() {
    if (!g_avIsRecording) {
        return true;
    }
    
    g_avIsRecording = false;
    
    @try {
        // Stop timer with Electron-safe cleanup
        if (g_avTimer) {
            // Mark as not recording FIRST to stop timer callbacks
            g_avIsRecording = false;
            
            // Cancel timer and wait a brief moment for completion
            dispatch_source_cancel(g_avTimer);
            
            // Use async to avoid deadlock in Electron
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                // Timer should be fully cancelled by now
            });
            
            g_avTimer = nil;
            NSLog(@"✅ AVFoundation timer stopped safely");
        }
        
        // Finish writing with null checks
        AVAssetWriterInput *writerInput = g_avVideoInput;
        if (writerInput) {
            [writerInput markAsFinished];
        }
        
        AVAssetWriter *writer = g_avWriter;
        if (writer && writer.status == AVAssetWriterStatusWriting) {
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            [writer finishWritingWithCompletionHandler:^{
                dispatch_semaphore_signal(semaphore);
            }];
            // Add timeout to prevent infinite wait in Electron
            dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
            dispatch_semaphore_wait(semaphore, timeout);
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

extern "C" bool isAVFoundationRecording() {
    return g_avIsRecording;
}
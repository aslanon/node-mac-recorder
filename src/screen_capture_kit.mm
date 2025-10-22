#import "screen_capture_kit.h"
#import "logging.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

// Pure ScreenCaptureKit implementation - NO AVFoundation
static SCStream * API_AVAILABLE(macos(12.3)) g_stream = nil;
static id<SCStreamDelegate> API_AVAILABLE(macos(12.3)) g_streamDelegate = nil;
static BOOL g_isRecording = NO;
static BOOL g_isCleaningUp = NO;  // Prevent recursive cleanup
static NSString *g_outputPath = nil;

static dispatch_queue_t g_videoQueue = nil;
static dispatch_queue_t g_audioQueue = nil;
static id g_videoStreamOutput = nil;
static id g_audioStreamOutput = nil;

static AVAssetWriter *g_videoWriter = nil;
static AVAssetWriterInput *g_videoInput = nil;
static CFTypeRef g_pixelBufferAdaptorRef = NULL;
static CMTime g_videoStartTime = kCMTimeInvalid;
static BOOL g_videoWriterStarted = NO;

static BOOL g_shouldCaptureAudio = NO;
static NSString *g_audioOutputPath = nil;
static AVAssetWriter *g_audioWriter = nil;
static AVAssetWriterInput *g_audioInput = nil;
static CMTime g_audioStartTime = kCMTimeInvalid;
static BOOL g_audioWriterStarted = NO;

static NSInteger g_configuredSampleRate = 48000;
static NSInteger g_configuredChannelCount = 2;

static void CleanupWriters(void);
static AVAssetWriterInputPixelBufferAdaptor * _Nullable CurrentPixelBufferAdaptor(void) {
    if (!g_pixelBufferAdaptorRef) {
        return nil;
    }
    return (__bridge AVAssetWriterInputPixelBufferAdaptor *)g_pixelBufferAdaptorRef;
}

static NSString *MRNormalizePath(id value) {
    if (!value || value == (id)kCFNull) {
        return nil;
    }
    if ([value isKindOfClass:[NSString class]]) {
        return (NSString *)value;
    }
    if ([value isKindOfClass:[NSURL class]]) {
        return [(NSURL *)value path];
    }
    if ([value isKindOfClass:[NSArray class]]) {
        for (id entry in (NSArray *)value) {
            NSString *candidate = MRNormalizePath(entry);
            if (candidate.length > 0) {
                return candidate;
            }
        }
    }
    return nil;
}

static void FinishWriter(AVAssetWriter *writer, AVAssetWriterInput *input) {
    if (!writer) {
        return;
    }
    
    if (input) {
        [input markAsFinished];
    }
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC));
    dispatch_semaphore_wait(semaphore, timeout);
}

static void CleanupWriters(void) {
    if (g_videoWriter) {
        FinishWriter(g_videoWriter, g_videoInput);
        g_videoWriter = nil;
        g_videoInput = nil;
        if (g_pixelBufferAdaptorRef) {
            CFRelease(g_pixelBufferAdaptorRef);
            g_pixelBufferAdaptorRef = NULL;
        }
        g_videoWriterStarted = NO;
        g_videoStartTime = kCMTimeInvalid;
    }
    
    if (g_audioWriter) {
        FinishWriter(g_audioWriter, g_audioInput);
        g_audioWriter = nil;
        g_audioInput = nil;
        g_audioWriterStarted = NO;
        g_audioStartTime = kCMTimeInvalid;
    }
}

@interface PureScreenCaptureDelegate : NSObject <SCStreamDelegate>
@end

extern "C" NSString *ScreenCaptureKitCurrentAudioPath(void) {
    if (!g_audioOutputPath) {
        return nil;
    }
    if ([g_audioOutputPath isKindOfClass:[NSArray class]]) {
        id first = [(NSArray *)g_audioOutputPath firstObject];
        if ([first isKindOfClass:[NSString class]]) {
            return first;
        }
        return nil;
    }
    return g_audioOutputPath;
}

@implementation PureScreenCaptureDelegate
- (void)stream:(SCStream * API_AVAILABLE(macos(12.3)))stream didStopWithError:(NSError *)error API_AVAILABLE(macos(12.3)) {
    MRLog(@"🛑 Pure ScreenCapture stream stopped");

    // Prevent recursive calls during cleanup
    if (g_isCleaningUp) {
        MRLog(@"⚠️ Already cleaning up, ignoring delegate callback");
        return;
    }

    @synchronized([ScreenCaptureKitRecorder class]) {
        g_isRecording = NO;
    }

    if (error) {
        NSLog(@"❌ Stream error: %@", error);
    } else {
        MRLog(@"✅ Stream stopped cleanly");
    }

    // ELECTRON FIX: Don't use dispatch_async to main queue - it can cause crashes
    // Instead, finalize directly on current thread with synchronization
    @synchronized([ScreenCaptureKitRecorder class]) {
        if (!g_isCleaningUp) {
            [ScreenCaptureKitRecorder finalizeRecording];
        }
    }
}
@end

@interface ScreenCaptureKitRecorder (Private)
+ (BOOL)prepareAudioWriterIfNeededWithSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

@interface ScreenCaptureVideoOutput : NSObject <SCStreamOutput>
@end

@implementation ScreenCaptureVideoOutput
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
    if (!g_isRecording || type != SCStreamOutputTypeScreen) {
        return;
    }
    
    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        return;
    }
    
    if (!g_videoWriter || !g_videoInput) {
        return;
    }
    
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    
    if (!g_videoWriterStarted) {
        if (![g_videoWriter startWriting]) {
            NSLog(@"❌ ScreenCaptureKit video writer failed to start: %@", g_videoWriter.error);
            return;
        }
        [g_videoWriter startSessionAtSourceTime:presentationTime];
        g_videoStartTime = presentationTime;
        g_videoWriterStarted = YES;
        MRLog(@"🎞️ Video writer session started @ %.3f", CMTimeGetSeconds(presentationTime));
    }
    
    if (!g_videoInput.readyForMoreMediaData) {
        return;
    }
    
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        return;
    }
    
    AVAssetWriterInputPixelBufferAdaptor *adaptorCandidate = CurrentPixelBufferAdaptor();
    if ([adaptorCandidate isKindOfClass:[NSArray class]]) {
        id first = [(NSArray *)adaptorCandidate firstObject];
        if ([first isKindOfClass:[AVAssetWriterInputPixelBufferAdaptor class]]) {
            adaptorCandidate = first;
            if (g_pixelBufferAdaptorRef) {
                CFRelease(g_pixelBufferAdaptorRef);
            }
            g_pixelBufferAdaptorRef = CFBridgingRetain(adaptorCandidate);
        }
    }
    if (![adaptorCandidate isKindOfClass:[AVAssetWriterInputPixelBufferAdaptor class]]) {
        if (adaptorCandidate) {
            MRLog(@"⚠️ Pixel buffer adaptor invalid (%@) – skipping frame", NSStringFromClass([adaptorCandidate class]));
        }
        NSLog(@"❌ Pixel buffer adaptor is nil – cannot append video frames");
        return;
    }
    
    AVAssetWriterInputPixelBufferAdaptor *adaptor = adaptorCandidate;
    BOOL appended = [adaptor appendPixelBuffer:pixelBuffer withPresentationTime:presentationTime];
    if (!appended) {
        NSLog(@"⚠️ Failed appending pixel buffer: %@", g_videoWriter.error);
    }
}
@end

@interface ScreenCaptureAudioOutput : NSObject <SCStreamOutput>
@end

@implementation ScreenCaptureAudioOutput
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
    if (!g_isRecording || !g_shouldCaptureAudio) {
        return;
    }
    
    if (@available(macOS 13.0, *)) {
        if (type != SCStreamOutputTypeAudio) {
            return;
        }
    } else {
        return;
    }
    
    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        return;
    }
    
    if (![ScreenCaptureKitRecorder prepareAudioWriterIfNeededWithSampleBuffer:sampleBuffer]) {
        return;
    }
    
    if (!g_audioWriter || !g_audioInput) {
        return;
    }
    
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    
    if (!g_audioWriterStarted) {
        if (![g_audioWriter startWriting]) {
            NSLog(@"❌ Audio writer failed to start: %@", g_audioWriter.error);
            return;
        }
        [g_audioWriter startSessionAtSourceTime:presentationTime];
        g_audioStartTime = presentationTime;
        g_audioWriterStarted = YES;
        MRLog(@"🔊 Audio writer session started @ %.3f", CMTimeGetSeconds(presentationTime));
    }
    
    if (!g_audioInput.readyForMoreMediaData) {
        return;
    }
    
    if (![g_audioInput appendSampleBuffer:sampleBuffer]) {
        NSLog(@"⚠️ Failed appending audio sample buffer: %@", g_audioWriter.error);
    }
}
@end

@implementation ScreenCaptureKitRecorder

+ (BOOL)prepareVideoWriterWithWidth:(NSInteger)width height:(NSInteger)height error:(NSError **)error {
    MRLog(@"🎬 Preparing video writer %ldx%ld", (long)width, (long)height);
    if (!g_outputPath) {
        MRLog(@"❌ Video writer failed: missing output path");
        return NO;
    }
    if (width <= 0 || height <= 0) {
        MRLog(@"❌ Video writer invalid dimensions %ldx%ld", (long)width, (long)height);
        return NO;
    }
    
    NSURL *outputURL = [NSURL fileURLWithPath:g_outputPath];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    
    g_videoWriter = [[AVAssetWriter alloc] initWithURL:outputURL fileType:AVFileTypeQuickTimeMovie error:error];
    if (!g_videoWriter || (error && *error)) {
        MRLog(@"❌ Failed creating video writer: %@", error && *error ? (*error).localizedDescription : @"unknown");
        return NO;
    }
    
    NSDictionary *compressionProps = @{
        AVVideoAverageBitRateKey: @(width * height * 6),
        AVVideoMaxKeyFrameIntervalKey: @30
    };
    
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: compressionProps
    };
    
    g_videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    g_videoInput.expectsMediaDataInRealTime = YES;
    
    AVAssetWriterInputPixelBufferAdaptor *pixelAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:g_videoInput sourcePixelBufferAttributes:@{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey: @(width),
        (NSString *)kCVPixelBufferHeightKey: @(height),
        (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    }];

    if (![g_videoWriter canAddInput:g_videoInput]) {
        MRLog(@"❌ Cannot add video input to writer");
        if (error) {
            *error = [NSError errorWithDomain:@"ScreenCaptureKitRecorder" code:-100 userInfo:@{NSLocalizedDescriptionKey: @"Cannot add video input to writer"}];
        }
        return NO;
    }
    
    [g_videoWriter addInput:g_videoInput];
    if (g_pixelBufferAdaptorRef) {
        CFRelease(g_pixelBufferAdaptorRef);
        g_pixelBufferAdaptorRef = NULL;
    }
    if (pixelAdaptor) {
        g_pixelBufferAdaptorRef = CFBridgingRetain(pixelAdaptor);
    }
    g_videoWriterStarted = NO;
    g_videoStartTime = kCMTimeInvalid;
    MRLog(@"✅ Video writer ready %ldx%ld", (long)width, (long)height);

    return YES;
}

+ (BOOL)prepareAudioWriterIfNeededWithSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!g_shouldCaptureAudio || g_audioWriter || !g_audioOutputPath) {
        return g_audioWriter != nil || !g_shouldCaptureAudio;
    }
    
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!formatDescription) {
        NSLog(@"⚠️ Missing audio format description");
        return NO;
    }
    
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
    if (!asbd) {
        NSLog(@"⚠️ Unsupported audio format description");
        return NO;
    }
    
    g_configuredSampleRate = (NSInteger)asbd->mSampleRate;
    g_configuredChannelCount = asbd->mChannelsPerFrame;
    
    NSString *originalPath = g_audioOutputPath ?: @"";
    NSURL *audioURL = [NSURL fileURLWithPath:originalPath];
    [[NSFileManager defaultManager] removeItemAtURL:audioURL error:nil];
    
    NSError *writerError = nil;
    AVFileType requestedFileType = AVFileTypeQuickTimeMovie;
    BOOL requestedWebM = NO;
    if (@available(macOS 15.0, *)) {
        requestedFileType = @"public.webm";
        requestedWebM = YES;
    }
    
    @try {
        g_audioWriter = [[AVAssetWriter alloc] initWithURL:audioURL fileType:requestedFileType error:&writerError];
    } @catch (NSException *exception) {
        NSDictionary *info = @{
            NSLocalizedDescriptionKey: exception.reason ?: @"Failed to initialize audio writer"
        };
        writerError = [NSError errorWithDomain:@"ScreenCaptureKitRecorder" code:-201 userInfo:info];
        g_audioWriter = nil;
    }
    
    if ((!g_audioWriter || writerError) && requestedWebM) {
        MRLog(@"⚠️ ScreenCaptureKit audio writer unavailable (%@) – falling back to QuickTime container", writerError.localizedDescription);
        NSString *fallbackPath = [[originalPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"mov"];
        if (!fallbackPath || [fallbackPath length] == 0) {
            fallbackPath = [originalPath stringByAppendingString:@".mov"];
        }
        [[NSFileManager defaultManager] removeItemAtPath:fallbackPath error:nil];
        NSURL *fallbackURL = [NSURL fileURLWithPath:fallbackPath];
        g_audioOutputPath = fallbackPath;
        writerError = nil;
        @try {
            g_audioWriter = [[AVAssetWriter alloc] initWithURL:fallbackURL fileType:AVFileTypeQuickTimeMovie error:&writerError];
        } @catch (NSException *exception) {
            NSDictionary *info = @{
                NSLocalizedDescriptionKey: exception.reason ?: @"Failed to initialize audio writer"
            };
            writerError = [NSError errorWithDomain:@"ScreenCaptureKitRecorder" code:-202 userInfo:info];
            g_audioWriter = nil;
        }
        audioURL = fallbackURL;
    }
    
    if (!g_audioWriter || writerError) {
        NSLog(@"❌ Failed to create audio writer: %@", writerError);
        return NO;
    }
    
    NSInteger channelCount = MAX(1, g_configuredChannelCount);
    AudioChannelLayout layout = {0};
    size_t layoutSize = 0;
    if (channelCount == 1) {
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
        layoutSize = sizeof(AudioChannelLayout);
    } else if (channelCount == 2) {
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
        layoutSize = sizeof(AudioChannelLayout);
    }

    NSMutableDictionary *audioSettings = [@{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @(g_configuredSampleRate),
        AVNumberOfChannelsKey: @(channelCount),
        AVEncoderBitRateKey: @(192000)
    } mutableCopy];

    if (layoutSize > 0) {
        audioSettings[AVChannelLayoutKey] = [NSData dataWithBytes:&layout length:layoutSize];
    }
    
    g_audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
    g_audioInput.expectsMediaDataInRealTime = YES;
    
    if (![g_audioWriter canAddInput:g_audioInput]) {
        NSLog(@"❌ Audio writer cannot add input");
        return NO;
    }
    [g_audioWriter addInput:g_audioInput];
    g_audioWriterStarted = NO;
    g_audioStartTime = kCMTimeInvalid;
    
    return YES;
}

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

        // Set flag early to prevent race conditions in Electron
        g_isRecording = YES;
    }

    NSString *outputPath = config[@"outputPath"];
    if (!outputPath || [outputPath length] == 0) {
        NSLog(@"❌ Invalid output path provided");
        @synchronized([ScreenCaptureKitRecorder class]) {
            g_isRecording = NO;
        }
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
    NSString *microphoneDeviceId = config[@"microphoneDeviceId"];
    NSString *audioOutputPath = MRNormalizePath(config[@"audioOutputPath"]);
    NSNumber *sessionTimestampNumber = config[@"sessionTimestamp"];
    
    MRLog(@"🎬 Starting PURE ScreenCaptureKit recording (NO AVFoundation)");
    MRLog(@"🔧 Config: cursor=%@ mic=%@ system=%@ display=%@ window=%@ crop=%@", 
          captureCursor, includeMicrophone, includeSystemAudio, displayId, windowId, captureRect);
    
    // CRITICAL DEBUG: Log EXACT audio parameter values
    MRLog(@"🔍 AUDIO DEBUG: includeMicrophone type=%@ value=%d", [includeMicrophone class], [includeMicrophone boolValue]);
    MRLog(@"🔍 AUDIO DEBUG: includeSystemAudio type=%@ value=%d", [includeSystemAudio class], [includeSystemAudio boolValue]);

    // ELECTRON FIX: Get shareable content asynchronously without blocking
    // This prevents deadlocks in Electron's event loop
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *contentError) {
        // This block runs asynchronously - safe for Electron
        @autoreleasepool {
        if (contentError) {
            NSLog(@"❌ Content error: %@", contentError);
            @synchronized([ScreenCaptureKitRecorder class]) {
                g_isRecording = NO;
            }
            return;  // Early return from completion handler block
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
                @synchronized([ScreenCaptureKitRecorder class]) {
                    g_isRecording = NO;
                }
                return;  // Early return from completion handler block
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
                @synchronized([ScreenCaptureKitRecorder class]) {
                    g_isRecording = NO;
                }
                return;  // Early return from completion handler block
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
        
        BOOL shouldCaptureMic = includeMicrophone ? [includeMicrophone boolValue] : NO;
        BOOL shouldCaptureSystemAudio = includeSystemAudio ? [includeSystemAudio boolValue] : NO;
        g_shouldCaptureAudio = shouldCaptureMic || shouldCaptureSystemAudio;
        g_audioOutputPath = audioOutputPath;
        if (g_shouldCaptureAudio && (!g_audioOutputPath || [g_audioOutputPath length] == 0)) {
            NSLog(@"⚠️ Audio capture requested but no audio output path supplied – audio will be disabled");
            g_shouldCaptureAudio = NO;
        }
        
        if (@available(macos 13.0, *)) {
            streamConfig.capturesAudio = g_shouldCaptureAudio;
            streamConfig.sampleRate = g_configuredSampleRate;
            streamConfig.channelCount = g_configuredChannelCount;
            streamConfig.excludesCurrentProcessAudio = !shouldCaptureSystemAudio;
        }
        
        if (@available(macos 15.0, *)) {
            streamConfig.captureMicrophone = shouldCaptureMic;
            if (microphoneDeviceId && microphoneDeviceId.length > 0) {
                streamConfig.microphoneCaptureDeviceID = microphoneDeviceId;
            }
        }
        
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
        
        NSError *writerError = nil;
        if (![ScreenCaptureKitRecorder prepareVideoWriterWithWidth:recordingWidth height:recordingHeight error:&writerError]) {
            NSLog(@"❌ Failed to prepare video writer: %@", writerError);
            @synchronized([ScreenCaptureKitRecorder class]) {
                g_isRecording = NO;
            }
            return;  // Early return from completion handler block
        }
        
        g_videoQueue = dispatch_queue_create("screen_capture_video_queue", DISPATCH_QUEUE_SERIAL);
        g_audioQueue = dispatch_queue_create("screen_capture_audio_queue", DISPATCH_QUEUE_SERIAL);
        g_videoStreamOutput = [[ScreenCaptureVideoOutput alloc] init];
        if (g_shouldCaptureAudio) {
            g_audioStreamOutput = [[ScreenCaptureAudioOutput alloc] init];
        } else {
            g_audioStreamOutput = nil;
        }
        
        g_streamDelegate = [[PureScreenCaptureDelegate alloc] init];
        g_stream = [[SCStream alloc] initWithFilter:filter configuration:streamConfig delegate:g_streamDelegate];
        
        if (!g_stream) {
            NSLog(@"❌ Failed to create pure stream");
            CleanupWriters();
            @synchronized([ScreenCaptureKitRecorder class]) {
                g_isRecording = NO;
            }
            return;  // Early return from completion handler block
        }
        
        NSError *outputError = nil;
        BOOL videoOutputAdded = [g_stream addStreamOutput:g_videoStreamOutput type:SCStreamOutputTypeScreen sampleHandlerQueue:g_videoQueue error:&outputError];
        if (!videoOutputAdded || outputError) {
            NSLog(@"❌ Failed to add video output: %@", outputError);
            CleanupWriters();
            @synchronized([ScreenCaptureKitRecorder class]) {
                g_isRecording = NO;
            }
            return;  // Early return from completion handler block
        }
        
        if (g_shouldCaptureAudio) {
            if (@available(macOS 13.0, *)) {
                NSError *audioError = nil;
                BOOL audioOutputAdded = [g_stream addStreamOutput:g_audioStreamOutput type:SCStreamOutputTypeAudio sampleHandlerQueue:g_audioQueue error:&audioError];
                if (!audioOutputAdded || audioError) {
                    NSLog(@"❌ Failed to add audio output: %@", audioError);
                    CleanupWriters();
                    @synchronized([ScreenCaptureKitRecorder class]) {
                        g_isRecording = NO;
                    }
                    return;  // Early return from completion handler block
                }
            } else {
                NSLog(@"⚠️ Audio capture requested but requires macOS 13.0+");
                g_shouldCaptureAudio = NO;
            }
        }
        
        MRLog(@"✅ Stream outputs configured (audio=%d)", g_shouldCaptureAudio);
        if (sessionTimestampNumber) {
            MRLog(@"🕒 Session timestamp: %@", sessionTimestampNumber);
        }

        // ELECTRON FIX: Start capture asynchronously
        [g_stream startCaptureWithCompletionHandler:^(NSError *startError) {
            if (startError) {
                NSLog(@"❌ Failed to start pure capture: %@", startError);
                CleanupWriters();
                @synchronized([ScreenCaptureKitRecorder class]) {
                    g_isRecording = NO;
                }
            } else {
                MRLog(@"🎉 PURE ScreenCaptureKit recording started successfully!");
                // g_isRecording already set to YES at the beginning
            }
        }];
        }  // End of autoreleasepool
    }];  // End of getShareableContentWithCompletionHandler

    // Return immediately - async completion will handle success/failure
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

    // ELECTRON FIX: Stop asynchronously without blocking
    [streamToStop stopCaptureWithCompletionHandler:^(NSError *stopError) {
        if (stopError) {
            NSLog(@"❌ Stop error: %@", stopError);
        } else {
            MRLog(@"✅ Pure stream stopped");
        }

        // Reset recording state to allow new recordings
        @synchronized([ScreenCaptureKitRecorder class]) {
            g_isRecording = NO;
        }

        // Cleanup after stop completes
        CleanupWriters();
        [ScreenCaptureKitRecorder cleanupVideoWriter];
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
        
        if (g_streamDelegate) {
            g_streamDelegate = nil;
            MRLog(@"✅ Stream delegate reference cleared");
        }
        
        g_videoStreamOutput = nil;
        g_audioStreamOutput = nil;
        g_videoQueue = nil;
        g_audioQueue = nil;
        if (g_pixelBufferAdaptorRef) {
            CFRelease(g_pixelBufferAdaptorRef);
            g_pixelBufferAdaptorRef = NULL;
        }
        g_audioOutputPath = nil;
        g_shouldCaptureAudio = NO;
        
        g_isRecording = NO;
        g_isCleaningUp = NO;  // Reset cleanup flag
        g_outputPath = nil;
        
        MRLog(@"🧹 Pure ScreenCaptureKit cleanup complete");
    }
}

@end

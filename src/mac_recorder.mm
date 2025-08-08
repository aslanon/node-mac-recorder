#import <napi.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CoreAudio/CoreAudio.h>

// Import screen capture
#import "screen_capture.h"
#import "screen_capture_kit.h"

// Cursor tracker function declarations
Napi::Object InitCursorTracker(Napi::Env env, Napi::Object exports);

// Window selector function declarations
Napi::Object InitWindowSelector(Napi::Env env, Napi::Object exports);

// ScreenCaptureKit Recording Delegate
API_AVAILABLE(macos(12.3))
@interface SCKRecorderDelegate : NSObject <SCStreamDelegate, SCStreamOutput>
@property (nonatomic, copy) void (^completionHandler)(NSURL *outputURL, NSError *error);
@property (nonatomic, copy) void (^startedHandler)(void);
@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *videoInput;
@property (nonatomic, strong) AVAssetWriterInput *audioInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *pixelBufferAdaptor;
@property (nonatomic, strong) NSURL *outputURL;
@property (nonatomic, assign) BOOL isWriting;
@property (nonatomic, assign) CMTime startTime;
@property (nonatomic, assign) BOOL hasStartTime;
@property (nonatomic, assign) BOOL startAttempted;
@property (nonatomic, assign) BOOL startFailed;
@end

@implementation SCKRecorderDelegate

// Standard SCStreamDelegate method - should be called automatically
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    NSLog(@"📹 SCStreamDelegate received sample buffer of type: %ld", (long)type);
    [self handleSampleBuffer:sampleBuffer ofType:type fromStream:stream];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    NSLog(@"🛑 Stream stopped with error: %@", error ? error.localizedDescription : @"none");
    if (self.completionHandler) {
        self.completionHandler(self.outputURL, error);
    }
}


// Main sample buffer handler (renamed to avoid conflicts)
- (void)handleSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type fromStream:(SCStream *)stream {
    NSLog(@"📹 Handling sample buffer of type: %ld", (long)type);
    
    if (!self.isWriting || !self.assetWriter) {
        NSLog(@"⚠️ Not writing or no asset writer available");
        return;
    }
    if (self.startFailed) {
        NSLog(@"⚠️ Asset writer start previously failed; ignoring buffers");
        return;
    }
    
    // Check asset writer status before processing
    if (self.assetWriter.status == AVAssetWriterStatusFailed) {
        NSLog(@"❌ Asset writer has failed status: %@", self.assetWriter.error.localizedDescription);
        self.startFailed = YES;
        return;
    }
    
    // Start asset writer on first sample buffer
    if (!self.hasStartTime) {
        NSLog(@"🚀 Starting asset writer with first sample buffer");
        if (self.startAttempted) {
            // Another thread already attempted start; wait for success/fail flag to flip
            return;
        }
        self.startAttempted = YES;
        if (![self.assetWriter startWriting]) {
            NSLog(@"❌ Failed to start asset writer: %@", self.assetWriter.error.localizedDescription);
            self.startFailed = YES;
            return;
        }
        
        NSLog(@"✅ Asset writer started successfully");
        self.startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        self.hasStartTime = YES;
        [self.assetWriter startSessionAtSourceTime:self.startTime];
        NSLog(@"✅ Asset writer session started at time: %lld", self.startTime.value);
    }
    
    switch (type) {
        case SCStreamOutputTypeScreen: {
            NSLog(@"📺 Processing screen sample buffer");
            if (self.videoInput && self.videoInput.isReadyForMoreMediaData) {
                // Check sample buffer validity
                if (!CMSampleBufferIsValid(sampleBuffer)) {
                    NSLog(@"⚠️ Invalid sample buffer received");
                    return;
                }
                
                // Check timing - ensure presentation time is advancing
                CMTime currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
                NSLog(@"📺 Sample buffer PTS: %lld", currentTime.value);
                
                BOOL success = NO;
                
                // Try using pixel buffer adaptor for better compatibility
                if (self.pixelBufferAdaptor && self.pixelBufferAdaptor.assetWriterInput.isReadyForMoreMediaData) {
                    // Extract pixel buffer from sample buffer
                    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
                    if (pixelBuffer) {
                        success = [self.pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:currentTime];
                        NSLog(@"📺 Pixel buffer appended via adaptor: %@", success ? @"SUCCESS" : @"FAILED");
                    } else {
                        // Fallback to direct sample buffer append
                        success = [self.videoInput appendSampleBuffer:sampleBuffer];
                        NSLog(@"📺 Sample buffer appended directly: %@", success ? @"SUCCESS" : @"FAILED");
                    }
                } else {
                    // Fallback to direct sample buffer append
                    success = [self.videoInput appendSampleBuffer:sampleBuffer];
                    NSLog(@"📺 Video sample buffer appended (fallback): %@", success ? @"SUCCESS" : @"FAILED");
                }
                
                if (!success) {
                    // Log detailed error information
                    NSLog(@"❌ Video input append failed - Asset Writer Status: %ld", (long)self.assetWriter.status);
                    if (self.assetWriter.error) {
                        NSLog(@"❌ Asset Writer Error: %@", self.assetWriter.error.localizedDescription);
                    }
                    
                    // Check if asset writer has failed and mark for cleanup
                    if (self.assetWriter.status == AVAssetWriterStatusFailed) {
                        self.startFailed = YES;
                    }
                }
            } else {
                NSLog(@"⚠️ Video input not ready for more data - isReadyForMoreMediaData: %@", 
                      self.videoInput.isReadyForMoreMediaData ? @"YES" : @"NO");
                
                // Also check pixel buffer adaptor readiness
                if (self.pixelBufferAdaptor) {
                    NSLog(@"📊 Pixel buffer adaptor ready: %@", 
                          self.pixelBufferAdaptor.assetWriterInput.isReadyForMoreMediaData ? @"YES" : @"NO");
                }
                
                // Log asset writer input status
                NSLog(@"📊 Asset Writer Status: %ld, Video Input Status: readyForMoreMediaData=%@", 
                      (long)self.assetWriter.status, 
                      self.videoInput.isReadyForMoreMediaData ? @"YES" : @"NO");
            }
            break;
        }
        case SCStreamOutputTypeAudio: {
            NSLog(@"🔊 Processing audio sample buffer");
            if (self.audioInput && self.audioInput.isReadyForMoreMediaData) {
                BOOL success = [self.audioInput appendSampleBuffer:sampleBuffer];
                NSLog(@"🔊 Audio sample buffer appended: %@", success ? @"SUCCESS" : @"FAILED");
                
                if (!success && self.assetWriter.error) {
                    NSLog(@"❌ Audio append error: %@", self.assetWriter.error.localizedDescription);
                }
            } else {
                NSLog(@"⚠️ Audio input not ready for more data (or no audio input)");
            }
            break;
        }
        case SCStreamOutputTypeMicrophone: {
            NSLog(@"🎤 Processing microphone sample buffer");
            if (self.audioInput && self.audioInput.isReadyForMoreMediaData) {
                BOOL success = [self.audioInput appendSampleBuffer:sampleBuffer];
                NSLog(@"🎤 Microphone sample buffer appended: %@", success ? @"SUCCESS" : @"FAILED");
                
                if (!success && self.assetWriter.error) {
                    NSLog(@"❌ Microphone append error: %@", self.assetWriter.error.localizedDescription);
                }
            } else {
                NSLog(@"⚠️ Microphone input not ready for more data (or no audio input)");
            }
            break;
        }
    }
}

@end

// Global state for ScreenCaptureKit recording
static SCStream *g_scStream = nil;
static SCKRecorderDelegate *g_scDelegate = nil;
static bool g_isRecording = false;
static BOOL g_screenOutputAttached = NO;
static BOOL g_audioOutputAttached = NO;
static dispatch_queue_t g_outputQueue = NULL; // use a dedicated serial queue for sample handling

// Helper function to cleanup ScreenCaptureKit recording resources
void cleanupSCKRecording() {
    NSLog(@"🛑 Cleaning up ScreenCaptureKit recording");

    // Detach outputs first to prevent further callbacks into the delegate
    if (g_scStream && g_scDelegate) {
        NSError *rmError = nil;
        if (g_screenOutputAttached) {
            [g_scStream removeStreamOutput:g_scDelegate type:SCStreamOutputTypeScreen error:&rmError];
            g_screenOutputAttached = NO;
        }
        if (g_audioOutputAttached) {
            rmError = nil;
            [g_scStream removeStreamOutput:g_scDelegate type:SCStreamOutputTypeAudio error:&rmError];
            g_audioOutputAttached = NO;
        }
    }

    if (g_scStream) {
        NSLog(@"🛑 Stopping SCStream");
        SCStream *streamToStop = g_scStream; // keep local until stop completes
        [streamToStop stopCaptureWithCompletionHandler:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"❌ Error stopping SCStream: %@", error.localizedDescription);
            } else {
                NSLog(@"✅ SCStream stopped successfully");
            }

            // Finish writer after stream has stopped to ensure no further buffers arrive
            if (g_scDelegate && g_scDelegate.assetWriter && g_scDelegate.isWriting) {
                NSLog(@"🛑 Finishing asset writer (status: %ld)", (long)g_scDelegate.assetWriter.status);
                g_scDelegate.isWriting = NO;

                if (g_scDelegate.assetWriter.status == AVAssetWriterStatusWriting) {
                    if (g_scDelegate.videoInput) {
                        [g_scDelegate.videoInput markAsFinished];
                    }
                    if (g_scDelegate.audioInput) {
                        [g_scDelegate.audioInput markAsFinished];
                    }

                    [g_scDelegate.assetWriter finishWritingWithCompletionHandler:^{
                        NSLog(@"✅ Asset writer finished. Status: %ld", (long)g_scDelegate.assetWriter.status);
                        if (g_scDelegate.assetWriter.error) {
                            NSLog(@"❌ Asset writer error: %@", g_scDelegate.assetWriter.error.localizedDescription);
                        }
                    }];
                } else if (g_scDelegate.assetWriter.status == AVAssetWriterStatusFailed) {
                    NSLog(@"❌ Asset writer failed: %@", g_scDelegate.assetWriter.error.localizedDescription);
                }
            }

            g_isRecording = false;
            g_scStream = nil;
            g_scDelegate = nil;
        }];
    } else {
        // No stream, just finalize writer if needed
        if (g_scDelegate && g_scDelegate.assetWriter && g_scDelegate.isWriting) {
            NSLog(@"🛑 Finishing asset writer (status: %ld)", (long)g_scDelegate.assetWriter.status);
            g_scDelegate.isWriting = NO;
            if (g_scDelegate.assetWriter.status == AVAssetWriterStatusWriting) {
                if (g_scDelegate.videoInput) {
                    [g_scDelegate.videoInput markAsFinished];
                }
                if (g_scDelegate.audioInput) {
                    [g_scDelegate.audioInput markAsFinished];
                }
                [g_scDelegate.assetWriter finishWritingWithCompletionHandler:^{}];
            }
        }
        g_isRecording = false;
        g_scDelegate = nil;
    }
}

// Check if ScreenCaptureKit is available
bool isScreenCaptureKitAvailable() {
    if (@available(macOS 12.3, *)) {
        return true;
    }
    return false;
}

// NAPI Function: Start Recording with ScreenCaptureKit
Napi::Value StartRecording(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    @autoreleasepool {
    if (!isScreenCaptureKitAvailable()) {
        NSLog(@"ScreenCaptureKit requires macOS 12.3 or later");
        return Napi::Boolean::New(env, false);
    }
    
    if (info.Length() < 1) {
        NSLog(@"Output path required");
        return Napi::Boolean::New(env, false);
    }
    
    if (g_isRecording) {
        NSLog(@"⚠️ Already recording");
        return Napi::Boolean::New(env, false);
    }
    
    // Verify permissions before starting
    if (!CGPreflightScreenCaptureAccess()) {
        NSLog(@"❌ Screen recording permission not granted - requesting access");
        bool requestResult = CGRequestScreenCaptureAccess();
        NSLog(@"📋 Permission request result: %@", requestResult ? @"SUCCESS" : @"FAILED");
        
        if (!CGPreflightScreenCaptureAccess()) {
            NSLog(@"❌ Screen recording permission still not available");
            return Napi::Boolean::New(env, false);
        }
    }
    NSLog(@"✅ Screen recording permission verified");
    
    std::string outputPath = info[0].As<Napi::String>().Utf8Value();
    
    // Default options
    bool captureCursor = false;
    bool includeSystemAudio = true;
    CGDirectDisplayID displayID = 0; // Will be set to first available display
    uint32_t windowID = 0;
    CGRect captureRect = CGRectNull;
    
    // Parse options
    if (info.Length() > 1 && info[1].IsObject()) {
        Napi::Object options = info[1].As<Napi::Object>();
        
        if (options.Has("captureCursor")) {
            captureCursor = options.Get("captureCursor").As<Napi::Boolean>();
        }
        
        
        if (options.Has("includeSystemAudio")) {
            includeSystemAudio = options.Get("includeSystemAudio").As<Napi::Boolean>();
        }
        
        if (options.Has("displayId") && !options.Get("displayId").IsNull()) {
            uint32_t tempDisplayID = options.Get("displayId").As<Napi::Number>().Uint32Value();
            if (tempDisplayID != 0) {
                displayID = tempDisplayID;
            }
        }
        
        if (options.Has("windowId") && !options.Get("windowId").IsNull()) {
            windowID = options.Get("windowId").As<Napi::Number>().Uint32Value();
        }
        
        if (options.Has("captureArea") && options.Get("captureArea").IsObject()) {
            Napi::Object rectObj = options.Get("captureArea").As<Napi::Object>();
            if (rectObj.Has("x") && rectObj.Has("y") && rectObj.Has("width") && rectObj.Has("height")) {
                captureRect = CGRectMake(
                    rectObj.Get("x").As<Napi::Number>().DoubleValue(),
                    rectObj.Get("y").As<Napi::Number>().DoubleValue(),
                    rectObj.Get("width").As<Napi::Number>().DoubleValue(),
                    rectObj.Get("height").As<Napi::Number>().DoubleValue()
                );
            }
        }
    }
    
    // Create output URL
    NSURL *outputURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:outputPath.c_str()]];
    NSLog(@"📁 Output URL: %@", outputURL.absoluteString);

    // Remove existing file if present to avoid AVAssetWriter "Cannot Save" error
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:outputURL.path]) {
        NSError *rmErr = nil;
        [fm removeItemAtURL:outputURL error:&rmErr];
        if (rmErr) {
            NSLog(@"⚠️ Failed to remove existing output file (%@): %@", outputURL.path, rmErr.localizedDescription);
        }
    }
    
    // Get shareable content
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *contentError = nil;
    __block SCShareableContent *shareableContent = nil;
    
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable error) {
        shareableContent = content;
        contentError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
    if (contentError) {
        NSLog(@"ScreenCaptureKit error: %@", contentError.localizedDescription);
        NSLog(@"This is likely due to missing screen recording permissions");
        return Napi::Boolean::New(env, false);
    }
    
    // Find target display or window
    SCContentFilter *contentFilter = nil;
    
    if (windowID > 0) {
        // Window recording
        SCWindow *targetWindow = nil;
        for (SCWindow *window in shareableContent.windows) {
            if (window.windowID == windowID) {
                targetWindow = window;
                break;
            }
        }
        
        if (!targetWindow) {
            NSLog(@"Window not found with ID: %u", windowID);
            return Napi::Boolean::New(env, false);
        }
        
        contentFilter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:targetWindow];
    } else {
        // Display recording
        NSLog(@"🔍 Selecting display among %lu available displays", (unsigned long)shareableContent.displays.count);
        
        SCDisplay *targetDisplay = nil;
        
        // Log all available displays first
        for (SCDisplay *display in shareableContent.displays) {
            NSLog(@"📺 Available display: ID=%u, width=%d, height=%d", display.displayID, (int)display.width, (int)display.height);
        }
        
        if (displayID != 0) {
            // Look for specific display ID
            for (SCDisplay *display in shareableContent.displays) {
                if (display.displayID == displayID) {
                    targetDisplay = display;
                    break;
                }
            }
            
            if (!targetDisplay) {
                NSLog(@"❌ Display not found with ID: %u", displayID);
            }
        }
        
        // If no specific display was requested or found, use the first available
        if (!targetDisplay) {
            if (shareableContent.displays.count > 0) {
                targetDisplay = shareableContent.displays.firstObject;
                NSLog(@"✅ Using first available display: ID=%u, %dx%d", targetDisplay.displayID, (int)targetDisplay.width, (int)targetDisplay.height);
            } else {
                NSLog(@"❌ No displays available at all");
                return Napi::Boolean::New(env, false);
            }
        } else {
            NSLog(@"✅ Using specified display: ID=%u, %dx%d", targetDisplay.displayID, (int)targetDisplay.width, (int)targetDisplay.height);
        }
        
        // Update displayID for subsequent use
        displayID = targetDisplay.displayID;
        
        // Build exclusion windows array if provided
        NSMutableArray<SCWindow *> *excluded = [NSMutableArray array];
        BOOL excludeCurrentApp = NO;
        if (info.Length() > 1 && info[1].IsObject()) {
            Napi::Object options = info[1].As<Napi::Object>();
            if (options.Has("excludeCurrentApp")) {
                excludeCurrentApp = options.Get("excludeCurrentApp").As<Napi::Boolean>();
            }
            if (options.Has("excludeWindowIds") && options.Get("excludeWindowIds").IsArray()) {
                Napi::Array arr = options.Get("excludeWindowIds").As<Napi::Array>();
                for (uint32_t i = 0; i < arr.Length(); i++) {
                    Napi::Value v = arr.Get(i);
                    if (v.IsNumber()) {
                        uint32_t wid = v.As<Napi::Number>().Uint32Value();
                        for (SCWindow *w in shareableContent.windows) {
                            if (w.windowID == wid) {
                                [excluded addObject:w];
                                break;
                            }
                        }
                    }
                }
            }
        }
        
        if (excludeCurrentApp) {
            pid_t pid = [[NSProcessInfo processInfo] processIdentifier];
            for (SCWindow *w in shareableContent.windows) {
                if (w.owningApplication && w.owningApplication.processID == pid) {
                    [excluded addObject:w];
                }
            }
        }
        
        contentFilter = [[SCContentFilter alloc] initWithDisplay:targetDisplay excludingWindows:excluded];
        NSLog(@"✅ Content filter created for display recording");
    }
    
    // Get actual display dimensions for proper video configuration
    CGRect displayBounds = CGDisplayBounds(displayID);
    NSSize videoSize = NSMakeSize(displayBounds.size.width, displayBounds.size.height);
    
    // Create stream configuration
    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.width = videoSize.width;
    config.height = videoSize.height;
    config.minimumFrameInterval = CMTimeMake(1, 30); // 30 FPS
    
    // Try a more compatible pixel format
    config.pixelFormat = kCVPixelFormatType_32BGRA;
    
    NSLog(@"📐 Stream configuration: %dx%d, FPS=30, cursor=%@", (int)config.width, (int)config.height, captureCursor ? @"YES" : @"NO");
    
    if (@available(macOS 13.0, *)) {
        config.capturesAudio = includeSystemAudio;
        config.excludesCurrentProcessAudio = YES;
        NSLog(@"🔊 Audio configuration: capture=%@, excludeProcess=%@", includeSystemAudio ? @"YES" : @"NO", @"YES");
    } else {
        NSLog(@"⚠️ macOS 13.0+ features not available");
    }
    config.showsCursor = captureCursor;
    
    if (!CGRectIsNull(captureRect)) {
        config.sourceRect = captureRect;
        // Update video size if capture rect is specified
        videoSize = NSMakeSize(captureRect.size.width, captureRect.size.height);
    }
    
    // Create delegate
    g_scDelegate = [[SCKRecorderDelegate alloc] init];
    g_scDelegate.outputURL = outputURL;
    g_scDelegate.hasStartTime = NO;
    g_scDelegate.startAttempted = NO;
    g_scDelegate.startFailed = NO;
    
    // Setup AVAssetWriter
    NSError *writerError = nil;
    g_scDelegate.assetWriter = [[AVAssetWriter alloc] initWithURL:outputURL fileType:AVFileTypeQuickTimeMovie error:&writerError];
    
    if (writerError) {
        NSLog(@"❌ Failed to create asset writer: %@", writerError.localizedDescription);
        return Napi::Boolean::New(env, false);
    }
    
    NSLog(@"✅ Asset writer created successfully");
    
    // Video input settings using actual dimensions
    NSLog(@"📺 Setting up video input: %dx%d", (int)videoSize.width, (int)videoSize.height);
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @((NSInteger)videoSize.width),
        AVVideoHeightKey: @((NSInteger)videoSize.height),
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(2000000), // 2 Mbps
            AVVideoMaxKeyFrameIntervalKey: @30
        }
    };
    
    g_scDelegate.videoInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    g_scDelegate.videoInput.expectsMediaDataInRealTime = YES;
    
    // Create pixel buffer adaptor for more robust handling
    NSDictionary *pixelBufferAttributes = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString*)kCVPixelBufferWidthKey: @((NSInteger)videoSize.width),
        (NSString*)kCVPixelBufferHeightKey: @((NSInteger)videoSize.height),
    };
    
    g_scDelegate.pixelBufferAdaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc] 
        initWithAssetWriterInput:g_scDelegate.videoInput 
        sourcePixelBufferAttributes:pixelBufferAttributes];
    
    if ([g_scDelegate.assetWriter canAddInput:g_scDelegate.videoInput]) {
        [g_scDelegate.assetWriter addInput:g_scDelegate.videoInput];
        NSLog(@"✅ Video input added to asset writer with pixel buffer adaptor");
    } else {
        NSLog(@"❌ Cannot add video input to asset writer");
    }
    
    // Audio input settings (if needed)
    if (includeSystemAudio) {
        NSDictionary *audioSettings = @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVSampleRateKey: @44100,
            AVNumberOfChannelsKey: @2
        };
        
        g_scDelegate.audioInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
        g_scDelegate.audioInput.expectsMediaDataInRealTime = YES;
        
        if ([g_scDelegate.assetWriter canAddInput:g_scDelegate.audioInput]) {
            [g_scDelegate.assetWriter addInput:g_scDelegate.audioInput];
        }
    }
    
    // Create a dedicated serial queue for output callbacks
    if (g_outputQueue == NULL) {
        g_outputQueue = dispatch_queue_create("com.node-mac-recorder.stream-output", DISPATCH_QUEUE_SERIAL);
    }

    // Create and start stream first
    g_scStream = [[SCStream alloc] initWithFilter:contentFilter configuration:config delegate:g_scDelegate];
    
    // Attach outputs to actually receive sample buffers
    NSLog(@"✅ Setting up stream output callback for sample buffers");
    dispatch_queue_t outputQueue = g_outputQueue;
    NSError *outputError = nil;
    BOOL addedScreenOutput = [g_scStream addStreamOutput:g_scDelegate type:SCStreamOutputTypeScreen sampleHandlerQueue:outputQueue error:&outputError];
    if (addedScreenOutput) {
        NSLog(@"✅ Screen output attached to SCStream");
        g_screenOutputAttached = YES;
    } else {
        NSLog(@"❌ Failed to attach screen output to SCStream: %@", outputError.localizedDescription);
    }
    if (includeSystemAudio) {
        outputError = nil;
        BOOL addedAudioOutput = [g_scStream addStreamOutput:g_scDelegate type:SCStreamOutputTypeAudio sampleHandlerQueue:outputQueue error:&outputError];
        if (addedAudioOutput) {
            NSLog(@"✅ Audio output attached to SCStream");
            g_audioOutputAttached = YES;
        } else {
            NSLog(@"⚠️ Failed to attach audio output to SCStream (audio may be disabled): %@", outputError.localizedDescription);
        }
    }
    
    if (!g_scStream) {
        NSLog(@"❌ Failed to create SCStream");
        return Napi::Boolean::New(env, false);
    }
    
    NSLog(@"✅ SCStream created successfully");
    
    // Add callback queue for sample buffers (this might be important)
    if (@available(macOS 14.0, *)) {
        // In macOS 14+, we can set a specific queue
        // For now, we'll rely on the default behavior
    }
    
    // Start capture and wait for it to begin
    dispatch_semaphore_t startSemaphore = dispatch_semaphore_create(0);
    __block NSError *startError = nil;
    
    NSLog(@"🚀 Starting ScreenCaptureKit capture");
    [g_scStream startCaptureWithCompletionHandler:^(NSError * _Nullable error) {
        startError = error;
        dispatch_semaphore_signal(startSemaphore);
    }];
    
    dispatch_semaphore_wait(startSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    
    if (startError) {
        NSLog(@"❌ Failed to start capture: %@", startError.localizedDescription);
        return Napi::Boolean::New(env, false);
    }
    
    NSLog(@"✅ ScreenCaptureKit capture started successfully");
    
    // Mark that we're ready to write (asset writer will be started in first sample buffer)
    g_scDelegate.isWriting = YES;
    g_isRecording = true;
    
    // Wait a moment to see if we get any sample buffers
    NSLog(@"⏱️ Waiting 1 second for sample buffers to arrive...");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (g_scDelegate && !g_scDelegate.hasStartTime) {
            NSLog(@"⚠️ No sample buffers received after 1 second - this might indicate a permission or configuration issue");
        } else if (g_scDelegate && g_scDelegate.hasStartTime) {
            NSLog(@"✅ Sample buffers are being received successfully");
        }
    });
    
    NSLog(@"🎬 Recording initialized successfully");
    return Napi::Boolean::New(env, true);
    }
}

// NAPI Function: Stop Recording
Napi::Value StopRecording(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (!g_isRecording) {
        return Napi::Boolean::New(env, false);
    }
    
    cleanupSCKRecording();
    return Napi::Boolean::New(env, true);
}

// NAPI Function: Get Recording Status (for JS compatibility)
Napi::Value GetRecordingStatus(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    return Napi::Boolean::New(env, g_isRecording);
}

// NAPI Function: Get Recording Status
Napi::Value IsRecording(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    return Napi::Boolean::New(env, g_isRecording);
}

// NAPI Function: Get Displays
Napi::Value GetDisplays(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (!isScreenCaptureKitAvailable()) {
        // Fallback to legacy method
        return GetAvailableDisplays(info);
    }
    
    // Use ScreenCaptureKit
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block SCShareableContent *shareableContent = nil;
    __block NSError *error = nil;
    
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable err) {
        shareableContent = content;
        error = err;
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
    if (error) {
        NSLog(@"Failed to get displays: %@", error.localizedDescription);
        return Napi::Array::New(env, 0);
    }
    
    Napi::Array displaysArray = Napi::Array::New(env);
    uint32_t index = 0;
    
    for (SCDisplay *display in shareableContent.displays) {
        Napi::Object displayObj = Napi::Object::New(env);
        displayObj.Set("id", Napi::Number::New(env, display.displayID));
        displayObj.Set("width", Napi::Number::New(env, display.width));
        displayObj.Set("height", Napi::Number::New(env, display.height));
        displayObj.Set("frame", Napi::Object::New(env)); // TODO: Add frame details
        
        displaysArray.Set(index++, displayObj);
    }
    
    return displaysArray;
}


// NAPI Function: Get Windows
Napi::Value GetWindows(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (!isScreenCaptureKitAvailable()) {
        // Use legacy CGWindowList method
        return GetWindowList(info);
    }
    
    // Use ScreenCaptureKit
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block SCShareableContent *shareableContent = nil;
    __block NSError *error = nil;
    
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable err) {
        shareableContent = content;
        error = err;
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
    if (error) {
        NSLog(@"Failed to get windows: %@", error.localizedDescription);
        return Napi::Array::New(env, 0);
    }
    
    Napi::Array windowsArray = Napi::Array::New(env);
    uint32_t index = 0;
    
    for (SCWindow *window in shareableContent.windows) {
        if (window.isOnScreen && window.frame.size.width > 50 && window.frame.size.height > 50) {
            Napi::Object windowObj = Napi::Object::New(env);
            windowObj.Set("id", Napi::Number::New(env, window.windowID));
            windowObj.Set("title", Napi::String::New(env, window.title ? [window.title UTF8String] : ""));
            windowObj.Set("ownerName", Napi::String::New(env, window.owningApplication.applicationName ? [window.owningApplication.applicationName UTF8String] : ""));
            windowObj.Set("bounds", Napi::Object::New(env)); // TODO: Add bounds details
            
            windowsArray.Set(index++, windowObj);
        }
    }
    
    return windowsArray;
}

// NAPI Function: Check Permissions
Napi::Value CheckPermissions(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    // Check screen recording permission
    bool hasPermission = CGPreflightScreenCaptureAccess();
    
    // If we don't have permission, try to request it
    if (!hasPermission) {
        NSLog(@"⚠️ Screen recording permission not granted, requesting access");
        bool requestResult = CGRequestScreenCaptureAccess();
        NSLog(@"📋 Permission request result: %@", requestResult ? @"SUCCESS" : @"FAILED");
        
        // Check again after request
        hasPermission = CGPreflightScreenCaptureAccess();
    }
    
    return Napi::Boolean::New(env, hasPermission);
}

// NAPI Function: Get Audio Devices  
Napi::Value GetAudioDevices(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    Napi::Array devices = Napi::Array::New(env);
    uint32_t index = 0;
    
    AudioObjectPropertyAddress propertyAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    
    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize);
    
    if (status != noErr) {
        return devices;
    }
    
    UInt32 deviceCount = dataSize / sizeof(AudioDeviceID);
    AudioDeviceID *audioDevices = (AudioDeviceID *)malloc(dataSize);
    
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize, audioDevices);
    
    if (status == noErr) {
        for (UInt32 i = 0; i < deviceCount; ++i) {
            AudioDeviceID deviceID = audioDevices[i];
            
            // Get device name
            CFStringRef deviceName = NULL;
            UInt32 size = sizeof(deviceName);
            AudioObjectPropertyAddress nameAddress = {
                kAudioDevicePropertyDeviceNameCFString,
                kAudioDevicePropertyScopeInput,
                kAudioObjectPropertyElementMain
            };
            
            status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, NULL, &size, &deviceName);
            
            if (status == noErr && deviceName) {
                Napi::Object deviceObj = Napi::Object::New(env);
                deviceObj.Set("id", Napi::String::New(env, std::to_string(deviceID)));
                
                const char *name = CFStringGetCStringPtr(deviceName, kCFStringEncodingUTF8);
                if (name) {
                    deviceObj.Set("name", Napi::String::New(env, name));
                } else {
                    deviceObj.Set("name", Napi::String::New(env, "Unknown Device"));
                }
                
                devices.Set(index++, deviceObj);
                CFRelease(deviceName);
            }
        }
    }
    
    free(audioDevices);
    return devices;
}

// Initialize the addon
Napi::Object Init(Napi::Env env, Napi::Object exports) {
    exports.Set("startRecording", Napi::Function::New(env, StartRecording));
    exports.Set("stopRecording", Napi::Function::New(env, StopRecording));
    exports.Set("isRecording", Napi::Function::New(env, IsRecording));
    exports.Set("getRecordingStatus", Napi::Function::New(env, GetRecordingStatus));
    exports.Set("getDisplays", Napi::Function::New(env, GetDisplays));
    exports.Set("getWindows", Napi::Function::New(env, GetWindows));
    exports.Set("checkPermissions", Napi::Function::New(env, CheckPermissions));
    exports.Set("getAudioDevices", Napi::Function::New(env, GetAudioDevices));
    
    // Initialize cursor tracker
    InitCursorTracker(env, exports);
    
    // Initialize window selector
    InitWindowSelector(env, exports);
    
    return exports;
}

NODE_API_MODULE(mac_recorder, Init)
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import "logging.h"
#import "sync_timeline.h"

static double g_cameraStartTimestamp = 0.0;

static NSError *MRCameraError(NSInteger code, NSString *message) {
    NSDictionary *info = @{
        NSLocalizedDescriptionKey: message ?: @"Camera error"
    };
    return [NSError errorWithDomain:@"CameraRecorder" code:code userInfo:info];
}

static BOOL MRAllowContinuityCamera() {
    if (getenv("ALLOW_CONTINUITY_CAMERA")) {
        return YES;
    }

    static dispatch_once_t onceToken;
    static BOOL allowContinuity = NO;
    dispatch_once(&onceToken, ^{
        id continuityKey = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSCameraUseContinuityCameraDeviceType"];
        if ([continuityKey respondsToSelector:@selector(boolValue)] && [continuityKey boolValue]) {
            allowContinuity = YES;
        }
    });
    return allowContinuity;
}

static BOOL MRIsContinuityCamera(AVCaptureDevice *device) {
    if (!device) {
        return NO;
    }

    if (@available(macOS 14.0, *)) {
        if ([device.deviceType isEqualToString:AVCaptureDeviceTypeContinuityCamera]) {
            return YES;
        }
    }

    NSString *deviceType = device.deviceType ?: @"";
    NSString *localizedName = device.localizedName ?: @"";
    NSString *modelId = device.modelID ?: @"";
    NSString *manufacturer = device.manufacturer ?: @"";

    BOOL nameMentionsContinuity = [localizedName rangeOfString:@"Continuity" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                  [modelId rangeOfString:@"Continuity" options:NSCaseInsensitiveSearch].location != NSNotFound;

    if (@available(macOS 14.0, *)) {
        if ([deviceType isEqualToString:AVCaptureDeviceTypeExternal] && nameMentionsContinuity) {
            return YES;
        }
    }

    if ([deviceType isEqualToString:AVCaptureDeviceTypeExternalUnknown] && nameMentionsContinuity) {
        return YES;
    }

    BOOL isApple = [manufacturer rangeOfString:@"Apple" options:NSCaseInsensitiveSearch].location != NSNotFound;
    if (isApple && nameMentionsContinuity) {
        if (@available(macOS 14.0, *)) {
            if ([deviceType isEqualToString:AVCaptureDeviceTypeExternal]) {
                return YES;
            }
        }
        if ([deviceType isEqualToString:AVCaptureDeviceTypeExternalUnknown]) {
            return YES;
        }
    }

    return NO;
}

static NSString *MRCameraNormalizeOutputPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || [path length] == 0) {
        return nil;
    }
    NSString *extension = path.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"webm"]) {
        NSString *updated = [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"mov"];
        MRLog(@"⚠️ Camera: .webm not supported, writing to %@", updated);
        return updated;
    }
    return path;
}

static void MRCameraRemoveFileIfExists(NSString *path) {
    if (!path || [path length] == 0) {
        return;
    }
    NSError *removeError = nil;
    [[NSFileManager defaultManager] removeItemAtPath:path error:&removeError];
    if (removeError && removeError.code != NSFileNoSuchFileError) {
        MRLog(@"⚠️ CameraRecorder: Failed to remove existing file at %@ (%@)", path, removeError.localizedDescription);
    }
}

@interface CameraRecorder : NSObject<AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureDeviceInput *deviceInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) AVAssetWriter *writer;
@property (nonatomic, strong) AVAssetWriterInput *writerInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *pixelBufferAdaptor;
@property (nonatomic, assign) CMTime startTime;
@property (nonatomic, assign) BOOL writerStarted;
@property (nonatomic, copy) NSString *outputPath;
@property (nonatomic, copy) NSString *lastFinishedOutputPath;

@property (atomic, assign) BOOL isRecording;
@property (atomic, assign) BOOL stopInFlight;

@property (atomic, assign) BOOL startCompleted;
@property (atomic, assign) BOOL startSucceeded;
@property (nonatomic, strong) dispatch_semaphore_t startSemaphore;

@property (nonatomic, strong) dispatch_semaphore_t stopSemaphore;
@property (atomic, assign) uint64_t activeToken;
@property (atomic, assign) BOOL unexpectedRestartAttempted;

+ (instancetype)sharedRecorder;
+ (NSArray<NSDictionary *> *)availableCameraDevices;

- (BOOL)startRecordingWithDeviceId:(NSString *)deviceId
                        outputPath:(NSString *)outputPath
                             error:(NSError **)error;
- (BOOL)stopRecording;
- (BOOL)waitForRecordingStartWithTimeout:(NSTimeInterval)timeout;

@end

@implementation CameraRecorder

- (instancetype)init {
    self = [super init];
    if (self) {
        _workQueue = dispatch_queue_create("com.macrecorder.camera", DISPATCH_QUEUE_SERIAL);
        _videoQueue = dispatch_queue_create("com.macrecorder.camera.video", DISPATCH_QUEUE_SERIAL);
        _startCompleted = YES;
        _startSucceeded = NO;
        _activeToken = 0;
        _unexpectedRestartAttempted = NO;
        _writerStarted = NO;
        _startTime = kCMTimeInvalid;
    }
    return self;
}

#pragma mark - Shared instance

+ (instancetype)sharedRecorder {
    static CameraRecorder *recorder = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        recorder = [[CameraRecorder alloc] init];
    });
    return recorder;
}

#pragma mark - Device listing helpers

+ (NSArray<NSDictionary *> *)availableCameraDevices {
    NSMutableArray<NSDictionary *> *devicesInfo = [NSMutableArray array];

    NSMutableArray<AVCaptureDeviceType> *deviceTypes = [NSMutableArray array];
    [deviceTypes addObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
    if (@available(macOS 14.0, *)) {
        [deviceTypes addObject:AVCaptureDeviceTypeExternal];
        [deviceTypes addObject:AVCaptureDeviceTypeContinuityCamera];
    } else {
        [deviceTypes addObject:AVCaptureDeviceTypeExternalUnknown];
    }

    AVCaptureDeviceDiscoverySession *discoverySession =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypes
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionUnspecified];

    for (AVCaptureDevice *device in discoverySession.devices) {
        BOOL continuityCamera = MRIsContinuityCamera(device);

        CMVideoDimensions bestDimensions = {0, 0};
        Float64 bestFrameRate = 0.0;

        for (AVCaptureDeviceFormat *format in device.formats) {
            CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            if (dims.width <= 0 || dims.height <= 0) {
                continue;
            }

            Float64 maxFrameRateForFormat = 0.0;
            for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
                maxFrameRateForFormat = MAX(maxFrameRateForFormat, range.maxFrameRate);
            }

            bool isBetterResolution = (dims.width * dims.height) > (bestDimensions.width * bestDimensions.height);
            bool sameResolutionHigherFps = (dims.width * dims.height) == (bestDimensions.width * bestDimensions.height) &&
                                           maxFrameRateForFormat > bestFrameRate;

            if (isBetterResolution || sameResolutionHigherFps) {
                bestDimensions = dims;
                bestFrameRate = maxFrameRateForFormat;
            }
        }

        NSString *position;
        switch (device.position) {
            case AVCaptureDevicePositionFront:
                position = @"front";
                break;
            case AVCaptureDevicePositionBack:
                position = @"back";
                break;
            default:
                position = @"unspecified";
                break;
        }

        BOOL isBuiltIn = NO;
        NSString *deviceName = device.localizedName ?: @"";
        NSString *deviceType = device.deviceType ?: @"";

        if ([deviceName rangeOfString:@"FaceTime" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [deviceName rangeOfString:@"iSight" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [deviceName rangeOfString:@"Built-in" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            isBuiltIn = YES;
        }

        if (@available(macOS 10.15, *)) {
            if ([deviceType isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera]) {
                isBuiltIn = YES;
            }
        }

        if (continuityCamera ||
            [deviceName rangeOfString:@"iPhone" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [deviceName rangeOfString:@"iPad" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [deviceName rangeOfString:@"Continuity" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            isBuiltIn = NO;
        }

        if (@available(macOS 14.0, *)) {
            if ([deviceType isEqualToString:AVCaptureDeviceTypeExternal] ||
                [deviceType isEqualToString:AVCaptureDeviceTypeContinuityCamera]) {
                isBuiltIn = NO;
            }
        }
        if ([deviceType isEqualToString:AVCaptureDeviceTypeExternalUnknown]) {
            isBuiltIn = NO;
        }

        NSDictionary *deviceInfo = @{
            @"id": device.uniqueID ?: @"",
            @"name": deviceName,
            @"model": device.modelID ?: @"",
            @"manufacturer": device.manufacturer ?: @"",
            @"position": position ?: @"unspecified",
            @"transportType": @(device.transportType),
            @"isConnected": @(device.isConnected),
            @"isDefault": @(isBuiltIn),
            @"hasFlash": @(device.hasFlash),
            @"supportsDepth": @NO,
            @"deviceType": deviceType,
            @"requiresContinuityCameraPermission": @(continuityCamera),
            @"maxResolution": @{
                @"width": @(bestDimensions.width),
                @"height": @(bestDimensions.height),
                @"maxFrameRate": @(bestFrameRate)
            }
        };

        [devicesInfo addObject:deviceInfo];
    }

    return devicesInfo;
}

#pragma mark - Device configuration

- (AVCaptureDevice *)deviceForId:(NSString *)deviceId {
    if (deviceId && deviceId.length > 0) {
        AVCaptureDevice *device = [AVCaptureDevice deviceWithUniqueID:deviceId];
        if (device) {
            return device;
        }
    }

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (device) {
        return device;
    }

    NSArray<NSDictionary *> *devices = [CameraRecorder availableCameraDevices];
    if (devices.count > 0) {
        NSString *fallbackId = devices.firstObject[@"id"];
        device = [AVCaptureDevice deviceWithUniqueID:fallbackId];
    }
    return device;
}

- (AVCaptureDeviceFormat *)bestFormatForDevice:(AVCaptureDevice *)device
                                      widthOut:(int32_t *)widthOut
                                     heightOut:(int32_t *)heightOut
                                   frameRateOut:(double *)frameRateOut {
    AVCaptureDeviceFormat *bestFormat = nil;
    int64_t bestResolutionScore = 0;
    double bestFrameRate = 0.0;

    for (AVCaptureDeviceFormat *format in device.formats) {
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        if (dims.width <= 0 || dims.height <= 0) {
            continue;
        }

        if (dims.width > 1280 || dims.height > 720) {
            continue;
        }

        int64_t score = (int64_t)dims.width * (int64_t)dims.height;

        double maxFrameRate = 0.0;
        for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
            maxFrameRate = MAX(maxFrameRate, range.maxFrameRate);
        }

        BOOL usesBetterResolution = score > bestResolutionScore;
        BOOL sameResolutionHigherFps = (score == bestResolutionScore) && (maxFrameRate > bestFrameRate);

        if (!bestFormat || usesBetterResolution || sameResolutionHigherFps) {
            bestFormat = format;
            bestResolutionScore = score;
            bestFrameRate = maxFrameRate;
            if (widthOut) *widthOut = dims.width;
            if (heightOut) *heightOut = dims.height;
            if (frameRateOut) *frameRateOut = bestFrameRate;
        }
    }

    return bestFormat;
}

- (BOOL)configureDevice:(AVCaptureDevice *)device
             withFormat:(AVCaptureDeviceFormat *)format
              frameRate:(double)frameRate
                  error:(NSError **)error {
    if (!device || !format) {
        if (error) {
            *error = MRCameraError(-3, @"Camera device unavailable");
        }
        return NO;
    }

    NSError *lockError = nil;
    if (![device lockForConfiguration:&lockError]) {
        if (error) {
            *error = lockError;
        }
        return NO;
    }

    @try {
        if ([device.formats containsObject:format]) {
            device.activeFormat = format;
        }

        double targetFrameRate = frameRate > 0 ? MIN(frameRate, 24.0) : 24.0;
        AVFrameRateRange *bestRange = nil;
        for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
            if (!bestRange || range.maxFrameRate > bestRange.maxFrameRate) {
                bestRange = range;
            }
        }

        if (bestRange) {
            double clampedRate = MIN(bestRange.maxFrameRate, MAX(bestRange.minFrameRate, targetFrameRate));
            double durationSeconds = clampedRate > 0.0 ? (1.0 / clampedRate) : CMTimeGetSeconds(bestRange.maxFrameDuration);
            int32_t preferredTimescale = bestRange.minFrameDuration.timescale > 0 ? bestRange.minFrameDuration.timescale : 600;
            CMTime desiredDuration = CMTimeMakeWithSeconds(durationSeconds, preferredTimescale);

            if (!CMTIME_IS_NUMERIC(desiredDuration)) {
                desiredDuration = bestRange.maxFrameDuration;
            }

            if (CMTimeCompare(desiredDuration, bestRange.minFrameDuration) < 0) {
                desiredDuration = bestRange.minFrameDuration;
            } else if (CMTimeCompare(desiredDuration, bestRange.maxFrameDuration) > 0) {
                desiredDuration = bestRange.maxFrameDuration;
            }

            device.activeVideoMinFrameDuration = desiredDuration;
            device.activeVideoMaxFrameDuration = desiredDuration;
        }
    } @catch (NSException *exception) {
        if (error) {
            *error = MRCameraError(-4, exception.reason ?: @"Failed to configure camera device");
        }
        [device unlockForConfiguration];
        return NO;
    }

    [device unlockForConfiguration];
    return YES;
}

#pragma mark - AVAssetWriter Setup

- (BOOL)setupWriterWithSampleBuffer:(CMSampleBufferRef)sampleBuffer error:(NSError **)error {
    if (self.writer) {
        return YES;  // Already initialized
    }

    if (!self.outputPath || [self.outputPath length] == 0) {
        if (error) {
            *error = MRCameraError(-100, @"Output path not set");
        }
        return NO;
    }

    NSURL *outputURL = [NSURL fileURLWithPath:self.outputPath];
    MRCameraRemoveFileIfExists(self.outputPath);

    NSError *writerError = nil;
    self.writer = [[AVAssetWriter alloc] initWithURL:outputURL
                                            fileType:AVFileTypeQuickTimeMovie
                                               error:&writerError];
    if (!self.writer || writerError) {
        if (error) {
            *error = writerError;
        }
        MRLog(@"❌ Failed to create camera AVAssetWriter: %@", writerError);
        return NO;
    }

    // Get video dimensions from sample buffer
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        if (error) {
            *error = MRCameraError(-101, @"No pixel buffer in sample");
        }
        return NO;
    }

    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);

    MRLog(@"🎥 Camera recording dimensions: %zux%zu", width, height);

    // H.264 video settings (matching current quality)
    NSInteger bitrate = (NSInteger)(width * height * 24);  // 24fps target
    bitrate = MAX(bitrate, 5 * 1000 * 1000);   // Min 5 Mbps
    bitrate = MIN(bitrate, 30 * 1000 * 1000);  // Max 30 Mbps

    NSDictionary *compressionProps = @{
        AVVideoAverageBitRateKey: @(bitrate),
        AVVideoMaxKeyFrameIntervalKey: @(24),
        AVVideoAllowFrameReorderingKey: @YES,
        AVVideoExpectedSourceFrameRateKey: @(24),
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
    };

    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: compressionProps
    };

    self.writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                          outputSettings:videoSettings];
    self.writerInput.expectsMediaDataInRealTime = YES;

    if (![self.writer canAddInput:self.writerInput]) {
        if (error) {
            *error = MRCameraError(-102, @"Cannot add video input to writer");
        }
        return NO;
    }
    [self.writer addInput:self.writerInput];

    // Create pixel buffer adaptor
    NSDictionary *pixelBufferAttributes = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString*)kCVPixelBufferWidthKey: @(width),
        (NSString*)kCVPixelBufferHeightKey: @(height),
        (NSString*)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString*)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };

    self.pixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.writerInput
                                   sourcePixelBufferAttributes:pixelBufferAttributes];

    MRLog(@"✅ Camera AVAssetWriter configured: %.2f Mbps, H.264", bitrate / (1000.0 * 1000.0));
    return YES;
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        return;
    }

    // Setup writer on first frame
    NSError *setupError = nil;
    if (![self setupWriterWithSampleBuffer:sampleBuffer error:&setupError]) {
        if (setupError) {
            MRLog(@"❌ Camera writer setup failed: %@", setupError);
        }
        return;
    }

    if (!self.writer || !self.writerInput || !self.pixelBufferAdaptor) {
        return;
    }

    CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

    // Hold camera frames until we see audio so timelines stay aligned
    if (MRSyncShouldHoldVideoFrame(timestamp)) {
        return;
    }

    // Start writer session on first frame
    if (!self.writerStarted) {
        if (![self.writer startWriting]) {
            MRLog(@"❌ Camera writer failed to start: %@", self.writer.error);
            return;
        }
        [self.writer startSessionAtSourceTime:kCMTimeZero];  // CRITICAL: t=0 timeline
        self.writerStarted = YES;
        
        // LIP SYNC FIX: Align camera startTime with audio's first timestamp for perfect lip sync
        // This ensures camera and audio start from the same reference point
        CMTime audioFirstTimestamp = MRSyncAudioFirstTimestamp();
        CMTime alignmentOffset = MRSyncVideoAlignmentOffset();
        
        if (CMTIME_IS_VALID(audioFirstTimestamp)) {
            // Use audio's first timestamp as reference - this is the key to lip sync
            self.startTime = audioFirstTimestamp;
            CMTime offset = CMTimeSubtract(timestamp, audioFirstTimestamp);
            double offsetMs = CMTimeGetSeconds(offset) * 1000.0;
            MRLog(@"🎥 Camera writer started @ t=0 (aligned with audio first timestamp, offset: %.1fms)", offsetMs);
        } else if (CMTIME_IS_VALID(alignmentOffset)) {
            // If audio came first, use the alignment offset to sync
            self.startTime = CMTimeSubtract(timestamp, alignmentOffset);
            double offsetMs = CMTimeGetSeconds(alignmentOffset) * 1000.0;
            MRLog(@"🎥 Camera writer started @ t=0 (using alignment offset: %.1fms)", offsetMs);
        } else {
            // Fallback: use camera's own timestamp (should not happen if sync is configured)
            self.startTime = timestamp;
            MRLog(@"🎥 Camera writer started @ t=0 (source PTS: %.3fs, no audio sync available)", CMTimeGetSeconds(timestamp));
        }
        
        g_cameraStartTimestamp = CFAbsoluteTimeGetCurrent();

        // Signal start completion
        [self completeStart:YES token:self.activeToken];
    }

    if (!self.writerInput.readyForMoreMediaData) {
        // Drop frame if writer is not ready (prevents blocking)
        return;
    }

    // TIMESTAMP NORMALIZATION (audio_recorder.mm pattern)
    // LIP SYNC FIX: Use audio-aligned startTime for perfect synchronization
    CMTime adjustedTimestamp = kCMTimeZero;
    if (CMTIME_IS_VALID(self.startTime)) {
        adjustedTimestamp = CMTimeSubtract(timestamp, self.startTime);
        if (CMTIME_COMPARE_INLINE(adjustedTimestamp, <, kCMTimeZero)) {
            adjustedTimestamp = kCMTimeZero;
        }
    } else {
        // Fallback: if startTime not set, use current timestamp as base
        // This should not happen if sync is working correctly
        adjustedTimestamp = kCMTimeZero;
    }

    // Get pixel buffer from sample
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        MRLog(@"⚠️ No pixel buffer in camera sample");
        return;
    }

    // Append to writer with normalized timestamp
    BOOL success = [self.pixelBufferAdaptor appendPixelBuffer:pixelBuffer
                                         withPresentationTime:adjustedTimestamp];
    if (!success) {
        MRLog(@"⚠️ Failed to append camera pixel buffer: %@", self.writer.error);
    }
}

#pragma mark - Synchronization helpers

- (uint64_t)nextToken {
    @synchronized (self) {
        self.activeToken += 1;
        return self.activeToken;
    }
}

- (BOOL)waitForStopCompletion:(NSTimeInterval)timeout {
    dispatch_semaphore_t stopSemaphore = self.stopSemaphore;
    if (!stopSemaphore) {
        return YES;
    }
    dispatch_time_t waitTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    long result = dispatch_semaphore_wait(stopSemaphore, waitTime);
    if (result != 0) {
        MRLog(@"⚠️ CameraRecorder: Previous stop did not finish within %.2fs", timeout);
        return NO;
    }
    self.stopSemaphore = nil;
    self.stopInFlight = NO;
    return YES;
}

- (void)completeStart:(BOOL)success token:(uint64_t)token {
    if (token != self.activeToken) {
        return;
    }
    if (self.startCompleted && self.startSucceeded == success) {
        return;
    }
    self.startCompleted = YES;
    self.startSucceeded = success;
    if (!success) {
        self.isRecording = NO;
    }
    dispatch_semaphore_t semaphore = self.startSemaphore;
    if (semaphore) {
        dispatch_semaphore_signal(semaphore);
    }
}

- (void)cleanupAfterStopOnQueue {
    self.session = nil;
    self.deviceInput = nil;
    self.videoOutput = nil;
    self.writer = nil;
    self.writerInput = nil;
    self.pixelBufferAdaptor = nil;
    self.writerStarted = NO;
    self.startTime = kCMTimeInvalid;
    self.isRecording = NO;
    self.stopInFlight = NO;
    self.outputPath = nil;
    self.unexpectedRestartAttempted = NO;
    g_cameraStartTimestamp = 0.0;
}

#pragma mark - Recording lifecycle

- (void)performStartWithDeviceId:(NSString *)deviceId
                      outputPath:(NSString *)outputPath
                           token:(uint64_t)token {
    @autoreleasepool {
        if (self.stopInFlight || token != self.activeToken) {
            [self completeStart:NO token:token];
            return;
        }

        NSString *normalizedPath = MRCameraNormalizeOutputPath(outputPath);
        if (!normalizedPath || [normalizedPath length] == 0) {
            [self completeStart:NO token:token];
            return;
        }

        MRCameraRemoveFileIfExists(normalizedPath);

        AVCaptureDevice *device = [self deviceForId:deviceId];
        if (!device) {
            MRLog(@"❌ No camera devices available");
            [self completeStart:NO token:token];
            return;
        }

        if (MRIsContinuityCamera(device) && !MRAllowContinuityCamera()) {
            MRLog(@"⚠️ Continuity Camera access denied - missing entitlement");
            [self completeStart:NO token:token];
            return;
        }

        int32_t width = 0;
        int32_t height = 0;
        double frameRate = 0.0;
        AVCaptureDeviceFormat *bestFormat = [self bestFormatForDevice:device widthOut:&width heightOut:&height frameRateOut:&frameRate];
        if (!bestFormat) {
            MRLog(@"❌ No suitable camera format found");
            [self completeStart:NO token:token];
            return;
        }

        NSError *configError = nil;
        if (![self configureDevice:device withFormat:bestFormat frameRate:frameRate error:&configError]) {
            MRLog(@"❌ Failed to configure device: %@", configError.localizedDescription);
            [self completeStart:NO token:token];
            return;
        }

        if (self.stopInFlight || token != self.activeToken) {
            [self completeStart:NO token:token];
            return;
        }

        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        session.sessionPreset = AVCaptureSessionPresetHigh;
        [session beginConfiguration];

        NSError *inputError = nil;
        AVCaptureDeviceInput *deviceInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:&inputError];
        if (!deviceInput || ![session canAddInput:deviceInput]) {
            MRLog(@"❌ Unable to add camera input: %@", inputError.localizedDescription);
            [session commitConfiguration];
            [self completeStart:NO token:token];
            return;
        }
        [session addInput:deviceInput];

        // Setup video data output with delegate pattern (realtime sync)
        AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];

        NSDictionary *videoSettings = @{
            (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
        };
        [videoOutput setVideoSettings:videoSettings];
        videoOutput.alwaysDiscardsLateVideoFrames = NO;  // Preserve all frames

        if (![session canAddOutput:videoOutput]) {
            MRLog(@"❌ Unable to add video data output to capture session");
            [session commitConfiguration];
            [self completeStart:NO token:token];
            return;
        }
        [session addOutput:videoOutput];

        // Set delegate for per-frame processing
        [videoOutput setSampleBufferDelegate:self queue:self.videoQueue];

        // Configure video mirroring for front camera
        AVCaptureConnection *videoConnection = [videoOutput connectionWithMediaType:AVMediaTypeVideo];
        if (videoConnection && videoConnection.isVideoMirroringSupported && device.position == AVCaptureDevicePositionFront) {
            if ([videoConnection respondsToSelector:@selector(setAutomaticallyAdjustsVideoMirroring:)]) {
                videoConnection.automaticallyAdjustsVideoMirroring = NO;
            }
            videoConnection.videoMirrored = YES;
        }

        [session commitConfiguration];

        if (self.stopInFlight || token != self.activeToken) {
            [self completeStart:NO token:token];
            return;
        }

        self.session = session;
        self.deviceInput = deviceInput;
        self.videoOutput = videoOutput;
        self.outputPath = normalizedPath;
        self.writerStarted = NO;
        self.startTime = kCMTimeInvalid;

        [session startRunning];

        // Give session a brief moment to warm up
        [NSThread sleepForTimeInterval:0.5];

        if (self.stopInFlight || token != self.activeToken) {
            [session stopRunning];
            [self completeStart:NO token:token];
            return;
        }

        MRLog(@"🎥 Camera session running - writer will start on first frame");
        // Note: Recording confirmation will be triggered by first video frame in delegate
    }
}

- (BOOL)startRecordingWithDeviceId:(NSString *)deviceId
                        outputPath:(NSString *)outputPath
                             error:(NSError **)error {
    if (![self waitForStopCompletion:5.0]) {
        if (error) {
            *error = MRCameraError(-20, @"Camera stop is still finalizing – please retry");
        }
        return NO;
    }

    if (self.isRecording) {
        if (error) {
            *error = MRCameraError(-1, @"Camera recording already in progress");
        }
        return NO;
    }

    if (!outputPath || outputPath.length == 0) {
        if (error) {
            *error = MRCameraError(-2, @"Invalid camera output path");
        }
        return NO;
    }

    AVAuthorizationStatus cameraStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (cameraStatus == AVAuthorizationStatusDenied || cameraStatus == AVAuthorizationStatusRestricted) {
        if (error) {
            *error = MRCameraError(-4, @"Camera permission denied - please grant permission in System Settings");
        }
        return NO;
    }

    if (cameraStatus == AVAuthorizationStatusNotDetermined) {
        MRLog(@"🔐 Camera permission not determined - requesting async (non-blocking)...");
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            if (granted) {
                MRLog(@"✅ Camera permission granted (async callback)");
            } else {
                MRLog(@"❌ Camera permission denied (async callback)");
            }
        }];
    }

    self.startCompleted = NO;
    self.startSucceeded = NO;
    self.startSemaphore = dispatch_semaphore_create(0);
    self.stopInFlight = NO;
    self.isRecording = YES;
    self.unexpectedRestartAttempted = NO;
    self.lastFinishedOutputPath = nil;

    uint64_t token = [self nextToken];

    dispatch_async(self.workQueue, ^{
        [self performStartWithDeviceId:deviceId outputPath:outputPath token:token];
    });

    return YES;
}

- (BOOL)stopRecording {
    BOOL hasActiveSession = (self.session && [self.session isRunning]);
    BOOL writerActive = (self.writer && self.writerStarted);
    if (!self.isRecording && !hasActiveSession && !writerActive) {
        [self waitForStopCompletion:5.0];
        return YES;
    }

    if (!self.startCompleted) {
        [self completeStart:NO token:self.activeToken];
    }

    self.stopInFlight = YES;

    dispatch_semaphore_t stopSemaphore = dispatch_semaphore_create(0);
    self.stopSemaphore = stopSemaphore;

    dispatch_async(self.workQueue, ^{
        // Stop video delegate
        if (self.videoOutput) {
            [self.videoOutput setSampleBufferDelegate:nil queue:nil];
        }

        // Finalize writer (audio_recorder.mm pattern)
        if (self.writer && self.writerStarted) {
            if (self.writerInput) {
                [self.writerInput markAsFinished];
            }

            dispatch_semaphore_t writerSemaphore = dispatch_semaphore_create(0);
            [self.writer finishWritingWithCompletionHandler:^{
                if (self.writer.status == AVAssetWriterStatusCompleted) {
                    MRLog(@"✅ Camera writer finished");
                } else if (self.writer.status == AVAssetWriterStatusFailed) {
                    MRLog(@"❌ Camera writer failed: %@", self.writer.error);
                }
                dispatch_semaphore_signal(writerSemaphore);
            }];

            // 3 second timeout (matching audio_recorder.mm:269)
            dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC);
            if (dispatch_semaphore_wait(writerSemaphore, timeout) != 0) {
                MRLog(@"⚠️ Camera writer timeout – canceling");
                [self.writer cancelWriting];
            }
        }

        dispatch_semaphore_signal(stopSemaphore);

        // Session cleanup
        if (self.session && [self.session isRunning]) {
            [self.session stopRunning];
        }

        if (self.session && self.deviceInput && [self.session.inputs containsObject:self.deviceInput]) {
            [self.session removeInput:self.deviceInput];
        }
        if (self.session && self.videoOutput && [self.session.outputs containsObject:self.videoOutput]) {
            [self.session removeOutput:self.videoOutput];
        }

        [self cleanupAfterStopOnQueue];
    });

    dispatch_time_t waitTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC));
    long waitResult = dispatch_semaphore_wait(stopSemaphore, waitTime);
    if (waitResult != 0) {
        MRLog(@"⚠️ CameraRecorder: Stop did not finish within 5s (proceeding)");
    } else {
        MRLog(@"✅ CameraRecorder: Stop finalized");
    }

    self.stopSemaphore = nil;
    self.isRecording = NO;
    self.stopInFlight = NO;
    return YES;
}

- (BOOL)waitForRecordingStartWithTimeout:(NSTimeInterval)timeout {
    if (self.startCompleted) {
        return self.startSucceeded;
    }
    dispatch_semaphore_t semaphore = self.startSemaphore;
    if (!semaphore) {
        return self.startSucceeded;
    }
    dispatch_time_t waitTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    long result = dispatch_semaphore_wait(semaphore, waitTime);
    if (result != 0 && !self.startCompleted) {
        return NO;
    }
    return self.startSucceeded;
}

@end

// MARK: - C Interface

extern "C" {

NSArray<NSDictionary *> *listCameraDevices() {
    return [CameraRecorder availableCameraDevices];
}

bool startCameraRecording(NSString *outputPath, NSString *deviceId, NSError **error) {
    return [[CameraRecorder sharedRecorder] startRecordingWithDeviceId:deviceId
                                                            outputPath:outputPath
                                                                 error:error];
}

bool waitForCameraRecordingStart(double timeoutSeconds) {
    return [[CameraRecorder sharedRecorder] waitForRecordingStartWithTimeout:timeoutSeconds];
}

double currentCameraRecordingStartTime(void) {
    return g_cameraStartTimestamp;
}

bool stopCameraRecording() {
    @autoreleasepool {
        return [[CameraRecorder sharedRecorder] stopRecording];
    }
}

bool isCameraRecording() {
    return [CameraRecorder sharedRecorder].isRecording;
}

NSString *currentCameraRecordingPath() {
    CameraRecorder *recorder = [CameraRecorder sharedRecorder];
    if (recorder.lastFinishedOutputPath && [recorder.lastFinishedOutputPath length] > 0) {
        return recorder.lastFinishedOutputPath;
    }
    return recorder.outputPath;
}

}

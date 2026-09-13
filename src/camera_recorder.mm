#import "recording_writer_safety.h"
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
@property (nonatomic, assign) BOOL primaryPrefixWritten;
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

    // H.264 video settings - optimized for smaller file size
    // Using lower bitrate multiplier for camera (2x instead of 24x) to reduce file size
    NSInteger bitrate = (NSInteger)(width * height * 2);
    bitrate = MAX(bitrate, 1 * 1000 * 1000);   // Min 1 Mbps
    bitrate = MIN(bitrate, 6 * 1000 * 1000);   // Max 6 Mbps (significantly reduced from 30)

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
    if (self.stopInFlight || !self.isRecording || output != self.videoOutput) return;
    @try {

    BOOL primaryTimeline = MRSyncUsesPrimaryTimeline();
    if (!primaryTimeline && MRSyncIsPaused()) {
        return;
    }

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
    CMTime primaryMediaTime = kCMTimeInvalid;
    if (primaryTimeline) {
        timestamp = MRSyncHostTimestamp(timestamp, self.session.masterClock);
        primaryMediaTime = MRSyncPrimaryMediaTime(timestamp);
        if (!CMTIME_IS_NUMERIC(primaryMediaTime)) return;
    }

    // Drop camera warm-up frames until the primary source (USB iPhone screen)
    // has committed its first frame. This keeps all files on one t=0 boundary.
    if (MRSyncShouldHoldForPrimary(timestamp)) {
        return;
    }

    // A/V SYNC: Signal camera's first frame to release audio hold
    MRSyncMarkCameraFirstFrame(timestamp);

    // "Ready" means the capture device delivered a real frame, not that the
    // writer already received audio. Signaling here lets the primary recorder
    // start its audio source; waiting until writer start creates a camera/audio
    // barrier cycle and can hold startup until the timeout.
    [self completeStart:YES token:self.activeToken];

    // Hold camera frames until we see audio so timelines stay aligned
    if (!primaryTimeline && MRSyncShouldHoldVideoFrame(timestamp)) {
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
        self.primaryPrefixWritten = NO;
        
        // LIP SYNC FIX: Align camera startTime with audio's first timestamp for perfect lip sync
        // This ensures camera and audio start from the same reference point
        CMTime audioFirstTimestamp = MRSyncAudioFirstTimestamp();
        CMTime alignmentOffset = MRSyncVideoAlignmentOffset();
        
        if (primaryTimeline) {
            self.startTime = MRSyncPrimaryStartTimestamp();
        } else if (CMTIME_IS_VALID(audioFirstTimestamp)) {
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
    adjustedTimestamp = primaryTimeline ? primaryMediaTime : MRSyncAdjustForPauses(adjustedTimestamp);

    // LIP SYNC FIX: Check stopLimit OR elapsed time to drop frames after recording duration
    // This prevents camera from recording longer than audio
    double frameTime = CMTimeGetSeconds(adjustedTimestamp);
    double stopLimit = MRSyncGetStopLimitSeconds();
    double videoTolerance = 0.05;  // 50ms tolerance for video frames (larger than audio's 20ms)

    // CRITICAL FIX: Also check elapsed time since recording started
    // This works even if stopLimit hasn't been set yet
    double elapsedTime = (g_cameraStartTimestamp > 0)
        ? MAX(0, CFAbsoluteTimeGetCurrent() - g_cameraStartTimestamp - MRSyncGetPausedDurationSeconds())
        : 0;
    double maxDuration = (stopLimit > 0) ? stopLimit : elapsedTime + 1.0;  // Use stopLimit if available, else allow 1s more

    // DEBUG: Log every 30th frame
    static int frameCounter = 0;
    frameCounter++;
    if (frameCounter % 30 == 0) {
        MRLog(@"📹 Camera frame #%d: frameTime=%.3fs, elapsedTime=%.3fs, stopLimit=%.3fs, maxDuration=%.3fs",
              frameCounter, frameTime, elapsedTime, stopLimit, maxDuration);
    }

    // Drop frame if it exceeds stopLimit (when set) or if elapsed time is suspiciously long
    if (stopLimit > 0 && frameTime > stopLimit + videoTolerance) {
        MRLog(@"🛑 Camera dropping frame #%d: frameTime %.3fs > stopLimit %.3fs + tolerance",
              frameCounter, frameTime, stopLimit);
        return;
    }

    // Safety check: Drop frames if recording has been going for too long (failsafe)
    if (elapsedTime > maxDuration + 1.0) {  // Allow 1s grace period
        MRLog(@"🛑 Camera dropping frame #%d: elapsed %.3fs > maxDuration %.3fs (failsafe)",
              frameCounter, elapsedTime, maxDuration);
        return;
    }

    // Get pixel buffer from sample
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        MRLog(@"⚠️ No pixel buffer in camera sample");
        return;
    }

    // Keep a late camera's initial delay in the media itself. Some demuxers
    // discard MOV empty edits and would otherwise pull the camera ahead of mic.
    if (primaryTimeline && !self.primaryPrefixWritten) {
        if (CMTimeCompare(adjustedTimestamp, kCMTimeZero) > 0 &&
            ![self.pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:kCMTimeZero]) return;
        self.primaryPrefixWritten = YES;
        if (!self.writerInput.readyForMoreMediaData) return;
    }

    // Append to writer with normalized timestamp
    BOOL success = [self.pixelBufferAdaptor appendPixelBuffer:pixelBuffer
                                         withPresentationTime:adjustedTimestamp];
    if (!success) {
        MRLog(@"⚠️ Failed to append camera pixel buffer: %@", self.writer.error);
    }
    } @catch (NSException *exception) {
        NSLog(@"[Recorder] Camera sample failed safely: %@", exception.reason);
        [self completeStart:NO token:self.activeToken];
        self.isRecording = NO;
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
    if (!stopSemaphore || !self.stopInFlight) {
        self.stopSemaphore = nil;
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

        // A/V SYNC FIX: Removed 500ms warmup delay that was causing lip sync issues.
        // The delegate pattern starts writing on first frame, no warmup needed.

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
        @try {
            [self performStartWithDeviceId:deviceId outputPath:outputPath token:token];
        } @catch (NSException *exception) {
            NSLog(@"[Recorder] Camera startup failed safely: %@", exception.reason);
            [self completeStart:NO token:token];
        }
    });

    return YES;
}

- (BOOL)stopRecording {
    if (self.stopInFlight) return [self waitForStopCompletion:5.0];
    if (!self.isRecording && !self.session && !self.writer) return YES;
    if (!self.startCompleted) [self completeStart:NO token:self.activeToken];
    self.stopInFlight = YES;
    self.isRecording = NO;
    [self nextToken]; // invalidate any queued startup work

    dispatch_semaphore_t stopSemaphore = dispatch_semaphore_create(0);
    self.stopSemaphore = stopSemaphore;
    dispatch_async(self.workQueue, ^{
      @autoreleasepool {
        @try {
            @try {
                if (self.videoOutput) [self.videoOutput setSampleBufferDelegate:nil queue:nil];
            } @catch (NSException *exception) {
                NSLog(@"[Recorder] Camera delegate detach failed safely: %@", exception.reason);
            }
            // A callback already running may still use the writer/adaptor.
            dispatch_sync(self.videoQueue, ^{});
            MRFinishAssetWriterSafely(self.writer, 3.0, MRSyncGetStopLimitSeconds());
            if (self.session.isRunning) [self.session stopRunning];
            if (self.deviceInput && [self.session.inputs containsObject:self.deviceInput]) {
                [self.session removeInput:self.deviceInput];
            }
            if (self.videoOutput && [self.session.outputs containsObject:self.videoOutput]) {
                [self.session removeOutput:self.videoOutput];
            }
        } @catch (NSException *exception) {
            NSLog(@"[Recorder] Camera stop failed safely: %@", exception.reason);
        } @finally {
            [self cleanupAfterStopOnQueue];
            // Signal only after the old session can no longer clear new state.
            dispatch_semaphore_signal(stopSemaphore);
        }
      }
    });
    // A timeout does NOT release the stop-in-flight gate. A subsequent start
    // must wait for this work queue to finish, especially after USB removal.
    return [self waitForStopCompletion:5.0];
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

bool hasCameraRecordingResources() {
    CameraRecorder *recorder = [CameraRecorder sharedRecorder];
    return recorder.isRecording || recorder.stopInFlight || recorder.session != nil || recorder.writer != nil;
}

bool isCameraRecordingStopping() {
    return [CameraRecorder sharedRecorder].stopInFlight;
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

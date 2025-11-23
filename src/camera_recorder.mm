#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import "logging.h"
#import "sync_timeline.h"

#ifdef __cplusplus
extern "C" {
#endif
double MRActiveStopLimitSeconds(void);
double MRScreenRecordingStartTimestampSeconds(void);
double currentCameraRecordingStartTime(void);
#ifdef __cplusplus
}
#endif

static double g_cameraStartTimestamp = 0.0;

#ifndef AVVideoCodecTypeVP9
static AVVideoCodecType const AVVideoCodecTypeVP9 = @"vp09";
#endif

static BOOL MRAllowContinuityCamera() {
    // Check environment variable first (allows runtime override)
    if (getenv("ALLOW_CONTINUITY_CAMERA")) {
        return YES;
    }

    // Check Info.plist
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

static void MRTrimMovieFileIfNeeded(NSString *path, double stopLimitSeconds, double headTrimSeconds) {
    BOOL hasStopLimit = stopLimitSeconds > 0.0;
    BOOL hasHeadTrim = headTrimSeconds > 0.0;
    if (!path || [path length] == 0 || (!hasStopLimit && !hasHeadTrim)) {
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    if (!asset) {
        return;
    }

    CMTime duration = asset.duration;
    if (!CMTIME_IS_NUMERIC(duration) || duration.value == 0) {
        return;
    }

    double assetSeconds = CMTimeGetSeconds(duration);
    double tolerance = 0.03;
    if (!hasStopLimit) {
        stopLimitSeconds = assetSeconds;
    }
    if (assetSeconds <= stopLimitSeconds + tolerance && !hasHeadTrim) {
        return;
    }

    int32_t timescale = duration.timescale > 0 ? duration.timescale : 600;
    double startTrimSeconds = hasHeadTrim ? MIN(headTrimSeconds, stopLimitSeconds - tolerance) : 0.0;
    if (startTrimSeconds < 0.0) {
        startTrimSeconds = 0.0;
    }

    CMTime targetDuration = CMTimeMakeWithSeconds(stopLimitSeconds, timescale);
    if (CMTIME_COMPARE_INLINE(targetDuration, <=, kCMTimeZero)) {
        return;
    }

    CMTime startTime = CMTimeMakeWithSeconds(startTrimSeconds, timescale);
    if (CMTIME_COMPARE_INLINE(startTime, >=, targetDuration)) {
        startTime = kCMTimeZero;
    }
    CMTime effectiveDuration = CMTimeSubtract(targetDuration, startTime);
    if (CMTIME_COMPARE_INLINE(effectiveDuration, <=, kCMTimeZero)) {
        startTime = kCMTimeZero;
        effectiveDuration = targetDuration;
    }

    CMTimeRange trimRange = CMTimeRangeMake(startTime, effectiveDuration);

    NSString *extension = path.pathExtension.lowercaseString;
    NSString *tempPath = [[path stringByDeletingPathExtension]
                          stringByAppendingFormat:@"_trim.tmp.%@", extension.length > 0 ? extension : @"mov"];
    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

    AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:asset
                                                                           presetName:AVAssetExportPresetPassthrough];
    if (!exportSession) {
        return;
    }
    exportSession.timeRange = trimRange;
    exportSession.outputURL = [NSURL fileURLWithPath:tempPath];

    NSString *fileType = AVFileTypeQuickTimeMovie;
    if ([extension isEqualToString:@"mp4"]) {
        fileType = AVFileTypeMPEG4;
    } else if ([extension isEqualToString:@"mov"]) {
        fileType = AVFileTypeQuickTimeMovie;
    }
    exportSession.outputFileType = fileType;

    if (startTrimSeconds > 0.0) {
        MRLog(@"✂️ Trimming camera head by %.3f s (target duration %.3f s) for %@", startTrimSeconds, stopLimitSeconds, path);
    } else {
        MRLog(@"✂️ Trimming %@ to %.3f seconds", path, stopLimitSeconds);
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC));
    dispatch_semaphore_wait(semaphore, timeout);

    if (exportSession.status == AVAssetExportSessionStatusCompleted) {
        NSError *removeError = nil;
        [[NSFileManager defaultManager] removeItemAtPath:path error:&removeError];
        if (removeError && removeError.code != NSFileNoSuchFileError) {
            MRLog(@"⚠️ Failed removing original camera file before trim replace: %@", removeError);
        }
        NSError *moveError = nil;
        if (![[NSFileManager defaultManager] moveItemAtPath:tempPath toPath:path error:&moveError]) {
            MRLog(@"⚠️ Failed to replace camera file with trimmed version: %@", moveError);
        } else {
            MRLog(@"✅ Camera file trimmed to %.3f seconds", stopLimitSeconds);
        }
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
        if (exportSession.error) {
            MRLog(@"⚠️ Camera trim export failed: %@", exportSession.error);
        } else {
            MRLog(@"⚠️ Camera trim export did not complete (status %ld)", (long)exportSession.status);
        }
    }
}

// Dedicated camera recorder used alongside screen capture
// ELECTRON FIX: Using MovieFileOutput instead of VideoDataOutput to avoid buffer conflicts
@interface CameraRecorder : NSObject<AVCaptureFileOutputRecordingDelegate>

@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureDeviceInput *deviceInput;
@property (nonatomic, strong) AVCaptureMovieFileOutput *movieFileOutput;
@property (nonatomic, strong) NSString *outputPath;
@property (atomic, assign) BOOL isRecording;
@property (nonatomic, strong) dispatch_semaphore_t recordingStartedSemaphore;
@property (nonatomic, strong) dispatch_semaphore_t recordingStoppedSemaphore;
@property (atomic, assign) BOOL recordingStartCompleted;
@property (atomic, assign) BOOL recordingStartSucceeded;

+ (instancetype)sharedRecorder;
+ (NSArray<NSDictionary *> *)availableCameraDevices;
- (BOOL)startRecordingWithDeviceId:(NSString *)deviceId
                        outputPath:(NSString *)outputPath
                             error:(NSError **)error;
- (BOOL)stopRecording;

@end

@implementation CameraRecorder

- (instancetype)init {
    self = [super init];
    if (self) {
        // MovieFileOutput-based recorder - no buffer management needed
        _recordingStartCompleted = YES;
        _recordingStartSucceeded = NO;
    }
    return self;
}

- (void)prepareRecordingStartSignal {
    self.recordingStartCompleted = NO;
    self.recordingStartSucceeded = NO;
    self.recordingStartedSemaphore = dispatch_semaphore_create(0);
}

- (void)finishRecordingStart:(BOOL)success {
    if (self.recordingStartCompleted && self.recordingStartSucceeded == success) {
        return;
    }
    self.recordingStartCompleted = YES;
    self.recordingStartSucceeded = success;
    dispatch_semaphore_t semaphore = self.recordingStartedSemaphore;
    if (semaphore) {
        dispatch_semaphore_signal(semaphore);
    }
}

- (BOOL)waitForRecordingStartWithTimeout:(NSTimeInterval)timeout {
    if (self.recordingStartCompleted) {
        return self.recordingStartSucceeded;
    }
    dispatch_semaphore_t semaphore = self.recordingStartedSemaphore;
    if (!semaphore) {
        return self.recordingStartSucceeded;
    }
    dispatch_time_t waitTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    long result = dispatch_semaphore_wait(semaphore, waitTime);
    if (result != 0 && !self.recordingStartCompleted) {
        return NO;
    }
    return self.recordingStartSucceeded;
}


+ (instancetype)sharedRecorder {
    static CameraRecorder *recorder = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        recorder = [[CameraRecorder alloc] init];
    });
    return recorder;
}

+ (NSArray<NSDictionary *> *)availableCameraDevices {
    NSMutableArray<NSDictionary *> *devicesInfo = [NSMutableArray array];

    NSMutableArray<AVCaptureDeviceType> *deviceTypes = [NSMutableArray array];
    BOOL allowContinuity = MRAllowContinuityCamera();

    // Always include built-in and external cameras
    if (@available(macOS 10.15, *)) {
        [deviceTypes addObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
    } else {
        [deviceTypes addObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
    }

    // ALWAYS add external cameras - they should be available regardless of Continuity permission
    if (@available(macOS 14.0, *)) {
        [deviceTypes addObject:AVCaptureDeviceTypeExternal];
    } else {
        [deviceTypes addObject:AVCaptureDeviceTypeExternalUnknown];
    }

    // CRITICAL FIX: ALWAYS add Continuity Camera so iPhone is visible
    // Users should always see their devices, even if permission is missing
    // Permission check happens at RECORDING time, not listing time
    if (@available(macOS 14.0, *)) {
        [deviceTypes addObject:AVCaptureDeviceTypeContinuityCamera];
        MRLog(@"✅ Added Continuity Camera device type (iPhone will be visible)");
    }

    AVCaptureDeviceDiscoverySession *discoverySession =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypes
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionUnspecified];

    for (AVCaptureDevice *device in discoverySession.devices) {
        BOOL continuityCamera = MRIsContinuityCamera(device);

        // NOTE: We list ALL cameras including Continuity Camera
        // The permission check happens at RECORDING time, not listing time
        // This allows users to see the device even if permission is missing
        
        // Determine the best (maximum) resolution format for this device
        CMVideoDimensions bestDimensions = {0, 0};
        Float64 bestFrameRate = 0.0;
        
        for (AVCaptureDeviceFormat *format in device.formats) {
            CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            
            // Skip invalid formats
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

        // PRIORITY FIX: MacBook built-in cameras should be default, not external cameras
        // Check if this is a built-in camera (MacBook's own camera)
        NSString *deviceName = device.localizedName ?: @"";
        NSString *deviceType = device.deviceType ?: @"";
        BOOL isBuiltIn = NO;

        // Built-in detection: Check for common built-in camera names
        if ([deviceName rangeOfString:@"FaceTime" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [deviceName rangeOfString:@"iSight" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [deviceName rangeOfString:@"Built-in" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            isBuiltIn = YES;
        }

        // Check device type for built-in wide angle camera
        if (@available(macOS 10.15, *)) {
            if ([deviceType isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera]) {
                isBuiltIn = YES;
            }
        }

        // External devices (Continuity Camera, iPhone, iPad, USB) should NOT be default
        if (continuityCamera ||
            [deviceName rangeOfString:@"iPhone" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [deviceName rangeOfString:@"iPad" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [deviceName rangeOfString:@"Continuity" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            isBuiltIn = NO;
        }

        // External device types should not be default
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
            @"isDefault": @(isBuiltIn), // Only built-in cameras are default
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

// ELECTRON FIX: MovieFileOutput-based recorder doesn't need buffer management
// These methods are kept for compatibility but do nothing
- (void)clearPendingSampleBuffers {
    // No-op: MovieFileOutput manages its own buffers
}

- (void)resetState {
    self.isRecording = NO;
    self.session = nil;
    self.deviceInput = nil;
    self.movieFileOutput = nil;
    self.outputPath = nil;
    self.recordingStartedSemaphore = nil;
    self.recordingStoppedSemaphore = nil;
}

- (AVCaptureDevice *)deviceForId:(NSString *)deviceId {
    if (deviceId && deviceId.length > 0) {
        AVCaptureDevice *device = [AVCaptureDevice deviceWithUniqueID:deviceId];
        if (device) {
            return device;
        }
    }
    
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device) {
        NSArray<NSDictionary *> *devices = [CameraRecorder availableCameraDevices];
        if (devices.count > 0) {
            NSString *fallbackId = devices.firstObject[@"id"];
            device = [AVCaptureDevice deviceWithUniqueID:fallbackId];
        }
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

    MRLog(@"🔍 Scanning formats for device: %@", device.localizedName);

    for (AVCaptureDeviceFormat *format in device.formats) {
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        if (dims.width <= 0 || dims.height <= 0) {
            continue;
        }

        // ELECTRON FIX: Limit resolution to 1280x720 (720p) for balance
        // Full HD works fine with MovieFileOutput since it doesn't conflict with ScreenCaptureKit
        // But we still cap at 720p for reasonable file sizes and performance
        if (dims.width > 1280 || dims.height > 720) {
            continue;  // Skip formats higher than 720p
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
            MRLog(@"   ✅ New best: %dx%d @ %.0ffps (score=%lld)",
                  dims.width, dims.height, maxFrameRate, score);
        }
    }

    if (bestFormat) {
        MRLog(@"📹 Selected format: %dx%d @ %.0ffps", *widthOut, *heightOut, *frameRateOut);
    } else {
        MRLog(@"❌ No suitable format found");
    }

    return bestFormat;
}

- (BOOL)configureDevice:(AVCaptureDevice *)device
             withFormat:(AVCaptureDeviceFormat *)format
              frameRate:(double)frameRate
                  error:(NSError **)error {
    if (!device || !format) {
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
        
        // ELECTRON FIX: Use reasonable frame rate (24 FPS) for good quality
        // MovieFileOutput works perfectly with ScreenCaptureKit - no conflicts!
        // 24fps provides smooth motion while keeping file size reasonable
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
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: exception.reason ?: @"Failed to configure camera device"
            };
            *error = [NSError errorWithDomain:@"CameraRecorder"
                                         code:-4
                                     userInfo:userInfo];
        }
        [device unlockForConfiguration];
        return NO;
    }
    
    [device unlockForConfiguration];
    return YES;
}

#if 0  // ELECTRON FIX: Old buffer management code - no longer used with MovieFileOutput
- (BOOL)setupWriterWithURL:(NSURL *)outputURL
                     width:(int32_t)width
                    height:(int32_t)height
                 frameRate:(double)frameRate
                     error:(NSError **)error {
    if (!outputURL) {
        return NO;
    }
    
    NSString *extension = outputURL.pathExtension.lowercaseString;
    BOOL wantsWebM = [extension isEqualToString:@"webm"];
    NSString *originalPath = outputURL.path ?: @"";
    
    NSString *codec = AVVideoCodecTypeH264;
    AVFileType fileType = AVFileTypeQuickTimeMovie;
    BOOL webMSupported = NO;
    
    if (wantsWebM) {
        if (@available(macOS 15.0, *)) {
            codec = AVVideoCodecTypeVP9;
            fileType = @"public.webm";
            webMSupported = YES;
            MRLog(@"📹 CameraRecorder: Using VP9 codec for WebM output");
        } else {
            MRLog(@"⚠️ CameraRecorder: WebM output requested but not supported on this macOS version. Falling back to .mov");
        }
    }
    
    NSError *writerError = nil;
    @try {
        self.assetWriter = [[AVAssetWriter alloc] initWithURL:outputURL fileType:fileType error:&writerError];
    } @catch (NSException *exception) {
        NSDictionary *info = @{
            NSLocalizedDescriptionKey: exception.reason ?: @"Failed to initialize asset writer"
        };
        writerError = [NSError errorWithDomain:@"CameraRecorder" code:-100 userInfo:info];
        self.assetWriter = nil;
    }
    
    if ((!self.assetWriter || writerError) && wantsWebM) {
        MRLog(@"⚠️ CameraRecorder: WebM writer unavailable (%@) – falling back to QuickTime container", writerError.localizedDescription);
        codec = AVVideoCodecTypeH264;
        fileType = AVFileTypeQuickTimeMovie;
        webMSupported = NO;
        writerError = nil;
        NSString *fallbackPath = [[originalPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"mov"];
        if (!fallbackPath || [fallbackPath length] == 0) {
            fallbackPath = [originalPath stringByAppendingString:@".mov"];
        }
        [[NSFileManager defaultManager] removeItemAtPath:fallbackPath error:nil];
        NSURL *fallbackURL = [NSURL fileURLWithPath:fallbackPath];
        self.outputPath = fallbackPath;
        @try {
            self.assetWriter = [[AVAssetWriter alloc] initWithURL:fallbackURL fileType:fileType error:&writerError];
        } @catch (NSException *exception) {
            NSDictionary *info = @{
                NSLocalizedDescriptionKey: exception.reason ?: @"Failed to initialize asset writer"
            };
            writerError = [NSError errorWithDomain:@"CameraRecorder" code:-100 userInfo:info];
            self.assetWriter = nil;
        }
        outputURL = fallbackURL;
    } else {
        self.outputPath = originalPath;
    }
    
    if (!self.assetWriter || writerError) {
        if (error) {
            *error = writerError;
        }
        return NO;
    }
    
    if (wantsWebM && !webMSupported) {
        MRLog(@"ℹ️ CameraRecorder: WebM unavailable, storing data in QuickTime container");
    }
    
    // Calculate bitrate based on resolution for high quality
    // Use higher multiplier for better quality (10 instead of 6)
    NSInteger bitrate = (NSInteger)(width * height * 10);
    bitrate = MAX(bitrate, 8 * 1000 * 1000); // Minimum 8 Mbps for quality
    bitrate = MIN(bitrate, 50 * 1000 * 1000); // Maximum 50 Mbps to avoid excessive file size

    MRLog(@"🎬 Camera encoder settings: %dx%d @ %.2ffps, bitrate=%.2fMbps",
          width, height, frameRate, bitrate / (1000.0 * 1000.0));
    
    NSMutableDictionary *compressionProps = [@{
        AVVideoAverageBitRateKey: @(bitrate),
        AVVideoMaxKeyFrameIntervalKey: @(MAX(1, (int)round(frameRate))),
        AVVideoAllowFrameReorderingKey: @YES,
        AVVideoExpectedSourceFrameRateKey: @(frameRate),
        // Add quality hint for better encoding
        AVVideoQualityKey: @(0.9) // 0.0-1.0, higher is better quality
    } mutableCopy];

    if ([codec isEqualToString:AVVideoCodecTypeH264]) {
        compressionProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel;
        // Use Main profile for better quality
        compressionProps[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC;
    }
    
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: codec,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: compressionProps
    };
    
    self.assetWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                               outputSettings:videoSettings];
    self.assetWriterInput.expectsMediaDataInRealTime = YES;
    
    NSDictionary *pixelBufferAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (NSString *)kCVPixelBufferWidthKey: @(width),
        (NSString *)kCVPixelBufferHeightKey: @(height),
        // Preserve aspect ratio and use high quality scaling
        (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };
    
    self.pixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.assetWriterInput
                                                                                              sourcePixelBufferAttributes:pixelBufferAttributes];
    
    if (![self.assetWriter canAddInput:self.assetWriterInput]) {
        if (error) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"Unable to attach video input to asset writer"
            };
            *error = [NSError errorWithDomain:@"CameraRecorder" code:-5 userInfo:userInfo];
        }
        return NO;
    }
    
    [self.assetWriter addInput:self.assetWriterInput];
    self.writerStarted = NO;
    self.firstSampleTime = kCMTimeInvalid;

    return YES;
}
#endif  // End old buffer management code (setupWriterWithURL)

// MARK: - NEW MovieFileOutput Implementation (NOT disabled!)

- (BOOL)startRecordingWithDeviceId:(NSString *)deviceId
                        outputPath:(NSString *)outputPath
                             error:(NSError **)error {
    if (self.isRecording) {
        if (error) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"Camera recording already in progress"
            };
            *error = [NSError errorWithDomain:@"CameraRecorder" code:-1 userInfo:userInfo];
        }
        return NO;
    }
    
    if (!outputPath || outputPath.length == 0) {
        if (error) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"Invalid camera output path"
            };
            *error = [NSError errorWithDomain:@"CameraRecorder" code:-2 userInfo:userInfo];
        }
        return NO;
    }
    
    // CRITICAL ELECTRON FIX: Non-blocking permission check
    AVAuthorizationStatus cameraStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];

    // Definitely denied - stop immediately
    if (cameraStatus == AVAuthorizationStatusDenied || cameraStatus == AVAuthorizationStatusRestricted) {
        if (error) {
            NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Camera permission denied - please grant permission in System Settings" };
            *error = [NSError errorWithDomain:@"CameraRecorder" code:-4 userInfo:userInfo];
        }
        return NO;
    }

    // CRITICAL ELECTRON FIX: For NotDetermined, request async and assume it will be granted
    // Blocking/polling here causes Electron crashes
    if (cameraStatus == AVAuthorizationStatusNotDetermined) {
        MRLog(@"🔐 Camera permission not determined - requesting async (non-blocking)...");
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            if (granted) {
                MRLog(@"✅ Camera permission granted (async callback)");
            } else {
                MRLog(@"❌ Camera permission denied (async callback)");
            }
        }];
        // Don't wait - camera will start when permission is granted
        MRLog(@"📤 Permission request sent, continuing without blocking...");
    }

    // CRITICAL ELECTRON FIX: Do ALL potentially blocking operations on background thread
    // File I/O and device locking MUST NOT block main thread

    // Store output path for later use
    self.outputPath = outputPath;
    self.isRecording = YES;  // Mark as recording early
    [self prepareRecordingStartSignal];
    self.recordingStoppedSemaphore = nil;

    // Schedule all blocking operations on background thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            // Remove any stale file (BLOCKING I/O - safe on background thread)
            NSError *removeError = nil;
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:&removeError];
            if (removeError && removeError.code != NSFileNoSuchFileError) {
                MRLog(@"⚠️ CameraRecorder: Failed to remove existing camera file: %@", removeError);
            }

            [self clearPendingSampleBuffers];
            AVCaptureDevice *device = [self deviceForId:deviceId];
            if (!device) {
                MRLog(@"❌ No camera devices available");
                self.isRecording = NO;
                [self finishRecordingStart:NO];
                return;
            }

            if (MRIsContinuityCamera(device) && !MRAllowContinuityCamera()) {
                MRLog(@"⚠️ Continuity Camera access denied - missing Info.plist entitlement");
                self.isRecording = NO;
                [self finishRecordingStart:NO];
                return;
            }

            int32_t width = 0;
            int32_t height = 0;
            double frameRate = 0.0;
            AVCaptureDeviceFormat *bestFormat = [self bestFormatForDevice:device widthOut:&width heightOut:&height frameRateOut:&frameRate];

            NSError *configError = nil;
            if (![self configureDevice:device withFormat:bestFormat frameRate:frameRate error:&configError]) {
                MRLog(@"❌ Failed to configure device: %@", configError);
                self.isRecording = NO;
                [self finishRecordingStart:NO];
                return;
            }

            // Continue with session setup on background thread
            [self continueSetupWithDevice:device width:width height:height frameRate:frameRate outputPath:outputPath];
        }
    });

    // Return immediately - setup continues async
    MRLog(@"📤 Camera setup scheduled on background thread (non-blocking)");
    return YES;
}

- (void)continueSetupWithDevice:(AVCaptureDevice *)device
                          width:(int32_t)width
                         height:(int32_t)height
                      frameRate:(double)frameRate
                     outputPath:(NSString *)outputPath {

    self.session = [[AVCaptureSession alloc] init];

    // ELECTRON FIX: Use HIGH preset for good quality
    // MovieFileOutput works perfectly with ScreenCaptureKit - no more crashes!
    // We already selected best format (up to 720p), so HIGH preset will use it
    self.session.sessionPreset = AVCaptureSessionPresetHigh;
    MRLog(@"📹 Camera session preset: HIGH (up to 720p based on selected format)");

    // CRITICAL ELECTRON FIX: Use beginConfiguration / commitConfiguration
    // This makes session configuration ATOMIC and prevents crashes
    [self.session beginConfiguration];

    NSError *localError = nil;
    self.deviceInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:&localError];
    if (!self.deviceInput) {
        MRLog(@"❌ Failed to create device input: %@", localError);
        [self.session commitConfiguration];
        [self resetState];
        [self finishRecordingStart:NO];
        return;
    }

    if ([self.session canAddInput:self.deviceInput]) {
        [self.session addInput:self.deviceInput];
    } else {
        MRLog(@"❌ Unable to add camera input to capture session");
        [self.session commitConfiguration];
        [self resetState];
        [self finishRecordingStart:NO];
        return;
    }

    // CRITICAL ELECTRON FIX: Use AVCaptureMovieFileOutput instead of VideoDataOutput
    // VideoDataOutput uses frame-by-frame buffers that conflict with ScreenCaptureKit
    // MovieFileOutput writes directly to file with different buffer management
    self.movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];

    if ([self.session canAddOutput:self.movieFileOutput]) {
        [self.session addOutput:self.movieFileOutput];
        MRLog(@"✅ Added AVCaptureMovieFileOutput (file-based recording, no buffer conflicts)");
    } else {
        MRLog(@"❌ Unable to add movie file output to capture session");
        [self.session commitConfiguration];
        [self resetState];
        [self finishRecordingStart:NO];
        return;
    }

    // CRITICAL FIX: Disable audio recording - we only want video from camera
    // MovieFileOutput by default tries to record both audio and video
    // Since we don't have an audio input, it won't start recording at all
    AVCaptureConnection *audioConnection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeAudio];
    if (audioConnection) {
        audioConnection.enabled = NO;
        MRLog(@"🔇 Disabled audio connection (video-only recording)");
    } else {
        MRLog(@"ℹ️ No audio connection found (expected - video-only setup)");
    }

    AVCaptureConnection *connection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
    if (connection) {
        // Mirror front cameras for natural preview
        if (connection.isVideoMirroringSupported && device.position == AVCaptureDevicePositionFront) {
            if ([connection respondsToSelector:@selector(setAutomaticallyAdjustsVideoMirroring:)]) {
                connection.automaticallyAdjustsVideoMirroring = NO;
            }
            connection.videoMirrored = YES;
        }
        MRLog(@"📐 Camera connection: orientation=%ld (native), mirrored=%d, format=%dx%d",
              (long)connection.videoOrientation,
              connection.isVideoMirrored,
              width, height);
    }

    // CRITICAL: Commit configuration BEFORE starting
    [self.session commitConfiguration];

    // Store configuration
    self.outputPath = outputPath;
    self.isRecording = YES;

    // CRITICAL ELECTRON FIX: Start on current thread (already on background)
    // Don't touch main thread at all - AVCaptureSession can start on background thread
    MRLog(@"🎥 Starting AVCaptureSession (camera) on background thread...");
    [self.session startRunning];

    // Wait a moment for session to fully start
    [NSThread sleepForTimeInterval:0.5];

    MRLog(@"✅ AVCaptureSession started");
    MRLog(@"🔍 Session isRunning: %d", [self.session isRunning]);

    // CRITICAL FIX: MovieFileOutput only supports .mov and .mp4, NOT .webm
    // If path ends with .webm, change it to .mov
    NSString *finalOutputPath = outputPath;
    if ([outputPath.pathExtension.lowercaseString isEqualToString:@"webm"]) {
        finalOutputPath = [[outputPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"mov"];
        MRLog(@"⚠️ Camera: Changed output from .webm to .mov (MovieFileOutput doesn't support WebM)");
        MRLog(@"   New path: %@", finalOutputPath);
        // Update stored path
        self.outputPath = finalOutputPath;
    }

    // CRITICAL: Start file recording immediately
    NSURL *outputURL = [NSURL fileURLWithPath:finalOutputPath];

    // Verify path and output are valid
    if (!outputURL) {
        MRLog(@"❌ Failed to create output URL from path: %@", finalOutputPath);
        [self finishRecordingStart:NO];
        return;
    }

    if (!self.movieFileOutput) {
        MRLog(@"❌ movieFileOutput is nil!");
        return;
    }

    MRLog(@"📁 Camera output path: %@", outputPath);
    MRLog(@"📁 Camera output URL: %@", outputURL);
    MRLog(@"🎥 Starting movie file recording...");

    [self.movieFileOutput startRecordingToOutputFileURL:outputURL recordingDelegate:self];

    MRLog(@"✅ startRecordingToOutputFileURL called");
    MRLog(@"🔍 Is recording: %d", [self.movieFileOutput isRecording]);

    MRLog(@"🎥 CameraRecorder started: %@ (file-based recording)", device.localizedName);
    MRLog(@"   Format reports: %dx%d @ %.2ffps", width, height, frameRate);
}

// MARK: - AVCaptureFileOutputRecordingDelegate

- (void)captureOutput:(AVCaptureFileOutput *)output
didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL
      fromConnections:(NSArray<AVCaptureConnection *> *)connections
                error:(NSError *)error {
    MRLog(@"🎬 DELEGATE: didFinishRecordingToOutputFileAtURL called");
    MRLog(@"   File URL: %@", outputFileURL.path);

    if (error) {
        MRLog(@"❌ Camera recording finished with ERROR:");
        MRLog(@"   Error code: %ld", (long)error.code);
        MRLog(@"   Error domain: %@", error.domain);
        MRLog(@"   Error description: %@", error.localizedDescription);
        if (error.userInfo) {
            MRLog(@"   Error userInfo: %@", error.userInfo);
        }
    } else {
        MRLog(@"✅ Camera recording finished SUCCESSFULLY");
        MRLog(@"   Output file: %@", outputFileURL.path);

        // Check if file actually exists
        BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:outputFileURL.path];
        MRLog(@"   File exists on disk: %d", fileExists);

        if (fileExists) {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outputFileURL.path error:nil];
            unsigned long long fileSize = [attrs fileSize];
            MRLog(@"   File size: %llu bytes", fileSize);
        }
    }

    // IMPORTANT: Avoid post-trim to prevent unintended short camera clips on subsequent recordings.
    // Stop limits can be miscomputed after consecutive runs; keeping the raw camera file is safer.
    MRLog(@"ℹ️ Camera trim disabled; keeping full recorded duration");
    g_cameraStartTimestamp = 0.0;

    // Signal any waiters that the stop finished
    dispatch_semaphore_t stopSemaphore = self.recordingStoppedSemaphore;
    if (stopSemaphore) {
        dispatch_semaphore_signal(stopSemaphore);
    }

    self.isRecording = NO;
}

- (void)captureOutput:(AVCaptureFileOutput *)output
didStartRecordingToOutputFileAtURL:(NSURL *)fileURL
      fromConnections:(NSArray<AVCaptureConnection *> *)connections {
    MRLog(@"🎬 DELEGATE: didStartRecordingToOutputFileAtURL called");
    MRLog(@"   File URL: %@", fileURL.path);
    MRLog(@"   Connections count: %lu", (unsigned long)connections.count);
    MRLog(@"✅ Camera file recording STARTED successfully!");
    g_cameraStartTimestamp = CFAbsoluteTimeGetCurrent();
    [self finishRecordingStart:YES];
}

- (BOOL)stopRecording {
    if (!self.isRecording) {
        return YES;
    }

    MRLog(@"🛑 CameraRecorder: Stopping recording...");
    if (!self.recordingStartCompleted) {
        [self finishRecordingStart:NO];
    }

    // Prepare stop semaphore so callers can wait for finalization
    dispatch_semaphore_t stopSemaphore = dispatch_semaphore_create(0);
    self.recordingStoppedSemaphore = stopSemaphore;

    // CRITICAL ELECTRON FIX: Stop movie file output (simple API)
    if (self.movieFileOutput && [self.movieFileOutput isRecording]) {
        [self.movieFileOutput stopRecording];
        MRLog(@"✅ Movie file output stop requested");
    } else {
        // If nothing to stop, signal immediately
        dispatch_semaphore_signal(stopSemaphore);
    }

    // Stop session
    if (self.session && [self.session isRunning]) {
        [self.session stopRunning];
        MRLog(@"✅ AVCaptureSession stopped");
    }

    // Wait (briefly) for file writer to finish flushing to disk so next start is clean
    dispatch_time_t waitTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC));
    long waitResult = dispatch_semaphore_wait(stopSemaphore, waitTime);
    if (waitResult != 0) {
        MRLog(@"⚠️ CameraRecorder: Stop did not finish within 2s (proceeding)");
    } else {
        MRLog(@"✅ CameraRecorder: Stop finalized");
    }

    // Cleanup
    self.isRecording = NO;
    self.session = nil;
    self.deviceInput = nil;
    self.movieFileOutput = nil;
    self.recordingStoppedSemaphore = nil;

    MRLog(@"✅ CameraRecorder stopped successfully");
    return YES;
}

#if 0  // ELECTRON FIX: Old buffer management code - no longer used with MovieFileOutput
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) {
        return;
    }
    if (![self.pendingSampleBuffers isKindOfClass:[NSMutableArray class]]) {
        MRLog(@"⚠️ CameraRecorder: pendingSampleBuffers not NSMutableArray (%@) — reinitializing",
              NSStringFromClass([self.pendingSampleBuffers class]));
        self.pendingSampleBuffers = [NSMutableArray array];
    }
    CMSampleBufferRef bufferCopy = NULL;
    OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, sampleBuffer, &bufferCopy);
    if (status == noErr && bufferCopy) {
        [self.pendingSampleBuffers addObject:[NSValue valueWithPointer:bufferCopy]];
    } else if (bufferCopy) {
        CFRelease(bufferCopy);
    }
}

- (void)flushPendingSampleBuffers {
    id container = self.pendingSampleBuffers;
    if (![container isKindOfClass:[NSArray class]]) {
        MRLog(@"⚠️ CameraRecorder: pendingSampleBuffers corrupted (%@) — resetting",
              NSStringFromClass([container class]));
        self.pendingSampleBuffers = [NSMutableArray array];
        return;
    }
    if ([(NSArray *)container count] == 0) {
        return;
    }

    NSArray<NSValue *> *queued = [(NSArray *)container copy];
    [self.pendingSampleBuffers removeAllObjects];

    CMTime audioStart = MRSyncAudioFirstTimestamp();
    BOOL hasAudioStart = CMTIME_IS_VALID(audioStart);

    double stopLimit = MRSyncGetStopLimitSeconds();

    for (NSValue *value in queued) {
        CMSampleBufferRef buffer = (CMSampleBufferRef)[value pointerValue];
        if (!buffer) {
            continue;
        }

        CMTime bufferTime = CMSampleBufferGetPresentationTimeStamp(buffer);
        if (hasAudioStart && CMTIME_IS_VALID(bufferTime)) {
            // Drop frames captured before audio actually began to keep durations aligned.
            if (CMTIME_COMPARE_INLINE(bufferTime, <, audioStart)) {
                CFRelease(buffer);
                continue;
            }
        }

        if (stopLimit > 0 && CMTIME_IS_VALID(bufferTime)) {
            CMTime baseline = kCMTimeInvalid;
            if (CMTIME_IS_VALID(self.firstSampleTime)) {
                baseline = self.firstSampleTime;
            } else if (hasAudioStart) {
                baseline = audioStart;
            }
            double frameSeconds = 0.0;
            if (CMTIME_IS_VALID(baseline)) {
                frameSeconds = CMTimeGetSeconds(CMTimeSubtract(bufferTime, baseline));
            }
            // Do NOT extend camera stop limit by audio start offset.
            // Clamping to the same stopLimit as audio ensures durations match.
            double effectiveStopLimit = stopLimit;
            double tolerance = self.expectedFrameRate > 0 ? (1.5 / self.expectedFrameRate) : 0.02;
            if (tolerance < 0.02) {
                tolerance = 0.02;
            }
            if (frameSeconds > effectiveStopLimit + tolerance) {
                CFRelease(buffer);
                continue;
            }
        }

        [self processSampleBufferReadyForWriting:buffer];
        CFRelease(buffer);
    }
}

- (void)processSampleBufferReadyForWriting:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) {
        return;
    }

    CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

    // Lazy initialization - setup writer with actual frame dimensions
    if (!self.assetWriter) {
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!pixelBuffer) {
            MRLog(@"❌ No pixel buffer in first frame");
            return;
        }

        size_t actualWidth = CVPixelBufferGetWidth(pixelBuffer);
        size_t actualHeight = CVPixelBufferGetHeight(pixelBuffer);

        MRLog(@"🎬 First frame received: %zux%zu (format said %dx%d)",
              actualWidth, actualHeight, self.expectedWidth, self.expectedHeight);

        NSURL *outputURL = [NSURL fileURLWithPath:self.outputPath];
        NSError *setupError = nil;

        double frameRate = self.expectedFrameRate > 0 ? self.expectedFrameRate : 30.0;

        if (![self setupWriterWithURL:outputURL
                                width:(int32_t)actualWidth
                               height:(int32_t)actualHeight
                            frameRate:frameRate
                                error:&setupError]) {
            MRLog(@"❌ Failed to setup writer with actual dimensions: %@", setupError);
            self.isRecording = NO;
            return;
        }

        MRLog(@"✅ Writer configured with ACTUAL dimensions: %zux%zu", actualWidth, actualHeight);
    }

    if (!self.writerStarted) {
        if (self.assetWriter.status == AVAssetWriterStatusUnknown) {
            if ([self.assetWriter startWriting]) {
                [self.assetWriter startSessionAtSourceTime:kCMTimeZero];
                self.writerStarted = YES;
                self.firstSampleTime = timestamp;
                MRLog(@"✅ Camera writer started (zero-based timeline)");
            } else {
                MRLog(@"❌ CameraRecorder: Failed to start asset writer: %@", self.assetWriter.error);
                self.isRecording = NO;
                return;
            }
        }
    }

    if (!self.writerStarted || self.assetWriter.status != AVAssetWriterStatusWriting) {
        return;
    }

    if (!self.assetWriterInput.readyForMoreMediaData) {
        return;
    }

    if (CMTIME_IS_INVALID(self.firstSampleTime)) {
        self.firstSampleTime = timestamp;
    }

    CMTime baseline = kCMTimeInvalid;
    CMTime audioStart = MRSyncAudioFirstTimestamp();
    if (CMTIME_IS_VALID(audioStart)) {
        baseline = audioStart;
    } else if (CMTIME_IS_VALID(self.firstSampleTime)) {
        baseline = self.firstSampleTime;
    }

    CMTime relativeTimestamp = kCMTimeZero;
    if (CMTIME_IS_VALID(baseline)) {
        relativeTimestamp = CMTimeSubtract(timestamp, baseline);
        if (CMTIME_COMPARE_INLINE(relativeTimestamp, <, kCMTimeZero)) {
            relativeTimestamp = kCMTimeZero;
        }
    } else {
        relativeTimestamp = timestamp;
    }

    double stopLimit = MRSyncGetStopLimitSeconds();
    if (stopLimit > 0) {
        // Do NOT extend camera stop limit by audio start offset.
        // Using the same stopLimit as audio keeps durations aligned.
        double frameSeconds = CMTimeGetSeconds(relativeTimestamp);
        double tolerance = self.expectedFrameRate > 0 ? (1.5 / self.expectedFrameRate) : 0.02;
        if (tolerance < 0.02) {
            tolerance = 0.02;
        }
        if (frameSeconds > stopLimit + tolerance) {
            return;
        }
    }

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        return;
    }

    CVPixelBufferRetain(pixelBuffer);
    BOOL appended = [self.pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:relativeTimestamp];
    CVPixelBufferRelease(pixelBuffer);

    if (!appended) {
        MRLog(@"⚠️ CameraRecorder: Failed to append camera frame at time %.2f (status %ld)",
              CMTimeGetSeconds(relativeTimestamp), (long)self.assetWriter.status);
        if (self.assetWriter.status == AVAssetWriterStatusFailed) {
            MRLog(@"❌ CameraRecorder writer failure: %@", self.assetWriter.error);
            self.isRecording = NO;
        }
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection *)connection {
    if (!self.isRecording) {
        return;
    }

    if (!sampleBuffer) {
        return;
    }

    CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

    // If audio is expected but not yet flowing, hold video frames to keep timeline aligned.
    if (MRSyncShouldHoldVideoFrame(timestamp)) {
        [self enqueueSampleBuffer:sampleBuffer];
        if (CMTIME_IS_INVALID(self.firstSampleTime)) {
            self.firstSampleTime = timestamp;
        }
        return;
    }

    // Flush any buffered frames now that audio is ready
    [self flushPendingSampleBuffers];

    [self processSampleBufferReadyForWriting:sampleBuffer];
}
#endif  // End old buffer management code

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
    return [CameraRecorder sharedRecorder].outputPath;
}

}

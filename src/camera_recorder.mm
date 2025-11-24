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

@interface CameraRecorder : NSObject<AVCaptureFileOutputRecordingDelegate>

@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureDeviceInput *deviceInput;
@property (nonatomic, strong) AVCaptureMovieFileOutput *fileOutput;
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
        _startCompleted = YES;
        _startSucceeded = NO;
        _activeToken = 0;
        _unexpectedRestartAttempted = NO;
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
    self.fileOutput = nil;
    self.isRecording = NO;
    self.stopInFlight = NO;
    self.outputPath = nil;
    self.unexpectedRestartAttempted = NO;
    g_cameraStartTimestamp = 0.0;
}

- (BOOL)attemptRestartAfterUnexpectedStop {
    if (self.unexpectedRestartAttempted) {
        MRLog(@"⚠️ Camera already retried after unexpected stop; skipping restart");
        return NO;
    }
    self.unexpectedRestartAttempted = YES;

    if (!self.outputPath || [self.outputPath length] == 0) {
        MRLog(@"⚠️ Cannot restart camera: missing output path");
        return NO;
    }
    if (!self.session || !self.fileOutput) {
        MRLog(@"⚠️ Cannot restart camera: session/output unavailable");
        return NO;
    }

    if (![self.session isRunning]) {
        [self.session startRunning];
    }

    NSURL *outputURL = [NSURL fileURLWithPath:self.outputPath];
    if (!outputURL) {
        MRLog(@"⚠️ Cannot restart camera: invalid output URL");
        return NO;
    }

    // Move existing clip aside so we don't lose it if restart fails
    NSString *backupPath = [self.outputPath stringByAppendingPathExtension:@"bak"];
    [[NSFileManager defaultManager] removeItemAtPath:backupPath error:nil];
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.outputPath]) {
        [[NSFileManager defaultManager] moveItemAtPath:self.outputPath toPath:backupPath error:nil];
    }

    MRLog(@"🔁 Attempting automatic camera restart after unexpected stop");
    @try {
        self.stopInFlight = NO;
        self.isRecording = YES;
        g_cameraStartTimestamp = 0.0;
        [self.fileOutput startRecordingToOutputFileURL:outputURL recordingDelegate:self];
        // Remove backup since restart succeeded
        [[NSFileManager defaultManager] removeItemAtPath:backupPath error:nil];
        return YES;
    } @catch (NSException *exception) {
        MRLog(@"❌ Camera auto-restart failed: %@", exception.reason);
        // Restore previous clip if we created a backup
        if ([[NSFileManager defaultManager] fileExistsAtPath:backupPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:self.outputPath error:nil];
            [[NSFileManager defaultManager] moveItemAtPath:backupPath toPath:self.outputPath error:nil];
        }
        self.isRecording = NO;
        return NO;
    }
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

        AVCaptureMovieFileOutput *fileOutput = [[AVCaptureMovieFileOutput alloc] init];
        if (![session canAddOutput:fileOutput]) {
            MRLog(@"❌ Unable to add movie file output to capture session");
            [session commitConfiguration];
            [self completeStart:NO token:token];
            return;
        }
        [session addOutput:fileOutput];

        // Ensure the file output does not auto-stop due to implicit limits
        fileOutput.movieFragmentInterval = kCMTimeInvalid;
        fileOutput.maxRecordedDuration = kCMTimeInvalid;
        fileOutput.maxRecordedFileSize = 0;

        AVCaptureConnection *audioConnection = [fileOutput connectionWithMediaType:AVMediaTypeAudio];
        if (audioConnection) {
            audioConnection.enabled = NO;
        }

        AVCaptureConnection *videoConnection = [fileOutput connectionWithMediaType:AVMediaTypeVideo];
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
        self.fileOutput = fileOutput;
        self.outputPath = normalizedPath;

        [session startRunning];

        // Give session a brief moment to warm up to avoid false start timeouts on slower devices
        [NSThread sleepForTimeInterval:0.5];

        if (self.stopInFlight || token != self.activeToken) {
            [session stopRunning];
            [self completeStart:NO token:token];
            return;
        }

        NSURL *outputURL = [NSURL fileURLWithPath:normalizedPath];
        if (!outputURL) {
            MRLog(@"❌ Failed to create output URL for camera recording");
            [self completeStart:NO token:token];
            return;
        }

        MRLog(@"🎥 Starting camera recording to %@", normalizedPath);
        @try {
            [fileOutput startRecordingToOutputFileURL:outputURL recordingDelegate:self];
            MRLog(@"📤 Camera setup scheduled on background queue (non-blocking)");
        } @catch (NSException *exception) {
            MRLog(@"❌ Exception while starting camera recording: %@", exception.reason);
            [self completeStart:NO token:token];
            return;
        }
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
    BOOL outputRecording = (self.fileOutput && [self.fileOutput isRecording]);
    if (!self.isRecording && !hasActiveSession && !outputRecording) {
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
        if (self.fileOutput && [self.fileOutput isRecording]) {
            MRLog(@"🛑 Movie file output stop requested");
            [self.fileOutput stopRecording];
        } else {
            dispatch_semaphore_signal(stopSemaphore);
        }

        if (self.session && [self.session isRunning]) {
            [self.session stopRunning];
        }

        if (self.session && self.deviceInput && [self.session.inputs containsObject:self.deviceInput]) {
            [self.session removeInput:self.deviceInput];
        }
        if (self.session && self.fileOutput && [self.session.outputs containsObject:self.fileOutput]) {
            [self.session removeOutput:self.fileOutput];
        }

        if (!self.fileOutput || ![self.fileOutput isRecording]) {
            [self cleanupAfterStopOnQueue];
        }
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

#pragma mark - AVCaptureFileOutputRecordingDelegate

- (void)captureOutput:(AVCaptureFileOutput *)output
didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL
      fromConnections:(NSArray<AVCaptureConnection *> *)connections
                error:(NSError *)error {
    double elapsedTime = g_cameraStartTimestamp > 0 ? (CFAbsoluteTimeGetCurrent() - g_cameraStartTimestamp) : 0;
    MRLog(@"🎬 Camera recording finished (elapsed: %.2fs)", elapsedTime);
    if (error) {
        MRLog(@"❌ Camera recording finished with error: %@", error);
    } else {
        MRLog(@"✅ Camera recording finished successfully");
    }
    self.lastFinishedOutputPath = outputFileURL.path ?: self.outputPath;

    dispatch_semaphore_t stopSemaphore = self.stopSemaphore;
    BOOL expectedStop = self.stopInFlight || (stopSemaphore != nil);
    dispatch_async(self.workQueue, ^{
        if (!expectedStop) {
            BOOL restarted = [self attemptRestartAfterUnexpectedStop];
            if (restarted) {
                MRLog(@"🔁 Camera auto-restart initiated after unexpected stop");
                return;
            } else {
                MRLog(@"⚠️ Camera could not auto-restart after unexpected stop");
            }
        }

        [self cleanupAfterStopOnQueue];
        if (stopSemaphore) {
            dispatch_semaphore_signal(stopSemaphore);
        }
    });
}

- (void)captureOutput:(AVCaptureFileOutput *)output
didStartRecordingToOutputFileAtURL:(NSURL *)fileURL
      fromConnections:(NSArray<AVCaptureConnection *> *)connections {
    MRLog(@"✅ Camera file recording started: %@", fileURL.path);
    g_cameraStartTimestamp = CFAbsoluteTimeGetCurrent();
    [self completeStart:YES token:self.activeToken];
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

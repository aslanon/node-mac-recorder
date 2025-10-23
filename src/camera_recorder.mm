#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import "logging.h"

#ifndef AVVideoCodecTypeVP9
static AVVideoCodecType const AVVideoCodecTypeVP9 = @"vp09";
#endif

static BOOL MRAllowContinuityCamera() {
    static dispatch_once_t onceToken;
    static BOOL allowContinuity = NO;
    dispatch_once(&onceToken, ^{
        id continuityKey = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSCameraUseContinuityCameraDeviceType"];
        if ([continuityKey respondsToSelector:@selector(boolValue)] && [continuityKey boolValue]) {
            allowContinuity = YES;
        }
        if (!allowContinuity && getenv("ALLOW_CONTINUITY_CAMERA")) {
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

// Dedicated camera recorder used alongside screen capture
@interface CameraRecorder : NSObject<AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureDeviceInput *deviceInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *assetWriterInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *pixelBufferAdaptor;
@property (nonatomic, strong) dispatch_queue_t captureQueue;
@property (nonatomic, strong) NSString *outputPath;
@property (atomic, assign) BOOL isRecording;
@property (atomic, assign) BOOL writerStarted;
@property (atomic, assign) BOOL isShuttingDown;
@property (nonatomic, assign) CMTime firstSampleTime;
@property (nonatomic, assign) int32_t expectedWidth;
@property (nonatomic, assign) int32_t expectedHeight;
@property (nonatomic, assign) double expectedFrameRate;
@property (atomic, assign) BOOL needsReconfiguration;

+ (instancetype)sharedRecorder;
+ (NSArray<NSDictionary *> *)availableCameraDevices;
- (BOOL)startRecordingWithDeviceId:(NSString *)deviceId
                        outputPath:(NSString *)outputPath
                             error:(NSError **)error;
- (BOOL)stopRecording;

@end

@implementation CameraRecorder

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

    // Only add Continuity Camera type if allowed
    if (allowContinuity) {
        if (@available(macOS 14.0, *)) {
            [deviceTypes addObject:AVCaptureDeviceTypeContinuityCamera];
        }
    }

    AVCaptureDeviceDiscoverySession *discoverySession =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypes
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionUnspecified];

    for (AVCaptureDevice *device in discoverySession.devices) {
        BOOL continuityCamera = MRIsContinuityCamera(device);
        // ONLY skip Continuity cameras when permission is missing
        // Regular USB/external cameras should ALWAYS be listed
        if (continuityCamera && !allowContinuity) {
            MRLog(@"⏭️ Skipping Continuity Camera (permission required): %@", device.localizedName);
            continue;
        }
        
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
        
        NSDictionary *deviceInfo = @{
            @"id": device.uniqueID ?: @"",
            @"name": device.localizedName ?: @"Unknown Camera",
            @"model": device.modelID ?: @"",
            @"manufacturer": device.manufacturer ?: @"",
            @"position": position ?: @"unspecified",
            @"transportType": @(device.transportType),
            @"isConnected": @(device.isConnected),
            @"hasFlash": @(device.hasFlash),
            @"supportsDepth": @NO,
            @"deviceType": device.deviceType ?: @"",
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

- (void)resetState {
    self.writerStarted = NO;
    self.isRecording = NO;
    self.isShuttingDown = NO;
    self.firstSampleTime = kCMTimeInvalid;
    self.session = nil;
    self.deviceInput = nil;
    self.videoOutput = nil;
    self.assetWriter = nil;
    self.assetWriterInput = nil;
    self.pixelBufferAdaptor = nil;
    self.outputPath = nil;
    self.captureQueue = nil;
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

        // No filtering - use whatever the device supports
        // The device knows best what it can capture

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
        
        // Clamp desired frame rate within supported ranges
        double targetFrameRate = frameRate > 0 ? frameRate : 30.0;
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
    
    // Ensure camera permission
    __block BOOL cameraPermissionGranted = YES;
    AVAuthorizationStatus cameraStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (cameraStatus == AVAuthorizationStatusNotDetermined) {
        dispatch_semaphore_t permissionSemaphore = dispatch_semaphore_create(0);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            cameraPermissionGranted = granted;
            dispatch_semaphore_signal(permissionSemaphore);
        }];
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC));
        dispatch_semaphore_wait(permissionSemaphore, timeout);
    } else if (cameraStatus != AVAuthorizationStatusAuthorized) {
        cameraPermissionGranted = NO;
    }

    if (!cameraPermissionGranted) {
        if (error) {
            NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Camera permission not granted" };
            *error = [NSError errorWithDomain:@"CameraRecorder" code:-4 userInfo:userInfo];
        }
        return NO;
    }

    // Remove any stale file
    NSError *removeError = nil;
    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:&removeError];
    if (removeError && removeError.code != NSFileNoSuchFileError) {
        MRLog(@"⚠️ CameraRecorder: Failed to remove existing camera file: %@", removeError);
    }
    
    AVCaptureDevice *device = [self deviceForId:deviceId];
    if (!device) {
        if (error) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"No camera devices available"
            };
            *error = [NSError errorWithDomain:@"CameraRecorder" code:-3 userInfo:userInfo];
        }
        return NO;
    }

    if (MRIsContinuityCamera(device) && !MRAllowContinuityCamera()) {
        if (error) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"Continuity Camera requires NSCameraUseContinuityCameraDeviceType=true in Info.plist"
            };
            *error = [NSError errorWithDomain:@"CameraRecorder" code:-5 userInfo:userInfo];
        }
        MRLog(@"⚠️ Continuity Camera access denied - missing Info.plist entitlement");
        return NO;
    }
    
    int32_t width = 0;
    int32_t height = 0;
    double frameRate = 0.0;
    AVCaptureDeviceFormat *bestFormat = [self bestFormatForDevice:device widthOut:&width heightOut:&height frameRateOut:&frameRate];
    
    if (![self configureDevice:device withFormat:bestFormat frameRate:frameRate error:error]) {
        return NO;
    }
    
    self.session = [[AVCaptureSession alloc] init];
    
    self.deviceInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:error];
    if (!self.deviceInput) {
        [self resetState];
        return NO;
    }
    
    if ([self.session canAddInput:self.deviceInput]) {
        [self.session addInput:self.deviceInput];
    } else {
        if (error) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"Unable to add camera input to capture session"
            };
            *error = [NSError errorWithDomain:@"CameraRecorder" code:-6 userInfo:userInfo];
        }
        [self resetState];
        return NO;
    }
    
    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.videoOutput.alwaysDiscardsLateVideoFrames = NO;
    // Use video range (not full range) for better compatibility and quality
    // YpCbCr 4:2:0 biplanar is the native format for most cameras
    self.videoOutput.videoSettings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    };
    
    self.captureQueue = dispatch_queue_create("node_mac_recorder.camera.queue", DISPATCH_QUEUE_SERIAL);
    [self.videoOutput setSampleBufferDelegate:self queue:self.captureQueue];
    
    if ([self.session canAddOutput:self.videoOutput]) {
        [self.session addOutput:self.videoOutput];
    } else {
        if (error) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"Unable to add camera output to capture session"
            };
            *error = [NSError errorWithDomain:@"CameraRecorder" code:-7 userInfo:userInfo];
        }
        [self resetState];
        return NO;
    }
    
    AVCaptureConnection *connection = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
    if (connection) {
        // DON'T set orientation - let the camera use its natural orientation
        // The device knows best (portrait for phones, landscape for webcams)
        // We just capture whatever comes through

        // Mirror front cameras for natural preview
        if (connection.isVideoMirroringSupported && device.position == AVCaptureDevicePositionFront) {
            if ([connection respondsToSelector:@selector(setAutomaticallyAdjustsVideoMirroring:)]) {
                connection.automaticallyAdjustsVideoMirroring = NO;
            }
            connection.videoMirrored = YES;
        }

        // Log actual connection properties for debugging
        MRLog(@"📐 Camera connection: orientation=%ld (native), mirrored=%d, format=%dx%d",
              (long)connection.videoOrientation,
              connection.isVideoMirrored,
              width, height);
    }
    
    // DON'T setup writer yet - wait for first frame to get actual dimensions
    // Store configuration for lazy initialization
    self.outputPath = outputPath;
    self.isRecording = YES;
    self.isShuttingDown = NO;
    self.expectedWidth = width;
    self.expectedHeight = height;
    self.expectedFrameRate = frameRate;
    self.needsReconfiguration = NO;

    [self.session startRunning];

    MRLog(@"🎥 CameraRecorder started: %@ (will use actual frame dimensions)", device.localizedName);
    MRLog(@"   Format reports: %dx%d @ %.2ffps", width, height, frameRate);
    return YES;
}

- (BOOL)stopRecording {
    if (!self.isRecording) {
        return YES;
    }
    
    self.isShuttingDown = YES;
    self.isRecording = NO;
    
    @try {
        [self.session stopRunning];
    } @catch (NSException *exception) {
        MRLog(@"⚠️ CameraRecorder: Exception while stopping session: %@", exception.reason);
    }
    
    [self.videoOutput setSampleBufferDelegate:nil queue:nil];
    
    if (self.assetWriterInput) {
        [self.assetWriterInput markAsFinished];
    }
    
    __block BOOL finished = NO;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self.assetWriter finishWritingWithCompletionHandler:^{
        finished = YES;
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC));
    dispatch_semaphore_wait(semaphore, timeout);
    
    if (!finished) {
        MRLog(@"⚠️ CameraRecorder: Timed out waiting for writer to finish");
    }
    
    BOOL success = (self.assetWriter.status == AVAssetWriterStatusCompleted);
    if (!success) {
        MRLog(@"⚠️ CameraRecorder: Writer finished with status %ld error %@", (long)self.assetWriter.status, self.assetWriter.error);
    } else {
        MRLog(@"✅ CameraRecorder stopped successfully");
    }
    
    [self resetState];
    return success;
}

- (void)captureOutput:(AVCaptureOutput *)output
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection *)connection {
    if (!self.isRecording || self.isShuttingDown) {
        return;
    }

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

        // Use ACTUAL dimensions from the frame, not format dimensions
        NSURL *outputURL = [NSURL fileURLWithPath:self.outputPath];
        NSError *setupError = nil;

        // Use frame rate from device configuration
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
                [self.assetWriter startSessionAtSourceTime:timestamp];
                self.writerStarted = YES;
                self.firstSampleTime = timestamp;
                MRLog(@"✅ Camera writer started");
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
    
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        return;
    }
    
    CVPixelBufferRetain(pixelBuffer);
    BOOL appended = [self.pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:timestamp];
    CVPixelBufferRelease(pixelBuffer);
    
    if (!appended) {
        MRLog(@"⚠️ CameraRecorder: Failed to append camera frame at time %.2f (status %ld)",
              CMTimeGetSeconds(timestamp), (long)self.assetWriter.status);
        if (self.assetWriter.status == AVAssetWriterStatusFailed) {
            MRLog(@"❌ CameraRecorder writer failure: %@", self.assetWriter.error);
            self.isRecording = NO;
        }
    }
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

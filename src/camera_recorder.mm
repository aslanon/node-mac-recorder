#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import "logging.h"

#ifndef AVVideoCodecTypeVP9
static AVVideoCodecType const AVVideoCodecTypeVP9 = @"vp09";
#endif

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
    
    if ([deviceType isEqualToString:AVCaptureDeviceTypeExternal] && nameMentionsContinuity) {
        return YES;
    }
    
    if ([deviceType isEqualToString:AVCaptureDeviceTypeExternal] &&
        [manufacturer rangeOfString:@"Apple" options:NSCaseInsensitiveSearch].location != NSNotFound &&
        nameMentionsContinuity) {
        return YES;
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
    [deviceTypes addObject:AVCaptureDeviceTypeExternalUnknown];
    if (@available(macOS 10.15, *)) {
        [deviceTypes addObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
        if (@available(macOS 14.0, *)) {
            [deviceTypes addObject:AVCaptureDeviceTypeContinuityCamera];
        }
    } else {
        [deviceTypes addObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
    }
    
    AVCaptureDeviceDiscoverySession *discoverySession =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypes
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionUnspecified];
    
    for (AVCaptureDevice *device in discoverySession.devices) {
        BOOL continuityCamera = MRIsContinuityCamera(device);
        
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
    
    for (AVCaptureDeviceFormat *format in device.formats) {
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        if (dims.width <= 0 || dims.height <= 0) {
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
            CMTime frameDuration = CMTimeMake(1, (int32_t)round(clampedRate));
            device.activeVideoMinFrameDuration = frameDuration;
            device.activeVideoMaxFrameDuration = frameDuration;
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
    self.assetWriter = [[AVAssetWriter alloc] initWithURL:outputURL fileType:fileType error:&writerError];
    
    if (!self.assetWriter || writerError) {
        if (error) {
            *error = writerError;
        }
        return NO;
    }
    
    // On fallback, if WebM was requested but not supported, log and switch extension to .mov
    if (wantsWebM && !webMSupported) {
        MRLog(@"ℹ️ CameraRecorder: WebM unavailable, storing data in QuickTime container");
    }
    
    NSInteger bitrate = (NSInteger)(width * height * 6); // Empirical bitrate multiplier
    bitrate = MAX(bitrate, 5 * 1000 * 1000); // Minimum 5 Mbps
    
    NSMutableDictionary *compressionProps = [@{
        AVVideoAverageBitRateKey: @(bitrate),
        AVVideoMaxKeyFrameIntervalKey: @(MAX(1, (int)round(frameRate))),
        AVVideoAllowFrameReorderingKey: @YES
    } mutableCopy];
    
    if ([codec isEqualToString:AVVideoCodecTypeH264]) {
        compressionProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel;
    }
    
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: codec,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: compressionProps
    };
    
    // Video-only writer input (camera recordings remain silent by design)
    self.assetWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                               outputSettings:videoSettings];
    self.assetWriterInput.expectsMediaDataInRealTime = YES;
    
    NSDictionary *pixelBufferAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (NSString *)kCVPixelBufferWidthKey: @(width),
        (NSString *)kCVPixelBufferHeightKey: @(height)
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

    BOOL isContinuityCamera = MRIsContinuityCamera(device);
    if (isContinuityCamera) {
        id continuityKey = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSCameraUseContinuityCameraDeviceType"];
        BOOL allowContinuity = NO;
        if ([continuityKey respondsToSelector:@selector(boolValue)]) {
            allowContinuity = [continuityKey boolValue];
        }
        if (!allowContinuity && getenv("ALLOW_CONTINUITY_CAMERA")) {
            allowContinuity = YES;
        }
        if (!allowContinuity) {
            if (error) {
                NSDictionary *userInfo = @{
                    NSLocalizedDescriptionKey: @"Continuity Camera requires NSCameraUseContinuityCameraDeviceType=true in Info.plist"
                };
                *error = [NSError errorWithDomain:@"CameraRecorder" code:-5 userInfo:userInfo];
            }
            MRLog(@"⚠️ Continuity Camera access denied - missing Info.plist entitlement");
            return NO;
        }
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
    self.videoOutput.videoSettings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
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
        if (connection.isVideoOrientationSupported) {
            connection.videoOrientation = AVCaptureVideoOrientationLandscapeRight;
        }
        if (connection.isVideoMirroringSupported && device.position == AVCaptureDevicePositionFront) {
            connection.videoMirrored = YES;
        }
    }
    
    NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
    if (![self setupWriterWithURL:outputURL width:width height:height frameRate:frameRate error:error]) {
        [self.session stopRunning];
        [self resetState];
        return NO;
    }
    
    self.outputPath = outputPath;
    self.isRecording = YES;
    self.isShuttingDown = NO;
    
    [self.session startRunning];
    
    MRLog(@"🎥 CameraRecorder started: %@ (%dx%d @ %.2ffps)", device.localizedName, width, height, frameRate);
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
    if (!self.writerStarted) {
        if (self.assetWriter.status == AVAssetWriterStatusUnknown) {
            if ([self.assetWriter startWriting]) {
                [self.assetWriter startSessionAtSourceTime:timestamp];
                self.writerStarted = YES;
                self.firstSampleTime = timestamp;
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
    @autoreleasepool {
        return [CameraRecorder availableCameraDevices];
    }
}

bool startCameraRecording(NSString *outputPath, NSString *deviceId, NSError **error) {
    @autoreleasepool {
        return [[CameraRecorder sharedRecorder] startRecordingWithDeviceId:deviceId
                                                                outputPath:outputPath
                                                                     error:error];
    }
}

bool stopCameraRecording() {
    @autoreleasepool {
        return [[CameraRecorder sharedRecorder] stopRecording];
    }
}

bool isCameraRecording() {
    return [CameraRecorder sharedRecorder].isRecording;
}

}

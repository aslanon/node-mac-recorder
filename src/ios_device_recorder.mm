#import <napi.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMediaIO/CMIOHardware.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import "logging.h"
#import "sync_timeline.h"

extern "C" bool startCameraRecording(NSString *outputPath, NSString *deviceId, NSError **error);
extern "C" bool waitForCameraRecordingStart(double timeoutSeconds);
extern "C" bool stopCameraRecording(void);
extern "C" bool stopIOSDeviceRecording(void);
extern "C" bool isCameraRecording(void);
extern "C" bool startStandaloneAudioRecording(NSString *outputPath, NSString *preferredDeviceId, NSError **error);
extern "C" bool stopStandaloneAudioRecording(void);
extern "C" bool isStandaloneAudioRecording(void);
extern "C" bool pauseIOSDeviceRecording(void);
extern "C" bool resumeIOSDeviceRecording(void);

@interface MRIOSDeviceRecorder : NSObject <AVCaptureFileOutputRecordingDelegate, AVCaptureFileOutputDelegate>
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureDeviceInput *deviceInput;
@property(nonatomic, strong) AVCaptureMovieFileOutput *movieOutput;
@property(nonatomic, copy) NSString *outputPath;
@property(atomic) BOOL recording;
@property(atomic) BOOL startCompleted;
@property(atomic) BOOL finishCompleted;
@property(atomic) BOOL startRequested;
@property(atomic) BOOL stopRequested;
@property(atomic) BOOL segmentStartPending;
@property(atomic, strong) NSError *finishError;
@property(atomic) BOOL paused;
@property(atomic) BOOL segmentStartCompleted;
@property(atomic) BOOL segmentFinishCompleted;
@property(atomic, strong) NSError *segmentFinishError;
@property(nonatomic, strong) NSMutableArray<NSString *> *segmentPaths;
@property(nonatomic, copy) NSString *currentSegmentPath;
@property(nonatomic) NSUInteger nextSegmentIndex;
@property(nonatomic) BOOL segmentFailure;
@property(nonatomic, strong) NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *pauseRanges;
@property(nonatomic) NSTimeInterval pauseStartedAtSeconds;
@property(nonatomic) BOOL captureCamera;
@property(nonatomic) BOOL captureMicrophone;
@property(nonatomic, copy) NSString *cameraOutputPath;
@property(nonatomic, copy) NSString *audioOutputPath;
@property(atomic) CMTime primaryStartHostTime;
@property(atomic) CMTime stopHostTime;
@end

static BOOL MRIOSHasProducedMedia(MRIOSDeviceRecorder *recorder) {
    if (!recorder.movieOutput.isRecording) return NO;
    CMTime duration = recorder.movieOutput.recordedDuration;
    return CMTIME_IS_NUMERIC(duration) &&
        CMTIME_COMPARE_INLINE(duration, >, kCMTimeZero);
}

static NSError *MRIOSNoFramesError(void) {
    return [NSError errorWithDomain:@"MacRecorderIOS"
                               code:17
                           userInfo:@{
        NSLocalizedDescriptionKey:
            @"iPhone is connected but is not sending video. Unlock it, keep the screen awake, then try again."
    }];
}

static void MRIOSMarkSegmentStarted(MRIOSDeviceRecorder *recorder,
                                    BOOL confirmedByDelegate) {
    recorder.recording = YES;
    recorder.segmentStartCompleted = YES;
    if (!recorder.startCompleted) {
        recorder.startCompleted = YES;
    }
    if (!confirmedByDelegate) {
        MRLog(@"✅ iPhone capture start confirmed from recorded media progress");
    }
}

@implementation MRIOSDeviceRecorder

- (BOOL)captureOutputShouldProvideSampleAccurateRecordingStart:(AVCaptureOutput *)output {
    return YES;
}

- (void)captureOutput:(AVCaptureFileOutput *)output
        didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection *)connection {
    if (!self.segmentStartPending || !CMSampleBufferDataIsReady(sampleBuffer)) return;
    @synchronized (self) {
        if (!self.segmentStartPending || self.stopRequested) return;
        CMTime hostTime = MRSyncHostTimestamp(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer), self.session.masterClock);
        if (!CMTIME_IS_NUMERIC(hostTime)) return;
        self.segmentStartPending = NO;
        @try {
            // macOS guarantees that a start requested inside this delegate
            // includes this exact sample. The later didStart/progress signal
            // confirms success but must never redefine the media's origin.
            [output startRecordingToOutputFileURL:[NSURL fileURLWithPath:self.currentSegmentPath]
                               recordingDelegate:self];
            self.primaryStartHostTime = hostTime;
            MRSyncMarkPrimaryStarted(hostTime);
        } @catch (NSException *exception) {
            self.segmentFinishError = [NSError errorWithDomain:@"MacRecorderIOS" code:18
                userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"iPhone sample start failed"}];
            self.segmentFinishCompleted = YES;
        }
    }
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput
        didStartRecordingToOutputFileAtURL:(NSURL *)fileURL
        fromConnections:(NSArray<AVCaptureConnection *> *)connections {
    MRIOSMarkSegmentStarted(self, YES);
    MRLog(@"📱 iPhone capture segment started: %@", fileURL.path);
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput
        didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL
        fromConnections:(NSArray<AVCaptureConnection *> *)connections
        error:(NSError *)error {
    self.recording = NO;
    self.segmentFinishError = error;
    self.segmentFinishCompleted = YES;
    if (self.stopRequested) {
        self.finishError = error;
        self.finishCompleted = YES;
    }
    if (error) {
        NSNumber *successfullyFinished = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey];
        if (![successfullyFinished boolValue]) {
            self.segmentFailure = YES;
            MRLog(@"❌ iPhone capture segment finalize failed: %@ (domain=%@, code=%ld, reason=%@, userInfo=%@)",
                  error.localizedDescription,
                  error.domain,
                  (long)error.code,
                  error.localizedFailureReason ?: @"",
                  error.userInfo ?: @{});
            return;
        }
    }
    MRLog(@"✅ iPhone capture segment finalized: %@", outputFileURL.path);
}

@end

static MRIOSDeviceRecorder *g_iosRecorder = nil;

static void MREnableIOSScreenCaptureDevices(void) {
    // Reapply this process-level opt-in before every discovery. CoreMediaIO can
    // restart after a cable/session transition; dispatch_once would then leave
    // the replacement service without the flag and later scans would be empty.
    CMIOObjectPropertyAddress address = {
        kCMIOHardwarePropertyAllowScreenCaptureDevices,
        kCMIOObjectPropertyScopeGlobal,
        kCMIOObjectPropertyElementMain
    };
    UInt32 allow = 1;
    OSStatus status = CMIOObjectSetPropertyData(
        kCMIOObjectSystemObject,
        &address,
        0,
        NULL,
        sizeof(allow),
        &allow
    );
    if (status == noErr) {
        static dispatch_once_t successLogToken;
        dispatch_once(&successLogToken, ^{
            MRLog(@"✅ CoreMediaIO iPhone screen capture devices enabled");
        });
    } else {
        MRLog(@"❌ CoreMediaIO could not enable iPhone screen capture devices (OSStatus=%d)", (int)status);
    }
}

static NSArray<AVCaptureDevice *> *MRDiscoverIOSCaptureDevices(void) {
    NSMutableArray<AVCaptureDevice *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seenIds = [NSMutableSet set];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (AVCaptureDevice *device in [AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed]) {
        if (device.uniqueID.length == 0 || [seenIds containsObject:device.uniqueID]) continue;
        [seenIds addObject:device.uniqueID];
        [result addObject:device];
    }
#pragma clang diagnostic pop

    NSMutableArray<AVCaptureDeviceType> *deviceTypes = [NSMutableArray array];
    if (@available(macOS 10.15, *)) {
        [deviceTypes addObject:AVCaptureDeviceTypeExternalUnknown];
    }
    if (@available(macOS 14.0, *)) {
        [deviceTypes addObject:AVCaptureDeviceTypeExternal];
    }
    if (deviceTypes.count > 0) {
        AVCaptureDeviceDiscoverySession *discovery =
            [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypes
                                                                   mediaType:AVMediaTypeMuxed
                                                                    position:AVCaptureDevicePositionUnspecified];
        for (AVCaptureDevice *device in discovery.devices) {
            if (device.uniqueID.length == 0 || [seenIds containsObject:device.uniqueID]) continue;
            [seenIds addObject:device.uniqueID];
            [result addObject:device];
        }
    }
    return result;
}

static NSString *MRUSBStringProperty(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!value) return nil;
    NSString *result = nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        result = [NSString stringWithString:(NSString *)value];
    }
    CFRelease(value);
    return result;
}

static NSNumber *MRUSBNumberProperty(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!value) return nil;
    NSNumber *result = nil;
    if (CFGetTypeID(value) == CFNumberGetTypeID() ||
        CFGetTypeID(value) == CFBooleanGetTypeID()) {
        result = [NSNumber numberWithLongLong:[(NSNumber *)value longLongValue]];
    }
    CFRelease(value);
    return result;
}

static NSArray<NSDictionary *> *MRUSBConnectedIOSDevices(void) {
    NSMutableArray<NSDictionary *> *devices = [NSMutableArray array];
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    if (!matching) return devices;

    io_iterator_t iterator = IO_OBJECT_NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    kern_return_t status = IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator);
#pragma clang diagnostic pop
    if (status != KERN_SUCCESS || iterator == IO_OBJECT_NULL) return devices;

    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator))) {
        NSNumber *supportsIOS = MRUSBNumberProperty(service, CFSTR("SupportsIPhoneOS"));
        NSNumber *vendorId = MRUSBNumberProperty(service, CFSTR("idVendor"));
        if (supportsIOS.boolValue && vendorId.unsignedIntegerValue == 0x05ac) {
            NSString *name = MRUSBStringProperty(service, CFSTR("USB Product Name"));
            NSString *serial = MRUSBStringProperty(service, CFSTR("USB Serial Number"));
            if (serial.length == 0) {
                serial = MRUSBStringProperty(service, CFSTR("kUSBSerialNumberString"));
            }
            NSNumber *location = MRUSBNumberProperty(service, CFSTR("locationID"));
            NSString *identifier = serial.length > 0
                ? [NSString stringWithFormat:@"usb:%@", serial]
                : [NSString stringWithFormat:@"usb:%llu", location.unsignedLongLongValue];
            [devices addObject:@{
                @"id": identifier,
                @"name": name.length > 0 ? name : @"iPhone",
                @"manufacturer": @"Apple",
                @"model": @"",
                @"connected": @YES,
                @"suspended": @YES,
                @"captureReady": @NO,
                @"width": @0,
                @"height": @0,
                @"hasAudio": @YES,
                @"transport": @"usb"
            }];
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return devices;
}

static NSArray<AVCaptureDevice *> *MRIOSCaptureDevices(NSTimeInterval timeoutSeconds) {
    MREnableIOSScreenCaptureDevices();

    // CoreMediaIO publishes and resumes the USB screen device asynchronously.
    // Recording startup may wait briefly for that transition. Inventory scans
    // request an immediate snapshot so renderer monitoring never blocks the UI.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(0.0, timeoutSeconds)];
    NSArray<AVCaptureDevice *> *devices = nil;
    do {
        devices = MRDiscoverIOSCaptureDevices();
        BOOL hasActiveDevice = NO;
        for (AVCaptureDevice *device in devices) {
            if (device.isConnected && !device.isSuspended) {
                hasActiveDevice = YES;
                break;
            }
        }
        if (hasActiveDevice) break;
        if ([deadline timeIntervalSinceNow] <= 0) break;
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    } while ([deadline timeIntervalSinceNow] > 0);
    return devices ?: @[];
}

static AVCaptureDevice *MRIOSDeviceForId(NSString *deviceId) {
    NSArray<AVCaptureDevice *> *devices = MRIOSCaptureDevices(3.0);
    if (deviceId.length == 0) {
        for (AVCaptureDevice *device in devices) {
            if (device.isConnected && !device.isSuspended) return device;
        }
        return nil;
    }
    for (AVCaptureDevice *device in devices) {
        if ([device.uniqueID isEqualToString:deviceId] &&
            device.isConnected && !device.isSuspended) return device;
    }
    return nil;
}

static bool MRWaitForFlag(bool (^readFlag)(void), NSTimeInterval timeoutSeconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    while (!readFlag() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return readFlag();
}

static BOOL MRIOSFileOutputSucceeded(NSError *error) {
    if (!error) return YES;
    NSNumber *successfullyFinished = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey];
    return [successfullyFinished boolValue];
}

static NSTimeInterval MRIOSRecordedDurationSeconds(MRIOSDeviceRecorder *recorder, CMTime hostTime) {
    if (CMTIME_IS_NUMERIC(recorder.primaryStartHostTime)) {
        return MAX(0.0, CMTimeGetSeconds(CMTimeSubtract(hostTime, recorder.primaryStartHostTime)));
    }
    CMTime duration = recorder.movieOutput.recordedDuration;
    if (CMTIME_IS_NUMERIC(duration) &&
        CMTIME_COMPARE_INLINE(duration, >=, kCMTimeZero)) {
        return MAX(0.0, CMTimeGetSeconds(duration));
    }
    return 0.0;
}

static void MRIOSBeginPauseRange(MRIOSDeviceRecorder *recorder, CMTime hostTime) {
    recorder.pauseStartedAtSeconds = MRIOSRecordedDurationSeconds(recorder, hostTime);
    MRLog(@"⏸️ iPhone capture pause marker at %.3f seconds",
          recorder.pauseStartedAtSeconds);
}

static void MRIOSEndPauseRange(MRIOSDeviceRecorder *recorder, CMTime hostTime) {
    if (recorder.pauseStartedAtSeconds < 0.0) return;
    NSTimeInterval end = MRIOSRecordedDurationSeconds(recorder, hostTime);
    NSTimeInterval start = recorder.pauseStartedAtSeconds;
    recorder.pauseStartedAtSeconds = -1.0;
    if (end <= start) return;
    [recorder.pauseRanges addObject:@{
        @"start": @(start),
        @"end": @(end)
    }];
    MRLog(@"▶️ iPhone capture resume marker at %.3f seconds (trim %.3f seconds)",
          end, end - start);
}

static NSString *MRIOSNextSegmentPath(MRIOSDeviceRecorder *recorder) {
    NSUInteger segmentIndex = recorder.nextSegmentIndex;
    recorder.nextSegmentIndex += 1;
    // A single continuously captured iPhone movie does not need an intermediate
    // filename. More importantly, some CoreMediaIO muxed devices reject a
    // re-targeted AVCaptureMovieFileOutput URL even though the same session can
    // record to the original requested path (the pre-segmentation behavior).
    if (segmentIndex == 0) return recorder.outputPath;
    NSString *base = [recorder.outputPath stringByDeletingPathExtension];
    NSString *path = [NSString stringWithFormat:@"%@.iphone-part-%03lu.mov",
                      base, (unsigned long)segmentIndex];
    return path;
}

static BOOL MRIOSStartNextSegment(MRIOSDeviceRecorder *recorder, NSError **errorOut) {
    NSString *segmentPath = MRIOSNextSegmentPath(recorder);
    [[NSFileManager defaultManager] removeItemAtPath:segmentPath error:nil];
    recorder.currentSegmentPath = segmentPath;
    recorder.segmentStartCompleted = NO;
    recorder.segmentFinishCompleted = NO;
    recorder.segmentFinishError = nil;
    recorder.recording = NO;

    recorder.segmentStartPending = YES;
    // AVCaptureMovieFileOutput can begin writing before its delegate callback
    // is delivered. That callback may be queued behind Electron's synchronous
    // native call, so requiring only the callback creates a false timeout even
    // though real frames are already reaching the file. Recorded duration is
    // an independent, frame-backed confirmation and is safe to use as the
    // fallback start signal.
    BOOL startObserved = MRWaitForFlag(^bool{
        return recorder.segmentStartCompleted ||
            recorder.segmentFinishCompleted ||
            MRIOSHasProducedMedia(recorder);
    }, 10.0);
    if (!recorder.segmentStartCompleted &&
        !recorder.segmentFinishCompleted &&
        MRIOSHasProducedMedia(recorder)) {
        MRIOSMarkSegmentStarted(recorder, NO);
    }
    BOOL started = startObserved && recorder.segmentStartCompleted &&
        recorder.movieOutput.isRecording && !recorder.segmentFinishCompleted;
    if (!started) {
        CMTime duration = recorder.movieOutput.recordedDuration;
        double durationSeconds = CMTIME_IS_NUMERIC(duration)
            ? MAX(0.0, CMTimeGetSeconds(duration))
            : 0.0;
        MRLog(@"❌ iPhone segment start timed out (sessionRunning=%@, outputRecording=%@, mediaDuration=%.3f, suspended=%@, connections=%lu)",
              recorder.session.isRunning ? @"YES" : @"NO",
              recorder.movieOutput.isRecording ? @"YES" : @"NO",
              durationSeconds,
              recorder.deviceInput.device.isSuspended ? @"YES" : @"NO",
              (unsigned long)recorder.movieOutput.connections.count);
        if (errorOut) {
            BOOL connectedButNoFrames = recorder.session.isRunning &&
                (recorder.segmentStartPending || recorder.movieOutput.isRecording) && durationSeconds <= 0.0;
            *errorOut = recorder.segmentFinishError ?: (connectedButNoFrames
                ? MRIOSNoFramesError()
                : [NSError errorWithDomain:@"MacRecorderIOS"
                                      code:11
                                  userInfo:@{NSLocalizedDescriptionKey: @"Timed out waiting for an iPhone recording segment"}]);
        }
        return NO;
    }
    [recorder.segmentPaths addObject:segmentPath];
    return YES;
}

static BOOL MRIOSStopCurrentSegment(MRIOSDeviceRecorder *recorder) {
    @synchronized (recorder) {
        recorder.segmentStartPending = NO;
    }
    if (recorder.movieOutput.isRecording) [recorder.movieOutput stopRecording];
    if (recorder.segmentStartCompleted && !recorder.segmentFinishCompleted) {
        if (!MRWaitForFlag(^bool{ return recorder.segmentFinishCompleted; }, 20.0)) {
            MRLog(@"⚠️ iPhone segment is still finalizing");
            return NO;
        }
    }
    if (!recorder.segmentStartCompleted) return YES;
    BOOL exists = recorder.currentSegmentPath.length > 0 &&
        [[NSFileManager defaultManager] fileExistsAtPath:recorder.currentSegmentPath];
    return recorder.segmentFinishCompleted &&
        MRIOSFileOutputSucceeded(recorder.segmentFinishError) && exists;
}

static BOOL MRIOSAssembleSegments(MRIOSDeviceRecorder *recorder, NSError **errorOut) {
    NSArray<NSString *> *segments = recorder.segmentPaths ?: @[];
    if (segments.count == 0 || recorder.outputPath.length == 0) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"MacRecorderIOS"
                                            code:12
                                        userInfo:@{NSLocalizedDescriptionKey: @"No iPhone recording segments were produced"}];
        }
        return NO;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSDictionary<NSString *, NSNumber *> *> *pauseRanges = recorder.pauseRanges ?: @[];
    if (segments.count == 1 && pauseRanges.count == 0) {
        if ([segments.firstObject isEqualToString:recorder.outputPath]) {
            BOOL exists = [fileManager fileExistsAtPath:recorder.outputPath];
            if (exists) MRLog(@"✅ iPhone recording finalized in its destination path");
            return exists;
        }
        [fileManager removeItemAtPath:recorder.outputPath error:nil];
        BOOL moved = [fileManager moveItemAtPath:segments.firstObject
                                         toPath:recorder.outputPath
                                          error:errorOut];
        if (moved) MRLog(@"✅ iPhone recording finalized without a pause merge");
        return moved;
    }

    AVMutableComposition *composition = [AVMutableComposition composition];
    CMTime insertionTime = kCMTimeZero;
    for (NSUInteger segmentIndex = 0; segmentIndex < segments.count; segmentIndex++) {
        NSString *segmentPath = segments[segmentIndex];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:segmentPath]
                                                options:nil];
        CMTime duration = asset.duration;
        if (!CMTIME_IS_NUMERIC(duration) || CMTIME_COMPARE_INLINE(duration, <=, kCMTimeZero)) {
            if (errorOut) {
                *errorOut = [NSError errorWithDomain:@"MacRecorderIOS"
                                                code:13
                                            userInfo:@{NSLocalizedDescriptionKey: @"An iPhone recording segment has no playable duration"}];
            }
            return NO;
        }
        // New recordings always contain one continuously written iPhone movie.
        // Keeping AVCaptureMovieFileOutput alive across pause avoids re-arming
        // the fragile USB muxed compressor. Remove paused ranges here instead.
        if (segments.count == 1 && pauseRanges.count > 0) {
            NSTimeInterval assetDuration = CMTimeGetSeconds(duration);
            NSTimeInterval sourceCursor = 0.0;
            int32_t timeScale = duration.timescale > 0 ? duration.timescale : 600;
            for (NSDictionary<NSString *, NSNumber *> *range in pauseRanges) {
                NSTimeInterval pauseStart = MIN(assetDuration,
                    MAX(sourceCursor, range[@"start"].doubleValue));
                NSTimeInterval pauseEnd = MIN(assetDuration,
                    MAX(pauseStart, range[@"end"].doubleValue));
                if (pauseStart > sourceCursor) {
                    CMTime sourceStart = CMTimeMakeWithSeconds(sourceCursor, timeScale);
                    CMTime keptDuration = CMTimeMakeWithSeconds(pauseStart - sourceCursor, timeScale);
                    NSError *insertError = nil;
                    if (![composition insertTimeRange:CMTimeRangeMake(sourceStart, keptDuration)
                                              ofAsset:asset
                                               atTime:insertionTime
                                                error:&insertError]) {
                        if (errorOut) *errorOut = insertError;
                        return NO;
                    }
                    insertionTime = CMTimeAdd(insertionTime, keptDuration);
                }
                sourceCursor = MAX(sourceCursor, pauseEnd);
            }
            if (assetDuration > sourceCursor) {
                CMTime sourceStart = CMTimeMakeWithSeconds(sourceCursor, timeScale);
                CMTime keptDuration = CMTimeMakeWithSeconds(assetDuration - sourceCursor, timeScale);
                NSError *insertError = nil;
                if (![composition insertTimeRange:CMTimeRangeMake(sourceStart, keptDuration)
                                          ofAsset:asset
                                           atTime:insertionTime
                                            error:&insertError]) {
                    if (errorOut) *errorOut = insertError;
                    return NO;
                }
                insertionTime = CMTimeAdd(insertionTime, keptDuration);
            }
        } else {
            NSError *insertError = nil;
            if (![composition insertTimeRange:CMTimeRangeMake(kCMTimeZero, duration)
                                      ofAsset:asset
                                       atTime:insertionTime
                                        error:&insertError]) {
                if (errorOut) *errorOut = insertError;
                return NO;
            }
            insertionTime = CMTimeAdd(insertionTime, duration);
        }
    }
    if (CMTIME_COMPARE_INLINE(insertionTime, <=, kCMTimeZero)) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"MacRecorderIOS"
                                            code:16
                                        userInfo:@{NSLocalizedDescriptionKey: @"The iPhone recording contains no unpaused media"}];
        }
        return NO;
    }

    AVAssetExportSession *exporter = [[AVAssetExportSession alloc]
        initWithAsset:composition presetName:AVAssetExportPresetPassthrough];
    if (!exporter) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"MacRecorderIOS"
                                            code:14
                                        userInfo:@{NSLocalizedDescriptionKey: @"The iPhone recording segments could not be joined"}];
        }
        return NO;
    }
    NSString *assembledPath = [[recorder.outputPath stringByDeletingPathExtension]
        stringByAppendingString:@".iphone-assembled.mov"];
    [fileManager removeItemAtPath:assembledPath error:nil];
    exporter.outputURL = [NSURL fileURLWithPath:assembledPath];
    exporter.outputFileType = AVFileTypeQuickTimeMovie;
    exporter.shouldOptimizeForNetworkUse = NO;

    __block volatile BOOL exportFinished = NO;
    [exporter exportAsynchronouslyWithCompletionHandler:^{ exportFinished = YES; }];
    BOOL completedInTime = MRWaitForFlag(^bool{ return exportFinished; }, 60.0);
    if (!completedInTime) [exporter cancelExport];
    BOOL completed = completedInTime && exporter.status == AVAssetExportSessionStatusCompleted;
    NSError *exportError = [[exporter.error retain] autorelease];
    if (!completed && errorOut) {
        *errorOut = exportError ?: [NSError errorWithDomain:@"MacRecorderIOS"
                                                   code:15
                                               userInfo:@{NSLocalizedDescriptionKey: @"Timed out while joining iPhone recording segments"}];
    }
    [exporter release];
    if (!completed) {
        [fileManager removeItemAtPath:assembledPath error:nil];
        return NO;
    }

    [fileManager removeItemAtPath:recorder.outputPath error:nil];
    NSError *moveError = nil;
    if (![fileManager moveItemAtPath:assembledPath
                             toPath:recorder.outputPath
                              error:&moveError]) {
        if (errorOut) *errorOut = moveError;
        return NO;
    }

    for (NSString *segmentPath in segments) {
        if (![segmentPath isEqualToString:recorder.outputPath]) {
            [fileManager removeItemAtPath:segmentPath error:nil];
        }
    }
    if (pauseRanges.count > 0) {
        MRLog(@"✅ Removed %lu paused range(s) from the iPhone recording",
              (unsigned long)pauseRanges.count);
    } else {
        MRLog(@"✅ Joined %lu iPhone recording segments", (unsigned long)segments.count);
    }
    return YES;
}

extern "C" NSArray<NSDictionary *> *listIOSCaptureDevices(void) {
    NSMutableArray<NSDictionary *> *devices = [NSMutableArray array];
    // Device listing is called by the renderer's lightweight monitor. Return a
    // snapshot immediately; the start path still gets a bounded readiness wait.
    for (AVCaptureDevice *device in MRIOSCaptureDevices(0.0)) {
        CMVideoDimensions largest = {0, 0};
        for (AVCaptureDeviceFormat *format in device.formats) {
            CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            if ((int64_t)dimensions.width * dimensions.height >
                (int64_t)largest.width * largest.height) {
                largest = dimensions;
            }
        }
        [devices addObject:@{
            @"id": device.uniqueID ?: @"",
            @"name": device.localizedName ?: @"iPhone",
            @"manufacturer": device.manufacturer ?: @"Apple",
            @"model": device.modelID ?: @"",
            @"connected": @(device.isConnected),
            @"suspended": @(device.isSuspended),
            @"captureReady": @(!device.isSuspended && device.isConnected),
            @"width": @(largest.width),
            @"height": @(largest.height),
            @"hasAudio": @YES,
            @"transport": @"usb"
        }];
    }
    if (devices.count == 0) {
        [devices addObjectsFromArray:MRUSBConnectedIOSDevices()];
    }
    return devices;
}

extern "C" bool startIOSDeviceRecording(NSString *outputPath,
                                         NSString *deviceId,
                                         BOOL captureCamera,
                                         NSString *cameraOutputPath,
                                         NSString *cameraDeviceId,
                                         BOOL captureMicrophone,
                                         NSString *audioOutputPath,
                                         NSString *audioDeviceId,
                                         NSError **errorOut) {
    @try {
        if (g_iosRecorder) {
            if (errorOut) {
                *errorOut = [NSError errorWithDomain:@"MacRecorderIOS"
                                                code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"An iPhone recording is already active"}];
            }
            return false;
        }

        AVCaptureDevice *device = MRIOSDeviceForId(deviceId);
        if (!device) {
            if (errorOut) {
                *errorOut = [NSError errorWithDomain:@"MacRecorderIOS"
                                                code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"No trusted USB iPhone capture device was found"}];
            }
            return false;
        }

        NSError *directoryError = nil;
        NSString *directory = [outputPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directoryError];
        if (directoryError) {
            if (errorOut) *errorOut = directoryError;
            return false;
        }
        [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
        if (captureCamera && cameraOutputPath.length > 0) {
            [[NSFileManager defaultManager] removeItemAtPath:cameraOutputPath error:nil];
        }
        if (captureMicrophone && audioOutputPath.length > 0) {
            [[NSFileManager defaultManager] removeItemAtPath:audioOutputPath error:nil];
        }

        NSError *inputError = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device
                                                                            error:&inputError];
        if (!input) {
            if (errorOut) *errorOut = inputError;
            return false;
        }

        MRIOSDeviceRecorder *recorder = [[MRIOSDeviceRecorder alloc] init];
        recorder.session = [[AVCaptureSession alloc] init];
        recorder.deviceInput = input;
        recorder.movieOutput = [[AVCaptureMovieFileOutput alloc] init];
        recorder.outputPath = outputPath;
        recorder.recording = NO;
        recorder.startCompleted = NO;
        recorder.finishCompleted = NO;
        recorder.finishError = nil;
        recorder.paused = NO;
        recorder.segmentStartCompleted = NO;
        recorder.segmentFinishCompleted = NO;
        recorder.segmentFinishError = nil;
        recorder.segmentPaths = [NSMutableArray array];
        recorder.currentSegmentPath = nil;
        recorder.nextSegmentIndex = 0;
        recorder.segmentFailure = NO;
        recorder.pauseRanges = [NSMutableArray array];
        recorder.pauseStartedAtSeconds = -1.0;
        recorder.captureCamera = captureCamera;
        recorder.captureMicrophone = captureMicrophone;
        recorder.cameraOutputPath = cameraOutputPath;
        recorder.audioOutputPath = audioOutputPath;
        recorder.primaryStartHostTime = kCMTimeInvalid;
        recorder.stopHostTime = kCMTimeInvalid;
        recorder.movieOutput.delegate = recorder;

        g_iosRecorder = recorder;
        [recorder.session beginConfiguration];
        if ([recorder.session canSetSessionPreset:AVCaptureSessionPresetHigh]) {
            recorder.session.sessionPreset = AVCaptureSessionPresetHigh;
        }
        if (![recorder.session canAddInput:input]) {
            [recorder.session commitConfiguration];
            stopIOSDeviceRecording();
            if (errorOut) {
                *errorOut = [NSError errorWithDomain:@"MacRecorderIOS"
                                                code:3
                                            userInfo:@{NSLocalizedDescriptionKey: @"The iPhone capture input could not be attached"}];
            }
            return false;
        }
        [recorder.session addInput:input];
        if (![recorder.session canAddOutput:recorder.movieOutput]) {
            [recorder.session commitConfiguration];
            stopIOSDeviceRecording();
            if (errorOut) {
                *errorOut = [NSError errorWithDomain:@"MacRecorderIOS"
                                                code:4
                                            userInfo:@{NSLocalizedDescriptionKey: @"The iPhone movie output could not be attached"}];
            }
            return false;
        }
        [recorder.session addOutput:recorder.movieOutput];
        [recorder.session commitConfiguration];

        // Frequent movie fragments keep long recordings recoverable if the cable
        // disconnects or the app exits before the final movie atom is written.
        recorder.movieOutput.movieFragmentInterval = CMTimeMakeWithSeconds(2.0, 600);
        g_iosRecorder = recorder;

        // Use the sample-accurate USB origin for every file, including a camera
        // or microphone whose first callback arrives later.
        MRSyncConfigure(captureMicrophone);
        MRSyncConfigureCamera(captureCamera);
        MRSyncConfigurePrimaryStart(YES);

        if (captureCamera) {
            NSError *cameraError = nil;
            if (cameraOutputPath.length == 0 ||
                !startCameraRecording(cameraOutputPath, cameraDeviceId, &cameraError)) {
                MRSyncConfigurePrimaryStart(NO);
                MRSyncConfigure(NO);
                stopIOSDeviceRecording();
                if (errorOut) {
                    *errorOut = cameraError ?: [NSError errorWithDomain:@"MacRecorderIOS"
                                                                    code:7
                                                                userInfo:@{NSLocalizedDescriptionKey: @"The selected camera could not be started"}];
                }
                return false;
            }
        }

        if (captureMicrophone) {
            NSError *audioError = nil;
            if (audioOutputPath.length == 0 ||
                !startStandaloneAudioRecording(audioOutputPath, audioDeviceId, &audioError)) {
                if (isCameraRecording()) stopCameraRecording();
                MRSyncConfigurePrimaryStart(NO);
                MRSyncConfigure(NO);
                stopIOSDeviceRecording();
                if (errorOut) {
                    *errorOut = audioError ?: [NSError errorWithDomain:@"MacRecorderIOS"
                                                                  code:8
                                                              userInfo:@{NSLocalizedDescriptionKey: @"The selected microphone could not be started"}];
                }
                return false;
            }
        }

        [recorder.session startRunning];
        if (!recorder.session.isRunning) {
            if (isCameraRecording()) stopCameraRecording();
            if (isStandaloneAudioRecording()) stopStandaloneAudioRecording();
            MRSyncConfigurePrimaryStart(NO);
            MRSyncConfigure(NO);
            if (errorOut) {
                *errorOut = [NSError errorWithDomain:@"MacRecorderIOS"
                                                code:5
                                            userInfo:@{NSLocalizedDescriptionKey: @"The iPhone capture session did not start"}];
            }
            stopIOSDeviceRecording();
            return false;
        }

        recorder.startRequested = YES;
        NSError *segmentError = nil;
        if (!MRIOSStartNextSegment(recorder, &segmentError)) {
            NSError *reportedSegmentError = [[segmentError retain] autorelease];
            MRIOSStopCurrentSegment(recorder);
            [recorder.session stopRunning];
            if (isCameraRecording()) stopCameraRecording();
            if (isStandaloneAudioRecording()) stopStandaloneAudioRecording();
            MRSyncConfigurePrimaryStart(NO);
            MRSyncConfigure(NO);
            stopIOSDeviceRecording();
            if (errorOut) {
                *errorOut = reportedSegmentError ?: [NSError errorWithDomain:@"MacRecorderIOS"
                                                                         code:6
                                                                     userInfo:@{NSLocalizedDescriptionKey: @"Timed out waiting for the first iPhone frame"}];
            }
            return false;
        }
        if (captureCamera && !waitForCameraRecordingStart(8.0)) {
            MRLog(@"❌ Camera did not produce a synchronized frame for iPhone recording");
            MRIOSStopCurrentSegment(recorder);
            [recorder.session stopRunning];
            if (isCameraRecording()) stopCameraRecording();
            if (isStandaloneAudioRecording()) stopStandaloneAudioRecording();
            MRSyncConfigurePrimaryStart(NO);
            MRSyncConfigure(NO);
            stopIOSDeviceRecording();
            if (errorOut) {
                *errorOut = [NSError errorWithDomain:@"MacRecorderIOS"
                                                code:9
                                            userInfo:@{NSLocalizedDescriptionKey: @"Timed out waiting for the selected camera"}];
            }
            return false;
        }
        return true;
    } @catch (NSException *exception) {
        // NSError must live in the caller's autorelease pool. The previous
        // inner pool returned a dangling NSError on device/startup failures.
        if (g_iosRecorder && !g_iosRecorder.startCompleted && !g_iosRecorder.movieOutput.isRecording) {
            g_iosRecorder.startRequested = NO;
        }
        @try { [g_iosRecorder.session commitConfiguration]; } @catch (NSException *ignored) {}
        stopIOSDeviceRecording();
        if (errorOut) *errorOut = [NSError errorWithDomain:@"MacRecorderIOS" code:10
            userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"iPhone capture startup failed"}];
        return false;
    }
}

extern "C" bool stopIOSDeviceRecording(void) {
    @autoreleasepool {
      @try {
        MRIOSDeviceRecorder *recorder = g_iosRecorder;
        if (!recorder) return true;

        CMTime stopHostTime;
        @synchronized (recorder) {
            if (!CMTIME_IS_NUMERIC(recorder.stopHostTime)) {
                recorder.stopHostTime = CMClockGetTime(CMClockGetHostTimeClock());
            }
            stopHostTime = recorder.stopHostTime;
            recorder.stopRequested = YES;
            recorder.segmentStartPending = NO;
        }
        // Request the USB stop before waiting for either auxiliary writer.
        // Do not hold the delegate lock across an AVFoundation stop call.
        if (recorder.movieOutput.isRecording) [recorder.movieOutput stopRecording];
        if (recorder.paused) {
            MRIOSEndPauseRange(recorder, stopHostTime);
            MRSyncResumeAtHostTime(stopHostTime);
        }
        CMTime mediaStopTime = MRSyncPrimaryMediaTime(stopHostTime);
        if (CMTIME_IS_NUMERIC(mediaStopTime)) MRSyncSetStopLimitSeconds(CMTimeGetSeconds(mediaStopTime));

        BOOL cameraStopped = YES;
        BOOL microphoneStopped = YES;
        if (recorder.captureCamera) {
            cameraStopped = stopCameraRecording();
        }
        if (recorder.captureMicrophone) {
            microphoneStopped = stopStandaloneAudioRecording();
        }

        BOOL primaryStopped = MRIOSStopCurrentSegment(recorder);
        if (!primaryStopped && recorder.segmentStartCompleted &&
            !recorder.segmentFinishCompleted) {
            // Keep ownership while AVCaptureMovieFileOutput still owns the
            // segment so a later stop retry cannot race its delegate callback.
            NSLog(@"[Recorder] iPhone is still finalizing; retaining the session");
            return false;
        }
        if (recorder.session.isRunning) [recorder.session stopRunning];

        NSError *assemblyError = nil;
        BOOL recordingSucceeded = primaryStopped && !recorder.segmentFailure;
        BOOL assembled = recordingSucceeded && MRIOSAssembleSegments(recorder, &assemblyError);
        if (!assembled && recorder.startCompleted) {
            MRLog(@"❌ iPhone recording assembly failed: %@",
                  assemblyError.localizedDescription ?: @"Unknown segment error");
        }
        BOOL finished = !recorder.startCompleted || assembled;
        BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:recorder.outputPath];
        MRSyncConfigurePrimaryStart(NO);
        MRSyncConfigure(NO);

        // AVCaptureSession keeps its input (and therefore the USB screen
        // device) retained after stopRunning. Detach everything before dropping
        // the recorder so the same iPhone is discoverable on the next attempt.
        @try {
            [recorder.session beginConfiguration];
            if (recorder.movieOutput && [recorder.session.outputs containsObject:recorder.movieOutput]) {
                [recorder.session removeOutput:recorder.movieOutput];
            }
            if (recorder.deviceInput && [recorder.session.inputs containsObject:recorder.deviceInput]) {
                [recorder.session removeInput:recorder.deviceInput];
            }
            [recorder.session commitConfiguration];
        } @catch (NSException *exception) {
            MRLog(@"⚠️ iPhone capture teardown warning: %@", exception.reason);
        }
        recorder.movieOutput.delegate = nil;
        recorder.movieOutput = nil;
        recorder.deviceInput = nil;
        recorder.session = nil;
        recorder.finishError = nil;
        recorder.segmentFinishError = nil;
        recorder.segmentPaths = nil;
        recorder.pauseRanges = nil;
        recorder.pauseStartedAtSeconds = -1.0;
        recorder.currentSegmentPath = nil;
        recorder.outputPath = nil;
        recorder.cameraOutputPath = nil;
        recorder.audioOutputPath = nil;
        recorder.primaryStartHostTime = kCMTimeInvalid;
        g_iosRecorder = nil;
        [recorder release];

        if (!recordingSucceeded) return false;
        if (!cameraStopped || !microphoneStopped) {
            MRLog(@"⚠️ iPhone recording finalized, but an auxiliary camera/microphone writer reported a stop error");
        }
        // Never discard a valid phone screen recording because an optional
        // auxiliary source failed to finalize. The JS layer validates each
        // returned path independently before packaging it.
        return finished && fileExists;
      } @catch (NSException *exception) {
        NSLog(@"[Recorder] iPhone stop failed safely: %@", exception.reason);
        return false;
      }
    }
}

extern "C" bool isIOSDeviceRecordingPending(void) {
    return g_iosRecorder != nil;
}

extern "C" bool isIOSDeviceRecordingStopping(void) {
    return g_iosRecorder && g_iosRecorder.stopRequested;
}

extern "C" bool isIOSDeviceRecording(void) {
    return g_iosRecorder && !g_iosRecorder.stopRequested &&
        (g_iosRecorder.recording || g_iosRecorder.paused || g_iosRecorder.movieOutput.isRecording);
}

extern "C" bool pauseIOSDeviceRecording(void) {
    @autoreleasepool {
        MRIOSDeviceRecorder *recorder = g_iosRecorder;
        if (!recorder) return false;
        if (recorder.paused) return true;
        if (!recorder.movieOutput.isRecording) return false;
        @try {
            // Do not stop or pause AVCaptureMovieFileOutput here. USB iPhone
            // muxed sources may fail to re-arm their compressor on resume.
            // Capture continuously and trim this time range during finalization.
            CMTime pauseHostTime = CMClockGetTime(CMClockGetHostTimeClock());
            MRIOSBeginPauseRange(recorder, pauseHostTime);
            MRSyncPauseAtHostTime(pauseHostTime);
            recorder.paused = YES;
            return true;
        } @catch (NSException *exception) {
            MRSyncResumeAtHostTime(CMClockGetTime(CMClockGetHostTimeClock()));
            MRLog(@"❌ iPhone pause failed: %@", exception.reason);
            return false;
        }
    }
}

extern "C" bool resumeIOSDeviceRecording(void) {
    @autoreleasepool {
        MRIOSDeviceRecorder *recorder = g_iosRecorder;
        if (!recorder) return false;
        if (!recorder.paused) return recorder.movieOutput.isRecording;
        if (!recorder.movieOutput.isRecording) return false;
        @try {
            CMTime resumeHostTime = CMClockGetTime(CMClockGetHostTimeClock());
            MRIOSEndPauseRange(recorder, resumeHostTime);
            recorder.paused = NO;
            MRSyncResumeAtHostTime(resumeHostTime);
            return true;
        } @catch (NSException *exception) {
            MRLog(@"❌ iPhone resume failed: %@", exception.reason);
            return false;
        }
    }
}

extern "C" NSString *currentIOSDeviceRecordingPath(void) {
    return g_iosRecorder.outputPath;
}

Napi::Value GetIOSCaptureDevices(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    @autoreleasepool {
      @try {
    NSArray<NSDictionary *> *devices = listIOSCaptureDevices();
    Napi::Array result = Napi::Array::New(env, devices.count);
    for (NSUInteger index = 0; index < devices.count; index++) {
        NSDictionary *device = devices[index];
        Napi::Object item = Napi::Object::New(env);
        item.Set("id", Napi::String::New(env, [device[@"id"] UTF8String]));
        item.Set("name", Napi::String::New(env, [device[@"name"] UTF8String]));
        item.Set("manufacturer", Napi::String::New(env, [device[@"manufacturer"] UTF8String]));
        item.Set("model", Napi::String::New(env, [device[@"model"] UTF8String]));
        item.Set("connected", Napi::Boolean::New(env, [device[@"connected"] boolValue]));
        item.Set("suspended", Napi::Boolean::New(env, [device[@"suspended"] boolValue]));
        item.Set("captureReady", Napi::Boolean::New(env, [device[@"captureReady"] boolValue]));
        item.Set("width", Napi::Number::New(env, [device[@"width"] intValue]));
        item.Set("height", Napi::Number::New(env, [device[@"height"] intValue]));
        item.Set("hasAudio", Napi::Boolean::New(env, true));
        item.Set("transport", Napi::String::New(env, "usb"));
        result.Set(index, item);
    }
    return result;
      } @catch (NSException *exception) {
        Napi::Error::New(env, exception.reason.UTF8String ?: "iPhone capture failed").ThrowAsJavaScriptException();
        return env.Null();
      }
    }

}

Napi::Value StartIOSDeviceRecording(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    @autoreleasepool {
      @try {
    if (info.Length() < 1 || !info[0].IsString()) {
        Napi::TypeError::New(env, "Output path is required").ThrowAsJavaScriptException();
        return env.Null();
    }
    NSString *outputPath = [NSString stringWithUTF8String:info[0].As<Napi::String>().Utf8Value().c_str()];
    NSString *deviceId = nil;
    if (info.Length() > 1 && info[1].IsString()) {
        deviceId = [NSString stringWithUTF8String:info[1].As<Napi::String>().Utf8Value().c_str()];
    }
    BOOL captureCamera = NO;
    BOOL captureMicrophone = NO;
    NSString *cameraOutputPath = nil;
    NSString *cameraDeviceId = nil;
    NSString *audioOutputPath = nil;
    NSString *audioDeviceId = nil;
    if (info.Length() > 2 && info[2].IsObject()) {
        Napi::Object options = info[2].As<Napi::Object>();
        auto readBool = [&](const char *key) -> BOOL {
            Napi::Value value = options.Get(key);
            return value.IsBoolean() && value.As<Napi::Boolean>().Value();
        };
        auto readString = [&](const char *key) -> NSString * {
            Napi::Value value = options.Get(key);
            if (!value.IsString()) return nil;
            std::string text = value.As<Napi::String>().Utf8Value();
            return text.empty() ? nil : [NSString stringWithUTF8String:text.c_str()];
        };
        captureCamera = readBool("captureCamera");
        captureMicrophone = readBool("includeMicrophone");
        cameraOutputPath = readString("cameraOutputPath");
        cameraDeviceId = readString("cameraDeviceId");
        audioOutputPath = readString("audioOutputPath");
        audioDeviceId = readString("audioDeviceId");
    }
    NSError *error = nil;
    bool success = startIOSDeviceRecording(outputPath,
                                           deviceId,
                                           captureCamera,
                                           cameraOutputPath,
                                           cameraDeviceId,
                                           captureMicrophone,
                                           audioOutputPath,
                                           audioDeviceId,
                                           &error);
    if (!success && error) {
        Napi::Error::New(env, error.localizedDescription.UTF8String ?: "iPhone capture could not start").ThrowAsJavaScriptException();
        return env.Null();
    }
    return Napi::Boolean::New(env, success);
      } @catch (NSException *exception) {
        Napi::Error::New(env, exception.reason.UTF8String ?: "iPhone capture failed").ThrowAsJavaScriptException();
        return env.Null();
      }
    }

}

Napi::Value StopIOSDeviceRecording(const Napi::CallbackInfo& info) {
    return Napi::Boolean::New(info.Env(), stopIOSDeviceRecording());
}

Napi::Value PauseIOSDeviceRecording(const Napi::CallbackInfo& info) {
    return Napi::Boolean::New(info.Env(), pauseIOSDeviceRecording());
}

Napi::Value ResumeIOSDeviceRecording(const Napi::CallbackInfo& info) {
    return Napi::Boolean::New(info.Env(), resumeIOSDeviceRecording());
}

Napi::Value GetIOSDeviceRecordingStatus(const Napi::CallbackInfo& info) {
    Napi::Object status = Napi::Object::New(info.Env());
    status.Set("isRecording", Napi::Boolean::New(info.Env(), isIOSDeviceRecording()));
    status.Set("isPaused", Napi::Boolean::New(info.Env(),
        g_iosRecorder && g_iosRecorder.paused));
    NSString *path = currentIOSDeviceRecordingPath();
    if (path.length > 0) status.Set("outputPath", Napi::String::New(info.Env(), [path UTF8String]));
    return status;
}

Napi::Object InitIOSDeviceRecorder(Napi::Env env, Napi::Object exports) {
    exports.Set("getIOSCaptureDevices", Napi::Function::New(env, GetIOSCaptureDevices));
    exports.Set("startIOSDeviceRecording", Napi::Function::New(env, StartIOSDeviceRecording));
    exports.Set("stopIOSDeviceRecording", Napi::Function::New(env, StopIOSDeviceRecording));
    exports.Set("pauseIOSDeviceRecording", Napi::Function::New(env, PauseIOSDeviceRecording));
    exports.Set("resumeIOSDeviceRecording", Napi::Function::New(env, ResumeIOSDeviceRecording));
    exports.Set("getIOSDeviceRecordingStatus", Napi::Function::New(env, GetIOSDeviceRecordingStatus));
    return exports;
}

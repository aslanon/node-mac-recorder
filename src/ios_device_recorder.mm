#import <napi.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMediaIO/CMIOHardware.h>
#import <Foundation/Foundation.h>
#import "logging.h"
#import "sync_timeline.h"

extern "C" bool startCameraRecording(NSString *outputPath, NSString *deviceId, NSError **error);
extern "C" bool waitForCameraRecordingStart(double timeoutSeconds);
extern "C" bool stopCameraRecording(void);
extern "C" bool isCameraRecording(void);
extern "C" bool startStandaloneAudioRecording(NSString *outputPath, NSString *preferredDeviceId, NSError **error);
extern "C" bool stopStandaloneAudioRecording(void);
extern "C" bool isStandaloneAudioRecording(void);

@interface MRIOSDeviceRecorder : NSObject <AVCaptureFileOutputRecordingDelegate>
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureDeviceInput *deviceInput;
@property(nonatomic, strong) AVCaptureMovieFileOutput *movieOutput;
@property(nonatomic, copy) NSString *outputPath;
@property(atomic) BOOL recording;
@property(atomic) BOOL startCompleted;
@property(atomic) BOOL finishCompleted;
@property(atomic, strong) NSError *finishError;
@property(nonatomic) BOOL captureCamera;
@property(nonatomic) BOOL captureMicrophone;
@property(nonatomic, copy) NSString *cameraOutputPath;
@property(nonatomic, copy) NSString *audioOutputPath;
@property(nonatomic, strong) NSDate *primaryStartedAt;
@end

@implementation MRIOSDeviceRecorder

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput
        didStartRecordingToOutputFileAtURL:(NSURL *)fileURL
        fromConnections:(NSArray<AVCaptureConnection *> *)connections {
    self.recording = YES;
    self.startCompleted = YES;
    self.primaryStartedAt = [NSDate date];
    MRSyncMarkPrimaryStarted(CMClockGetTime(CMClockGetHostTimeClock()));
    MRLog(@"📱 iPhone capture started: %@", fileURL.path);
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput
        didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL
        fromConnections:(NSArray<AVCaptureConnection *> *)connections
        error:(NSError *)error {
    self.recording = NO;
    self.finishError = error;
    self.finishCompleted = YES;
    if (error) {
        NSNumber *successfullyFinished = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey];
        if (![successfullyFinished boolValue]) {
            MRLog(@"❌ iPhone capture finalize failed: %@", error.localizedDescription);
            return;
        }
    }
    MRLog(@"✅ iPhone capture finalized: %@", outputFileURL.path);
}

@end

static MRIOSDeviceRecorder *g_iosRecorder = nil;

static void MREnableIOSScreenCaptureDevices(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
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
            MRLog(@"✅ CoreMediaIO iPhone screen capture devices enabled");
        } else {
            MRLog(@"❌ CoreMediaIO could not enable iPhone screen capture devices (OSStatus=%d)", (int)status);
        }
    });
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

static NSArray<AVCaptureDevice *> *MRIOSCaptureDevices(void) {
    MREnableIOSScreenCaptureDevices();

    // CoreMediaIO publishes the USB screen device asynchronously after the
    // allow flag changes. Poll briefly so the first click works without asking
    // the user to close and reopen the recorder.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    NSArray<AVCaptureDevice *> *devices = nil;
    do {
        devices = MRDiscoverIOSCaptureDevices();
        if (devices.count > 0) break;
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    } while ([deadline timeIntervalSinceNow] > 0);
    return devices ?: @[];
}

static AVCaptureDevice *MRIOSDeviceForId(NSString *deviceId) {
    NSArray<AVCaptureDevice *> *devices = MRIOSCaptureDevices();
    if (deviceId.length == 0) return devices.firstObject;
    for (AVCaptureDevice *device in devices) {
        if ([device.uniqueID isEqualToString:deviceId]) return device;
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

extern "C" NSArray<NSDictionary *> *listIOSCaptureDevices(void) {
    NSMutableArray<NSDictionary *> *devices = [NSMutableArray array];
    for (AVCaptureDevice *device in MRIOSCaptureDevices()) {
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
            @"width": @(largest.width),
            @"height": @(largest.height),
            @"hasAudio": @YES,
            @"transport": @"usb"
        }];
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
    @autoreleasepool {
        if (g_iosRecorder && (g_iosRecorder.recording || g_iosRecorder.startCompleted)) {
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
        recorder.captureCamera = captureCamera;
        recorder.captureMicrophone = captureMicrophone;
        recorder.cameraOutputPath = cameraOutputPath;
        recorder.audioOutputPath = audioOutputPath;
        recorder.primaryStartedAt = nil;

        [recorder.session beginConfiguration];
        if ([recorder.session canSetSessionPreset:AVCaptureSessionPresetHigh]) {
            recorder.session.sessionPreset = AVCaptureSessionPresetHigh;
        }
        if (![recorder.session canAddInput:input]) {
            [recorder.session commitConfiguration];
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

        // Camera and microphone sessions are prepared first but discard their
        // warm-up samples until AVCaptureMovieFileOutput confirms the iPhone's
        // first frame. Every produced file therefore starts at the same t=0.
        MRSyncConfigure(captureMicrophone);
        MRSyncConfigureCamera(captureCamera);
        MRSyncConfigurePrimaryStart(captureCamera || captureMicrophone);

        if (captureCamera) {
            NSError *cameraError = nil;
            if (cameraOutputPath.length == 0 ||
                !startCameraRecording(cameraOutputPath, cameraDeviceId, &cameraError)) {
                MRSyncConfigurePrimaryStart(NO);
                MRSyncConfigure(NO);
                g_iosRecorder = nil;
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
                g_iosRecorder = nil;
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
            g_iosRecorder = nil;
            return false;
        }

        [recorder.movieOutput startRecordingToOutputFileURL:[NSURL fileURLWithPath:outputPath]
                                          recordingDelegate:recorder];
        bool started = MRWaitForFlag(^bool{
            return recorder.startCompleted;
        }, 10.0);
        if (!started) {
            if (recorder.movieOutput.isRecording) [recorder.movieOutput stopRecording];
            [recorder.session stopRunning];
            if (isCameraRecording()) stopCameraRecording();
            if (isStandaloneAudioRecording()) stopStandaloneAudioRecording();
            MRSyncConfigurePrimaryStart(NO);
            MRSyncConfigure(NO);
            g_iosRecorder = nil;
            if (errorOut) {
                *errorOut = [NSError errorWithDomain:@"MacRecorderIOS"
                                                code:6
                                            userInfo:@{NSLocalizedDescriptionKey: @"Timed out waiting for the first iPhone frame"}];
            }
            return false;
        }
        if (captureCamera && !waitForCameraRecordingStart(8.0)) {
            MRLog(@"❌ Camera did not produce a synchronized frame for iPhone recording");
            if (recorder.movieOutput.isRecording) [recorder.movieOutput stopRecording];
            MRWaitForFlag(^bool{ return recorder.finishCompleted; }, 10.0);
            [recorder.session stopRunning];
            if (isCameraRecording()) stopCameraRecording();
            if (isStandaloneAudioRecording()) stopStandaloneAudioRecording();
            MRSyncConfigurePrimaryStart(NO);
            MRSyncConfigure(NO);
            g_iosRecorder = nil;
            if (errorOut) {
                *errorOut = [NSError errorWithDomain:@"MacRecorderIOS"
                                                code:9
                                            userInfo:@{NSLocalizedDescriptionKey: @"Timed out waiting for the selected camera"}];
            }
            return false;
        }
        return true;
    }
}

extern "C" bool stopIOSDeviceRecording(void) {
    @autoreleasepool {
        MRIOSDeviceRecorder *recorder = g_iosRecorder;
        if (!recorder) return true;

        if (recorder.primaryStartedAt) {
            NSTimeInterval duration = MAX(0.0, -[recorder.primaryStartedAt timeIntervalSinceNow]);
            MRSyncSetStopLimitSeconds(duration);
        }

        BOOL cameraStopped = YES;
        BOOL microphoneStopped = YES;
        if (recorder.captureCamera && isCameraRecording()) {
            cameraStopped = stopCameraRecording();
        }
        if (recorder.captureMicrophone && isStandaloneAudioRecording()) {
            microphoneStopped = stopStandaloneAudioRecording();
        }

        if (recorder.movieOutput.isRecording) {
            [recorder.movieOutput stopRecording];
            MRWaitForFlag(^bool{
                return recorder.finishCompleted;
            }, 20.0);
        }
        if (recorder.session.isRunning) [recorder.session stopRunning];

        NSError *finishError = recorder.finishError;
        BOOL finished = recorder.finishCompleted || !recorder.startCompleted;
        BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:recorder.outputPath];
        MRSyncConfigurePrimaryStart(NO);
        MRSyncConfigure(NO);
        g_iosRecorder = nil;

        if (finishError) {
            NSNumber *successfullyFinished = finishError.userInfo[AVErrorRecordingSuccessfullyFinishedKey];
            if (![successfullyFinished boolValue]) return false;
        }
        if (!cameraStopped || !microphoneStopped) {
            MRLog(@"⚠️ iPhone recording finalized, but an auxiliary camera/microphone writer reported a stop error");
        }
        // Never discard a valid phone screen recording because an optional
        // auxiliary source failed to finalize. The JS layer validates each
        // returned path independently before packaging it.
        return finished && fileExists;
    }
}

extern "C" bool isIOSDeviceRecording(void) {
    return g_iosRecorder && (g_iosRecorder.recording || g_iosRecorder.movieOutput.isRecording);
}

extern "C" NSString *currentIOSDeviceRecordingPath(void) {
    return g_iosRecorder.outputPath;
}

Napi::Value GetIOSCaptureDevices(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
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
        item.Set("width", Napi::Number::New(env, [device[@"width"] intValue]));
        item.Set("height", Napi::Number::New(env, [device[@"height"] intValue]));
        item.Set("hasAudio", Napi::Boolean::New(env, true));
        item.Set("transport", Napi::String::New(env, "usb"));
        result.Set(index, item);
    }
    return result;
}

Napi::Value StartIOSDeviceRecording(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
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
        // startIOSDeviceRecording owns an inner autorelease pool. Do not bridge
        // the NSError past that pool into V8; the JS wrapper turns false into a
        // stable user-facing error and avoids a dangling Objective-C object.
        MRLog(@"❌ iPhone capture could not start");
    }
    return Napi::Boolean::New(env, success);
}

Napi::Value StopIOSDeviceRecording(const Napi::CallbackInfo& info) {
    return Napi::Boolean::New(info.Env(), stopIOSDeviceRecording());
}

Napi::Value GetIOSDeviceRecordingStatus(const Napi::CallbackInfo& info) {
    Napi::Object status = Napi::Object::New(info.Env());
    status.Set("isRecording", Napi::Boolean::New(info.Env(), isIOSDeviceRecording()));
    NSString *path = currentIOSDeviceRecordingPath();
    if (path.length > 0) status.Set("outputPath", Napi::String::New(info.Env(), [path UTF8String]));
    return status;
}

Napi::Object InitIOSDeviceRecorder(Napi::Env env, Napi::Object exports) {
    exports.Set("getIOSCaptureDevices", Napi::Function::New(env, GetIOSCaptureDevices));
    exports.Set("startIOSDeviceRecording", Napi::Function::New(env, StartIOSDeviceRecording));
    exports.Set("stopIOSDeviceRecording", Napi::Function::New(env, StopIOSDeviceRecording));
    exports.Set("getIOSDeviceRecordingStatus", Napi::Function::New(env, GetIOSDeviceRecordingStatus));
    return exports;
}

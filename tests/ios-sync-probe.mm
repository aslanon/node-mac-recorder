// Exercise the production delegates and MOV writers without opening devices.
#import "../src/sync_timeline.mm"
#import "../src/audio_recorder.mm"
#import "../src/camera_recorder.mm"
#import "../src/ios_device_recorder.mm"
#include <unistd.h>

@interface MRProbeSession : AVCaptureSession
@property(nonatomic, assign) CMClockRef probeClock;
@end
@implementation MRProbeSession
- (CMClockRef)masterClock { return self.probeClock ?: CMClockGetHostTimeClock(); }
- (BOOL)isRunning { return NO; }
@end

@interface MRProbeMovieOutput : AVCaptureMovieFileOutput
@property NSUInteger starts;
@end
@implementation MRProbeMovieOutput
- (void)startRecordingToOutputFileURL:(NSURL *)url recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate {
    self.starts += 1;
}
@end

static CMTime T(double seconds) { return CMTimeMakeWithSeconds(seconds, 48000); }

static CMSampleBufferRef Video(double seconds) {
    CVPixelBufferRef pixels = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
        (CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}}, &pixels);
    CVPixelBufferLockBaseAddress(pixels, 0);
    memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetDataSize(pixels));
    CVPixelBufferUnlockBaseAddress(pixels, 0);
    CMVideoFormatDescriptionRef format = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixels, &format);
    CMSampleTimingInfo timing = { T(1.0 / 30), T(seconds), kCMTimeInvalid };
    CMSampleBufferRef sample = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixels, format, &timing, &sample);
    CFRelease(format);
    CFRelease(pixels);
    return sample;
}

static CMSampleBufferRef Audio(double seconds) {
    AudioStreamBasicDescription asbd = {};
    asbd.mSampleRate = 48000;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket = asbd.mBytesPerFrame = 2;
    asbd.mFramesPerPacket = asbd.mChannelsPerFrame = 1;
    asbd.mBitsPerChannel = 16;
    CMAudioFormatDescriptionRef format = NULL;
    CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &format);
    CMBlockBufferRef block = NULL;
    CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, 1920,
        kCFAllocatorDefault, NULL, 0, 1920, 0, &block);
    CMBlockBufferFillDataBytes(0, block, 0, 1920);
    char *data = NULL;
    CMBlockBufferGetDataPointer(block, 0, NULL, NULL, &data);
    for (int i = 0; i < 960; i++) ((int16_t *)data)[i] = (int16_t)(8000 * sin(i * 2 * M_PI / 48));
    CMSampleTimingInfo timing = { T(1.0 / 48000), T(seconds), kCMTimeInvalid };
    size_t size = 2;
    CMSampleBufferRef sample = NULL;
    CMSampleBufferCreateReady(kCFAllocatorDefault, block, format, 960, 1, &timing, 1, &size, &sample);
    CFRelease(format);
    CFRelease(block);
    return sample;
}

static void WaitForInput(AVAssetWriterInput *input) {
    for (int i = 0; input && !input.readyForMoreMediaData && i < 2000; i++) usleep(1000);
}

static Napi::Value Run(const Napi::CallbackInfo &info) {
    @autoreleasepool {
        NSString *directory = [NSString stringWithUTF8String:info[0].As<Napi::String>().Utf8Value().c_str()];
        NSMutableArray *failures = [NSMutableArray array];
        NSUInteger checks = 0;
        auto check = [&](BOOL ok, NSString *message) { checks++; if (!ok) [failures addObject:message]; };
        auto near = [&](CMTime actual, double expected, NSString *message) {
            check(CMTIME_IS_NUMERIC(actual) && fabs(CMTimeGetSeconds(actual) - expected) < 0.0001, message);
        };

        MRSyncConfigure(YES);
        MRSyncConfigureCamera(YES);
        MRSyncConfigurePrimaryStart(YES);
        check(!CMTIME_IS_NUMERIC(MRSyncPrimaryMediaTime(T(100))), @"warmup must not enter a writer");
        MRIOSDeviceRecorder *phone = [[[MRIOSDeviceRecorder alloc] init] autorelease];
        phone.session = [[[MRProbeSession alloc] init] autorelease];
        MRProbeMovieOutput *movie = [[[MRProbeMovieOutput alloc] init] autorelease];
        phone.movieOutput = movie;
        phone.currentSegmentPath = [directory stringByAppendingPathComponent:@"phone.mov"];
        phone.primaryStartHostTime = kCMTimeInvalid;
        phone.segmentStartPending = YES;
        CMSampleBufferRef first = Video(100);
        [phone captureOutput:movie didOutputSampleBuffer:first fromConnection:nil];
        [phone captureOutput:movie didOutputSampleBuffer:first fromConnection:nil];
        CFRelease(first);
        check(movie.starts == 1, @"sample-accurate USB start must happen exactly once");
        near(MRSyncPrimaryStartTimestamp(), 100, @"origin must come from the first USB sample");
        MRIOSMarkSegmentStarted(phone, NO);
        MRIOSMarkSegmentStarted(phone, YES);
        near(MRSyncPrimaryStartTimestamp(), 100, @"delayed progress/delegate must not move the origin");
        check(!CMTIME_IS_NUMERIC(MRSyncPrimaryMediaTime(T(99.9))), @"pre-origin samples are discarded");
        near(MRSyncPrimaryMediaTime(T(100.6)), 0.6, @"late camera keeps its actual offset");
        check(!CMTIME_IS_NUMERIC(MRSyncHostTimestamp(T(100), NULL)), @"missing capture clock is rejected");

        // Distinct session clock epochs must not become an A/V offset.
        CMTimebaseRef cameraClock = NULL, audioClock = NULL;
        CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &cameraClock);
        CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &audioClock);
        CMTimebaseSetTime(cameraClock, T(2000));
        CMTimebaseSetRate(cameraClock, 1);
        CMTimebaseSetTime(audioClock, T(500));
        CMTimebaseSetRate(audioClock, 1);
        MRProbeSession *cameraSession = [[[MRProbeSession alloc] init] autorelease];
        cameraSession.probeClock = (CMClockRef)cameraClock;
        MRProbeSession *audioSession = [[[MRProbeSession alloc] init] autorelease];
        audioSession.probeClock = (CMClockRef)audioClock;

        CameraRecorder *camera = [[[CameraRecorder alloc] init] autorelease];
        camera.session = cameraSession;
        camera.videoOutput = [[[AVCaptureVideoDataOutput alloc] init] autorelease];
        camera.outputPath = [directory stringByAppendingPathComponent:@"camera.mov"];
        camera.isRecording = YES;
        NativeAudioRecorder *microphone = [[[NativeAudioRecorder alloc] init] autorelease];
        microphone.session = audioSession;
        microphone.audioOutput = [[[AVCaptureAudioDataOutput alloc] init] autorelease];
        microphone.outputPath = [directory stringByAppendingPathComponent:@"microphone.mov"];
        auto sendVideo = [&](double time) {
            WaitForInput(camera.writerInput);
            double sourceTime = CMTimeGetSeconds(CMSyncConvertTime(T(time), CMClockGetHostTimeClock(), cameraClock));
            CMSampleBufferRef sample = Video(sourceTime);
            [camera captureOutput:camera.videoOutput didOutputSampleBuffer:sample fromConnection:nil];
            CFRelease(sample);
        };
        auto sendAudio = [&](double time) {
            WaitForInput(microphone.writerInput);
            double sourceTime = CMTimeGetSeconds(CMSyncConvertTime(T(time), CMClockGetHostTimeClock(), audioClock));
            CMSampleBufferRef sample = Audio(sourceTime);
            [microphone captureOutput:microphone.audioOutput didOutputSampleBuffer:sample fromConnection:nil];
            CFRelease(sample);
        };
        // Deliberately start the mic 400 ms before the camera. Both must retain
        // their offsets to the phone, without waiting for the other device.
        for (int i = 0; i < 40; i++) sendAudio(100.2 + i * 0.02);
        for (int i = 0; i < 12; i++) sendVideo(100.6 + i / 30.0);
        near(microphone.startTime, 100, @"mic writer uses USB origin");
        near(camera.startTime, 100, @"camera writer uses USB origin");
        MRSyncPauseAtHostTime(T(101));
        phone.pauseRanges = [NSMutableArray array];
        MRIOSBeginPauseRange(phone, T(101));
        near(MRSyncPrimaryMediaTime(T(100.99)), 0.99, @"buffer queued before pause retains its timestamp");
        check(!CMTIME_IS_NUMERIC(MRSyncPrimaryMediaTime(T(101.1))), @"paused samples are dropped");
        sendAudio(102);
        sendVideo(102);
        MRSyncResumeAtHostTime(T(104));
        MRIOSEndPauseRange(phone, T(104));
        check(phone.pauseRanges.count == 1 &&
            fabs(phone.pauseRanges[0][@"start"].doubleValue - 1) < 0.0001 &&
            fabs(phone.pauseRanges[0][@"end"].doubleValue - 4) < 0.0001,
            @"phone trims the exact same 1-to-4-second range as camera and microphone");
        check(!CMTIME_IS_NUMERIC(MRSyncPrimaryMediaTime(T(102))), @"late delivery of a paused sample is still dropped");
        near(MRSyncPrimaryMediaTime(T(104.5)), 1.5, @"resume removes exactly the phone's pause range");
        for (int i = 0; i < 50; i++) sendAudio(104 + i * 0.02);
        for (int i = 0; i < 30; i++) sendVideo(104 + i / 30.0);
        MRSyncSetStopLimitSeconds(2);
        check(MRFinishAssetWriterSafely(camera.writer, 5, 2), @"camera MOV finalizes");
        check(MRFinishAssetWriterSafely(microphone.writer, 5, 2), @"microphone MOV finalizes");
        for (NSString *kind in @[@"camera", @"microphone"]) {
            NSURL *url = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:[kind stringByAppendingString:@".mov"]]];
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
            BOOL isCamera = [kind isEqualToString:@"camera"];
            AVAssetTrack *track = [asset tracksWithMediaType:isCamera ? AVMediaTypeVideo : AVMediaTypeAudio].firstObject;
            check(track != nil, [kind stringByAppendingString:@" track exists"]);
            if (!track) continue;
            check(fabs(CMTimeGetSeconds(asset.duration) - 2) < 0.04, [kind stringByAppendingString:@" has the shared stop boundary"]);
            NSError *error = nil;
            AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
            AVAssetReaderOutput *output = isCamera
                ? [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil]
                : [AVAssetReaderAudioMixOutput assetReaderAudioMixOutputWithAudioTracks:@[track]
                    audioSettings:@{AVFormatIDKey: @(kAudioFormatLinearPCM), AVLinearPCMBitDepthKey: @16,
                        AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsNonInterleaved: @NO}];
            [reader addOutput:output];
            [reader startReading];
            CMTime previous = kCMTimeInvalid;
            CMTime firstPTS = kCMTimeInvalid;
            CMTime lastPTS = kCMTimeInvalid;
            double firstSound = -1;
            double secondVideoPTS = INFINITY;
            NSUInteger count = 0;
            while (CMSampleBufferRef sample = [output copyNextSampleBuffer]) {
                CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
                if (CMSampleBufferGetTotalSampleSize(sample) == 0) { CFRelease(sample); continue; }
                CMTime dts = CMSampleBufferGetDecodeTimeStamp(sample);
                if (!CMTIME_IS_NUMERIC(dts)) dts = pts;
                check(!CMTIME_IS_NUMERIC(previous) || CMTimeCompare(dts, previous) >= 0,
                    [kind stringByAppendingString:@" has monotonic decode timestamps after pause"]);
                previous = dts;
                firstPTS = CMTIME_IS_NUMERIC(firstPTS) ? CMTimeMinimum(firstPTS, pts) : pts;
                lastPTS = CMTIME_IS_NUMERIC(lastPTS) ? CMTimeMaximum(lastPTS, pts) : pts;
                if (isCamera && CMTimeGetSeconds(pts) > 0.001) secondVideoPTS = MIN(secondVideoPTS, CMTimeGetSeconds(pts));
                if (!isCamera && firstSound < 0) {
                    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
                    size_t length = CMBlockBufferGetDataLength(block);
                    std::vector<int16_t> pcm(length / sizeof(int16_t));
                    CMBlockBufferCopyDataBytes(block, 0, length, pcm.data());
                    for (size_t i = 0; i < pcm.size(); i++) {
                        if (abs(pcm[i]) > 500) { firstSound = CMTimeGetSeconds(pts) + i / 48000.0; break; }
                    }
                }
                count++;
                CFRelease(sample);
            }
            check(fabs(CMTimeGetSeconds(firstPTS)) < 0.04,
                [NSString stringWithFormat:@"%@ starts at zero even when a reader ignores empty edits (%.3f)", kind, CMTimeGetSeconds(firstPTS)]);
            if (isCamera) check(fabs(secondVideoPTS - 0.6) < 0.04, @"camera holds its first frame until the actual capture time");
            else check(fabs(firstSound - 0.2) < 0.04,
                [NSString stringWithFormat:@"microphone leading silence preserves sound onset (%.3f)", firstSound]);
            check(count > 1 && CMTimeGetSeconds(lastPTS) > 1.5,
                [NSString stringWithFormat:@"%@ contains media on both sides of pause (count %lu, last PTS %.3f)", kind, count, CMTimeGetSeconds(lastPTS)]);
        }
        // Repeated pauses across a long session: no callback-time accumulation.
        for (int i = 0; i < 100; i++) {
            MRSyncPauseAtHostTime(T(110 + i * 10));
            MRSyncResumeAtHostTime(T(113 + i * 10));
        }
        near(MRSyncPrimaryMediaTime(T(1110)), 707, @"100 pauses preserve the common long-recording timeline");
        MRSyncConfigure(NO);
        check(!MRSyncUsesPrimaryTimeline(), @"desktop recording does not inherit the iPhone timeline");
        check(!MRSyncShouldHoldVideoFrame(T(200)), @"desktop camera barrier remains unchanged");
        near(MRSyncAdjustForPauses(T(5)), 5, @"desktop pause duration resets between recordings");
        cameraSession.probeClock = nil;
        audioSession.probeClock = nil;
        CFRelease(cameraClock);
        CFRelease(audioClock);
        Napi::Object result = Napi::Object::New(info.Env());
        result.Set("checks", Napi::Number::New(info.Env(), checks));
        result.Set("failures", Napi::String::New(info.Env(), [[failures componentsJoinedByString:@"\n"] UTF8String]));
        return result;
    }
}

static Napi::Object InitProbe(Napi::Env env, Napi::Object exports) {
    exports.Set("run", Napi::Function::New(env, Run));
    return exports;
}
NODE_API_MODULE(ios_sync_probe, InitProbe)

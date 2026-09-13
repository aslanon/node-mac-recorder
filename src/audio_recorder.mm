#import "recording_writer_safety.h"
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "logging.h"
#import "sync_timeline.h"

static dispatch_queue_t g_audioCaptureQueue = nil;
static NSString *g_lastStandaloneAudioOutputPath = nil;

// A real PCM prefix survives readers/exporters that normalize track timestamps
// and ignore MOV empty edits. Allocation is bounded even for a bad device PTS.
static CMSampleBufferRef MRCreateSilentAudioPrefix(CMSampleBufferRef sample, double seconds) {
    CMAudioFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    const AudioStreamBasicDescription *asbd = format ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : NULL;
    if (!asbd || asbd->mFormatID != kAudioFormatLinearPCM ||
        !isfinite(seconds) || seconds <= 0 || seconds > 30 ||
        !isfinite(asbd->mSampleRate) || asbd->mSampleRate <= 0 ||
        asbd->mBytesPerFrame == 0) return NULL;
    double frameCount = floor(seconds * asbd->mSampleRate);
    double byteCount = frameCount * asbd->mBytesPerFrame;
    if (frameCount < 1 || byteCount > 32 * 1024 * 1024) return NULL;
    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, (size_t)byteCount,
        kCFAllocatorDefault, NULL, 0, (size_t)byteCount, 0, &block);
    if (status != noErr || !block) return NULL;
    status = CMBlockBufferFillDataBytes(0, block, 0, (size_t)byteCount);
    CMSampleBufferRef silence = NULL;
    if (status == noErr) {
        CMSampleTimingInfo timing = { CMTimeMake(1, (int32_t)asbd->mSampleRate), kCMTimeZero, kCMTimeInvalid };
        size_t frameSize = asbd->mBytesPerFrame;
        CMSampleBufferCreateReady(kCFAllocatorDefault, block, format, (CMItemCount)frameCount,
            1, &timing, 1, &frameSize, &silence);
    }
    CFRelease(block);
    return silence;
}

@interface NativeAudioRecorder : NSObject<AVCaptureAudioDataOutputSampleBufferDelegate>

@property (nonatomic, strong) AVAssetWriter *writer;
@property (nonatomic, strong) AVAssetWriterInput *writerInput;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureAudioDataOutput *audioOutput;
@property (nonatomic, assign) BOOL writerStarted;
@property (nonatomic, assign) BOOL primaryPrefixWritten;
@property (nonatomic, assign) CMTime startTime;
@property (nonatomic, strong) NSString *outputPath;

- (BOOL)startRecordingWithDeviceId:(NSString *)deviceId
                        outputPath:(NSString *)outputPath
                             error:(NSError **)error;
- (BOOL)isRecording;
- (BOOL)stopRecording;

@end

@implementation NativeAudioRecorder

- (instancetype)init {
    self = [super init];
    if (self) {
        _writerStarted = NO;
        _startTime = kCMTimeInvalid;
    }
    return self;
}

- (AVCaptureDevice *)deviceForId:(NSString *)deviceId {
    if (deviceId.length > 0) {
        AVCaptureDevice *device = [AVCaptureDevice deviceWithUniqueID:deviceId];
        if (device) {
            return device;
        }
    }
    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
}

- (BOOL)configureVoiceProcessingForDevice:(AVCaptureDevice *)device {
    // NOTE: Voice Isolation (microphoneMode) is iOS-only and not available on macOS
    // For macOS noise reduction, users should:
    // 1. Enable "Voice Isolation" in macOS Control Center > Microphone menu (macOS 13+)
    // 2. Or use third-party apps like Krisp, RTX Voice, or SoundSource
    //
    // AVCaptureDevice on macOS does not expose noise reduction or voice processing properties
    // Alternative approaches would require:
    // - Core Audio AUVoiceIO unit (complex, requires audio graph restructuring)
    // - AVAudioEngine with voice processing (causes crashes on macOS with aggregate devices)
    // - Custom DSP filtering (significant development effort, may not be effective)

    MRLog(@"ℹ️ macOS microphone noise reduction: Use System Settings or Control Center to enable Voice Isolation");
    return NO;
}

- (BOOL)setupWriterWithSampleBuffer:(CMSampleBufferRef)sampleBuffer error:(NSError **)error {
    if (self.writer) {
        return YES;
    }
    
    if (!self.outputPath) {
        return NO;
    }
    
    NSURL *outputURL = [NSURL fileURLWithPath:self.outputPath];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    
    NSError *writerError = nil;
    AVFileType requestedFileType = AVFileTypeQuickTimeMovie;
    BOOL requestedWebM = NO;
    if (@available(macOS 15.0, *)) {
        if (!MRSyncUsesPrimaryTimeline()) {
            requestedFileType = @"public.webm";
            requestedWebM = YES;
        }
    }
    
    @try {
        self.writer = [[AVAssetWriter alloc] initWithURL:outputURL fileType:requestedFileType error:&writerError];
    } @catch (NSException *exception) {
        NSDictionary *info = @{
            NSLocalizedDescriptionKey: exception.reason ?: @"Failed to initialize audio writer"
        };
        writerError = [NSError errorWithDomain:@"NativeAudioRecorder" code:-30 userInfo:info];
        self.writer = nil;
    }
    
    if ((!self.writer || writerError) && requestedWebM) {
        NSString *fallbackPath = [[self.outputPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"mov"];
        if (!fallbackPath || [fallbackPath length] == 0) {
            fallbackPath = [self.outputPath stringByAppendingString:@".mov"];
        }
        [[NSFileManager defaultManager] removeItemAtPath:fallbackPath error:nil];
        NSURL *fallbackURL = [NSURL fileURLWithPath:fallbackPath];
        self.outputPath = fallbackPath;
        writerError = nil;
        @try {
            self.writer = [[AVAssetWriter alloc] initWithURL:fallbackURL fileType:AVFileTypeQuickTimeMovie error:&writerError];
        } @catch (NSException *exception) {
            NSDictionary *info = @{
                NSLocalizedDescriptionKey: exception.reason ?: @"Failed to initialize audio writer"
            };
            writerError = [NSError errorWithDomain:@"NativeAudioRecorder" code:-31 userInfo:info];
            self.writer = nil;
        }
        outputURL = fallbackURL;
    }
    
    if (!self.writer || writerError) {
        if (error) {
            *error = writerError;
        }
        return NO;
    }
    
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd = formatDescription ? CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) : NULL;

    double sampleRate = asbd ? asbd->mSampleRate : 48000.0;  // Default to 48kHz (not 44.1kHz)
    NSUInteger channels = asbd ? asbd->mChannelsPerFrame : 1;  // Default to mono
    channels = MAX((NSUInteger)1, channels);

    MRLog(@"🎤 Audio format: %.0f Hz, %lu channel(s)", sampleRate, (unsigned long)channels);

    // Create audio settings
    NSMutableDictionary *audioSettings = [@{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @(sampleRate),
        AVNumberOfChannelsKey: @(channels),
        AVEncoderBitRateKey: @(256000),  // Increased from 192k to 256k for better quality
        AVEncoderAudioQualityKey: @(AVAudioQualityHigh)
    } mutableCopy];

    // CRITICAL FIX: AVChannelLayoutKey is REQUIRED for ALL channel counts
    // Force to stereo or mono for AAC compatibility
    NSUInteger validChannels = (channels <= 1) ? 1 : 2; // Force to mono or stereo
    audioSettings[AVNumberOfChannelsKey] = @(validChannels); // Update settings

    AudioChannelLayout layout = {0};
    layout.mChannelLayoutTag = (validChannels == 1) ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo;
    size_t layoutSize = sizeof(AudioChannelLayout);
    audioSettings[AVChannelLayoutKey] = [NSData dataWithBytes:&layout length:layoutSize];

    MRLog(@"🎤 Using %lu channel(s) for AAC encoding (original: %lu)", (unsigned long)validChannels, (unsigned long)channels);
    
    self.writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
    self.writerInput.expectsMediaDataInRealTime = YES;
    
    if (![self.writer canAddInput:self.writerInput]) {
        if (error) {
            *error = [NSError errorWithDomain:@"NativeAudioRecorder" code:-10 userInfo:@{NSLocalizedDescriptionKey: @"Cannot add audio input"}];
        }
        return NO;
    }
    
    [self.writer addInput:self.writerInput];
    self.writerStarted = NO;
    self.startTime = kCMTimeInvalid;
    
    return YES;
}

- (BOOL)startRecordingWithDeviceId:(NSString *)deviceId
                        outputPath:(NSString *)outputPath
                             error:(NSError **)error {
    if (self.session) {
        if (error) {
            *error = [NSError errorWithDomain:@"NativeAudioRecorder" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Audio recording already in progress"}];
        }
        return NO;
    }
    
    AVCaptureDevice *device = [self deviceForId:deviceId];
    if (!device) {
        if (error) {
            *error = [NSError errorWithDomain:@"NativeAudioRecorder" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Audio device not found"}];
        }
        return NO;
    }

    // Configure voice processing to filter keyboard/mouse clicks and background noise
    [self configureVoiceProcessingForDevice:device];

    self.outputPath = outputPath;
    self.session = [[AVCaptureSession alloc] init];
    
    NSError *inputError = nil;
    AVCaptureDeviceInput *deviceInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:&inputError];
    if (!deviceInput || inputError) {
        if (error) {
            *error = inputError;
        }
        return NO;
    }
    
    if (![self.session canAddInput:deviceInput]) {
        if (error) {
            *error = [NSError errorWithDomain:@"NativeAudioRecorder" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Cannot add audio input"}];
        }
        return NO;
    }
    [self.session addInput:deviceInput];
    
    self.audioOutput = [[AVCaptureAudioDataOutput alloc] init];
    if (![self.session canAddOutput:self.audioOutput]) {
        if (error) {
            *error = [NSError errorWithDomain:@"NativeAudioRecorder" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"Cannot add audio output"}];
        }
        return NO;
    }

    // Configure audio output settings to ensure proper PCM format
    NSDictionary *audioOutputSettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey: @(16),
        AVLinearPCMIsFloatKey: @(NO),
        AVLinearPCMIsBigEndianKey: @(NO),
        AVLinearPCMIsNonInterleaved: @(NO)
    };
    [self.audioOutput setAudioSettings:audioOutputSettings];

    if (!g_audioCaptureQueue) {
        g_audioCaptureQueue = dispatch_queue_create("native_audio_recorder.queue", DISPATCH_QUEUE_SERIAL);
    }
    [self.audioOutput setSampleBufferDelegate:self queue:g_audioCaptureQueue];
    [self.session addOutput:self.audioOutput];
    
    [self.session startRunning];
    MRLog(@"🎙️ Native audio capture started using device: %@", device.localizedName);
    return YES;
}

- (BOOL)isRecording {
    return self.session.isRunning;
}

- (BOOL)stopRecording {
    if (!self.session) {
        return YES;
    }

    // CRITICAL FIX: For external devices (especially Continuity Microphone),
    // stopRunning can hang if device is disconnected. Use async approach.
    MRLog(@"🛑 AudioRecorder: Stopping session (external device safe)...");

    // Stop session on background thread to avoid blocking
    AVCaptureSession *sessionToStop = [self.session retain];
    AVCaptureAudioDataOutput *outputToStop = [self.audioOutput retain];

    // Clear references FIRST to prevent new samples
    self.session = nil;
    self.audioOutput = nil;

    // Stop session asynchronously with timeout protection
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        @autoreleasepool {
          @try {
            if ([sessionToStop isRunning]) {
                MRLog(@"🛑 Stopping AVCaptureSession...");
                [sessionToStop stopRunning];
                MRLog(@"✅ AVCaptureSession stopped");
            }
          } @catch (NSException *exception) {
            NSLog(@"[Recorder] Microphone session stop failed safely: %@", exception.reason);
          }
            // Release happens automatically when block completes
        }
    });

    // Detach callbacks before draining; otherwise a late audio sample can
    // recreate or append to a writer which is being finalized.
    [sessionToStop release]; // the copied dispatch block owns it now
    @try { [outputToStop setSampleBufferDelegate:nil queue:nil]; }
    @catch (NSException *exception) { NSLog(@"[Recorder] Microphone delegate detach: %@", exception.reason); }
    [outputToStop release];
    if (g_audioCaptureQueue) dispatch_sync(g_audioCaptureQueue, ^{});
    MRFinishAssetWriterSafely(self.writer, 8.0,
        MRSyncUsesPrimaryTimeline() ? MRSyncGetStopLimitSeconds() : -1.0);

    self.writer = nil;
    self.writerInput = nil;
    self.writerStarted = NO;
    self.startTime = kCMTimeInvalid;
    self.outputPath = nil;

    MRLog(@"✅ AudioRecorder stopped (safe for external devices)");
    return YES;
}

#pragma mark - AVCaptureAudioDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (!self.session || output != self.audioOutput) return;
    @try {
    BOOL primaryTimeline = MRSyncUsesPrimaryTimeline();
    if (!primaryTimeline && MRSyncIsPaused()) {
        return;
    }
    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        return;
    }
    
    NSError *writerError = nil;
    if (![self setupWriterWithSampleBuffer:sampleBuffer error:&writerError]) {
        if (writerError) {
            NSLog(@"❌ Audio writer setup failed: %@", writerError);
        }
        return;
    }
    
    if (!self.writer || !self.writerInput) {
        return;
    }
    
    CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMClockRef captureClock = self.session.masterClock;
    if (primaryTimeline) {
        timestamp = MRSyncHostTimestamp(timestamp, captureClock);
        if (!CMTIME_IS_NUMERIC(MRSyncPrimaryMediaTime(timestamp))) return;
    }

    // Keep microphone warm-up outside the recording until the USB iPhone movie
    // output has actually started writing its first frame.
    if (MRSyncShouldHoldForPrimary(timestamp)) {
        return;
    }

    // A/V SYNC: Hold audio samples until camera produces first frame
    // This ensures both audio and camera files start from the same wall-clock moment
    if (!primaryTimeline && MRSyncShouldHoldAudioSample(timestamp)) {
        return;
    }

    MRSyncMarkAudioSample(timestamp);

    if (!self.writerStarted) {
        if (![self.writer startWriting]) {
            NSLog(@"❌ Audio writer failed to start: %@", self.writer.error);
            return;
        }
        [self.writer startSessionAtSourceTime:kCMTimeZero];
        self.writerStarted = YES;
        self.primaryPrefixWritten = NO;
        self.startTime = primaryTimeline ? MRSyncPrimaryStartTimestamp() : timestamp;
    }
    
    if (!self.writerInput.readyForMoreMediaData) {
        return;
    }

    if (primaryTimeline && !self.primaryPrefixWritten) {
        double leadingSeconds = CMTimeGetSeconds(MRSyncPrimaryMediaTime(timestamp));
        CMSampleBufferRef silence = MRCreateSilentAudioPrefix(sampleBuffer, leadingSeconds);
        if (silence) {
            BOOL appended = [self.writerInput appendSampleBuffer:silence];
            CFRelease(silence);
            if (!appended) return;
        }
        self.primaryPrefixWritten = YES;
        if (!self.writerInput.readyForMoreMediaData) return;
    }
    
    if (CMTIME_IS_INVALID(self.startTime)) {
        self.startTime = timestamp;
    }
    
    CMSampleBufferRef bufferToAppend = sampleBuffer;
    CMItemCount timingEntryCount = 0;
    OSStatus timingStatus = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, 0, NULL, &timingEntryCount);
    CMSampleTimingInfo *timingInfo = NULL;
    double stopLimit = MRSyncGetStopLimitSeconds();
    double audioTolerance = 0.02;
    BOOL shouldDropBuffer = NO;
    
    if (timingStatus == noErr && timingEntryCount > 0) {
        timingInfo = (CMSampleTimingInfo *)malloc(sizeof(CMSampleTimingInfo) * timingEntryCount);
        if (timingInfo) {
            timingStatus = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, timingEntryCount, timingInfo, &timingEntryCount);
            
            if (timingStatus == noErr) {
                for (CMItemCount i = 0; i < timingEntryCount; ++i) {
                    // Shift audio timestamps to begin at t=0 so they align with camera capture
                    if (CMTIME_IS_VALID(timingInfo[i].presentationTimeStamp)) {
                        CMTime adjustedPTS = CMTimeSubtract(timingInfo[i].presentationTimeStamp, self.startTime);
                        if (CMTIME_COMPARE_INLINE(adjustedPTS, <, kCMTimeZero)) {
                            adjustedPTS = kCMTimeZero;
                        }
                        adjustedPTS = primaryTimeline
                            ? MRSyncPrimaryMediaTime(MRSyncHostTimestamp(timingInfo[i].presentationTimeStamp, captureClock))
                            : MRSyncAdjustForPauses(adjustedPTS);
                        if (!CMTIME_IS_NUMERIC(adjustedPTS)) shouldDropBuffer = YES;
                        timingInfo[i].presentationTimeStamp = adjustedPTS;
                        
                        if (stopLimit > 0) {
                            double sampleStart = CMTimeGetSeconds(adjustedPTS);
                            double sampleDuration = CMTIME_IS_VALID(timingInfo[i].duration) ? CMTimeGetSeconds(timingInfo[i].duration) : 0.0;
                            if (sampleStart > stopLimit + audioTolerance ||
                                (sampleDuration > 0.0 && (sampleStart + sampleDuration) > stopLimit + audioTolerance)) {
                                shouldDropBuffer = YES;
                            }
                        }
                    } else {
                        timingInfo[i].presentationTimeStamp = kCMTimeZero;
                    }
                    
                    if (CMTIME_IS_VALID(timingInfo[i].decodeTimeStamp)) {
                        CMTime adjustedDTS = CMTimeSubtract(timingInfo[i].decodeTimeStamp, self.startTime);
                        if (CMTIME_COMPARE_INLINE(adjustedDTS, <, kCMTimeZero)) {
                            adjustedDTS = kCMTimeZero;
                        }
                        timingInfo[i].decodeTimeStamp = primaryTimeline
                            ? MRSyncPrimaryMediaTime(MRSyncHostTimestamp(timingInfo[i].decodeTimeStamp, captureClock))
                            : MRSyncAdjustForPauses(adjustedDTS);
                    }
                }
                
                CMSampleBufferRef adjustedBuffer = NULL;
                timingStatus = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault,
                                                                     sampleBuffer,
                                                                     timingEntryCount,
                                                                     timingInfo,
                                                                     &adjustedBuffer);
                if (timingStatus == noErr && adjustedBuffer) {
                    bufferToAppend = adjustedBuffer;
                }
            }
            
            free(timingInfo);
            timingInfo = NULL;
        }
    }

    // Never feed absolute device-clock timestamps into a zero-based iPhone
    // writer if allocation or retiming failed.
    if (primaryTimeline && bufferToAppend == sampleBuffer) shouldDropBuffer = YES;
    if (stopLimit > 0 && !shouldDropBuffer && bufferToAppend == sampleBuffer) {
        // No timing info available; approximate using buffer timestamp.
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        if (CMTIME_IS_VALID(pts)) {
            double relativeStart = CMTimeGetSeconds(
                MRSyncAdjustForPauses(CMTimeSubtract(pts, self.startTime)));
            if (relativeStart > stopLimit + audioTolerance) {
                shouldDropBuffer = YES;
            }
        }
    }

    if (shouldDropBuffer) {
        if (bufferToAppend != sampleBuffer) {
            CFRelease(bufferToAppend);
        }
        return;
    }
    
    if (![self.writerInput appendSampleBuffer:bufferToAppend]) {
        NSLog(@"⚠️ Failed appending audio buffer: %@", self.writer.error);
    }
    
    if (bufferToAppend != sampleBuffer) {
        CFRelease(bufferToAppend);
    }
    } @catch (NSException *exception) {
        NSLog(@"[Recorder] Audio sample failed safely: %@", exception.reason);
    }

}

@end

static NativeAudioRecorder *g_audioRecorder = nil;

extern "C" {

NSArray<NSDictionary *> *listAudioCaptureDevices() {
    NSMutableArray<NSDictionary *> *devicesInfo = [NSMutableArray array];

    // CRITICAL FIX: Include all audio device types including external and Continuity
    NSMutableArray<AVCaptureDeviceType> *deviceTypes = [NSMutableArray arrayWithArray:@[
        AVCaptureDeviceTypeBuiltInMicrophone,
        AVCaptureDeviceTypeExternalUnknown
    ]];

    // Add external microphones (includes Continuity Microphone on macOS 14+)
    if (@available(macOS 14.0, *)) {
        [deviceTypes addObject:AVCaptureDeviceTypeExternal];
        MRLog(@"✅ Added External audio device type (iPhone microphone will be visible)");
    }

    AVCaptureDeviceDiscoverySession *session = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:deviceTypes
                              mediaType:AVMediaTypeAudio
                               position:AVCaptureDevicePositionUnspecified];

    for (AVCaptureDevice *device in session.devices) {
        // PRIORITY FIX: MacBook built-in devices should be default, not external devices
        // Check if this is a built-in device (MacBook's own microphone)
        NSString *deviceName = device.localizedName ?: @"";
        BOOL isBuiltIn = NO;

        // Built-in detection: Check for "MacBook", "iMac", "Mac Studio", "Mac mini", "Mac Pro" in name
        if ([deviceName rangeOfString:@"MacBook" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [deviceName rangeOfString:@"iMac" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [deviceName rangeOfString:@"Mac Studio" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [deviceName rangeOfString:@"Mac mini" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [deviceName rangeOfString:@"Mac Pro" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            isBuiltIn = YES;
        }

        // Also check for generic "Built-in" in name
        if ([deviceName rangeOfString:@"Built-in" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            isBuiltIn = YES;
        }

        // External devices (Continuity, USB, etc.) should NOT be default
        if ([deviceName rangeOfString:@"Continuity" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [deviceName rangeOfString:@"iPhone" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [deviceName rangeOfString:@"iPad" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            isBuiltIn = NO;
        }

        NSDictionary *info = @{
            @"id": device.uniqueID ?: @"",
            @"name": deviceName,
            @"manufacturer": device.manufacturer ?: @"",
            @"isDefault": @(isBuiltIn), // Only built-in devices are default
            @"transportType": @(device.transportType)
        };
        [devicesInfo addObject:info];
    }
    
    return devicesInfo;
}

bool startStandaloneAudioRecording(NSString *outputPath,
                                   NSString *preferredDeviceId,
                                   NSError **error) {
    if (g_audioRecorder && [g_audioRecorder isRecording]) {
        if (error) {
            *error = [NSError errorWithDomain:@"NativeAudioRecorder" code:-20 userInfo:@{NSLocalizedDescriptionKey: @"Audio recording already active"}];
        }
        return false;
    }
    
    AVAuthorizationStatus audioStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    __block BOOL audioPermissionGranted = (audioStatus == AVAuthorizationStatusAuthorized);
    if (audioStatus == AVAuthorizationStatusNotDetermined) {
        dispatch_semaphore_t permissionSemaphore = dispatch_semaphore_create(0);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            audioPermissionGranted = granted;
            dispatch_semaphore_signal(permissionSemaphore);
        }];
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC));
        dispatch_semaphore_wait(permissionSemaphore, timeout);
    } else if (audioStatus != AVAuthorizationStatusAuthorized) {
        audioPermissionGranted = NO;
    }
    
    if (!audioPermissionGranted) {
        if (error) {
            *error = [NSError errorWithDomain:@"NativeAudioRecorder" code:-21 userInfo:@{NSLocalizedDescriptionKey: @"Audio permission not granted"}];
        }
        return false;
    }
    
    g_audioRecorder = [[NativeAudioRecorder alloc] init];
    if (outputPath && [outputPath length] > 0) {
        NSString *ownedOutputPath = [outputPath copy];
        [g_lastStandaloneAudioOutputPath release];
        g_lastStandaloneAudioOutputPath = ownedOutputPath;
    }
    @try {
        BOOL started = [g_audioRecorder startRecordingWithDeviceId:preferredDeviceId outputPath:outputPath error:error];
        if (!started) [g_audioRecorder stopRecording];
        return started;
    } @catch (NSException *exception) {
        NSLog(@"[Recorder] Microphone startup failed safely: %@", exception.reason);
        @try { [g_audioRecorder stopRecording]; } @catch (NSException *cleanupError) {}
        if (error) *error = [NSError errorWithDomain:@"NativeAudioRecorder" code:-22
            userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Microphone startup failed"}];
        return false;
    }
}

bool stopStandaloneAudioRecording() {
    if (!g_audioRecorder) {
        return true;
    }
    BOOL result = [g_audioRecorder stopRecording];
    g_audioRecorder = nil;
    return result;
}

bool isStandaloneAudioRecording() {
    if (!g_audioRecorder) {
        return false;
    }
    return [g_audioRecorder isRecording];
}

bool hasAudioPermission() {
    return [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusAuthorized;
}

void requestAudioPermission(void (^completion)(BOOL granted)) {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:completion];
}

NSString *currentStandaloneAudioRecordingPath() {
    if (!g_audioRecorder) {
        return nil;
    }
    return g_audioRecorder.outputPath;
}

// Returns last standalone mic output path (even after stop)
extern "C" NSString *lastStandaloneAudioRecordingPath() {
    return g_lastStandaloneAudioOutputPath;
}

// C API for AVFoundation integration
void* createNativeAudioRecorder() {
    return (__bridge_retained void*)[[NativeAudioRecorder alloc] init];
}

bool startNativeAudioRecording(void* recorder, const char* deviceId, const char* outputPath) {
    if (!recorder || !outputPath) {
        return false;
    }

    NativeAudioRecorder* audioRecorder = (__bridge NativeAudioRecorder*)recorder;
    NSString* deviceIdStr = deviceId ? [NSString stringWithUTF8String:deviceId] : nil;
    NSString* outputPathStr = [NSString stringWithUTF8String:outputPath];

    NSError* error = nil;
    return [audioRecorder startRecordingWithDeviceId:deviceIdStr outputPath:outputPathStr error:&error];
}

bool stopNativeAudioRecording(void* recorder) {
    if (!recorder) {
        return false;
    }

    NativeAudioRecorder* audioRecorder = (__bridge NativeAudioRecorder*)recorder;
    return [audioRecorder stopRecording];
}

void destroyNativeAudioRecorder(void* recorder) {
    if (recorder) {
        CFRelease(recorder);
    }
}

}

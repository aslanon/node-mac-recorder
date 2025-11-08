#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

static BOOL MRFileExistsNonEmpty(NSString *path) {
    if (!path || path.length == 0) return NO;
    BOOL isDir = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
    if (!exists || isDir) return NO;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    return size > 0;
}

static NSURL *MRTempMixURLFor(NSString *destinationPath) {
    NSString *dir = [destinationPath stringByDeletingLastPathComponent];
    NSString *base = [[destinationPath lastPathComponent] stringByDeletingPathExtension];
    NSString *tmpName = [NSString stringWithFormat:@"%@.mixed.tmp.mov", base.length ? base : @"audio"];
    return [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:tmpName]];
}

static BOOL MRAtomicallyReplace(NSString *sourcePath, NSURL *tmpURL) {
    if (!sourcePath || sourcePath.length == 0 || !tmpURL) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    if ([fm fileExistsAtPath:sourcePath]) {
        [fm removeItemAtPath:sourcePath error:&err];
        err = nil;
    }
    return [fm moveItemAtURL:tmpURL toURL:[NSURL fileURLWithPath:sourcePath] error:&err];
}

static AVMutableComposition *MRBuildCompositionFromTracks(NSArray<AVAssetTrack *> *tracks) {
    if (tracks.count == 0) return nil;
    AVMutableComposition *comp = [AVMutableComposition composition];
    for (AVAssetTrack *src in tracks) {
        if (![src.mediaType isEqualToString:AVMediaTypeAudio]) continue;
        AVMutableCompositionTrack *dst = [comp addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
        CMTimeRange full = CMTimeRangeMake(kCMTimeZero, src.timeRange.duration);
        NSError *insErr = nil;
        if (![dst insertTimeRange:full ofTrack:src atTime:kCMTimeZero error:&insErr]) {
            return nil;
        }
    }
    return comp;
}

static AVAudioMix *MRBuildAudioMixForTracks(NSArray<AVAssetTrack *> *tracks, float gainA, float gainB) {
    NSMutableArray *params = [NSMutableArray array];
    for (NSUInteger i = 0; i < tracks.count; i++) {
        AVAssetTrack *t = tracks[i];
        AVMutableAudioMixInputParameters *p = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:t];
        [p setVolume:(i == 0 ? gainA : gainB) atTime:kCMTimeZero];
        [params addObject:p];
    }
    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = params;
    return mix;
}

static BOOL MRMixImpl(NSString *primaryAudioPath,
                      NSString *externalMicPath,
                      BOOL preferInternalTracks,
                      float micGain,
                      float systemGain) {
    if (!MRFileExistsNonEmpty(primaryAudioPath)) {
        return NO;
    }
    NSURL *primaryURL = [NSURL fileURLWithPath:primaryAudioPath];
    AVURLAsset *primaryAsset = [AVURLAsset URLAssetWithURL:primaryURL options:nil];
    NSArray<AVAssetTrack *> *primaryTracks = [primaryAsset tracksWithMediaType:AVMediaTypeAudio];

    NSMutableArray<AVAssetTrack *> *tracksToMix = [NSMutableArray array];
    if (preferInternalTracks && primaryTracks.count >= 2) {
        [tracksToMix addObject:primaryTracks[0]]; // mic first
        [tracksToMix addObject:primaryTracks[1]]; // system
    } else if (MRFileExistsNonEmpty(externalMicPath)) {
        if (primaryTracks.count > 0) {
            [tracksToMix addObject:primaryTracks[0]]; // system
        }
        AVURLAsset *micAsset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:externalMicPath] options:nil];
        NSArray<AVAssetTrack *> *micTracks = [micAsset tracksWithMediaType:AVMediaTypeAudio];
        if (micTracks.count > 0) {
            [tracksToMix addObject:micTracks[0]]; // mic
        }
    } else {
        return NO;
    }
    if (tracksToMix.count < 2) return NO;

    AVMutableComposition *composition = MRBuildCompositionFromTracks(tracksToMix);
    if (!composition) return NO;

    float g0 = 0.5f, g1 = 0.5f;
    if (preferInternalTracks) {
        g0 = micGain;   // track[0] mic
        g1 = systemGain;// track[1] system
    } else {
        g0 = systemGain;// track[0] system
        g1 = micGain;   // track[1] mic
    }
    AVAudioMix *audioMix = MRBuildAudioMixForTracks(tracksToMix, g0, g1);

    NSError *readerError = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:composition error:&readerError];
    if (!reader || readerError) return NO;

    NSDictionary *pcmSettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(48000),
        AVNumberOfChannelsKey: @(2),
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMBitDepthKey: @(16),
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO
    };
    NSArray<AVAssetTrack *> *compAudioTracks = [composition tracksWithMediaType:AVMediaTypeAudio];
    if (compAudioTracks.count < 1) return NO;
    AVAssetReaderAudioMixOutput *mixOutput = [AVAssetReaderAudioMixOutput assetReaderAudioMixOutputWithAudioTracks:compAudioTracks audioSettings:pcmSettings];
    mixOutput.audioMix = audioMix;
    if (![reader canAddOutput:mixOutput]) return NO;
    [reader addOutput:mixOutput];

    NSURL *tmpURL = MRTempMixURLFor(primaryAudioPath);
    NSError *writerError = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:tmpURL fileType:AVFileTypeQuickTimeMovie error:&writerError];
    if (!writer || writerError) return NO;

    AudioChannelLayout layout = {0};
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
    NSData *layoutData = [NSData dataWithBytes:&layout length:sizeof(AudioChannelLayout)];
    NSDictionary *aacSettings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @(48000),
        AVNumberOfChannelsKey: @(2),
        AVEncoderBitRateKey: @(256000),
        AVChannelLayoutKey: layoutData
    };
    AVAssetWriterInput *writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:aacSettings];
    writerInput.expectsMediaDataInRealTime = NO;
    if (![writer canAddInput:writerInput]) return NO;
    [writer addInput:writerInput];

    if (![reader startReading]) return NO;
    if (![writer startWriting]) return NO;
    [writer startSessionAtSourceTime:kCMTimeZero];

    CMSampleBufferRef sample = NULL;
    BOOL success = YES;
    while (reader.status == AVAssetReaderStatusReading) {
        @autoreleasepool {
            if (writerInput.readyForMoreMediaData) {
                sample = [mixOutput copyNextSampleBuffer];
                if (sample) {
                    if (![writerInput appendSampleBuffer:sample]) {
                        success = NO;
                        CFRelease(sample);
                        break;
                    }
                    CFRelease(sample);
                } else {
                    break;
                }
            } else {
                usleep(1000);
            }
        }
    }

    [writerInput markAsFinished];
    if (success && reader.status == AVAssetReaderStatusCompleted) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block BOOL finishedOK = NO;
        [writer finishWritingWithCompletionHandler:^{
            finishedOK = (writer.status == AVAssetWriterStatusCompleted);
            dispatch_semaphore_signal(sem);
        }];
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC));
        dispatch_semaphore_wait(sem, timeout);
        if (!finishedOK) return NO;
        return MRAtomicallyReplace(primaryAudioPath, tmpURL);
    } else {
        [writer cancelWriting];
        return NO;
    }
}

extern "C" BOOL MRMixAudioToSingleTrack(NSString *primaryAudioPath,
                                         NSString *externalMicPath,
                                         BOOL preferInternalTracks) {
    @autoreleasepool {
        return MRMixImpl(primaryAudioPath, externalMicPath, preferInternalTracks, 0.5f, 0.5f);
    }
}

extern "C" BOOL MRMixAudioToSingleTrackWithGains(NSString *primaryAudioPath,
                                                  NSString *externalMicPath,
                                                  BOOL preferInternalTracks,
                                                  float micGain,
                                                  float systemGain) {
    @autoreleasepool {
        return MRMixImpl(primaryAudioPath, externalMicPath, preferInternalTracks, micGain, systemGain);
    }
}

extern "C" BOOL MRMuxAudioIntoVideo(NSString *videoPath, NSString *audioPath) {
    @autoreleasepool {
        if (!MRFileExistsNonEmpty(videoPath) || !MRFileExistsNonEmpty(audioPath)) {
            return NO;
        }
        NSURL *videoURL = [NSURL fileURLWithPath:videoPath];
        NSURL *audioURL = [NSURL fileURLWithPath:audioPath];
        AVURLAsset *videoAsset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
        AVURLAsset *audioAsset = [AVURLAsset URLAssetWithURL:audioURL options:nil];

        NSArray<AVAssetTrack *> *videoTracks = [videoAsset tracksWithMediaType:AVMediaTypeVideo];
        NSArray<AVAssetTrack *> *audioTracks = [audioAsset tracksWithMediaType:AVMediaTypeAudio];
        if (videoTracks.count == 0 || audioTracks.count == 0) {
            return NO;
        }

        AVMutableComposition *composition = [AVMutableComposition composition];
        // Insert video
        AVAssetTrack *vsrc = videoTracks.firstObject;
        AVMutableCompositionTrack *vdst = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
        CMTimeRange vrange = CMTimeRangeMake(kCMTimeZero, vsrc.timeRange.duration);
        NSError *err = nil;
        if (![vdst insertTimeRange:vrange ofTrack:vsrc atTime:kCMTimeZero error:&err]) {
            return NO;
        }
        // Insert audio
        AVAssetTrack *asrc = audioTracks.firstObject;
        AVMutableCompositionTrack *adst = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
        CMTimeRange arange = CMTimeRangeMake(kCMTimeZero, asrc.timeRange.duration);
        err = nil;
        if (![adst insertTimeRange:arange ofTrack:asrc atTime:kCMTimeZero error:&err]) {
            return NO;
        }

        // Export passthrough then replace
        NSString *dir = [videoPath stringByDeletingLastPathComponent];
        NSString *base = [[videoPath lastPathComponent] stringByDeletingPathExtension];
        NSString *tmpName = [NSString stringWithFormat:@"%@.mux.tmp.mov", base.length ? base : @"screen"];
        NSURL *tmpURL = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:tmpName]];
        [[NSFileManager defaultManager] removeItemAtURL:tmpURL error:nil];

        AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetPassthrough];
        if (!exporter) {
            return NO;
        }
        exporter.outputURL = tmpURL;
        exporter.outputFileType = AVFileTypeQuickTimeMovie;
        exporter.shouldOptimizeForNetworkUse = NO;

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block BOOL ok = NO;
        [exporter exportAsynchronouslyWithCompletionHandler:^{
            ok = (exporter.status == AVAssetExportSessionStatusCompleted);
            dispatch_semaphore_signal(sem);
        }];
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC));
        dispatch_semaphore_wait(sem, timeout);
        if (!ok) {
            return NO;
        }
        return MRAtomicallyReplace(videoPath, tmpURL);
    }
}


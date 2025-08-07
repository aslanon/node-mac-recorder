#import "screen_capture_kit.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>

static SCStream *g_scStream = nil;
static SCRecordingOutput *g_scRecordingOutput = nil;
static NSURL *g_outputURL = nil;

@interface ScreenCaptureKitRecorder () <SCRecordingOutputDelegate>
@end

@implementation ScreenCaptureKitRecorder

+ (BOOL)isScreenCaptureKitAvailable {
    if (@available(macOS 14.0, *)) {
        Class streamClass = NSClassFromString(@"SCStream");
        Class recordingOutputClass = NSClassFromString(@"SCRecordingOutput");
        return (streamClass != nil && recordingOutputClass != nil);
    }
    return NO;
}

+ (BOOL)isRecording {
    return g_scStream != nil;
}

+ (BOOL)startRecordingWithConfiguration:(NSDictionary *)config 
                               delegate:(id)delegate 
                                  error:(NSError **)error {
    if (![self isScreenCaptureKitAvailable]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ScreenCaptureKitRecorder"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"ScreenCaptureKit not available"}];
        }
        return NO;
    }

    if (g_scStream) {
        return NO;
    }

    @try {
        __block SCShareableContent *content = nil;
        __block NSError *contentErr = nil;

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        if (@available(macOS 13.0, *)) {
            [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                                    onScreenWindowsOnly:YES
                                                          completionHandler:^(SCShareableContent * _Nullable shareableContent, NSError * _Nullable err) {
                content = shareableContent;
                contentErr = err;
                dispatch_semaphore_signal(sem);
            }];
        } else {
            dispatch_semaphore_signal(sem);
        }
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

        if (!content || contentErr) {
            if (error) { *error = contentErr ?: [NSError errorWithDomain:@"ScreenCaptureKitRecorder" code:-2 userInfo:nil]; }
            return NO;
        }

        NSNumber *displayIdNumber = config[@"displayId"]; // CGDirectDisplayID
        NSDictionary *captureArea = config[@"captureArea"]; // {x,y,width,height}
        NSNumber *captureCursorNum = config[@"captureCursor"];
        NSNumber *includeMicNum = config[@"includeMicrophone"];
        NSNumber *includeSystemAudioNum = config[@"includeSystemAudio"];
        NSArray<NSString *> *excludedBundleIds = config[@"excludedAppBundleIds"];
        NSArray<NSNumber *> *excludedPIDs = config[@"excludedPIDs"];
        NSArray<NSNumber *> *excludedWindowIds = config[@"excludedWindowIds"];
        NSString *outputPath = config[@"outputPath"];

        SCDisplay *targetDisplay = nil;
        if (displayIdNumber) {
            uint32_t wanted = (uint32_t)displayIdNumber.unsignedIntValue;
            for (SCDisplay *d in content.displays) {
                if (d.displayID == wanted) { targetDisplay = d; break; }
            }
        }
        if (!targetDisplay) {
            targetDisplay = content.displays.firstObject;
            if (!targetDisplay) { return NO; }
        }

        NSMutableArray<SCRunningApplication*> *appsToExclude = [NSMutableArray array];
        if (excludedBundleIds.count > 0) {
            for (SCRunningApplication *app in content.applications) {
                if ([excludedBundleIds containsObject:app.bundleIdentifier]) {
                    [appsToExclude addObject:app];
                }
            }
        }
        if (excludedPIDs.count > 0) {
            for (SCRunningApplication *app in content.applications) {
                if ([excludedPIDs containsObject:@(app.processID)]) {
                    [appsToExclude addObject:app];
                }
            }
        }

        NSMutableArray<SCWindow*> *windowsToExclude = [NSMutableArray array];
        if (excludedWindowIds.count > 0) {
            for (SCWindow *w in content.windows) {
                if ([excludedWindowIds containsObject:@(w.windowID)]) {
                    [windowsToExclude addObject:w];
                }
            }
        }

        SCContentFilter *filter = nil;
        if (appsToExclude.count > 0) {
            if (@available(macOS 13.0, *)) {
                filter = [[SCContentFilter alloc] initWithDisplay:targetDisplay excludingApplications:appsToExclude exceptingWindows:windowsToExclude];
            }
        }
        if (!filter) {
            if (@available(macOS 13.0, *)) {
                filter = [[SCContentFilter alloc] initWithDisplay:targetDisplay excludingWindows:windowsToExclude];
            }
        }
        if (!filter) { return NO; }

        SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
        if (captureArea && captureArea[@"width"] && captureArea[@"height"]) {
            CGRect src = CGRectMake([captureArea[@"x"] doubleValue],
                                    [captureArea[@"y"] doubleValue],
                                    [captureArea[@"width"] doubleValue],
                                    [captureArea[@"height"] doubleValue]);
            cfg.sourceRect = src;
            cfg.width = (int)src.size.width;
            cfg.height = (int)src.size.height;
        } else {
            CGRect displayFrame = targetDisplay.frame;
            cfg.width = (int)displayFrame.size.width;
            cfg.height = (int)displayFrame.size.height;
        }
        cfg.showsCursor = captureCursorNum.boolValue;
        if (includeMicNum || includeSystemAudioNum) {
            cfg.capturesAudio = YES;
        }

        g_scStream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:nil];

        if (@available(macOS 14.0, *)) {
            SCRecordingOutputConfiguration *recCfg = [[SCRecordingOutputConfiguration alloc] init];
            g_outputURL = [NSURL fileURLWithPath:outputPath];
            recCfg.outputURL = g_outputURL;
            recCfg.outputFileType = AVFileTypeQuickTimeMovie;
            g_scRecordingOutput = [[SCRecordingOutput alloc] initWithConfiguration:recCfg delegate:(id<SCRecordingOutputDelegate>)delegate ?: (id<SCRecordingOutputDelegate>)self];
            NSError *addErr = nil;
            BOOL added = [g_scStream addRecordingOutput:g_scRecordingOutput error:&addErr];
            if (!added) {
                if (error) { *error = addErr ?: [NSError errorWithDomain:@"ScreenCaptureKitRecorder" code:-3 userInfo:nil]; }
                g_scRecordingOutput = nil; g_scStream = nil; g_outputURL = nil;
                return NO;
            }

            __block NSError *startErr = nil;
            dispatch_semaphore_t startSem = dispatch_semaphore_create(0);
            [g_scStream startCaptureWithCompletionHandler:^(NSError * _Nullable err) {
                startErr = err;
                dispatch_semaphore_signal(startSem);
            }];
            dispatch_semaphore_wait(startSem, DISPATCH_TIME_FOREVER);
            if (startErr) {
                if (error) { *error = startErr; }
                [g_scStream removeRecordingOutput:g_scRecordingOutput error:nil];
                g_scRecordingOutput = nil; g_scStream = nil; g_outputURL = nil;
                return NO;
            }
            return YES;
        }

        return NO;
    } @catch (__unused NSException *ex) {
        return NO;
    }
}

+ (void)stopRecording {
    if (!g_scStream) { return; }
    @try {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [g_scStream stopCaptureWithCompletionHandler:^(NSError * _Nullable error) {
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    } @catch (__unused NSException *ex) {
    }
    if (g_scRecordingOutput) {
        [g_scStream removeRecordingOutput:g_scRecordingOutput error:nil];
    }
    g_scRecordingOutput = nil;
    g_scStream = nil;
    g_outputURL = nil;
}

@end



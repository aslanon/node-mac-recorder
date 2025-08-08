#import "screen_capture_kit.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>

static SCStream *g_scStream = nil;
static SCRecordingOutput *g_scRecordingOutput = nil;
static NSURL *g_outputURL = nil;
static ScreenCaptureKitRecorder *g_scDelegate = nil;
static NSArray<SCRunningApplication *> *g_appsToExclude = nil;
static NSArray<SCWindow *> *g_windowsToExclude = nil;

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
        SCShareableContent *content = nil;
        if (@available(macOS 13.0, *)) {
            NSLog(@"[SCK] Fetching shareable content...");
            content = [SCShareableContent currentShareableContent];
        }
        if (!content) {
            if (error) { *error = [NSError errorWithDomain:@"ScreenCaptureKitRecorder" code:-2 userInfo:@{NSLocalizedDescriptionKey:@"Failed to get shareable content"}]; }
            NSLog(@"[SCK] Failed to get shareable content");
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
            if (!targetDisplay) { NSLog(@"[SCK] No displays found"); return NO; }
        }
        NSLog(@"[SCK] Using displayID=%u", targetDisplay.displayID);

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

        // Keep strong references to excluded items for the lifetime of the stream
        g_appsToExclude = [appsToExclude copy];
        g_windowsToExclude = [windowsToExclude copy];

        SCContentFilter *filter = nil;
        if (appsToExclude.count > 0) {
            if (@available(macOS 13.0, *)) {
                filter = [[SCContentFilter alloc] initWithDisplay:targetDisplay excludingApplications:(g_appsToExclude ?: @[]) exceptingWindows:(g_windowsToExclude ?: @[])];
            }
        }
        if (!filter) {
            if (@available(macOS 13.0, *)) {
                filter = [[SCContentFilter alloc] initWithDisplay:targetDisplay excludingWindows:(g_windowsToExclude ?: @[])];
            }
        }
        if (!filter) { NSLog(@"[SCK] Failed to create filter"); return NO; }

        SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
        if (captureArea && captureArea[@"width"] && captureArea[@"height"]) {
            CGRect displayFrame = targetDisplay.frame;
            double x = [captureArea[@"x"] doubleValue];
            double yBottom = [captureArea[@"y"] doubleValue];
            double w = [captureArea[@"width"] doubleValue];
            double h = [captureArea[@"height"] doubleValue];

            // Convert bottom-left origin (used by legacy path) to top-left for SC
            double y = displayFrame.size.height - yBottom - h;

            // Clamp to display bounds to avoid invalid sourceRect
            if (w < 1) w = 1; if (h < 1) h = 1;
            if (x < 0) x = 0; if (y < 0) y = 0;
            if (x + w > displayFrame.size.width) w = MAX(1, displayFrame.size.width - x);
            if (y + h > displayFrame.size.height) h = MAX(1, displayFrame.size.height - y);

            CGRect src = CGRectMake(x, y, w, h);
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
            if (@available(macOS 13.0, *)) {
                cfg.capturesAudio = YES;
            }
        }

        if (@available(macOS 15.0, *)) {
            g_scStream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:nil];
            NSLog(@"[SCK] Stream created. w=%d h=%d cursor=%@ audio=%@", cfg.width, cfg.height, cfg.showsCursor?@"YES":@"NO", (@available(macOS 13.0, *) ? (cfg.capturesAudio?@"YES":@"NO") : @"N/A"));

            SCRecordingOutputConfiguration *recCfg = [[SCRecordingOutputConfiguration alloc] init];
            g_outputURL = [NSURL fileURLWithPath:outputPath];
            recCfg.outputURL = g_outputURL;
            recCfg.outputFileType = AVFileTypeQuickTimeMovie;

            id<SCRecordingOutputDelegate> delegateObject = (id<SCRecordingOutputDelegate>)delegate;
            if (!delegateObject) {
                if (!g_scDelegate) {
                    g_scDelegate = [[ScreenCaptureKitRecorder alloc] init];
                }
                delegateObject = (id<SCRecordingOutputDelegate>)g_scDelegate;
            }
            g_scRecordingOutput = [[SCRecordingOutput alloc] initWithConfiguration:recCfg delegate:delegateObject];

            NSError *addErr = nil;
            BOOL added = [g_scStream addRecordingOutput:g_scRecordingOutput error:&addErr];
            if (!added) {
                NSLog(@"[SCK] addRecordingOutput failed: %@", addErr.localizedDescription);
                if (error) { *error = addErr ?: [NSError errorWithDomain:@"ScreenCaptureKitRecorder" code:-3 userInfo:nil]; }
                g_scRecordingOutput = nil; g_scStream = nil; g_outputURL = nil;
                return NO;
            }

            [g_scStream startCaptureWithCompletionHandler:^(NSError * _Nullable err) {
                if (err) {
                    NSLog(@"[SCK] startCapture error: %@", err.localizedDescription);
                    [g_scStream removeRecordingOutput:g_scRecordingOutput error:nil];
                    g_scRecordingOutput = nil; g_scStream = nil; g_outputURL = nil;
                } else {
                    NSLog(@"[SCK] startCapture OK");
                }
            }];
            // Return immediately; capture will start asynchronously
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



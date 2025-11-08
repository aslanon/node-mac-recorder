#import <napi.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CoreAudio/CoreAudio.h>
#import "logging.h"
#import "sync_timeline.h"

// Import screen capture (ScreenCaptureKit only)
#import "screen_capture_kit.h"

// AVFoundation fallback declarations
extern "C" {
    bool startAVFoundationRecording(const std::string& outputPath,
                                   CGDirectDisplayID displayID,
                                   uint32_t windowID,
                                   CGRect captureRect,
                                   bool captureCursor,
                                   bool includeMicrophone,
                                   bool includeSystemAudio,
                                   NSString* audioDeviceId,
                                   NSString* audioOutputPath,
                                   double frameRate);
    bool stopAVFoundationRecording();
    bool isAVFoundationRecording();
    NSString* getAVFoundationAudioPath();

    NSArray<NSDictionary *> *listCameraDevices();
    bool startCameraRecording(NSString *outputPath, NSString *deviceId, NSError **error);
    bool stopCameraRecording();
    bool isCameraRecording();
    NSString *currentCameraRecordingPath();
    bool waitForCameraRecordingStart(double timeoutSeconds);
    double currentCameraRecordingStartTime(void);
    NSString *currentStandaloneAudioRecordingPath();

    NSArray<NSDictionary *> *listAudioCaptureDevices();
    bool startStandaloneAudioRecording(NSString *outputPath, NSString *preferredDeviceId, NSError **error);
    bool stopStandaloneAudioRecording();
    bool isStandaloneAudioRecording();
    bool hasAudioPermission();

    NSString *ScreenCaptureKitCurrentAudioPath(void);
}

// Cursor tracker function declarations
Napi::Object InitCursorTracker(Napi::Env env, Napi::Object exports);

// Window selector function declarations  
Napi::Object InitWindowSelector(Napi::Env env, Napi::Object exports);

// Window selector overlay functions (external)
extern "C" void hideOverlays();
extern "C" void showOverlays();

@interface MacRecorderDelegate : NSObject
@end

@implementation MacRecorderDelegate
@end

// Global state for recording (ScreenCaptureKit only)
static MacRecorderDelegate *g_delegate = nil;
static bool g_isRecording = false;
static bool g_usingStandaloneAudio = false;
static CFTimeInterval g_recordingStartTime = 0;
static bool g_hasRecordingStartTime = false;
static double g_activeStopLimitSeconds = -1.0;

static void MRMarkRecordingStartTimestamp(void) {
    g_recordingStartTime = CFAbsoluteTimeGetCurrent();
    g_hasRecordingStartTime = true;
}

static double MRComputeElapsedRecordingSeconds(void) {
    if (!g_hasRecordingStartTime) {
        return -1.0;
    }
    CFTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - g_recordingStartTime;
    if (elapsed <= 0.0) {
        return -1.0;
    }
    return (double)elapsed;
}

static void MRResetRecordingStartTimestamp(void) {
    g_hasRecordingStartTime = false;
    g_recordingStartTime = 0;
}

static void MRStoreActiveStopLimit(double seconds) {
    g_activeStopLimitSeconds = seconds;
}

extern "C" double MRActiveStopLimitSeconds(void) {
    return g_activeStopLimitSeconds;
}

extern "C" double MRScreenRecordingStartTimestampSeconds(void) {
    return g_hasRecordingStartTime ? g_recordingStartTime : 0.0;
}

static bool startCameraIfRequested(bool captureCamera,
                                   NSString **cameraOutputPathRef,
                                   NSString *cameraDeviceId,
                                   const std::string &screenOutputPath,
                                   int64_t sessionTimestampMs) {
    if (!captureCamera) {
        return true;
    }
    
    NSString *resolvedOutputPath = cameraOutputPathRef ? *cameraOutputPathRef : nil;
    if (!resolvedOutputPath || [resolvedOutputPath length] == 0) {
        NSString *screenPath = [NSString stringWithUTF8String:screenOutputPath.c_str()];
        NSString *directory = nil;
        if (screenPath && [screenPath length] > 0) {
            directory = [screenPath stringByDeletingLastPathComponent];
        }
        if (!directory || [directory length] == 0) {
            directory = [[NSFileManager defaultManager] currentDirectoryPath];
        }
        int64_t timestampValue = sessionTimestampMs > 0 ? sessionTimestampMs
                               : (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
        NSString *fileName = [NSString stringWithFormat:@"temp_camera_%lld.webm", timestampValue];
        resolvedOutputPath = [directory stringByAppendingPathComponent:fileName];
        MRLog(@"📁 Auto-generated camera path: %@", resolvedOutputPath);
    }
    
    NSError *cameraError = nil;
    bool cameraStarted = startCameraRecording(resolvedOutputPath, cameraDeviceId, &cameraError);
    if (!cameraStarted) {
        if (cameraError) {
            NSLog(@"❌ Failed to start camera recording: %@", cameraError.localizedDescription);
        } else {
            NSLog(@"❌ Failed to start camera recording: Unknown error");
        }
        return false;
    }
    NSString *actualPath = currentCameraRecordingPath();
    if (actualPath && [actualPath length] > 0) {
        resolvedOutputPath = actualPath;
        if (cameraOutputPathRef) {
            *cameraOutputPathRef = actualPath;
        }
    }
    
    MRLog(@"🎥 Camera recording started (output: %@)", resolvedOutputPath);
    return true;
}

static bool startCameraWithConfirmation(bool captureCamera,
                                        NSString **cameraOutputPathRef,
                                        NSString *cameraDeviceId,
                                        const std::string &screenOutputPath,
                                        int64_t sessionTimestampMs) {
    if (!captureCamera) {
        return true;
    }
    if (!startCameraIfRequested(true, cameraOutputPathRef, cameraDeviceId, screenOutputPath, sessionTimestampMs)) {
        return false;
    }
    double cameraWaitTimeout = 3.0;
    if (!waitForCameraRecordingStart(cameraWaitTimeout)) {
        MRLog(@"❌ Camera did not signal recording start within %.1fs", cameraWaitTimeout);
        stopCameraRecording();
        return false;
    }
    MRLog(@"✅ Camera recording confirmed");
    return true;
}

static bool startAudioIfRequested(bool captureAudio,
                                  NSString *audioOutputPath,
                                  NSString *preferredDeviceId) {
    if (!captureAudio) {
        return true;
    }
    if (!audioOutputPath || [audioOutputPath length] == 0) {
        NSLog(@"❌ Audio recording requested but no output path provided");
        return false;
    }
    NSError *audioError = nil;
    bool started = startStandaloneAudioRecording(audioOutputPath, preferredDeviceId, &audioError);
    if (!started) {
        if (audioError) {
            NSLog(@"❌ Failed to start audio recording: %@", audioError.localizedDescription);
        } else {
            NSLog(@"❌ Failed to start audio recording (unknown error)");
        }
        return false;
    }
    g_usingStandaloneAudio = true;
    MRLog(@"🎙️ Standalone audio recording started (output: %@)", audioOutputPath);
    return true;
}

// Helper function to cleanup recording resources
void cleanupRecording() {
    // ScreenCaptureKit cleanup
    if (@available(macOS 12.3, *)) {
        if ([ScreenCaptureKitRecorder isRecording]) {
            [ScreenCaptureKitRecorder stopRecording];
        }
    }
    
    // AVFoundation cleanup (supports both Node.js and Electron)
    if (isAVFoundationRecording()) {
        stopAVFoundationRecording();
    }

    if (isCameraRecording()) {
        stopCameraRecording();
    }
    if (isStandaloneAudioRecording()) {
        stopStandaloneAudioRecording();
    }
    g_usingStandaloneAudio = false;
    
    g_isRecording = false;
    MRSyncConfigure(NO);
    MRResetRecordingStartTimestamp();
    MRStoreActiveStopLimit(-1.0);
}

// NAPI Function: Start Recording
Napi::Value StartRecording(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (info.Length() < 1) {
        Napi::TypeError::New(env, "Output path required").ThrowAsJavaScriptException();
        return env.Null();
    }
    
    // IMPORTANT: Clean up any stale recording state before starting
    // This fixes the issue where macOS 14/13 users get "recording already in progress"
    MRLog(@"🧹 Cleaning up any previous recording state...");
    cleanupRecording();
    MRStoreActiveStopLimit(-1.0);

    if (g_isRecording) {
        MRLog(@"⚠️ Still recording after cleanup - forcing stop");
        return Napi::Boolean::New(env, false);
    }

    // CRITICAL FIX: Check if ScreenCaptureKit is still cleaning up (async stop in progress)
    if (@available(macOS 12.3, *)) {
        extern BOOL isScreenCaptureKitCleaningUp();
        if (isScreenCaptureKitCleaningUp()) {
            MRLog(@"⚠️ ScreenCaptureKit is still stopping previous recording - please wait");
            return Napi::Boolean::New(env, false);
        }
    }
    g_usingStandaloneAudio = false;
    
    std::string outputPath = info[0].As<Napi::String>().Utf8Value();
    
    // Options parsing
    CGRect captureRect = CGRectNull;
    bool captureCursor = false; // Default olarak cursor gizli
    bool includeMicrophone = false; // Default olarak mikrofon kapalı
    bool includeSystemAudio = true; // Default olarak sistem sesi açık
    CGDirectDisplayID displayID = CGMainDisplayID(); // Default ana ekran
    uint32_t windowID = 0; // Default no window selection
    NSString *audioDeviceId = nil; // Default audio device ID
    NSString *systemAudioDeviceId = nil; // System audio device ID
    bool captureCamera = false;
    NSString *cameraDeviceId = nil;
    NSString *cameraOutputPath = nil;
    int64_t sessionTimestamp = 0;
    NSString *audioOutputPath = nil;
    double frameRate = 60.0;
    bool mixAudio = true; // Default: mix mic+system into single track when possible
    double mixMicGain = 0.8;    // default mic priority
    double mixSystemGain = 0.4; // default system lower
    bool preferScreenCaptureKitOption = false; // Allow opting into ScreenCaptureKit
    
    if (info.Length() > 1 && info[1].IsObject()) {
        Napi::Object options = info[1].As<Napi::Object>();

        // Capture area
        if (options.Has("captureArea") && options.Get("captureArea").IsObject()) {
            Napi::Object rectObj = options.Get("captureArea").As<Napi::Object>();
            if (rectObj.Has("x") && rectObj.Has("y") && rectObj.Has("width") && rectObj.Has("height")) {
                captureRect = CGRectMake(
                    rectObj.Get("x").As<Napi::Number>().DoubleValue(),
                    rectObj.Get("y").As<Napi::Number>().DoubleValue(),
                    rectObj.Get("width").As<Napi::Number>().DoubleValue(),
                    rectObj.Get("height").As<Napi::Number>().DoubleValue()
                );
            }
        }
        
        // Capture cursor
        if (options.Has("captureCursor")) {
            captureCursor = options.Get("captureCursor").As<Napi::Boolean>();
        }
        
        // Microphone
        if (options.Has("includeMicrophone")) {
            includeMicrophone = options.Get("includeMicrophone").As<Napi::Boolean>().Value();
        }

        // Audio device ID
        if (options.Has("audioDeviceId") && !options.Get("audioDeviceId").IsNull()) {
            std::string deviceId = options.Get("audioDeviceId").As<Napi::String>().Utf8Value();
            audioDeviceId = [NSString stringWithUTF8String:deviceId.c_str()];
        }

        // System audio
        if (options.Has("includeSystemAudio")) {
            includeSystemAudio = options.Get("includeSystemAudio").As<Napi::Boolean>();
        }
        
        // System audio device ID
        if (options.Has("systemAudioDeviceId") && !options.Get("systemAudioDeviceId").IsNull()) {
            std::string sysDeviceId = options.Get("systemAudioDeviceId").As<Napi::String>().Utf8Value();
            systemAudioDeviceId = [NSString stringWithUTF8String:sysDeviceId.c_str()];
        }

        // Camera capture options
        if (options.Has("captureCamera")) {
            captureCamera = options.Get("captureCamera").As<Napi::Boolean>();
        }
        
        if (options.Has("cameraDeviceId") && !options.Get("cameraDeviceId").IsNull()) {
            std::string cameraDevice = options.Get("cameraDeviceId").As<Napi::String>().Utf8Value();
            cameraDeviceId = [NSString stringWithUTF8String:cameraDevice.c_str()];
        }
        
        if (options.Has("cameraOutputPath") && !options.Get("cameraOutputPath").IsNull()) {
            std::string cameraPath = options.Get("cameraOutputPath").As<Napi::String>().Utf8Value();
            cameraOutputPath = [NSString stringWithUTF8String:cameraPath.c_str()];
        }

        if (options.Has("audioOutputPath") && !options.Get("audioOutputPath").IsNull()) {
            std::string audioPath = options.Get("audioOutputPath").As<Napi::String>().Utf8Value();
            audioOutputPath = [NSString stringWithUTF8String:audioPath.c_str()];
        }

        if (options.Has("sessionTimestamp") && options.Get("sessionTimestamp").IsNumber()) {
            sessionTimestamp = options.Get("sessionTimestamp").As<Napi::Number>().Int64Value();
        }

        // Frame rate
        if (options.Has("frameRate") && options.Get("frameRate").IsNumber()) {
            double fps = options.Get("frameRate").As<Napi::Number>().DoubleValue();
            if (fps > 0) {
                // Clamp to reasonable range
                if (fps < 1.0) fps = 1.0;
                if (fps > 120.0) fps = 120.0;
                frameRate = fps;
            }
        }

        // Optional: allow caller to prefer ScreenCaptureKit when available (macOS 15+)
        if (options.Has("preferScreenCaptureKit")) {
            preferScreenCaptureKitOption = options.Get("preferScreenCaptureKit").As<Napi::Boolean>();
        }

        // Post-process audio mixing toggle (default true)
        if (options.Has("mixAudio")) {
            mixAudio = options.Get("mixAudio").As<Napi::Boolean>();
        }

        // Equal mix or explicit gains
        if (options.Has("equalMix") && options.Get("equalMix").IsBoolean()) {
            bool eq = options.Get("equalMix").As<Napi::Boolean>();
            if (eq) {
                mixMicGain = 0.5;
                mixSystemGain = 0.5;
            }
        }
        if (options.Has("mixGains") && options.Get("mixGains").IsObject()) {
            Napi::Object gains = options.Get("mixGains").As<Napi::Object>();
            if (gains.Has("mic") && gains.Get("mic").IsNumber()) {
                mixMicGain = gains.Get("mic").As<Napi::Number>().DoubleValue();
            }
            if (gains.Has("system") && gains.Get("system").IsNumber()) {
                mixSystemGain = gains.Get("system").As<Napi::Number>().DoubleValue();
            }
            // Clamp
            if (mixMicGain < 0.0) mixMicGain = 0.0;
            if (mixMicGain > 2.0) mixMicGain = 2.0;
            if (mixSystemGain < 0.0) mixSystemGain = 0.0;
            if (mixSystemGain > 2.0) mixSystemGain = 2.0;
        }
        
        // Display ID (accepts either real CGDirectDisplayID or index [0-based or 1-based])
        if (options.Has("displayId") && !options.Get("displayId").IsNull()) {
            double displayIdNum = options.Get("displayId").As<Napi::Number>().DoubleValue();
            
            // First, assume the provided value is a real CGDirectDisplayID
            CGDirectDisplayID candidateID = (CGDirectDisplayID)displayIdNum;
            
            // Verify against active displays
            uint32_t displayCount = 0;
            CGGetActiveDisplayList(0, NULL, &displayCount);
            if (displayCount > 0) {
                CGDirectDisplayID *displays = (CGDirectDisplayID*)malloc(displayCount * sizeof(CGDirectDisplayID));
                CGGetActiveDisplayList(displayCount, displays, &displayCount);
                
                bool matchedByID = false;
                for (uint32_t i = 0; i < displayCount; i++) {
                    if (displays[i] == candidateID) {
                        matchedByID = true;
                        displayID = candidateID;
                        break;
                    }
                }
                
                if (!matchedByID) {
                    // Tolerant mapping: allow passing index instead of CGDirectDisplayID
                    // Try 0-based index
                    int idx0 = (int)displayIdNum;
                    if (idx0 >= 0 && idx0 < (int)displayCount) {
                        displayID = displays[idx0];
                    } else {
                        // Try 1-based index (common in user examples)
                        int idx1 = (int)displayIdNum - 1;
                        if (idx1 >= 0 && idx1 < (int)displayCount) {
                            displayID = displays[idx1];
                        } else {
                            // Fallback to main display
                            displayID = CGMainDisplayID();
                        }
                    }
                }
                
                free(displays);
            }
        }
        
        // Window ID support 
        if (options.Has("windowId") && !options.Get("windowId").IsNull()) {
            windowID = options.Get("windowId").As<Napi::Number>().Uint32Value();
            MRLog(@"🪟 Window ID specified: %u", windowID);
        }
    }

    if (captureCamera && sessionTimestamp == 0) {
        // Allow native side to auto-generate timestamp if not provided
        sessionTimestamp = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
    }

    bool captureMicrophone = includeMicrophone;
    bool captureSystemAudio = includeSystemAudio;
    bool screenCaptureSupportsMic = false;
    if (@available(macOS 15.0, *)) {
        screenCaptureSupportsMic = true;
    }
    bool captureStandaloneMic = captureMicrophone && !screenCaptureSupportsMic;
    bool captureScreenAudio = captureSystemAudio || (screenCaptureSupportsMic && captureMicrophone);
    bool captureAnyAudio = captureScreenAudio || captureStandaloneMic;
    MRSyncConfigure(captureAnyAudio);
    NSString *preferredAudioDeviceId = nil;
    if (captureSystemAudio && systemAudioDeviceId && [systemAudioDeviceId length] > 0) {
        preferredAudioDeviceId = systemAudioDeviceId;
    } else if (captureMicrophone && audioDeviceId && [audioDeviceId length] > 0) {
        preferredAudioDeviceId = audioDeviceId;
    }

    // Auto-generate audio output path if audio is requested but no path provided
    if (captureAnyAudio && (!audioOutputPath || [audioOutputPath length] == 0)) {
        NSString *screenPath = [NSString stringWithUTF8String:outputPath.c_str()];
        NSString *directory = nil;
        if (screenPath && [screenPath length] > 0) {
            directory = [screenPath stringByDeletingLastPathComponent];
        }
        if (!directory || [directory length] == 0) {
            directory = [[NSFileManager defaultManager] currentDirectoryPath];
        }
        int64_t ts = sessionTimestamp != 0 ? sessionTimestamp : (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
        NSString *fileName = [NSString stringWithFormat:@"temp_audio_%lld.mov", ts];
        audioOutputPath = [directory stringByAppendingPathComponent:fileName];
        MRLog(@"📁 Auto-generated audio path: %@", audioOutputPath);
    }

    NSString *standaloneMicOutputPath = nil;
    if (captureStandaloneMic) {
        if (captureScreenAudio) {
            // Avoid clashing writers: use a different file for standalone mic when SCK also writes audio
            NSString *screenPath = [NSString stringWithUTF8String:outputPath.c_str()];
            NSString *directory = screenPath && [screenPath length] > 0
                ? [screenPath stringByDeletingLastPathComponent]
                : [[NSFileManager defaultManager] currentDirectoryPath];
            int64_t tsMic = sessionTimestamp != 0 ? sessionTimestamp : (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
            NSString *micFileName = [NSString stringWithFormat:@"temp_audio_mic_%lld.mov", tsMic];
            standaloneMicOutputPath = [directory stringByAppendingPathComponent:micFileName];
        } else {
            standaloneMicOutputPath = audioOutputPath;
        }

        // Always use microphone device ID for standalone mic capture
        if (!startAudioIfRequested(true, standaloneMicOutputPath, audioDeviceId)) {
            MRLog(@"❌ Standalone microphone recording failed to start");
            return Napi::Boolean::New(env, false);
        }
        g_usingStandaloneAudio = true;
        MRLog(@"🎙️ Standalone microphone recording started (audio-only)");
    }

    @try {
        // Smart Recording Selection: ScreenCaptureKit vs Alternative
        MRLog(@"🎯 Smart Recording Engine Selection");
        
        // Electron environment detection (removed disable logic)
        BOOL isElectron = (NSBundle.mainBundle.bundleIdentifier && 
                          [NSBundle.mainBundle.bundleIdentifier containsString:@"electron"]) ||
                         (NSProcessInfo.processInfo.processName && 
                          [NSProcessInfo.processInfo.processName containsString:@"Electron"]) ||
                         (NSProcessInfo.processInfo.environment[@"ELECTRON_RUN_AS_NODE"] != nil) ||
                         (NSBundle.mainBundle.bundlePath && 
                          [NSBundle.mainBundle.bundlePath containsString:@"Electron"]);
        
        // Check macOS version for ScreenCaptureKit compatibility
        NSOperatingSystemVersion osVersion = [[NSProcessInfo processInfo] operatingSystemVersion];
        BOOL isM15Plus = (osVersion.majorVersion >= 15);
        BOOL isM14Plus = (osVersion.majorVersion >= 14);
        BOOL isM13Plus = (osVersion.majorVersion >= 13);

        MRLog(@"🖥️ macOS Version: %ld.%ld.%ld",
              (long)osVersion.majorVersion, (long)osVersion.minorVersion, (long)osVersion.patchVersion);

        if (isElectron) {
            MRLog(@"⚡ Electron environment detected");
        }

        // Allow preferring ScreenCaptureKit via env or option; allow forcing AVFoundation
        BOOL preferSCKEnv = (getenv("PREFER_SCREENCAPTUREKIT") != NULL) ||
                            (getenv("USE_SCREENCAPTUREKIT") != NULL) ||
                            (getenv("FORCE_SCREENCAPTUREKIT") != NULL) ||
                            preferScreenCaptureKitOption;
        BOOL forceAVFoundationEnv = (getenv("FORCE_AVFOUNDATION") != NULL);

        // POLICY (per request): On macOS 14+ always try ScreenCaptureKit first (Electron included),
        // then gracefully fall back to AVFoundation if unavailable/fails.
        BOOL tryScreenCaptureKit = (isM14Plus || isM15Plus) && !forceAVFoundationEnv;

        MRLog(@"🔧 FRAMEWORK SELECTION INPUTS:");
        MRLog(@"   Environment: %@", isElectron ? @"Electron" : @"Node.js");
        MRLog(@"   macOS: %ld.%ld.%ld", (long)osVersion.majorVersion, (long)osVersion.minorVersion, (long)osVersion.patchVersion);
        MRLog(@"   preferSCK(env|option): %@", preferSCKEnv ? @"YES" : @"NO");
        MRLog(@"   forceAV(env): %@", forceAVFoundationEnv ? @"YES" : @"NO");

        if (tryScreenCaptureKit) {
            if (isElectron) {
                MRLog(@"⚡ ELECTRON: macOS 14+ → trying ScreenCaptureKit first");
            } else {
                MRLog(@"✅ macOS 14+ Node.js → using ScreenCaptureKit");
            }
            
            // Try ScreenCaptureKit with extensive safety measures
            @try {
                if (@available(macOS 12.3, *)) {
                if ([ScreenCaptureKitRecorder isScreenCaptureKitAvailable]) {
                    MRLog(@"✅ ScreenCaptureKit availability check passed");
                    MRLog(@"🎯 Using ScreenCaptureKit - overlay windows will be automatically excluded");
                    
                    // Create configuration for ScreenCaptureKit
                NSMutableDictionary *sckConfig = [NSMutableDictionary dictionary];
                sckConfig[@"displayId"] = @(displayID);
                sckConfig[@"windowId"] = @(windowID);
                sckConfig[@"captureCursor"] = @(captureCursor);
                sckConfig[@"includeSystemAudio"] = @(captureScreenAudio);
                sckConfig[@"includeMicrophone"] = @((screenCaptureSupportsMic && captureMicrophone) ? YES : NO);
                sckConfig[@"audioDeviceId"] = audioDeviceId;
                sckConfig[@"outputPath"] = [NSString stringWithUTF8String:outputPath.c_str()];
                if (audioOutputPath) {
                    sckConfig[@"audioOutputPath"] = audioOutputPath;
                }
                if (audioDeviceId) {
                    sckConfig[@"microphoneDeviceId"] = audioDeviceId;
                }
                if (sessionTimestamp != 0) {
                    sckConfig[@"sessionTimestamp"] = @(sessionTimestamp);
                }
                // Pass requested frame rate and audio mixing preference
                sckConfig[@"frameRate"] = @(frameRate);
                sckConfig[@"mixAudio"] = @(mixAudio);
                sckConfig[@"mixMicGain"] = @((double)mixMicGain);
                sckConfig[@"mixSystemGain"] = @((double)mixSystemGain);
                
                if (!CGRectIsNull(captureRect)) {
                    sckConfig[@"captureRect"] = @{
                        @"x": @(captureRect.origin.x),
                        @"y": @(captureRect.origin.y),
                        @"width": @(captureRect.size.width),
                        @"height": @(captureRect.size.height)
                    };
                }
                
                    // Use ScreenCaptureKit with window exclusion and timeout protection
                    NSError *sckError = nil;

                    // CRITICAL SYNC FIX: Start camera BEFORE ScreenCaptureKit
                    // This allows camera warmup to happen in parallel with async ScreenCaptureKit init
                    if (captureCamera) {
                        MRLog(@"🎥 Starting camera recording BEFORE ScreenCaptureKit (parallel warmup)");
                        if (!startCameraWithConfirmation(true, &cameraOutputPath, cameraDeviceId, outputPath, sessionTimestamp)) {
                            MRLog(@"❌ Camera failed to start - aborting recording");
                            return Napi::Boolean::New(env, false);
                        }
                    }

                    // Set timeout for ScreenCaptureKit initialization
                    // Attempt to start ScreenCaptureKit with safety wrapper
                    @try {
                        MRLog(@"🎯 SYNC: Starting ScreenCaptureKit recording");
                        if ([ScreenCaptureKitRecorder startRecordingWithConfiguration:sckConfig
                                                                             delegate:g_delegate
                                                                                error:&sckError]) {

                            // ScreenCaptureKit başlatma başarılı - validation yapmıyoruz
                            MRLog(@"🎬 RECORDING METHOD: ScreenCaptureKit");
                            MRLog(@"✅ SYNC: ScreenCaptureKit recording started successfully");

                            g_isRecording = true;
                            MRMarkRecordingStartTimestamp();

                            return Napi::Boolean::New(env, true);
                        } else {
                            NSLog(@"❌ ScreenCaptureKit failed to start");
                            NSLog(@"❌ Error: %@", sckError ? sckError.localizedDescription : @"Unknown error");
                        }
                    } @catch (NSException *sckException) {
                        NSLog(@"❌ Exception during ScreenCaptureKit startup: %@", sckException.reason);

                    // Cleanup camera on exception
                    if (isCameraRecording()) {
                        stopCameraRecording();
                    }
                }
                    NSLog(@"❌ ScreenCaptureKit failed or unsafe - will fallback to AVFoundation");
                    
                } else {
                    NSLog(@"❌ ScreenCaptureKit availability check failed - will fallback to AVFoundation");
                }
                } else {
                    NSLog(@"❌ ScreenCaptureKit not available on this macOS version - falling back to AVFoundation");
                }
            } @catch (NSException *availabilityException) {
                NSLog(@"❌ Exception during ScreenCaptureKit availability check - will fallback to AVFoundation: %@", availabilityException.reason);
            }
            
            // If we reach here, ScreenCaptureKit failed, so fall through to AVFoundation
            MRLog(@"⏭️ ScreenCaptureKit failed - falling back to AVFoundation");
        } else {
            // macOS 14/13 or forced AVFoundation → ALWAYS use AVFoundation (Electron supported!)
            if (isElectron) {
                if (isM14Plus) {
                    MRLog(@"⚡ ELECTRON PRIORITY: macOS 14/13 Electron → AVFoundation with full support");
                } else if (isM13Plus) {
                    MRLog(@"⚡ ELECTRON PRIORITY: macOS 13 Electron → AVFoundation with limited features");
                }
            } else {
                if (isM14Plus) {
                    MRLog(@"🎯 macOS 14 Node.js → using AVFoundation (primary method)");
                } else if (isM13Plus) {
                    MRLog(@"🎯 macOS 13 Node.js → using AVFoundation (limited features)");  
                }
            }
            
            if (!isM13Plus) {
                NSLog(@"❌ macOS version too old (< 13.0) - Not supported");
                return Napi::Boolean::New(env, false);
            }
            
            // DIRECT AVFoundation for all environments (Node.js + Electron)
            MRLog(@"⏭️ Using AVFoundation directly - supports both Node.js and Electron");
        }
        
        // AVFoundation recording (either fallback from ScreenCaptureKit or direct)
        MRLog(@"🎥 Starting AVFoundation recording...");

        @try {
            // Import AVFoundation recording functions (if available)
            extern bool startAVFoundationRecording(const std::string& outputPath,
                                                   CGDirectDisplayID displayID,
                                                   uint32_t windowID,
                                                   CGRect captureRect,
                                                   bool captureCursor,
                                                   bool includeMicrophone,
                                                   bool includeSystemAudio,
                                                   NSString* audioDeviceId,
                                                   NSString* audioOutputPath,
                                                   double frameRate);

            MRLog(@"🎯 SYNC: Starting screen recording");
            bool avResult = startAVFoundationRecording(outputPath, displayID, windowID, captureRect,
                                                      captureCursor, includeMicrophone, includeSystemAudio,
                                                      audioDeviceId, audioOutputPath, frameRate);

            if (avResult) {
                MRLog(@"🎥 RECORDING METHOD: AVFoundation");
                MRLog(@"✅ SYNC: Screen recording started successfully");

                if (captureCamera) {
                    MRLog(@"🎥 Starting camera recording for AVFoundation fallback");
                    if (!startCameraWithConfirmation(true, &cameraOutputPath, cameraDeviceId, outputPath, sessionTimestamp)) {
                        MRLog(@"❌ Camera failed to start for AVFoundation - stopping");
                        stopAVFoundationRecording();
                        return Napi::Boolean::New(env, false);
                    }
                }

                // NOTE: Audio is handled internally by AVFoundation, no need for standalone audio
                // AVFoundation integrates audio recording directly

                g_isRecording = true;
                MRMarkRecordingStartTimestamp();
                MRStoreActiveStopLimit(-1.0);
                return Napi::Boolean::New(env, true);
            } else {
                NSLog(@"❌ AVFoundation recording failed to start");
                NSLog(@"❌ Check permissions and output path validity");
            }
        } @catch (NSException *avException) {
            NSLog(@"❌ Exception during AVFoundation startup: %@", avException.reason);
            NSLog(@"❌ Stack trace: %@", [avException callStackSymbols]);

            // Cleanup camera on exception
    if (isCameraRecording()) {
        stopCameraRecording();
    }
        }
        
        // Both ScreenCaptureKit and AVFoundation failed
        NSLog(@"❌ All recording methods failed - no recording available");
        return Napi::Boolean::New(env, false);
        
    } @catch (NSException *exception) {
        cleanupRecording();
        return Napi::Boolean::New(env, false);
    }
}

// NAPI Function: Stop Recording
Napi::Value StopRecording(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    MRLog(@"📞 StopRecording native method called");

    double requestedStopLimit = -1.0;
    bool explicitStopLimit = false;
    if (info.Length() > 0 && info[0].IsNumber()) {
        requestedStopLimit = info[0].As<Napi::Number>().DoubleValue();
        if (requestedStopLimit > 0) {
            explicitStopLimit = true;
            MRLog(@"⏲️ Requested stop limit: %.3f seconds", requestedStopLimit);
        }
    }

    if (!explicitStopLimit) {
        double autoLimit = MRComputeElapsedRecordingSeconds();
        if (autoLimit > 0) {
            requestedStopLimit = autoLimit;
            MRLog(@"⏲️ Auto stop limit applied: %.3f seconds", requestedStopLimit);
        }
    }

    if (requestedStopLimit > 0) {
        MRStoreActiveStopLimit(requestedStopLimit);
        MRSyncSetStopLimitSeconds(requestedStopLimit);
    } else {
        MRStoreActiveStopLimit(-1.0);
        MRSyncSetStopLimitSeconds(-1.0);
    }
    MRResetRecordingStartTimestamp();
    
    // Try ScreenCaptureKit first
    if (@available(macOS 12.3, *)) {
        if ([ScreenCaptureKitRecorder isRecording]) {
            MRLog(@"🛑 Stopping ScreenCaptureKit recording");

            // CRITICAL FIX: Stop camera and audio FIRST (they are synchronous)
            if (isCameraRecording()) {
                MRLog(@"🛑 Stopping camera recording...");
                bool cameraStopped = stopCameraRecording();
                if (cameraStopped) {
                    MRLog(@"✅ Camera stopped successfully");
                } else {
                    MRLog(@"⚠️ Camera stop may have timed out");
                }
            }

            // Stop standalone microphone if it was used (macOS 13/14)
            if (g_usingStandaloneAudio && isStandaloneAudioRecording()) {
                MRLog(@"🛑 Stopping standalone microphone recording...");
                bool micStopped = stopStandaloneAudioRecording();
                if (micStopped) {
                    MRLog(@"✅ Standalone microphone stopped successfully");
                } else {
                    MRLog(@"⚠️ Standalone microphone stop may have timed out");
                }
                g_usingStandaloneAudio = false;
            }

            // Now stop ScreenCaptureKit (asynchronous)
            // WARNING: [ScreenCaptureKitRecorder stopRecording] is ASYNC!
            // It will set g_isRecording = NO in its completion handler
            [ScreenCaptureKitRecorder stopRecording];

            // DO NOT set g_isRecording here - let ScreenCaptureKit completion handler do it
            // Otherwise we have a race condition where JS thinks recording stopped but it's still running
            g_usingStandaloneAudio = false;
            return Napi::Boolean::New(env, true);
        }
    }
    
    // Try AVFoundation fallback (supports both Node.js and Electron)
    extern bool isAVFoundationRecording();
    extern bool stopAVFoundationRecording();
    extern NSString* getAVFoundationAudioPath();
    
    @try {
        if (isAVFoundationRecording()) {
            MRLog(@"🛑 Stopping AVFoundation recording");

            BOOL cameraWasRecording = isCameraRecording();
            BOOL audioWasRecording = g_usingStandaloneAudio && isStandaloneAudioRecording();
            __block BOOL cameraStopResult = YES;
            __block BOOL audioStopResult = YES;

            // SYNC FIX: Create unified stop group for camera and audio
            dispatch_group_t stopGroup = dispatch_group_create();

            // SYNC FIX: Stop camera and audio SIMULTANEOUSLY in parallel
            if (cameraWasRecording) {
                MRLog(@"🛑 SYNC: Stopping camera recording...");
                cameraStopResult = NO;
                dispatch_group_enter(stopGroup);
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                    cameraStopResult = stopCameraRecording() ? YES : NO;
                    dispatch_group_leave(stopGroup);
                });
            }

            if (audioWasRecording) {
                MRLog(@"🛑 SYNC: Stopping audio recording...");
                audioStopResult = NO;
                dispatch_group_enter(stopGroup);
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                    audioStopResult = stopStandaloneAudioRecording() ? YES : NO;
                    dispatch_group_leave(stopGroup);
                });
            }

            bool avFoundationStopped = stopAVFoundationRecording();

            // SYNC FIX: Wait for both camera AND audio to finish (increased timeout to 5s)
            if (cameraWasRecording || audioWasRecording) {
                dispatch_time_t waitTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC));
                long waitResult = dispatch_group_wait(stopGroup, waitTime);
                if (waitResult != 0) {
                    MRLog(@"⚠️ SYNC: Camera/Audio stop did not finish within 5 seconds");
                    if (cameraWasRecording && !cameraStopResult) {
                        MRLog(@"   ⚠️ Camera stop timed out");
                    }
                    if (audioWasRecording && !audioStopResult) {
                        MRLog(@"   ⚠️ Audio stop timed out");
                    }
                } else {
                    if (cameraWasRecording) {
                        MRLog(@"✅ SYNC: Camera stopped successfully");
                    }
                    if (audioWasRecording) {
                        MRLog(@"✅ SYNC: Audio stopped successfully");
                    }
                }
            }

            g_isRecording = false;
            g_usingStandaloneAudio = false;

            if (avFoundationStopped && (!cameraWasRecording || cameraStopResult)) {
                MRLog(@"✅ AVFoundation recording stopped");
                return Napi::Boolean::New(env, true);
            } else {
                NSLog(@"❌ Failed to stop AVFoundation recording");
                return Napi::Boolean::New(env, false);
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"❌ Exception stopping AVFoundation: %@", exception.reason);
        g_isRecording = false;
        g_usingStandaloneAudio = false;
        MRSyncSetStopLimitSeconds(-1.0);
        return Napi::Boolean::New(env, false);
    }
    
    MRLog(@"⚠️ No active recording found to stop");
    if (isCameraRecording()) {
        stopCameraRecording();
    }
    g_isRecording = false;
    MRSyncSetStopLimitSeconds(-1.0);
    return Napi::Boolean::New(env, true);
}



// NAPI Function: Get Windows List
Napi::Value GetWindows(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    Napi::Array windowArray = Napi::Array::New(env);
    
    @try {
        // Get window list
        CFArrayRef windowList = CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID
        );
        
        if (!windowList) {
            return windowArray;
        }
        
        CFIndex windowCount = CFArrayGetCount(windowList);
        uint32_t arrayIndex = 0;
        
        for (CFIndex i = 0; i < windowCount; i++) {
            CFDictionaryRef window = (CFDictionaryRef)CFArrayGetValueAtIndex(windowList, i);
            
            // Get window ID
            CFNumberRef windowIDRef = (CFNumberRef)CFDictionaryGetValue(window, kCGWindowNumber);
            if (!windowIDRef) continue;
            
            uint32_t windowID;
            CFNumberGetValue(windowIDRef, kCFNumberSInt32Type, &windowID);
            
            // Get window name
            CFStringRef windowNameRef = (CFStringRef)CFDictionaryGetValue(window, kCGWindowName);
            std::string windowName = "";
            if (windowNameRef) {
                const char* windowNameCStr = CFStringGetCStringPtr(windowNameRef, kCFStringEncodingUTF8);
                if (windowNameCStr) {
                    windowName = std::string(windowNameCStr);
                } else {
                    // Fallback for non-ASCII characters
                    CFIndex length = CFStringGetLength(windowNameRef);
                    CFIndex maxSize = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
                    char* buffer = (char*)malloc(maxSize);
                    if (CFStringGetCString(windowNameRef, buffer, maxSize, kCFStringEncodingUTF8)) {
                        windowName = std::string(buffer);
                    }
                    free(buffer);
                }
            }
            
            // Get application name
            CFStringRef appNameRef = (CFStringRef)CFDictionaryGetValue(window, kCGWindowOwnerName);
            std::string appName = "";
            if (appNameRef) {
                const char* appNameCStr = CFStringGetCStringPtr(appNameRef, kCFStringEncodingUTF8);
                if (appNameCStr) {
                    appName = std::string(appNameCStr);
                } else {
                    CFIndex length = CFStringGetLength(appNameRef);
                    CFIndex maxSize = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
                    char* buffer = (char*)malloc(maxSize);
                    if (CFStringGetCString(appNameRef, buffer, maxSize, kCFStringEncodingUTF8)) {
                        appName = std::string(buffer);
                    }
                    free(buffer);
                }
            }
            
            // Get window bounds
            CFDictionaryRef boundsRef = (CFDictionaryRef)CFDictionaryGetValue(window, kCGWindowBounds);
            CGRect bounds = CGRectZero;
            if (boundsRef) {
                CGRectMakeWithDictionaryRepresentation(boundsRef, &bounds);
            }
            
            // Skip windows without name or very small windows
            if (windowName.empty() || bounds.size.width < 50 || bounds.size.height < 50) {
                continue;
            }
            
            // Create window object
            Napi::Object windowObj = Napi::Object::New(env);
            windowObj.Set("id", Napi::Number::New(env, windowID));
            windowObj.Set("name", Napi::String::New(env, windowName));
            windowObj.Set("appName", Napi::String::New(env, appName));
            windowObj.Set("x", Napi::Number::New(env, bounds.origin.x));
            windowObj.Set("y", Napi::Number::New(env, bounds.origin.y));
            windowObj.Set("width", Napi::Number::New(env, bounds.size.width));
            windowObj.Set("height", Napi::Number::New(env, bounds.size.height));
            
            windowArray.Set(arrayIndex++, windowObj);
        }
        
        CFRelease(windowList);
        return windowArray;
        
    } @catch (NSException *exception) {
        return windowArray;
    }
}

// NAPI Function: Get Audio Devices
Napi::Value GetAudioDevices(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        NSArray<NSDictionary *> *devices = listAudioCaptureDevices();
        if (!devices) {
            return Napi::Array::New(env, 0);
        }
        
        Napi::Array result = Napi::Array::New(env, devices.count);
        for (NSUInteger i = 0; i < devices.count; i++) {
            NSDictionary *device = devices[i];
            if (![device isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            Napi::Object deviceObj = Napi::Object::New(env);
            NSString *deviceId = device[@"id"];
            NSString *deviceName = device[@"name"];
            NSString *manufacturer = device[@"manufacturer"];
            NSNumber *isDefault = device[@"isDefault"];
            NSNumber *transportType = device[@"transportType"];
            
            deviceObj.Set("id", Napi::String::New(env, deviceId ? [deviceId UTF8String] : ""));
            deviceObj.Set("name", Napi::String::New(env, deviceName ? [deviceName UTF8String] : "Unknown Audio Device"));
            if (manufacturer && [manufacturer isKindOfClass:[NSString class]]) {
                deviceObj.Set("manufacturer", Napi::String::New(env, [manufacturer UTF8String]));
            }
            if (isDefault && [isDefault isKindOfClass:[NSNumber class]]) {
                deviceObj.Set("isDefault", Napi::Boolean::New(env, [isDefault boolValue]));
            }
            if (transportType && [transportType isKindOfClass:[NSNumber class]]) {
                deviceObj.Set("transportType", Napi::Number::New(env, [transportType integerValue]));
            }
            result[i] = deviceObj;
        }
        return result;
    } @catch (NSException *exception) {
        return Napi::Array::New(env, 0);
    }
}

Napi::Value GetCameraDevices(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    Napi::Array result = Napi::Array::New(env);
    
    @try {
        @autoreleasepool {
            NSArray<NSDictionary *> *devices = listCameraDevices();
            if (!devices) {
                return result;
            }
            
            NSUInteger index = 0;
            for (id entry in devices) {
                if (![entry isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                
                NSDictionary *camera = (NSDictionary *)entry;
                Napi::Object cameraObj = Napi::Object::New(env);
                
                NSString *identifier = camera[@"id"];
                NSString *name = camera[@"name"];
                NSString *model = camera[@"model"];
                NSString *manufacturer = camera[@"manufacturer"];
                NSString *position = camera[@"position"];
                NSNumber *transportType = camera[@"transportType"];
                NSNumber *isConnected = camera[@"isConnected"];
                NSNumber *isDefault = camera[@"isDefault"];
                NSNumber *hasFlash = camera[@"hasFlash"];
                NSNumber *supportsDepth = camera[@"supportsDepth"];
                
                if (identifier && [identifier isKindOfClass:[NSString class]]) {
                    cameraObj.Set("id", Napi::String::New(env, [identifier UTF8String]));
                } else {
                    cameraObj.Set("id", Napi::String::New(env, ""));
                }
                
                if (name && [name isKindOfClass:[NSString class]]) {
                    cameraObj.Set("name", Napi::String::New(env, [name UTF8String]));
                } else {
                    cameraObj.Set("name", Napi::String::New(env, "Unknown Camera"));
                }
                
                if (model && [model isKindOfClass:[NSString class]]) {
                    cameraObj.Set("model", Napi::String::New(env, [model UTF8String]));
                }
                
                if (manufacturer && [manufacturer isKindOfClass:[NSString class]]) {
                    cameraObj.Set("manufacturer", Napi::String::New(env, [manufacturer UTF8String]));
                }
                
                if (position && [position isKindOfClass:[NSString class]]) {
                    cameraObj.Set("position", Napi::String::New(env, [position UTF8String]));
                }
                
                if (transportType && [transportType isKindOfClass:[NSNumber class]]) {
                    cameraObj.Set("transportType", Napi::Number::New(env, [transportType integerValue]));
                }
                
                if (isConnected && [isConnected isKindOfClass:[NSNumber class]]) {
                    cameraObj.Set("isConnected", Napi::Boolean::New(env, [isConnected boolValue]));
                }

                if (isDefault && [isDefault isKindOfClass:[NSNumber class]]) {
                    cameraObj.Set("isDefault", Napi::Boolean::New(env, [isDefault boolValue]));
                }

                if (hasFlash && [hasFlash isKindOfClass:[NSNumber class]]) {
                    cameraObj.Set("hasFlash", Napi::Boolean::New(env, [hasFlash boolValue]));
                }
                
                if (supportsDepth && [supportsDepth isKindOfClass:[NSNumber class]]) {
                    cameraObj.Set("supportsDepth", Napi::Boolean::New(env, [supportsDepth boolValue]));
                }
                
                NSDictionary *maxResolution = camera[@"maxResolution"];
                if (maxResolution && [maxResolution isKindOfClass:[NSDictionary class]]) {
                    Napi::Object maxResObj = Napi::Object::New(env);
                    
                    NSNumber *width = maxResolution[@"width"];
                    NSNumber *height = maxResolution[@"height"];
                    NSNumber *frameRate = maxResolution[@"maxFrameRate"];
                    
                    if (width && [width isKindOfClass:[NSNumber class]]) {
                        maxResObj.Set("width", Napi::Number::New(env, [width integerValue]));
                    }
                    if (height && [height isKindOfClass:[NSNumber class]]) {
                        maxResObj.Set("height", Napi::Number::New(env, [height integerValue]));
                    }
                    if (frameRate && [frameRate isKindOfClass:[NSNumber class]]) {
                        maxResObj.Set("maxFrameRate", Napi::Number::New(env, [frameRate doubleValue]));
                    }
                    
                    cameraObj.Set("maxResolution", maxResObj);
                }
                
                result[index++] = cameraObj;
            }
        }
        
        return result;
    } @catch (NSException *exception) {
        NSLog(@"❌ Exception while listing camera devices: %@", exception.reason);
        return result;
    }
}

Napi::Value GetCameraRecordingPath(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    @try {
        NSString *path = currentCameraRecordingPath();
        if (!path || [path length] == 0) {
            return env.Null();
        }
        return Napi::String::New(env, [path UTF8String]);
    } @catch (NSException *exception) {
        NSLog(@"❌ Exception while reading camera output path: %@", exception.reason);
        return env.Null();
    }
}

Napi::Value GetAudioRecordingPath(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    @try {
        NSString *path = nil;
        if (@available(macOS 12.3, *)) {
            path = ScreenCaptureKitCurrentAudioPath();
        }
        if ([path isKindOfClass:[NSArray class]]) {
            path = [(NSArray *)path firstObject];
        }
        if (!path || [path length] == 0) {
            path = currentStandaloneAudioRecordingPath();
        }
        if (!path || [path length] == 0) {
            path = getAVFoundationAudioPath();
        }
        if (!path || [path length] == 0) {
            return env.Null();
        }
        return Napi::String::New(env, [path UTF8String]);
    } @catch (NSException *exception) {
        NSLog(@"❌ Exception while reading audio output path: %@", exception.reason);
        return env.Null();
    }
}

// NAPI Function: Get Displays
Napi::Value GetDisplays(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        // Get active displays directly using CGDirectDisplayID
        NSMutableArray *displays = [NSMutableArray array];
        CGDirectDisplayID activeDisplays[32];
        uint32_t displayCount;
        CGGetActiveDisplayList(32, activeDisplays, &displayCount);
        
        for (uint32_t i = 0; i < displayCount; i++) {
            CGDirectDisplayID displayID = activeDisplays[i];
            CGRect displayBounds = CGDisplayBounds(displayID);
            bool isPrimary = (displayID == CGMainDisplayID());
            
            NSDictionary *displayInfo = @{
                @"id": @(displayID),  // Direct CGDirectDisplayID
                @"name": [NSString stringWithFormat:@"Display %u", (unsigned int)(i + 1)],
                @"width": @((int)displayBounds.size.width),
                @"height": @((int)displayBounds.size.height),
                @"x": @((int)displayBounds.origin.x),
                @"y": @((int)displayBounds.origin.y),
                @"isPrimary": @(isPrimary)
            };
            [displays addObject:displayInfo];
        }
        Napi::Array result = Napi::Array::New(env, displays.count);
        
        // NSLog(@"Found %lu displays", (unsigned long)displays.count);

        for (NSUInteger i = 0; i < displays.count; i++) {
            NSDictionary *display = displays[i];
            // NSLog(@"Display %lu: ID=%u, Name=%@, Size=%@x%@",
            //       (unsigned long)i,
            //       [display[@"id"] unsignedIntValue],
            //       display[@"name"],
            //       display[@"width"],
            //       display[@"height"]);
                  
            Napi::Object displayObj = Napi::Object::New(env);
            displayObj.Set("id", Napi::Number::New(env, [display[@"id"] unsignedIntValue]));
            displayObj.Set("name", Napi::String::New(env, [display[@"name"] UTF8String]));
            displayObj.Set("width", Napi::Number::New(env, [display[@"width"] doubleValue]));
            displayObj.Set("height", Napi::Number::New(env, [display[@"height"] doubleValue]));
            displayObj.Set("x", Napi::Number::New(env, [display[@"x"] doubleValue]));
            displayObj.Set("y", Napi::Number::New(env, [display[@"y"] doubleValue]));
            displayObj.Set("isPrimary", Napi::Boolean::New(env, [display[@"isPrimary"] boolValue]));
            result[i] = displayObj;
        }
        
        return result;
        
    } @catch (NSException *exception) {
        NSLog(@"Exception in GetDisplays: %@", exception);
        return Napi::Array::New(env, 0);
    }
}

// NAPI Function: Get Recording Status
Napi::Value GetRecordingStatus(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    // CRITICAL: For ScreenCaptureKit, ONLY return true when FULLY initialized
    // This ensures camera/cursor sync doesn't start until ScreenCaptureKit is ready
    if (@available(macOS 12.3, *)) {
        BOOL sckRecording = [ScreenCaptureKitRecorder isRecording];
        if (sckRecording) {
            // Return true ONLY if fully initialized (first frames captured)
            BOOL fullyInit = [ScreenCaptureKitRecorder isFullyInitialized];
            static int logCount = 0;
            if (logCount++ < 3) {
                NSLog(@"🔍 GetRecordingStatus: SCK recording=%d, fullyInit=%d", sckRecording, fullyInit);
            }
            return Napi::Boolean::New(env, fullyInit);
        }
    }

    // Check AVFoundation (supports both Node.js and Electron)
    if (isAVFoundationRecording()) {
        NSLog(@"🔍 GetRecordingStatus: Using AVFoundation → true");
        return Napi::Boolean::New(env, true);
    }

    // Fallback to global recording flag
    NSLog(@"🔍 GetRecordingStatus: Fallback g_isRecording=%d", g_isRecording);
    return Napi::Boolean::New(env, g_isRecording);
}

// NAPI Function: Get Window Thumbnail
Napi::Value GetWindowThumbnail(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (info.Length() < 1) {
        Napi::TypeError::New(env, "Window ID is required").ThrowAsJavaScriptException();
        return env.Null();
    }
    
    uint32_t windowID = info[0].As<Napi::Number>().Uint32Value();
    
    // Optional parameters
    int maxWidth = 300;  // Default thumbnail width
    int maxHeight = 200; // Default thumbnail height
    
    if (info.Length() >= 2 && !info[1].IsNull()) {
        maxWidth = info[1].As<Napi::Number>().Int32Value();
    }
    if (info.Length() >= 3 && !info[2].IsNull()) {
        maxHeight = info[2].As<Napi::Number>().Int32Value();
    }
    
    @try {
        // Create window image
        CGImageRef windowImage = CGWindowListCreateImage(
            CGRectNull,
            kCGWindowListOptionIncludingWindow,
            windowID,
            kCGWindowImageBoundsIgnoreFraming | kCGWindowImageShouldBeOpaque
        );
        
        if (!windowImage) {
            return env.Null();
        }
        
        // Get original dimensions
        size_t originalWidth = CGImageGetWidth(windowImage);
        size_t originalHeight = CGImageGetHeight(windowImage);
        
        // Calculate scaled dimensions maintaining aspect ratio
        double scaleX = (double)maxWidth / originalWidth;
        double scaleY = (double)maxHeight / originalHeight;
        double scale = std::min(scaleX, scaleY);
        
        size_t thumbnailWidth = (size_t)(originalWidth * scale);
        size_t thumbnailHeight = (size_t)(originalHeight * scale);
        
        // Create scaled image
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(
            NULL,
            thumbnailWidth,
            thumbnailHeight,
            8,
            thumbnailWidth * 4,
            colorSpace,
            kCGImageAlphaPremultipliedLast
        );
        
        if (context) {
            CGContextDrawImage(context, CGRectMake(0, 0, thumbnailWidth, thumbnailHeight), windowImage);
            CGImageRef thumbnailImage = CGBitmapContextCreateImage(context);
            
            if (thumbnailImage) {
                // Convert to PNG data
                NSBitmapImageRep *imageRep = [[NSBitmapImageRep alloc] initWithCGImage:thumbnailImage];
                NSData *pngData = [imageRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                
                if (pngData) {
                    // Convert to Base64
                    NSString *base64String = [pngData base64EncodedStringWithOptions:0];
                    std::string base64Std = [base64String UTF8String];
                    
                    CGImageRelease(thumbnailImage);
                    CGContextRelease(context);
                    CGColorSpaceRelease(colorSpace);
                    CGImageRelease(windowImage);
                    
                    return Napi::String::New(env, base64Std);
                }
                
                CGImageRelease(thumbnailImage);
            }
            
            CGContextRelease(context);
        }
        
        CGColorSpaceRelease(colorSpace);
        CGImageRelease(windowImage);
        
        return env.Null();
        
    } @catch (NSException *exception) {
        return env.Null();
    }
}

// NAPI Function: Get Display Thumbnail
Napi::Value GetDisplayThumbnail(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    if (info.Length() < 1) {
        Napi::TypeError::New(env, "Display ID is required").ThrowAsJavaScriptException();
        return env.Null();
    }
    
    uint32_t displayID = info[0].As<Napi::Number>().Uint32Value();
    
    // Optional parameters
    int maxWidth = 300;  // Default thumbnail width
    int maxHeight = 200; // Default thumbnail height
    
    if (info.Length() >= 2 && !info[1].IsNull()) {
        maxWidth = info[1].As<Napi::Number>().Int32Value();
    }
    if (info.Length() >= 3 && !info[2].IsNull()) {
        maxHeight = info[2].As<Napi::Number>().Int32Value();
    }
    
    @try {
        // Verify display exists
        CGDirectDisplayID activeDisplays[32];
        uint32_t displayCount;
        CGError err = CGGetActiveDisplayList(32, activeDisplays, &displayCount);
        
        if (err != kCGErrorSuccess) {
            NSLog(@"Failed to get active display list: %d", err);
            return env.Null();
        }
        
        bool displayFound = false;
        for (uint32_t i = 0; i < displayCount; i++) {
            if (activeDisplays[i] == displayID) {
                displayFound = true;
                break;
            }
        }
        
        if (!displayFound) {
            NSLog(@"Display ID %u not found in active displays", displayID);
            return env.Null();
        }
        
        // Create display image
        CGImageRef displayImage = CGDisplayCreateImage(displayID);
        
        if (!displayImage) {
            NSLog(@"CGDisplayCreateImage failed for display ID: %u", displayID);
            return env.Null();
        }
        
        // Get original dimensions
        size_t originalWidth = CGImageGetWidth(displayImage);
        size_t originalHeight = CGImageGetHeight(displayImage);
        
        NSLog(@"Original dimensions: %zux%zu", originalWidth, originalHeight);
        
        // Calculate scaled dimensions maintaining aspect ratio
        double scaleX = (double)maxWidth / originalWidth;
        double scaleY = (double)maxHeight / originalHeight;
        double scale = std::min(scaleX, scaleY);
        
        size_t thumbnailWidth = (size_t)(originalWidth * scale);
        size_t thumbnailHeight = (size_t)(originalHeight * scale);
        
        NSLog(@"Thumbnail dimensions: %zux%zu (scale: %f)", thumbnailWidth, thumbnailHeight, scale);
        
        // Create scaled image
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(
            NULL,
            thumbnailWidth,
            thumbnailHeight,
            8,
            thumbnailWidth * 4,
            colorSpace,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
        );
        
        if (!context) {
            NSLog(@"Failed to create bitmap context");
            CGImageRelease(displayImage);
            CGColorSpaceRelease(colorSpace);
            return env.Null();
        }
        
        // Set interpolation quality for better scaling
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        
        // Draw the image
        CGContextDrawImage(context, CGRectMake(0, 0, thumbnailWidth, thumbnailHeight), displayImage);
        CGImageRef thumbnailImage = CGBitmapContextCreateImage(context);
        
        if (!thumbnailImage) {
            NSLog(@"Failed to create thumbnail image");
            CGContextRelease(context);
            CGImageRelease(displayImage);
            CGColorSpaceRelease(colorSpace);
            return env.Null();
        }
        
        // Convert to PNG data
        NSBitmapImageRep *imageRep = [[NSBitmapImageRep alloc] initWithCGImage:thumbnailImage];
        NSDictionary *properties = @{NSImageCompressionFactor: @0.8};
        NSData *pngData = [imageRep representationUsingType:NSBitmapImageFileTypePNG properties:properties];
        
        if (!pngData) {
            NSLog(@"Failed to convert image to PNG data");
            CGImageRelease(thumbnailImage);
            CGContextRelease(context);
            CGImageRelease(displayImage);
            CGColorSpaceRelease(colorSpace);
            return env.Null();
        }
        
        // Convert to Base64
        NSString *base64String = [pngData base64EncodedStringWithOptions:0];
        std::string base64Std = [base64String UTF8String];
        
        NSLog(@"Successfully created thumbnail with base64 length: %lu", (unsigned long)base64Std.length());
        
        // Cleanup
        CGImageRelease(thumbnailImage);
        CGContextRelease(context);
        CGColorSpaceRelease(colorSpace);
        CGImageRelease(displayImage);
        
        return Napi::String::New(env, base64Std);
        
    } @catch (NSException *exception) {
        NSLog(@"Exception in GetDisplayThumbnail: %@", exception);
        return env.Null();
    }
}

// NAPI Function: Check Permissions
Napi::Value CheckPermissions(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        // Determine which framework will be used (same logic as startRecording)
        NSOperatingSystemVersion osVersion = [[NSProcessInfo processInfo] operatingSystemVersion];
        BOOL isM15Plus = (osVersion.majorVersion >= 15);
        BOOL isM14Plus = (osVersion.majorVersion >= 14);
        BOOL isM13Plus = (osVersion.majorVersion >= 13);
        
        // Electron detection and preference flags (mirror StartRecording logic)
        BOOL isElectron = (NSBundle.mainBundle.bundleIdentifier && 
                          [NSBundle.mainBundle.bundleIdentifier containsString:@"electron"]) ||
                         (NSProcessInfo.processInfo.processName && 
                          [NSProcessInfo.processInfo.processName containsString:@"Electron"]) ||
                         (NSProcessInfo.processInfo.environment[@"ELECTRON_RUN_AS_NODE"] != nil) ||
                         (NSBundle.mainBundle.bundlePath && 
                          [NSBundle.mainBundle.bundlePath containsString:@"Electron"]);

        BOOL preferSCKEnv = (getenv("PREFER_SCREENCAPTUREKIT") != NULL) ||
                            (getenv("USE_SCREENCAPTUREKIT") != NULL) ||
                            (getenv("FORCE_SCREENCAPTUREKIT") != NULL);

        NSLog(@"🔒 Permission check for macOS %ld.%ld.%ld", 
              (long)osVersion.majorVersion, (long)osVersion.minorVersion, (long)osVersion.patchVersion);
        
        // Determine which framework will be used (same policy as StartRecording)
        BOOL forceAVFoundationEnv = (getenv("FORCE_AVFOUNDATION") != NULL);
        BOOL willUseScreenCaptureKit = (isM14Plus && !forceAVFoundationEnv);
        BOOL willUseAVFoundation = (!willUseScreenCaptureKit && (isM13Plus || isM14Plus));
        
        if (willUseScreenCaptureKit) {
            NSLog(@"🎯 Will use ScreenCaptureKit - checking ScreenCaptureKit permissions");
        } else if (willUseAVFoundation) {
            NSLog(@"🎯 Will use AVFoundation - checking AVFoundation permissions");
        } else {
            NSLog(@"❌ No compatible recording framework available");
            return Napi::Boolean::New(env, false);
        }
        
        // Check screen recording permission
        bool hasScreenPermission = false;
        
        if (@available(macOS 14.0, *)) {
            // macOS 14+ - Use CGRequestScreenCaptureAccess for both frameworks
            hasScreenPermission = CGRequestScreenCaptureAccess();
            NSLog(@"🔒 Screen recording permission: %s", hasScreenPermission ? "GRANTED" : "DENIED");
            
            if (!hasScreenPermission) {
                NSLog(@"❌ Screen recording permission DENIED");
                NSLog(@"📝 Please go to System Settings > Privacy & Security > Screen Recording");
                NSLog(@"📝 and enable permission for your application");
            }
        } else if (@available(macOS 10.15, *)) {
            // macOS 10.15-13 - Try to create a minimal display image to test permissions
            CGImageRef testImage = CGDisplayCreateImage(CGMainDisplayID());
            if (testImage) {
                hasScreenPermission = true;
                CGImageRelease(testImage);
                NSLog(@"🔒 Screen recording permission: GRANTED");
            } else {
                hasScreenPermission = false;
                NSLog(@"❌ Screen recording permission: DENIED");
                NSLog(@"📝 Please grant screen recording permission in System Preferences");
            }
        } else {
            // macOS < 10.15 - No permission system for screen recording
            hasScreenPermission = true;
            NSLog(@"🔒 Screen recording: No permission system (macOS < 10.15)");
        }
        
        bool audioPermissionGranted = hasAudioPermission();
        NSLog(@"🔒 Audio permission: %s", audioPermissionGranted ? "GRANTED" : "DENIED");
        if (!audioPermissionGranted) {
            NSLog(@"📝 Grant microphone access in System Settings > Privacy & Security > Microphone");
        }
        
        NSLog(@"🔒 Final permission status:");
        NSLog(@"   Framework: %s", willUseScreenCaptureKit ? "ScreenCaptureKit" : "AVFoundation");
        NSLog(@"   Screen Recording: %s", hasScreenPermission ? "GRANTED" : "DENIED");
        NSLog(@"   Audio: %s", audioPermissionGranted ? "READY" : "NOT READY");
        
        return Napi::Boolean::New(env, hasScreenPermission && audioPermissionGranted);
        
    } @catch (NSException *exception) {
        NSLog(@"❌ Exception in permission check: %@", exception.reason);
        return Napi::Boolean::New(env, false);
    }
}

// Initialize NAPI Module
Napi::Object Init(Napi::Env env, Napi::Object exports) {
    exports.Set(Napi::String::New(env, "startRecording"), Napi::Function::New(env, StartRecording));
    exports.Set(Napi::String::New(env, "stopRecording"), Napi::Function::New(env, StopRecording));

    exports.Set(Napi::String::New(env, "getAudioDevices"), Napi::Function::New(env, GetAudioDevices));
    exports.Set(Napi::String::New(env, "getCameraDevices"), Napi::Function::New(env, GetCameraDevices));
    exports.Set(Napi::String::New(env, "getCameraRecordingPath"), Napi::Function::New(env, GetCameraRecordingPath));
    exports.Set(Napi::String::New(env, "getAudioRecordingPath"), Napi::Function::New(env, GetAudioRecordingPath));
    exports.Set(Napi::String::New(env, "getDisplays"), Napi::Function::New(env, GetDisplays));
    exports.Set(Napi::String::New(env, "getWindows"), Napi::Function::New(env, GetWindows));
    exports.Set(Napi::String::New(env, "getRecordingStatus"), Napi::Function::New(env, GetRecordingStatus));
    exports.Set(Napi::String::New(env, "checkPermissions"), Napi::Function::New(env, CheckPermissions));
    
    // Thumbnail functions
    exports.Set(Napi::String::New(env, "getWindowThumbnail"), Napi::Function::New(env, GetWindowThumbnail));
    exports.Set(Napi::String::New(env, "getDisplayThumbnail"), Napi::Function::New(env, GetDisplayThumbnail));
    
    // Initialize cursor tracker
    InitCursorTracker(env, exports);
    
    // Initialize window selector
    InitWindowSelector(env, exports);
    
    return exports;
}

NODE_API_MODULE(mac_recorder, Init) 

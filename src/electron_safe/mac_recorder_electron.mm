#import <napi.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CoreAudio/CoreAudio.h>

// Electron-safe screen capture headers
#import "screen_capture_electron.h"

// Forward declarations for other modules
Napi::Object InitCursorTrackerElectron(Napi::Env env, Napi::Object exports);
Napi::Object InitWindowSelectorElectron(Napi::Env env, Napi::Object exports);

// Thread-safe recording state with proper synchronization
@interface ElectronSafeRecordingState : NSObject
@property (atomic) BOOL isRecording;
@property (atomic, strong) NSString *outputPath;
@property (atomic, strong) NSDate *startTime;
+ (instancetype)sharedState;
- (void)resetState;
@end

@implementation ElectronSafeRecordingState
+ (instancetype)sharedState {
    static ElectronSafeRecordingState *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[ElectronSafeRecordingState alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        [self resetState];
    }
    return self;
}

- (void)resetState {
    self.isRecording = NO;
    self.outputPath = nil;
    self.startTime = nil;
}
@end

// Electron-safe cleanup function
void electronSafeCleanup() {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [[ElectronSafeRecordingState sharedState] resetState];
            
            // Stop any active recording safely
            if (@available(macOS 12.3, *)) {
                [ElectronSafeScreenCapture stopRecordingSafely];
            }
        } @catch (NSException *e) {
            NSLog(@"⚠️ Safe cleanup exception: %@", e.reason);
        }
    });
}

// NAPI Function: Electron-safe Start Recording
Napi::Value StartRecordingElectronSafe(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        if (info.Length() < 1) {
            Napi::TypeError::New(env, "Output path required").ThrowAsJavaScriptException();
            return env.Null();
        }
        
        ElectronSafeRecordingState *state = [ElectronSafeRecordingState sharedState];
        
        if (state.isRecording) {
            NSLog(@"⚠️ Recording already in progress");
            return Napi::Boolean::New(env, false);
        }
        
        std::string outputPath = info[0].As<Napi::String>().Utf8Value();
        
        // Parse options safely
        NSDictionary *options = @{};
        if (info.Length() > 1 && info[1].IsObject()) {
            Napi::Object optionsObj = info[1].As<Napi::Object>();
            NSMutableDictionary *mutableOptions = [NSMutableDictionary dictionary];
            
            // Extract options with proper type checking
            if (optionsObj.Has("captureCursor")) {
                mutableOptions[@"captureCursor"] = @(optionsObj.Get("captureCursor").As<Napi::Boolean>().Value());
            }
            if (optionsObj.Has("includeMicrophone")) {
                mutableOptions[@"includeMicrophone"] = @(optionsObj.Get("includeMicrophone").As<Napi::Boolean>().Value());
            }
            if (optionsObj.Has("includeSystemAudio")) {
                mutableOptions[@"includeSystemAudio"] = @(optionsObj.Get("includeSystemAudio").As<Napi::Boolean>().Value());
            }
            if (optionsObj.Has("displayId")) {
                mutableOptions[@"displayId"] = @(optionsObj.Get("displayId").As<Napi::Number>().Uint32Value());
            }
            if (optionsObj.Has("windowId")) {
                mutableOptions[@"windowId"] = @(optionsObj.Get("windowId").As<Napi::Number>().Uint32Value());
            }
            
            // Capture area with bounds checking
            if (optionsObj.Has("captureArea") && optionsObj.Get("captureArea").IsObject()) {
                Napi::Object areaObj = optionsObj.Get("captureArea").As<Napi::Object>();
                if (areaObj.Has("x") && areaObj.Has("y") && areaObj.Has("width") && areaObj.Has("height")) {
                    double x = areaObj.Get("x").As<Napi::Number>().DoubleValue();
                    double y = areaObj.Get("y").As<Napi::Number>().DoubleValue();
                    double width = areaObj.Get("width").As<Napi::Number>().DoubleValue();
                    double height = areaObj.Get("height").As<Napi::Number>().DoubleValue();
                    
                    // Validate bounds
                    if (width > 0 && height > 0 && x >= 0 && y >= 0) {
                        mutableOptions[@"captureArea"] = @{
                            @"x": @(x),
                            @"y": @(y),
                            @"width": @(width),
                            @"height": @(height)
                        };
                    }
                }
            }
            
            options = [mutableOptions copy];
        }
        
        // Start recording on main queue for Electron safety
        __block BOOL success = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            @try {
                NSString *nsOutputPath = [NSString stringWithUTF8String:outputPath.c_str()];
                
                if (@available(macOS 12.3, *)) {
                    success = [ElectronSafeScreenCapture startRecordingWithPath:nsOutputPath options:options];
                } else {
                    NSLog(@"❌ ScreenCaptureKit not available on this macOS version");
                    success = NO;
                }
                
                if (success) {
                    state.isRecording = YES;
                    state.outputPath = nsOutputPath;
                    state.startTime = [NSDate date];
                    NSLog(@"✅ Electron-safe recording started: %@", nsOutputPath);
                }
            } @catch (NSException *e) {
                NSLog(@"❌ Recording start exception: %@", e.reason);
                success = NO;
            }
        });
        
        return Napi::Boolean::New(env, success);
        
    } @catch (NSException *e) {
        NSLog(@"❌ Fatal exception in StartRecordingElectronSafe: %@", e.reason);
        electronSafeCleanup();
        Napi::Error::New(env, "Native recording failed").ThrowAsJavaScriptException();
        return env.Null();
    }
}

// NAPI Function: Electron-safe Stop Recording
Napi::Value StopRecordingElectronSafe(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        ElectronSafeRecordingState *state = [ElectronSafeRecordingState sharedState];
        
        if (!state.isRecording) {
            NSLog(@"⚠️ No recording in progress");
            return Napi::Boolean::New(env, false);
        }
        
        __block BOOL success = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            @try {
                if (@available(macOS 12.3, *)) {
                    success = [ElectronSafeScreenCapture stopRecordingSafely];
                }
                
                // Always reset state
                [state resetState];
                
                NSLog(@"✅ Electron-safe recording stopped");
            } @catch (NSException *e) {
                NSLog(@"❌ Recording stop exception: %@", e.reason);
                [state resetState]; // Reset state even on error
                success = NO;
            }
        });
        
        return Napi::Boolean::New(env, success);
        
    } @catch (NSException *e) {
        NSLog(@"❌ Fatal exception in StopRecordingElectronSafe: %@", e.reason);
        electronSafeCleanup();
        Napi::Error::New(env, "Native stop recording failed").ThrowAsJavaScriptException();
        return env.Null();
    }
}

// NAPI Function: Get Recording Status (Electron-safe)
Napi::Value GetRecordingStatusElectronSafe(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        ElectronSafeRecordingState *state = [ElectronSafeRecordingState sharedState];
        
        Napi::Object status = Napi::Object::New(env);
        status.Set("isRecording", Napi::Boolean::New(env, state.isRecording));
        
        if (state.outputPath) {
            status.Set("outputPath", Napi::String::New(env, [state.outputPath UTF8String]));
        }
        
        if (state.startTime) {
            NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:state.startTime];
            status.Set("elapsedTime", Napi::Number::New(env, elapsed));
        }
        
        return status;
        
    } @catch (NSException *e) {
        NSLog(@"❌ Fatal exception in GetRecordingStatusElectronSafe: %@", e.reason);
        Napi::Error::New(env, "Failed to get status").ThrowAsJavaScriptException();
        return env.Null();
    }
}

// NAPI Function: Get Displays (Electron-safe)
Napi::Value GetDisplaysElectronSafe(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        __block NSArray *displays = nil;
        
        dispatch_sync(dispatch_get_main_queue(), ^{
            @try {
                displays = [ElectronSafeScreenCapture getAvailableDisplays];
            } @catch (NSException *e) {
                NSLog(@"❌ Exception getting displays: %@", e.reason);
            }
        });
        
        if (!displays) {
            return Napi::Array::New(env, 0);
        }
        
        Napi::Array result = Napi::Array::New(env, displays.count);
        for (NSUInteger i = 0; i < displays.count; i++) {
            NSDictionary *display = displays[i];
            Napi::Object displayObj = Napi::Object::New(env);
            
            displayObj.Set("id", Napi::Number::New(env, [display[@"id"] unsignedIntValue]));
            displayObj.Set("name", Napi::String::New(env, [display[@"name"] UTF8String]));
            displayObj.Set("width", Napi::Number::New(env, [display[@"width"] intValue]));
            displayObj.Set("height", Napi::Number::New(env, [display[@"height"] intValue]));
            displayObj.Set("x", Napi::Number::New(env, [display[@"x"] intValue]));
            displayObj.Set("y", Napi::Number::New(env, [display[@"y"] intValue]));
            displayObj.Set("isPrimary", Napi::Boolean::New(env, [display[@"isPrimary"] boolValue]));
            
            result.Set(i, displayObj);
        }
        
        return result;
        
    } @catch (NSException *e) {
        NSLog(@"❌ Fatal exception in GetDisplaysElectronSafe: %@", e.reason);
        Napi::Error::New(env, "Failed to get displays").ThrowAsJavaScriptException();
        return env.Null();
    }
}

// NAPI Function: Check Permissions (Electron-safe)
Napi::Value CheckPermissionsElectronSafe(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        __block BOOL hasPermission = NO;
        
        dispatch_sync(dispatch_get_main_queue(), ^{
            @try {
                hasPermission = [ElectronSafeScreenCapture checkPermissions];
            } @catch (NSException *e) {
                NSLog(@"❌ Exception checking permissions: %@", e.reason);
            }
        });
        
        return Napi::Boolean::New(env, hasPermission);
        
    } @catch (NSException *e) {
        NSLog(@"❌ Fatal exception in CheckPermissionsElectronSafe: %@", e.reason);
        return Napi::Boolean::New(env, false);
    }
}

// Module initialization for Electron
Napi::Object InitElectronSafe(Napi::Env env, Napi::Object exports) {
    @try {
        NSLog(@"🔌 Initializing Electron-safe mac-recorder module");
        
        // Export Electron-safe functions
        exports.Set("startRecording", Napi::Function::New(env, StartRecordingElectronSafe));
        exports.Set("stopRecording", Napi::Function::New(env, StopRecordingElectronSafe));
        exports.Set("getRecordingStatus", Napi::Function::New(env, GetRecordingStatusElectronSafe));
        exports.Set("getDisplays", Napi::Function::New(env, GetDisplaysElectronSafe));
        exports.Set("checkPermissions", Napi::Function::New(env, CheckPermissionsElectronSafe));
        
        // Initialize sub-modules safely
        @try {
            InitCursorTrackerElectron(env, exports);
        } @catch (NSException *e) {
            NSLog(@"⚠️ Cursor tracker initialization failed: %@", e.reason);
        }
        
        @try {
            InitWindowSelectorElectron(env, exports);
        } @catch (NSException *e) {
            NSLog(@"⚠️ Window selector initialization failed: %@", e.reason);
        }
        
        NSLog(@"✅ Electron-safe module initialized successfully");
        return exports;
        
    } @catch (NSException *e) {
        NSLog(@"❌ Fatal exception during module initialization: %@", e.reason);
        return exports;
    }
}

// Register the module
NODE_API_MODULE(mac_recorder_electron, InitElectronSafe)

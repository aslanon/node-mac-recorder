#import <napi.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>

// Thread-safe audio device management for Electron
static dispatch_queue_t g_audioQueue = nil;

static void initializeAudioQueue() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_audioQueue = dispatch_queue_create("com.macrecorder.audio.electron", DISPATCH_QUEUE_SERIAL);
    });
}

// NAPI Function: Get Audio Devices (Electron-safe)
Napi::Value GetAudioDevicesElectronSafe(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    
    @try {
        initializeAudioQueue();
        
        __block NSArray *devices = nil;
        
        dispatch_sync(g_audioQueue, ^{
            @try {
                NSMutableArray *audioDevices = [NSMutableArray array];
                
                // Get all audio devices
                AudioObjectPropertyAddress propertyAddress = {
                    kAudioHardwarePropertyDevices,
                    kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMaster
                };
                
                UInt32 dataSize = 0;
                OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, 
                                                               &propertyAddress, 
                                                               0, 
                                                               NULL, 
                                                               &dataSize);
                
                if (status == noErr && dataSize > 0) {
                    UInt32 deviceCount = dataSize / sizeof(AudioDeviceID);
                    AudioDeviceID *audioDeviceIDs = (AudioDeviceID*)malloc(dataSize);
                    
                    status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                                       &propertyAddress,
                                                       0,
                                                       NULL,
                                                       &dataSize,
                                                       audioDeviceIDs);
                    
                    if (status == noErr) {
                        for (UInt32 i = 0; i < deviceCount; i++) {
                            AudioDeviceID deviceID = audioDeviceIDs[i];
                            
                            // Get device name
                            CFStringRef deviceName = NULL;
                            UInt32 nameSize = sizeof(CFStringRef);
                            AudioObjectPropertyAddress nameAddress = {
                                kAudioDevicePropertyDeviceNameCFString,
                                kAudioObjectPropertyScopeGlobal,
                                kAudioObjectPropertyElementMaster
                            };
                            
                            status = AudioObjectGetPropertyData(deviceID,
                                                               &nameAddress,
                                                               0,
                                                               NULL,
                                                               &nameSize,
                                                               &deviceName);
                            
                            if (status == noErr && deviceName) {
                                NSString *name = (__bridge NSString*)deviceName;
                                
                                NSDictionary *deviceInfo = @{
                                    @"id": @(deviceID),
                                    @"name": name,
                                    @"type": @"Audio Device"
                                };
                                
                                [audioDevices addObject:deviceInfo];
                                CFRelease(deviceName);
                            }
                        }
                    }
                    
                    free(audioDeviceIDs);
                }
                
                devices = [audioDevices copy];
                
            } @catch (NSException *e) {
                NSLog(@"❌ Exception getting audio devices: %@", e.reason);
                devices = @[];
            }
        });
        
        Napi::Array result = Napi::Array::New(env, devices ? devices.count : 0);
        
        if (devices) {
            for (NSUInteger i = 0; i < devices.count; i++) {
                NSDictionary *device = devices[i];
                Napi::Object deviceObj = Napi::Object::New(env);
                
                deviceObj.Set("id", Napi::Number::New(env, [device[@"id"] unsignedIntValue]));
                deviceObj.Set("name", Napi::String::New(env, [device[@"name"] UTF8String]));
                deviceObj.Set("type", Napi::String::New(env, [device[@"type"] UTF8String]));
                
                result.Set(i, deviceObj);
            }
        }
        
        return result;
        
    } @catch (NSException *e) {
        NSLog(@"❌ Fatal exception in GetAudioDevicesElectronSafe: %@", e.reason);
        Napi::Error::New(env, "Failed to get audio devices").ThrowAsJavaScriptException();
        return env.Null();
    }
}

// Initialize audio capture module
Napi::Object InitAudioCaptureElectron(Napi::Env env, Napi::Object exports) {
    @try {
        initializeAudioQueue();
        
        exports.Set("getAudioDevices", Napi::Function::New(env, GetAudioDevicesElectronSafe));
        
        NSLog(@"✅ Electron-safe audio capture initialized");
        return exports;
        
    } @catch (NSException *e) {
        NSLog(@"❌ Exception initializing audio capture: %@", e.reason);
        return exports;
    }
}

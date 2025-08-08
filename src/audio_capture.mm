#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>

@interface AudioCapture : NSObject

+ (NSArray *)getAudioDevices;
+ (NSArray *)getSystemAudioDevices;
+ (BOOL)hasAudioPermission;
+ (void)requestAudioPermission:(void(^)(BOOL granted))completion;

@end

@implementation AudioCapture

+ (NSArray *)getAudioDevices {
    NSMutableArray *devices = [NSMutableArray array];
    
    // Get microphone devices using AVFoundation
    AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession 
        discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInMicrophone, AVCaptureDeviceTypeExternalUnknown]
        mediaType:AVMediaTypeAudio
        position:AVCaptureDevicePositionUnspecified];
    NSArray *audioDevices = discoverySession.devices;
    
    for (AVCaptureDevice *device in audioDevices) {
        NSDictionary *deviceInfo = @{
            @"id": device.uniqueID,
            @"name": device.localizedName,
            @"manufacturer": device.manufacturer ?: @"Unknown",
            @"type": @"microphone",
            @"isDefault": @([device isEqual:[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio]])
        };
        
        [devices addObject:deviceInfo];
    }
    
    // Add system audio devices using Core Audio API
    NSArray *systemDevices = [self getSystemAudioDevices];
    [devices addObjectsFromArray:systemDevices];
    
    return [devices copy];
}

+ (NSArray *)getSystemAudioDevices {
    NSMutableArray *devices = [NSMutableArray array];
    
    AudioObjectPropertyAddress propertyAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain  // Changed from kAudioObjectPropertyElementMaster (deprecated)
    };
    
    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize);
    
    if (status == kAudioHardwareNoError) {
        UInt32 deviceCount = dataSize / sizeof(AudioDeviceID);
        AudioDeviceID *audioDeviceIDs = (AudioDeviceID *)malloc(dataSize);
        
        status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize, audioDeviceIDs);
        
        if (status == kAudioHardwareNoError) {
            for (UInt32 i = 0; i < deviceCount; i++) {
                AudioDeviceID deviceID = audioDeviceIDs[i];
                
                // Get device name
                CFStringRef deviceName = NULL;
                UInt32 size = sizeof(deviceName);
                AudioObjectPropertyAddress nameAddress = {
                    kAudioDevicePropertyDeviceNameCFString,
                    kAudioDevicePropertyScopeOutput,  // Focus on output devices for system audio
                    kAudioObjectPropertyElementMain
                };
                
                status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, NULL, &size, &deviceName);
                
                if (status == kAudioHardwareNoError && deviceName) {
                    // Check if this is an output device
                    AudioObjectPropertyAddress streamAddress = {
                        kAudioDevicePropertyStreams,
                        kAudioDevicePropertyScopeOutput,
                        kAudioObjectPropertyElementMain
                    };
                    
                    UInt32 streamSize = 0;
                    status = AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, NULL, &streamSize);
                    
                    if (status == kAudioHardwareNoError && streamSize > 0) {
                        // This is an output device - can be used for system audio capture
                        const char *name = CFStringGetCStringPtr(deviceName, kCFStringEncodingUTF8);
                        NSString *deviceNameStr = name ? [NSString stringWithUTF8String:name] : @"Unknown Device";
                        
                        NSDictionary *deviceInfo = @{
                            @"id": [NSString stringWithFormat:@"%u", deviceID],
                            @"name": deviceNameStr,
                            @"manufacturer": @"System",
                            @"type": @"system_audio",
                            @"isDefault": @(NO)  // We'll determine default separately if needed
                        };
                        
                        [devices addObject:deviceInfo];
                    }
                    
                    CFRelease(deviceName);
                }
            }
        }
        
        free(audioDeviceIDs);
    }
    
    return [devices copy];
}

+ (BOOL)hasAudioPermission {
    // Check microphone permission using AVFoundation
    AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    return authStatus == AVAuthorizationStatusAuthorized;
}

+ (void)requestAudioPermission:(void(^)(BOOL granted))completion {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(granted);
            }
        });
    }];
}

@end

// ScreenCaptureKit Audio Configuration Helper
API_AVAILABLE(macos(12.3))
@interface SCKAudioConfiguration : NSObject

+ (BOOL)configureAudioForStream:(SCStreamConfiguration *)config 
                 includeMicrophone:(BOOL)includeMicrophone
               includeSystemAudio:(BOOL)includeSystemAudio
                  microphoneDevice:(NSString *)micDeviceID
                systemAudioDevice:(NSString *)sysDeviceID;

@end

@implementation SCKAudioConfiguration

+ (BOOL)configureAudioForStream:(SCStreamConfiguration *)config 
                 includeMicrophone:(BOOL)includeMicrophone
               includeSystemAudio:(BOOL)includeSystemAudio
                  microphoneDevice:(NSString *)micDeviceID
                systemAudioDevice:(NSString *)sysDeviceID {
    
    // Configure system audio capture (requires macOS 13.0+)
    if (@available(macOS 13.0, *)) {
        config.capturesAudio = includeSystemAudio;
        config.excludesCurrentProcessAudio = YES;
        
        if (includeSystemAudio) {
            // ScreenCaptureKit will capture system audio from the selected content
            // Quality settings
            config.channelCount = 2;  // Stereo
            config.sampleRate = 48000; // 48kHz
        } else {
            config.capturesAudio = NO;
        }
    }
    
    return YES;
}

@end
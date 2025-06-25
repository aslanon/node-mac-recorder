#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>

@interface AudioCapture : NSObject

+ (NSArray *)getAudioDevices;
+ (BOOL)hasAudioPermission;
+ (void)requestAudioPermission:(void(^)(BOOL granted))completion;

@end

@implementation AudioCapture

+ (NSArray *)getAudioDevices {
    NSMutableArray *devices = [NSMutableArray array];
    
    // Get all audio devices
    NSArray *audioDevices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
    
    for (AVCaptureDevice *device in audioDevices) {
        NSDictionary *deviceInfo = @{
            @"id": device.uniqueID,
            @"name": device.localizedName,
            @"manufacturer": device.manufacturer ?: @"Unknown",
            @"isDefault": @([device isEqual:[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio]])
        };
        
        [devices addObject:deviceInfo];
    }
    
    // Also get system audio devices using Core Audio
    AudioObjectPropertyAddress propertyAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMaster
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
                propertyAddress.mSelector = kAudioDevicePropertyDeviceNameCFString;
                propertyAddress.mScope = kAudioObjectPropertyScopeGlobal;
                
                CFStringRef deviceName = NULL;
                dataSize = sizeof(deviceName);
                
                status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, NULL, &dataSize, &deviceName);
                
                if (status == kAudioHardwareNoError && deviceName) {
                    // Check if it's an input device
                    propertyAddress.mSelector = kAudioDevicePropertyStreamConfiguration;
                    propertyAddress.mScope = kAudioDevicePropertyScopeInput;
                    
                    AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, NULL, &dataSize);
                    
                    if (dataSize > 0) {
                        AudioBufferList *bufferList = (AudioBufferList *)malloc(dataSize);
                        AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, NULL, &dataSize, bufferList);
                        
                        if (bufferList->mNumberBuffers > 0) {
                            NSDictionary *deviceInfo = @{
                                @"id": @(deviceID),
                                @"name": (__bridge NSString *)deviceName,
                                @"type": @"System Audio Input",
                                @"isSystemDevice": @YES
                            };
                            
                            [devices addObject:deviceInfo];
                        }
                        
                        free(bufferList);
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
    if (@available(macOS 10.14, *)) {
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        return status == AVAuthorizationStatusAuthorized;
    }
    return YES; // Older versions don't require explicit permission
}

+ (void)requestAudioPermission:(void(^)(BOOL granted))completion {
    if (@available(macOS 10.14, *)) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(granted);
            });
        }];
    } else {
        completion(YES);
    }
}

@end 
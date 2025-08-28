#import <Foundation/Foundation.h>

@interface AudioCapture : NSObject

+ (NSArray *)getAudioDevices;
+ (BOOL)hasAudioPermission;
+ (void)requestAudioPermission:(void(^)(BOOL granted))completion;

@end

@implementation AudioCapture

+ (NSArray *)getAudioDevices {
    NSMutableArray *devices = [NSMutableArray array];
    
    // ScreenCaptureKit handles audio internally - return default device
    NSDictionary *deviceInfo = @{
        @"id": @"default",
        @"name": @"Default Audio Device", 
        @"manufacturer": @"System",
        @"isDefault": @YES
    };
    
    [devices addObject:deviceInfo];
    
    return devices;
}

+ (BOOL)hasAudioPermission {
    // ScreenCaptureKit handles audio permissions internally
    return YES;
}

+ (void)requestAudioPermission:(void(^)(BOOL granted))completion {
    // ScreenCaptureKit handles audio permissions internally
    if (completion) {
        completion(YES);
    }
}

@end
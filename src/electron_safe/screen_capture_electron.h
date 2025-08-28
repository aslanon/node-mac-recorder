#ifndef SCREEN_CAPTURE_ELECTRON_H
#define SCREEN_CAPTURE_ELECTRON_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

@interface ElectronSafeScreenCapture : NSObject

// Core recording functions
+ (BOOL)startRecordingWithPath:(NSString *)outputPath options:(NSDictionary *)options;
+ (BOOL)stopRecordingSafely;
+ (BOOL)isRecording;

// Information functions
+ (NSArray *)getAvailableDisplays;
+ (NSArray *)getAvailableWindows;
+ (BOOL)checkPermissions;

// Thumbnail functions
+ (NSString *)getDisplayThumbnailBase64:(CGDirectDisplayID)displayID 
                               maxWidth:(NSInteger)maxWidth 
                              maxHeight:(NSInteger)maxHeight;
+ (NSString *)getWindowThumbnailBase64:(uint32_t)windowID 
                              maxWidth:(NSInteger)maxWidth 
                             maxHeight:(NSInteger)maxHeight;

@end

#endif // SCREEN_CAPTURE_ELECTRON_H

#ifndef SCREEN_CAPTURE_H
#define SCREEN_CAPTURE_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface ScreenCapture : NSObject

+ (NSArray *)getAvailableDisplays;
+ (BOOL)captureDisplay:(CGDirectDisplayID)displayID 
                toFile:(NSString *)filePath 
                  rect:(CGRect)rect
           includeCursor:(BOOL)includeCursor;
+ (CGImageRef)createScreenshotFromDisplay:(CGDirectDisplayID)displayID 
                                     rect:(CGRect)rect;

@end

#endif // SCREEN_CAPTURE_H 
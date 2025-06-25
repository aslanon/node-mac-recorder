#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>

@interface ScreenCapture : NSObject

+ (NSArray *)getAvailableDisplays;
+ (BOOL)captureDisplay:(CGDirectDisplayID)displayID 
                toFile:(NSString *)filePath 
                  rect:(CGRect)rect
           includeCursor:(BOOL)includeCursor;
+ (CGImageRef)createScreenshotFromDisplay:(CGDirectDisplayID)displayID 
                                     rect:(CGRect)rect;

@end

@implementation ScreenCapture

+ (NSArray *)getAvailableDisplays {
    NSMutableArray *displays = [NSMutableArray array];
    
    uint32_t displayCount;
    CGGetActiveDisplayList(0, NULL, &displayCount);
    
    CGDirectDisplayID *displayList = (CGDirectDisplayID *)malloc(displayCount * sizeof(CGDirectDisplayID));
    CGGetActiveDisplayList(displayCount, displayList, &displayCount);
    
    for (uint32_t i = 0; i < displayCount; i++) {
        CGDirectDisplayID displayID = displayList[i];
        
        // Get display bounds
        CGRect bounds = CGDisplayBounds(displayID);
        
        // Create display info dictionary
        NSDictionary *displayInfo = @{
            @"id": @(displayID),
            @"name": [NSString stringWithFormat:@"Display %d", i + 1],
            @"width": @(bounds.size.width),
            @"height": @(bounds.size.height),
            @"x": @(bounds.origin.x),
            @"y": @(bounds.origin.y),
            @"isPrimary": @(CGDisplayIsMain(displayID))
        };
        
        [displays addObject:displayInfo];
    }
    
    free(displayList);
    return [displays copy];
}

+ (BOOL)captureDisplay:(CGDirectDisplayID)displayID 
                toFile:(NSString *)filePath 
                  rect:(CGRect)rect
           includeCursor:(BOOL)includeCursor {
    
    CGImageRef screenshot = [self createScreenshotFromDisplay:displayID rect:rect];
    if (!screenshot) {
        return NO;
    }
    
    // Create image destination
    NSURL *fileURL = [NSURL fileURLWithPath:filePath];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)fileURL, 
        kUTTypePNG, 
        1, 
        NULL
    );
    
    if (!destination) {
        CGImageRelease(screenshot);
        return NO;
    }
    
    // Add cursor if requested
    if (includeCursor) {
        // Get cursor position
        CGPoint cursorPos = CGEventGetLocation(CGEventCreate(NULL));
        
        // Create mutable image context
        size_t width = CGImageGetWidth(screenshot);
        size_t height = CGImageGetHeight(screenshot);
        
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(
            NULL, width, height, 8, width * 4,
            colorSpace, kCGImageAlphaPremultipliedFirst
        );
        
        if (context) {
            // Draw original screenshot
            CGContextDrawImage(context, CGRectMake(0, 0, width, height), screenshot);
            
            // Draw cursor (simplified - just a small circle)
            CGRect displayBounds = CGDisplayBounds(displayID);
            CGFloat relativeX = cursorPos.x - displayBounds.origin.x;
            CGFloat relativeY = height - (cursorPos.y - displayBounds.origin.y);
            
            if (!CGRectIsNull(rect)) {
                relativeX -= rect.origin.x;
                relativeY -= rect.origin.y;
            }
            
            if (relativeX >= 0 && relativeX < width && relativeY >= 0 && relativeY < height) {
                CGContextSetRGBFillColor(context, 1.0, 0.0, 0.0, 0.8); // Red cursor
                CGContextFillEllipseInRect(context, CGRectMake(relativeX - 5, relativeY - 5, 10, 10));
            }
            
            CGImageRef finalImage = CGBitmapContextCreateImage(context);
            CGContextRelease(context);
            CGImageRelease(screenshot);
            screenshot = finalImage;
        }
        
        CGColorSpaceRelease(colorSpace);
    }
    
    // Save image
    CGImageDestinationAddImage(destination, screenshot, NULL);
    BOOL success = CGImageDestinationFinalize(destination);
    
    CFRelease(destination);
    CGImageRelease(screenshot);
    
    return success;
}

+ (CGImageRef)createScreenshotFromDisplay:(CGDirectDisplayID)displayID 
                                     rect:(CGRect)rect {
    
    if (CGRectIsNull(rect)) {
        // Capture entire display
        return CGDisplayCreateImage(displayID);
    } else {
        // Capture specific rect
        return CGDisplayCreateImageForRect(displayID, rect);
    }
}

@end 
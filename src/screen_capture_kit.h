#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>

API_AVAILABLE(macos(12.3))
@interface ScreenCaptureKitRecorder : NSObject

+ (BOOL)isScreenCaptureKitAvailable;
+ (BOOL)startRecordingWithConfiguration:(NSDictionary *)config 
                               delegate:(id)delegate 
                                  error:(NSError **)error;
+ (void)stopRecording;
+ (BOOL)isRecording;
+ (BOOL)setupVideoWriterWithWidth:(NSInteger)width 
                           height:(NSInteger)height 
                       outputPath:(NSString *)outputPath 
                     includeAudio:(BOOL)includeAudio;

@end
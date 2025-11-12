#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
// NO AVFoundation - Pure ScreenCaptureKit implementation

API_AVAILABLE(macos(12.3))
@interface ScreenCaptureKitRecorder : NSObject

+ (BOOL)isScreenCaptureKitAvailable;

// MULTI-SESSION API: New session-based recording
+ (NSString *)startRecordingWithConfiguration:(NSDictionary *)config
                                     delegate:(id)delegate
                                        error:(NSError **)error;  // Returns sessionId
+ (BOOL)stopRecording:(NSString *)sessionId;  // Stop specific session
+ (BOOL)isRecording:(NSString *)sessionId;    // Check specific session
+ (BOOL)isFullyInitialized:(NSString *)sessionId;  // Check if session's first frames received
+ (NSTimeInterval)getVideoStartTimestamp:(NSString *)sessionId;  // Get session's video start timestamp
+ (NSArray<NSString *> *)getActiveSessions;  // Get all active session IDs
+ (NSInteger)getActiveSessionCount;  // Get number of active sessions

// LEGACY API: For backward compatibility (uses implicit default session)
+ (void)stopRecording;  // Stops all sessions
+ (BOOL)isRecording;    // Returns YES if ANY session is recording
+ (BOOL)isFullyInitialized;  // Check if default session initialized
+ (NSTimeInterval)getVideoStartTimestamp;  // Get default session timestamp

+ (BOOL)setupVideoWriter;
+ (void)finalizeRecording;
+ (void)finalizeVideoWriter;
+ (void)cleanupVideoWriter;

@end

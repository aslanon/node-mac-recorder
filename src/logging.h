// Lightweight runtime-controlled logging helpers
#import <Foundation/Foundation.h>

static inline BOOL MRShouldVerboseLog(void) {
    static dispatch_once_t onceToken;
    static BOOL enabled = NO;
    dispatch_once(&onceToken, ^{
        const char *env = getenv("MAC_RECORDER_DEBUG");
        if (env && (*env == '1' || *env == 't' || *env == 'T' || *env == 'y' || *env == 'Y')) {
            enabled = YES;
        }
    });
    return enabled;
}

#define MRLog(fmt, ...) do { if (MRShouldVerboseLog()) { NSLog((fmt), ##__VA_ARGS__); } } while(0)


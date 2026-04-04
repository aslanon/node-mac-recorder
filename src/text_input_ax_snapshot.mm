#import "text_input_ax_snapshot.h"
#import <ApplicationServices/ApplicationServices.h>

static inline BOOL MRStringEqualsAny(NSString *value, NSArray<NSString *> *candidates) {
    if (!value) {
        return NO;
    }
    for (NSString *c in candidates) {
        if ([value isEqualToString:c]) {
            return YES;
        }
    }
    return NO;
}

static NSString *MRCopyAttributeString(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    AXError err = AXUIElementCopyAttributeValue(element, attribute, &value);
    if (err != kAXErrorSuccess || !value) {
        return nil;
    }
    if (CFGetTypeID(value) != CFStringGetTypeID()) {
        CFRelease(value);
        return nil;
    }
    NSString *s = [NSString stringWithString:(__bridge NSString *)value];
    CFRelease(value);
    return s;
}

static BOOL MRCopyAttributeBoolean(AXUIElementRef element, CFStringRef attribute, BOOL *outValue) {
    CFTypeRef value = NULL;
    AXError err = AXUIElementCopyAttributeValue(element, attribute, &value);
    if (err != kAXErrorSuccess || !value) {
        return NO;
    }
    BOOL ok = NO;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        *outValue = CFBooleanGetValue((CFBooleanRef)value);
        ok = YES;
    }
    CFRelease(value);
    return ok;
}

NSDictionary *MRTextInputSnapshotDictionary(void) {
    __block NSDictionary *result = nil;
    void (^work)(void) = ^{
        @autoreleasepool {
            @try {
                AXUIElementRef systemWide = AXUIElementCreateSystemWide();
                if (!systemWide) {
                    return;
                }

                AXUIElementRef focusedElement = NULL;
                AXError focusErr = AXUIElementCopyAttributeValue(
                    systemWide, kAXFocusedUIElementAttribute, (CFTypeRef *)&focusedElement);

                if (focusErr != kAXErrorSuccess || !focusedElement) {
                    CFRelease(systemWide);
                    return;
                }

                NSString *role = MRCopyAttributeString(focusedElement, kAXRoleAttribute);
                BOOL isEditable = NO;
                MRCopyAttributeBoolean(focusedElement, CFSTR("AXEditable"), &isEditable);

                CFTypeRef selectedRangeValue = NULL;
                AXError rangeProbeErr = AXUIElementCopyAttributeValue(
                    focusedElement, CFSTR("AXSelectedTextRange"), (CFTypeRef *)&selectedRangeValue);
                BOOL hasTextRange = (rangeProbeErr == kAXErrorSuccess && selectedRangeValue != NULL);

                BOOL isStandardTextRole = MRStringEqualsAny(role, @[
                    @"AXTextField", @"AXTextArea", @"AXTextView",
                    @"AXTextEditor", @"AXSearchField",
                    @"AXComboBox"
                ]);
                BOOL isWebAreaWithCaret = [role isEqualToString:@"AXWebArea"] && hasTextRange;
                BOOL isTextField = isStandardTextRole || isEditable || isWebAreaWithCaret || hasTextRange;

                if (!isTextField) {
                    if (selectedRangeValue) {
                        CFRelease(selectedRangeValue);
                    }
                    CFRelease(focusedElement);
                    CFRelease(systemWide);
                    return;
                }

                CGPoint inputOrigin = CGPointZero;
                CGSize inputSize = CGSizeZero;
                AXValueRef positionValue = NULL;
                AXValueRef sizeValue = NULL;

                AXUIElementCopyAttributeValue(focusedElement, kAXPositionAttribute, (CFTypeRef *)&positionValue);
                AXUIElementCopyAttributeValue(focusedElement, kAXSizeAttribute, (CFTypeRef *)&sizeValue);

                if (positionValue) {
                    AXValueGetValue(positionValue, kAXValueTypeCGPoint, &inputOrigin);
                    CFRelease(positionValue);
                }
                if (sizeValue) {
                    AXValueGetValue(sizeValue, kAXValueTypeCGSize, &inputSize);
                    CFRelease(sizeValue);
                }

                CGPoint caretPos = CGPointMake(inputOrigin.x, inputOrigin.y);
                BOOL hasCaretPos = NO;

                if (selectedRangeValue) {
                    CFTypeRef boundsValue = NULL;
                    AXError boundsErr = AXUIElementCopyParameterizedAttributeValue(
                        focusedElement, CFSTR("AXBoundsForRange"),
                        selectedRangeValue, &boundsValue);

                    if (boundsErr == kAXErrorSuccess && boundsValue) {
                        CGRect caretBounds = CGRectZero;
                        if (AXValueGetValue((AXValueRef)boundsValue, kAXValueTypeCGRect, &caretBounds)) {
                            caretPos = CGPointMake(
                                caretBounds.origin.x,
                                caretBounds.origin.y + caretBounds.size.height / 2.0
                            );
                            hasCaretPos = YES;
                        }
                        CFRelease(boundsValue);
                    }
                    CFRelease(selectedRangeValue);
                }

                if (!hasCaretPos) {
                    caretPos = CGPointMake(inputOrigin.x + 4, inputOrigin.y + inputSize.height / 2.0);
                }

                result = @{
                    @"caretX": @((int)lround(caretPos.x)),
                    @"caretY": @((int)lround(caretPos.y)),
                    @"inputFrame": @{
                        @"x": @((int)lround(inputOrigin.x)),
                        @"y": @((int)lround(inputOrigin.y)),
                        @"width": @((int)lround(inputSize.width)),
                        @"height": @((int)lround(inputSize.height))
                    }
                };

                CFRelease(focusedElement);
                CFRelease(systemWide);
            } @catch (__unused NSException *e) {
                result = nil;
            }
        }
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }

    return result;
}

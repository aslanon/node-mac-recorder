// Exercise the production detector with real AppKit images, including detached
// bitmap copies as returned for cursors belonging to other applications.
#import "../src/cursor_tracker.mm"

static Napi::Value RunCursorTests(const Napi::CallbackInfo &info) {
    @autoreleasepool {
        NSMutableArray<NSString *> *failures = [NSMutableArray array];
        NSUInteger checks = 0;
        auto expect = [&](NSString *actual, NSString *expected, NSString *label) {
            checks++;
            if (!StringsEqual(actual, expected)) {
                [failures addObject:[NSString stringWithFormat:@"%@: expected %@, got %@", label, expected, actual]];
            }
        };
        InitializeCursorFingerprintMap();
        auto checkCursor = [&](NSCursor *cursor, NSString *expected, NSString *label) {
            expect(normalizeCursorTypeForDesktop(cursorTypeFromNSCursor(cursor)), expected, label);
            NSImage *image = cursor.image;
            if (!image || image.size.width <= 0 || image.size.height <= 0) {
                [failures addObject:[label stringByAppendingString:@": AppKit image unavailable"]];
                return;
            }
            for (NSUInteger scale = 1; scale <= 2; scale++) {
                NSSize size = image.size;
                NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc]
                    initWithBitmapDataPlanes:NULL pixelsWide:lround(size.width * scale)
                    pixelsHigh:lround(size.height * scale) bitsPerSample:8 samplesPerPixel:4
                    hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
                    bytesPerRow:0 bitsPerPixel:0] autorelease];
                bitmap.size = size;
                [NSGraphicsContext saveGraphicsState];
                [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
                [image drawInRect:NSMakeRect(0, 0, size.width, size.height) fromRect:NSZeroRect
                    operation:NSCompositingOperationCopy fraction:1.0];
                [NSGraphicsContext restoreGraphicsState];
                NSImage *copy = [[[NSImage alloc] initWithSize:size] autorelease];
                [copy addRepresentation:bitmap];
                NSCursor *detached = [[[NSCursor alloc] initWithImage:copy hotSpot:cursor.hotSpot] autorelease];
                expect(normalizeCursorTypeForDesktop(cursorTypeFromNSCursor(detached)), expected,
                    [NSString stringWithFormat:@"%@ detached %lux", label, (unsigned long)scale]);
            }
        };

        NSDictionary *names = @{
            @"contextualMenuCursor": @"default", @"dragLinkCursor": @"alias",
            @"move": @"all-scroll", @"help": @"help", @"zoomOutCursor": @"zoom-out",
            @"n-resize": @"ns-resize", @"s-resize": @"ns-resize",
            @"e-resize": @"col-resize", @"w-resize": @"col-resize",
            @"ne-resize": @"nesw-resize", @"sw-resize": @"nesw-resize",
            @"nw-resize": @"nwse-resize", @"se-resize": @"nwse-resize",
            @"resizeNorthEastCursor": @"nesw-resize", @"resizeNorthWestCursor": @"nwse-resize",
            @"row-resize": @"row-resize", @"col-resize": @"col-resize",
            @"resizeNorthSouthCursor": @"ns-resize", @"resizeEastWestCursor": @"col-resize"
        };
        for (NSString *name in names) {
            expect(normalizeCursorTypeForDesktop(cursorTypeFromCursorName(name)), names[name], name);
        }
        expect(cursorTypeFromCursorName(@"unknown-resize"), nil, @"unknown direction must remain unknown");

        checkCursor(NSCursor.arrowCursor, @"default", @"arrow");
        checkCursor(NSCursor.pointingHandCursor, @"pointer", @"pointing hand");
        checkCursor(NSCursor.IBeamCursor, @"text", @"text");
        checkCursor(NSCursor.crosshairCursor, @"crosshair", @"crosshair");
        checkCursor(NSCursor.openHandCursor, @"grab", @"open hand");
        checkCursor(NSCursor.closedHandCursor, @"grabbing", @"closed hand");
        checkCursor(NSCursor.dragCopyCursor, @"copy", @"copy");
        checkCursor(NSCursor.dragLinkCursor, @"alias", @"alias");
        checkCursor(NSCursor.operationNotAllowedCursor, @"not-allowed", @"not allowed");
        if ([NSCursor instancesRespondToSelector:NSSelectorFromString(@"_coreCursorType")]) {
            checkCursor([[[MRSystemReferenceCursor alloc] initWithCoreType:39] autorelease], @"all-scroll", @"CoreCursor move");
            checkCursor([[[MRSystemReferenceCursor alloc] initWithCoreType:11] autorelease], @"grabbing", @"CoreCursor closed hand");
            checkCursor([[[MRSystemReferenceCursor alloc] initWithCoreType:12] autorelease], @"grab", @"CoreCursor open hand");
        }
        if (@available(macOS 15.0, *)) {
            checkCursor(NSCursor.zoomInCursor, @"zoom-in", @"zoom in");
            checkCursor(NSCursor.zoomOutCursor, @"zoom-out", @"zoom out");
            for (NSUInteger direction = 1; direction <= 3; direction++) {
                checkCursor([NSCursor rowResizeCursorInDirections:(NSVerticalDirections)direction], @"row-resize", @"row");
                checkCursor([NSCursor columnResizeCursorInDirections:(NSHorizontalDirections)direction], @"col-resize", @"column");
                const NSCursorFrameResizePosition positions[] = {
                    NSCursorFrameResizePositionTop, NSCursorFrameResizePositionBottom,
                    NSCursorFrameResizePositionLeft, NSCursorFrameResizePositionRight,
                    NSCursorFrameResizePositionTopLeft, NSCursorFrameResizePositionBottomRight,
                    NSCursorFrameResizePositionTopRight, NSCursorFrameResizePositionBottomLeft
                };
                NSArray *expected = @[@"ns-resize", @"ns-resize", @"col-resize", @"col-resize",
                    @"nwse-resize", @"nwse-resize", @"nesw-resize", @"nesw-resize"];
                for (NSUInteger i = 0; i < 8; i++) {
                    checkCursor([NSCursor frameResizeCursorFromPosition:positions[i]
                        inDirections:(NSCursorFrameResizeDirections)direction], expected[i],
                        [NSString stringWithFormat:@"frame %lu direction %lu", (unsigned long)i, (unsigned long)direction]);
                }
            }
        }

        NSDictionary *resources = @{
            @"help": @"help", @"busybutclickable": @"progress", @"move": @"all-scroll",
            @"zoomin": @"zoom-in", @"zoomout": @"zoom-out",
            @"resizenortheast": @"nesw-resize", @"resizesouthwest": @"nesw-resize",
            @"resizenorthwest": @"nwse-resize", @"resizesoutheast": @"nwse-resize",
            @"resizenortheastsouthwest": @"nesw-resize", @"resizenorthwestsoutheast": @"nwse-resize",
            @"resizenorthsouth": @"ns-resize", @"resizeupdown": @"row-resize"
        };
        NSString *resourceRoot = @"/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors";
        for (NSString *resource in resources) {
            NSString *directory = [resourceRoot stringByAppendingPathComponent:resource];
            NSImage *image = [[[NSImage alloc] initWithContentsOfFile:[directory stringByAppendingPathComponent:@"cursor.pdf"]] autorelease];
            if (!image) continue; // Legacy resources are optional on future macOS versions.
            NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:[directory stringByAppendingPathComponent:@"info.plist"]];
            NSCursor *cursor = [[[NSCursor alloc] initWithImage:image
                hotSpot:NSMakePoint([metadata[@"hotx"] doubleValue], [metadata[@"hoty"] doubleValue])] autorelease];
            checkCursor(cursor, resources[resource], resource);
        }

        // Unrelated custom cursors may have exactly the old heuristic dimensions.
        NSImage *custom = [[[NSImage alloc] initWithSize:NSMakeSize(22, 22)] autorelease];
        [custom lockFocus];
        [[NSColor redColor] setFill];
        NSRectFill(NSMakeRect(0, 0, 22, 22));
        [custom unlockFocus];
        NSCursor *customCursor = [[[NSCursor alloc] initWithImage:custom hotSpot:NSMakePoint(11, 11)] autorelease];
        expect(cursorTypeFromNSCursor(customCursor), @"default", @"unknown 22x22 custom image");

        ResetCursorEventHistory();
        RememberCursorEvent(CGPointMake(100, 100), @"default", @"move");
        expect(ShouldEmitCursorEvent(CGPointMake(100, 100), @"nesw-resize", @"move") ? @"yes" : @"no", @"yes", @"stationary shape change");
        expect(ShouldEmitCursorEvent(CGPointMake(100, 100), @"default", @"move") ? @"yes" : @"no", @"no", @"stationary duplicate");
        RememberCursorEvent(CGPointMake(100, 100), @"nwse-resize", @"drag");
        expect(ShouldEmitCursorEvent(CGPointMake(100, 100), @"nesw-resize", @"drag") ? @"yes" : @"no", @"yes", @"stationary drag shape change");
        ResetCursorEventHistory();

        Napi::Object result = Napi::Object::New(info.Env());
        result.Set("checks", Napi::Number::New(info.Env(), checks));
        result.Set("failures", Napi::String::New(info.Env(), [[failures componentsJoinedByString:@"\n"] UTF8String]));
        return result;
    }
}

// Opt-in integration test: briefly display owned cursors and read them back from
// WindowServer. Restore the previous system cursor even when an assertion fails.
static Napi::Value RunLiveCursorTests(const Napi::CallbackInfo &info) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        InitializeCursorFingerprintMap();
        NSMutableArray *failures = [NSMutableArray array];
        NSMutableArray<NSCursor *> *cursors = [NSMutableArray arrayWithObjects:NSCursor.arrowCursor,
            NSCursor.IBeamCursor, NSCursor.pointingHandCursor, NSCursor.openHandCursor,
            NSCursor.closedHandCursor, NSCursor.dragCopyCursor, NSCursor.dragLinkCursor,
            NSCursor.operationNotAllowedCursor, NSCursor.crosshairCursor, nil];
        NSMutableArray *types = [NSMutableArray arrayWithArray:@[@"default", @"text", @"pointer",
            @"grab", @"grabbing", @"copy", @"alias", @"not-allowed", @"crosshair"]];
        if ([NSCursor instancesRespondToSelector:NSSelectorFromString(@"_coreCursorType")]) {
            [cursors addObject:[[[MRSystemReferenceCursor alloc] initWithCoreType:39] autorelease]];
            [types addObject:@"all-scroll"];
        }
        if (@available(macOS 15.0, *)) {
            [cursors addObjectsFromArray:@[NSCursor.zoomInCursor, NSCursor.zoomOutCursor,
                NSCursor.columnResizeCursor, NSCursor.rowResizeCursor,
                [NSCursor frameResizeCursorFromPosition:NSCursorFrameResizePositionTop inDirections:NSCursorFrameResizeDirectionsAll],
                [NSCursor frameResizeCursorFromPosition:NSCursorFrameResizePositionTopLeft inDirections:NSCursorFrameResizeDirectionsAll],
                [NSCursor frameResizeCursorFromPosition:NSCursorFrameResizePositionTopRight inDirections:NSCursorFrameResizeDirectionsAll]]];
            [types addObjectsFromArray:@[@"zoom-in", @"zoom-out", @"col-resize", @"row-resize", @"ns-resize", @"nwse-resize", @"nesw-resize"]];
        }
        NSCursor *previous = [[NSCursor currentSystemCursor] retain];
        NSRunningApplication *previousApp = [[NSWorkspace sharedWorkspace].frontmostApplication retain];
        NSPoint mouse = NSEvent.mouseLocation;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(mouse.x - 80, mouse.y - 60, 160, 120)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        window.title = @"Cursor detection test";
        [window disableCursorRects];
        @try {
            [window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
            for (NSUInteger i = 0; i < cursors.count; i++) {
                [cursors[i] set];
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
                NSString *actual = getCursorType();
                if (!StringsEqual(actual, types[i])) {
                    NSCursor *system = NSCursor.currentSystemCursor;
                    [failures addObject:[NSString stringWithFormat:@"%@: got %@ (system image %@, hotspot %@)",
                        types[i], actual, NSStringFromSize(system.image.size), NSStringFromPoint(system.hotSpot)]];
                }
            }
        } @finally {
            [window close];
            [window release];
            [previousApp activateWithOptions:NSApplicationActivateIgnoringOtherApps];
            [previousApp release];
            [previous set];
            [previous release];
        }
        Napi::Object result = Napi::Object::New(info.Env());
        result.Set("checks", Napi::Number::New(info.Env(), cursors.count));
        result.Set("failures", Napi::String::New(info.Env(), [[failures componentsJoinedByString:@"\n"] UTF8String]));
        return result;
    }
}

static Napi::Object InitProbe(Napi::Env env, Napi::Object exports) {
    exports.Set("run", Napi::Function::New(env, RunCursorTests));
    exports.Set("runLive", Napi::Function::New(env, RunLiveCursorTests));
    return exports;
}
NODE_API_MODULE(cursor_detection_probe, InitProbe)

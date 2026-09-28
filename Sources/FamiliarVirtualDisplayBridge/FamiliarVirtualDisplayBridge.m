#import "FamiliarVirtualDisplayBridge.h"
#import <CoreGraphics/CoreGraphics.h>

// Private ABI declarations cross-checked against DeskPad and Chromium's macOS
// virtual-display utility. Runtime lookup keeps an unavailable API from stopping
// Familiar from launching; no private classes escape this module.
// https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h
// https://github.com/chromium/chromium/blob/main/ui/display/mac/test/virtual_display_util_mac.mm
@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, strong) NSString *name;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) uint32_t maxPixelsWide;
@property(nonatomic) uint32_t maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) uint32_t vendorID;
@property(nonatomic) uint32_t productID;
@property(nonatomic) uint32_t serialNum;
@property(nonatomic) uint32_t serialNumber;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, strong) NSArray *modes;
@property(nonatomic) uint32_t hiDPI;
@property(nonatomic) uint32_t rotation;
@end

@interface CGVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static NSError *DisplayError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:@"Familiar.VirtualDisplay" code:code
                          userInfo:@{NSLocalizedDescriptionKey: description}];
}

@implementation FAMVirtualDisplay {
    CGVirtualDisplay *_display;
    CGVirtualDisplayDescriptor *_descriptor;
    CGVirtualDisplaySettings *_settings;
    uint32_t _displayID;
}

- (nullable instancetype)initWithWidth:(uint32_t)width
                               height:(uint32_t)height
                                error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (!self) { return nil; }

    if (width == 0 || height == 0 || width > 16384 || height > 16384) {
        if (error) { *error = DisplayError(1, @"The background display dimensions are unsupported."); }
        return nil;
    }

    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    if (!descriptorClass || !displayClass || !settingsClass || !modeClass) {
        if (error) { *error = DisplayError(2, @"This version of macOS does not provide the virtual display API."); }
        return nil;
    }

    @try {
        _descriptor = [[descriptorClass alloc] init];
        _descriptor.name = @"Familiar Background Workspace";
        _descriptor.queue = dispatch_get_main_queue();
        _descriptor.maxPixelsWide = width;
        _descriptor.maxPixelsHigh = height;
        _descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / 110.0, height * 25.4 / 110.0);
        _descriptor.vendorID = 0x46414D;
        _descriptor.productID = 1;
        // macOS 14 requires nonzero vendor identity and distinct live-display serials.
        uint32_t serial = arc4random_uniform(UINT32_MAX - 1) + 1;
        _descriptor.serialNum = serial;
        if ([_descriptor respondsToSelector:@selector(setSerialNumber:)]) {
            _descriptor.serialNumber = serial;
        }
        _descriptor.redPrimary = CGPointMake(0.64, 0.33);
        _descriptor.greenPrimary = CGPointMake(0.30, 0.60);
        _descriptor.bluePrimary = CGPointMake(0.15, 0.06);
        _descriptor.whitePoint = CGPointMake(0.3127, 0.3290);

        _display = [[displayClass alloc] initWithDescriptor:_descriptor];
        if (!_display) {
            if (error) { *error = DisplayError(3, @"macOS could not create the background display."); }
            [self invalidate];
            return nil;
        }

        _settings = [[settingsClass alloc] init];
        _settings.hiDPI = 0;
        if ([_settings respondsToSelector:@selector(setRotation:)]) {
            _settings.rotation = 0;
        }
        CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:width height:height refreshRate:60.0];
        if (!mode) {
            if (error) { *error = DisplayError(4, @"macOS could not configure the background display mode."); }
            [self invalidate];
            return nil;
        }
        _settings.modes = @[mode];
        if (![_display applySettings:_settings] || _display.displayID == kCGNullDirectDisplay) {
            if (error) { *error = DisplayError(5, @"macOS rejected the background display settings."); }
            [self invalidate];
            return nil;
        }
        _displayID = _display.displayID;
        return self;
    } @catch (NSException *exception) {
        if (error) {
            *error = DisplayError(6, [NSString stringWithFormat:@"The virtual display API failed (%@).", exception.name]);
        }
        [self invalidate];
        return nil;
    }
}

- (uint32_t)displayID {
    return _displayID;
}

- (void)invalidate {
    _displayID = 0;
    _display = nil;
    _settings = nil;
    _descriptor = nil;
}

@end

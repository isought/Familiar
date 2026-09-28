#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns one optional macOS virtual display. Call invalidate after restoring its windows.
/// Creation and invalidation must be serialized by the caller.
@interface FAMVirtualDisplay : NSObject

@property(nonatomic, readonly) uint32_t displayID;

- (nullable instancetype)initWithWidth:(uint32_t)width
                               height:(uint32_t)height
                                error:(NSError * _Nullable * _Nullable)error;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Releases the virtual display. Safe to call more than once; displayID becomes zero.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END

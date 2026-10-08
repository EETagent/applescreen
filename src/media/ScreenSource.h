#import "MediaSourceTypes.h"
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// ScreenCaptureKit is available on the existing macOS 12.7.6 deployment floor.
// Video only. Capture callbacks and the stream lifecycle share one serial queue.
// The OS owns a bounded three-frame queue; this source never copies raw pixels.
API_AVAILABLE(macos(12.3))
@interface ASScreenSource : NSObject <ASMediaSource>
// Zero intentionally selects the current main display; a missing explicit ID
// is an error, rather than silently switching to a different display.
- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Apply validated negotiated capture limits after preparation and before Start.
// The serial capture owner processes this before a following Start request.
- (void)applyVideoWidth:(size_t)width height:(size_t)height framesPerSecond:(double)fps;
@end

NS_ASSUME_NONNULL_END

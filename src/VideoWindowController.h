#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

@interface VideoWindowController : NSWindowController <NSWindowDelegate>
- (instancetype)initWithLayer:(CALayer *)layer title:(NSString *)title
                     onClose:(dispatch_block_t)onClose;
// Programmatic close does not request a second media stop.
- (void)closeWithoutStopping;
@end

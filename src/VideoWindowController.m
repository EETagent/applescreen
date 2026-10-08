#import "VideoWindowController.h"

@interface ASVideoView : NSView
@property(nonatomic, strong) CALayer *videoLayer;
@end
@implementation ASVideoView
- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.videoLayer.frame = self.bounds;
    self.videoLayer.contentsScale = self.window.backingScaleFactor ?: 1;
    [CATransaction commit];
}
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    self.needsLayout = YES;
}
@end

@interface VideoWindowController ()
@property(nonatomic, copy) dispatch_block_t closeHandler;
@end
@implementation VideoWindowController
- (instancetype)initWithLayer:(CALayer *)layer title:(NSString *)title onClose:(dispatch_block_t)onClose {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 540)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                  NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    self = [super initWithWindow:window];
    if (self) {
        self.closeHandler = onClose;
        window.title = title;
        window.releasedWhenClosed = NO;
        window.delegate = self;
        window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
        window.contentMinSize = NSMakeSize(160, 90);
        ASVideoView *view = [[ASVideoView alloc] initWithFrame:window.contentView.bounds];
        view.wantsLayer = YES;
        view.layer.backgroundColor = NSColor.blackColor.CGColor;
        view.videoLayer = layer;
        [view.layer addSublayer:layer];
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        window.contentView = view;
        [window center];
    }
    return self;
}
- (void)windowWillClose:(NSNotification *)notification {
    dispatch_block_t handler = self.closeHandler;
    self.closeHandler = nil;
    if (handler) handler();
}
- (void)closeWithoutStopping {
    self.closeHandler = nil;
    [self close];
}
@end

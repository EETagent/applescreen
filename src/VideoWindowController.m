// VideoWindowController.m
// Window controller for video playback

#import "VideoWindowController.h"

@interface VideoWindowController ()
@property (nonatomic, strong) MetalVideoView* videoView;
@end

@implementation VideoWindowController

- (instancetype)initWithWidth:(int)width height:(int)height title:(NSString*)title {
    NSRect frame = NSMakeRect(100, 100, width, height);
    NSWindow* window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskTitled |
                                                            NSWindowStyleMaskClosable |
                                                            NSWindowStyleMaskResizable |
                                                            NSWindowStyleMaskMiniaturizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = title;
    window.releasedWhenClosed = NO;

    self = [super initWithWindow:window];
    if (self) {
        self.videoView = [[MetalVideoView alloc] initWithFrame:window.contentView.bounds];
        self.videoView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [window.contentView addSubview:self.videoView];
    }
    return self;
}

@end

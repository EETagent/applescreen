// VideoWindowController.h
// Window controller for video playback

#import <Cocoa/Cocoa.h>
#import "MetalVideoView.h"

@interface VideoWindowController : NSWindowController

@property (nonatomic, strong, readonly) MetalVideoView* videoView;

- (instancetype)initWithWidth:(int)width height:(int)height title:(NSString*)title;

@end

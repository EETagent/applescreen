// ReceiverViewController.h

#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
#import "AudioRingBuffer.h"
#import "VideoWindowController.h"

#include "cast/standalone_receiver/my_lib.h"

@protocol ReceiverViewControllerDelegate <NSObject>
- (void)receiverDidUpdateStatus:(NSString*)status;
@end

@interface ReceiverViewController : NSViewController

@property (nonatomic, weak) id<ReceiverViewControllerDelegate> delegate;

- (void)startReceiver;
- (void)stopReceiver;
- (BOOL)isRunning;

- (void)openVideoWindowWithWidth:(int)width height:(int)height title:(const char*)title;
- (void)closeVideoWindow;
- (void)resizeVideoWindowToWidth:(int)width height:(int)height;
- (void)displayVideoFrame:(const CastVideoFrame*)frame;
- (void)handleAudioFrame:(const CastAudioFrame*)frame;
- (void)handleError:(int)errorCode message:(const char*)message;

@end

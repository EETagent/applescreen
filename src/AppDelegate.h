// AppDelegate.h
// Main application delegate with tabbed interface

#import <Cocoa/Cocoa.h>
#import "ReceiverViewController.h"
#import "SenderViewController.h"

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate,
                                   ReceiverViewControllerDelegate, SenderViewControllerDelegate>

@property (nonatomic, strong, readonly) NSWindow* mainWindow;
@property (nonatomic, strong, readonly) ReceiverViewController* receiverViewController;
@property (nonatomic, strong, readonly) SenderViewController* senderViewController;

@end

// SenderViewController.h

#import <Cocoa/Cocoa.h>

@protocol SenderViewControllerDelegate <NSObject>
- (void)senderDidUpdateStatus:(NSString*)status;
@end

@interface SenderViewController : NSViewController <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, weak) id<SenderViewControllerDelegate> delegate;

- (void)startDiscovery;
- (void)stopDiscovery;
- (BOOL)isConnected;

@end

#import "AppDelegate.h"
#import "FormRows.h"
#import "ReceiverViewController.h"
#import "SenderViewController.h"
#include "cast.h"

@interface AppDelegate ()
@property(nonatomic) ASCastRuntime *runtime;
@property(nonatomic, strong) NSWindow *mainWindow;
@property(nonatomic, strong) ReceiverViewController *receiver;
@property(nonatomic, strong) SenderViewController *sender;
@property(nonatomic) BOOL terminationPending;
@end
@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.runtime = ASCastRuntimeCreate();
    if (!self.runtime) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Cannot create the Cast runtime.";
        [alert runModal];
        [NSApp terminate:nil];
        return;
    }
    self.receiver = [[ReceiverViewController alloc] initWithRuntime:self.runtime];
    self.sender = [[SenderViewController alloc] initWithRuntime:self.runtime];
    NSTabViewController *tabs = [NSTabViewController new];
    tabs.tabStyle = NSTabViewControllerTabStyleSegmentedControlOnTop;
    NSTabViewItem *receiveTab = [NSTabViewItem tabViewItemWithViewController:self.receiver];
    receiveTab.label = @"Receiver";
    NSTabViewItem *sendTab = [NSTabViewItem tabViewItemWithViewController:self.sender];
    sendTab.label = @"Sender";
    [tabs addTabViewItem:receiveTab];
    [tabs addTabViewItem:sendTab];
    self.mainWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 720, 460)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                  NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.mainWindow.title = @"Applescreen";
    self.mainWindow.delegate = self;
    self.mainWindow.releasedWhenClosed = NO;
    self.mainWindow.contentViewController = tabs;
    self.mainWindow.contentMinSize = NSMakeSize(660, 420);
    [self.mainWindow center];
    [self.mainWindow makeKeyAndOrderFront:nil];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)application {
    if (!self.runtime) return NSTerminateNow;
    if (self.terminationPending) return NSTerminateLater;
    self.terminationPending = YES;
    // Main remains available for capture/native renderer completion callbacks.
    [self.sender stopWithCompletion:^{
        [self.receiver stopWithCompletion:^{
            ASCastRuntimeStop(self.runtime, ASInvokeCompletion, ASCompletionContext(^{
                ASCastRuntimeDestroy(self.runtime);
                self.runtime = NULL;
                [application replyToApplicationShouldTerminate:YES];
            }));
        }];
    }];
    return NSTerminateLater;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application { return YES; }
- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.mainWindow) [NSApp terminate:nil];
}
@end

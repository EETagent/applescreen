// AppDelegate.m
// Main application delegate with tabbed interface

#import "AppDelegate.h"

@interface AppDelegate ()

@property (nonatomic, strong) NSWindow* mainWindow;
@property (nonatomic, strong) NSTabView* tabView;
@property (nonatomic, strong) ReceiverViewController* receiverViewController;
@property (nonatomic, strong) SenderViewController* senderViewController;

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    [self createMainWindow];
}

- (void)createMainWindow {
    NSRect frame = NSMakeRect(200, 200, 520, 400);
    self.mainWindow = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:NSWindowStyleMaskTitled |
                                                           NSWindowStyleMaskClosable |
                                                           NSWindowStyleMaskMiniaturizable
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    self.mainWindow.title = @"Applescreen";
    self.mainWindow.delegate = self;

    self.tabView = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 520, 400)];
    self.tabView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSTabViewItem* receiverTab = [[NSTabViewItem alloc] initWithIdentifier:@"receiver"];
    receiverTab.label = @"Receiver";
    self.receiverViewController = [[ReceiverViewController alloc] init];
    self.receiverViewController.delegate = self;
    receiverTab.view = self.receiverViewController.view;
    [self.tabView addTabViewItem:receiverTab];

    NSTabViewItem* senderTab = [[NSTabViewItem alloc] initWithIdentifier:@"sender"];
    senderTab.label = @"Sender";
    self.senderViewController = [[SenderViewController alloc] init];
    self.senderViewController.delegate = self;
    senderTab.view = self.senderViewController.view;
    [self.tabView addTabViewItem:senderTab];

    [self.mainWindow.contentView addSubview:self.tabView];
    [self.mainWindow makeKeyAndOrderFront:nil];
}

#pragma mark - ReceiverViewControllerDelegate

- (void)receiverDidUpdateStatus:(NSString*)status {
    NSLog(@"Receiver: %@", status);
}

#pragma mark - SenderViewControllerDelegate

- (void)senderDidUpdateStatus:(NSString*)status {
    NSLog(@"Sender: %@", status);
}

#pragma mark - NSApplicationDelegate

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    [self.receiverViewController stopReceiver];
    [self.senderViewController stopDiscovery];
}

#pragma mark - NSWindowDelegate

- (void)windowWillClose:(NSNotification*)notification {
    if (notification.object == self.mainWindow) {
        [self.receiverViewController stopReceiver];
        [self.senderViewController stopDiscovery];
        [NSApp terminate:nil];
    }
}

@end

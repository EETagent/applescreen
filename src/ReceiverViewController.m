#import "ReceiverViewController.h"
#import "FormRows.h"
#import "VideoWindowController.h"
#include <net/if.h>

@interface ReceiverViewController ()
@property(nonatomic) ASCastRuntime *runtime;
@property(nonatomic) ASCastState state;
@property(nonatomic) uint64_t generation, mediaGeneration;
@property(nonatomic, strong) NSMutableArray<dispatch_block_t> *stopCompletions;
@property(nonatomic, strong) NSTextField *nameField, *caField, *keyField, *portField, *status;
@property(nonatomic, strong) NSPopUpButton *interfacePicker;
@property(nonatomic, strong) NSButton *startButton, *caButton, *keyButton;
@property(nonatomic, strong) VideoWindowController *videoWindow;
@property(nonatomic, copy) NSString *receiverID, *sessionName, *lastError;
@end
static void ReceiverEvent(void *context, const ASCastEvent *event);

@implementation ReceiverViewController
- (instancetype)initWithRuntime:(ASCastRuntime *)runtime {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _runtime = runtime;
        _state = ASCastIdle;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        _receiverID = [defaults stringForKey:@"receiverID"];
        if (!_receiverID.length) {
            _receiverID = [[[NSUUID.UUID UUIDString] stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
            [defaults setObject:_receiverID forKey:@"receiverID"];
        }
    }
    return self;
}
- (void)loadView {
    self.nameField = [NSTextField textFieldWithString:[NSString stringWithFormat:@"Applescreen on %@", NSProcessInfo.processInfo.hostName]];
    [self.nameField.widthAnchor constraintGreaterThanOrEqualToConstant:280].active = YES;
    self.interfacePicker = ASInterfacePicker(nil, NULL);
    self.portField = [NSTextField textFieldWithString:@"8010"];
    [self.portField.widthAnchor constraintEqualToConstant:90].active = YES;
    self.caField = ASPathField(@"Development CA certificate (.pem or .crt)");
    self.keyField = ASPathField(@"Matching development CA private key");
    self.caButton = [NSButton buttonWithTitle:@"Choose…" target:self action:@selector(chooseCA:)];
    self.keyButton = [NSButton buttonWithTitle:@"Choose…" target:self action:@selector(chooseKey:)];
    self.startButton = [NSButton buttonWithTitle:@"Start Receiver" target:self action:@selector(startOrStop:)];
    self.status = [NSTextField wrappingLabelWithString:@"Choose development credentials, then start listening."];
    NSTextField *explanation = [NSTextField wrappingLabelWithString:
        @"Senders must trust the selected development CA. Device authentication remains enabled. Closing a playback window ends that stream while this receiver keeps listening."];
    explanation.textColor = NSColor.secondaryLabelColor;
    self.view = ASForm(@[
        ASFieldRow(@"Receiver name", self.nameField),
        ASFieldRow(@"Interface", self.interfacePicker),
        ASFieldRow(@"Port", self.portField),
        ASFieldRow(@"Developer CA", ASButtons(@[self.caField, self.caButton])),
        ASFieldRow(@"CA key", ASButtons(@[self.keyField, self.keyButton])),
        explanation, ASButtons(@[self.startButton]), self.status]);
}
- (void)chooseCA:(id)sender { ASChooseFile(self.view.window, self.caField, @[@"crt", @"pem"]); }
- (void)chooseKey:(id)sender { ASChooseFile(self.view.window, self.keyField, @[@"key", @"pem"]); }
- (void)updateControls {
    if (!self.isViewLoaded) return;
    BOOL busy = self.generation != 0;
    for (NSControl *control in @[self.nameField, self.caField, self.keyField, self.portField,
                                 self.interfacePicker, self.caButton, self.keyButton]) control.enabled = !busy;
    self.startButton.title = busy ? @"Stop Receiver" : @"Start Receiver";
    self.startButton.enabled = self.stopCompletions == nil;
}
- (void)startOrStop:(id)sender {
    if (self.generation) {
        [self stopWithCompletion:^{}];
        return;
    }
    NSString *interface = ASSelectedInterface(self.interfacePicker);
    unsigned index = interface.length ? if_nametoindex(interface.UTF8String) : 0;
    if (interface.length && !index) {
        self.status.stringValue = @"The selected interface is no longer available.";
        return;
    }
    NSScanner *scanner = [NSScanner scannerWithString:self.portField.stringValue];
    int port = 0;
    if (![scanner scanInt:&port] || !scanner.isAtEnd || port < 1 || port > UINT16_MAX) {
        self.status.stringValue = @"Enter a port from 1 to 65535.";
        return;
    }
    if (!self.nameField.stringValue.length || !self.caField.stringValue.length || !self.keyField.stringValue.length) {
        self.status.stringValue = @"A receiver name, development CA and matching CA key are required.";
        return;
    }
    self.lastError = nil;
    self.sessionName = [self.nameField.stringValue copy];
    NSScreen *screen = self.view.window.screen ?: NSScreen.mainScreen;
    NSSize size = screen.frame.size;
    CGFloat scale = screen.backingScaleFactor;
    ASCastReceiverConfig config = {
        .receiver_id = self.receiverID.UTF8String, .name = self.sessionName.UTF8String,
        .developer_ca_path = self.caField.stringValue.UTF8String,
        .developer_key_path = self.keyField.stringValue.UTF8String,
        .interface_index = index, .port = (uint16_t)port,
        .display_width = (int)(size.width * scale), .display_height = (int)(size.height * scale),
        .max_fps = 60,
    };
    self.generation = ASCastStartReceiver(self.runtime, config, ReceiverEvent, (__bridge void *)self);
    if (!self.generation) self.status.stringValue = @"The receiver is still stopping. Try again when it is idle.";
    [self updateControls];
}
- (void)receiveEvent:(const ASCastEvent *)event {
    if (event->generation != self.generation) return;
    self.state = event->state;
    switch (event->state) {
        case ASCastStarting:
            self.status.stringValue = @"Opening listeners and publishing receiver…";
            break;
        case ASCastReady:
            self.lastError = [(__bridge NSString *)event->error copy];
            self.status.stringValue = self.lastError.length ?
                [NSString stringWithFormat:@"Stream ended: %@ Listening for a new connection.", self.lastError] :
                @"Listening for Cast connections.";
            [self.videoWindow closeWithoutStopping];
            self.videoWindow = nil;
            self.mediaGeneration = event->media_generation;
            break;
        case ASCastStreaming: {
            self.lastError = nil;
            self.status.stringValue = event->video ? @"Receiving video" : @"Receiving audio";
            if (event->audio && event->video) self.status.stringValue = @"Receiving audio and video";
            if (self.mediaGeneration != event->media_generation || !event->video_layer) {
                [self.videoWindow closeWithoutStopping];
                self.videoWindow = nil;
            }
            self.mediaGeneration = event->media_generation;
            if (event->video_layer && !self.videoWindow) {
                uint64_t generation = event->generation, media = event->media_generation;
                __weak ReceiverViewController *weakSelf = self;
                self.videoWindow = [[VideoWindowController alloc] initWithLayer:(__bridge CALayer *)event->video_layer
                    title:self.sessionName onClose:^{
                        ReceiverViewController *self = weakSelf;
                        if (!self || self.generation != generation || self.mediaGeneration != media) return;
                        ASCastStopReceiverMedia(self.runtime, generation, media);
                        self.videoWindow = nil;
                    }];
                [self.videoWindow showWindow:nil];
            }
            break;
        }
        case ASCastStopping:
            self.status.stringValue = @"Stopping receiver…";
            break;
        case ASCastFailed:
            self.lastError = [(__bridge NSString *)event->error copy] ?: @"Receiver failed.";
            self.status.stringValue = self.lastError;
            [self.videoWindow closeWithoutStopping];
            self.videoWindow = nil;
            if (!self.stopCompletions) [self stopWithCompletion:^{}];
            break;
        case ASCastStopped:
            [self.videoWindow closeWithoutStopping];
            self.videoWindow = nil;
            if (!self.stopCompletions) [self stopWithCompletion:^{}];
            break;
        default: break;
    }
    [self updateControls];
}
- (void)stopWithCompletion:(dispatch_block_t)completion {
    if (self.stopCompletions) {
        [self.stopCompletions addObject:[completion copy]];
        return;
    }
    self.stopCompletions = [NSMutableArray arrayWithObject:[completion copy]];
    [self updateControls];
    [self.videoWindow closeWithoutStopping];
    self.videoWindow = nil;
    ASCastStopReceiver(self.runtime, ASInvokeCompletion, ASCompletionContext(^{
        self.generation = self.mediaGeneration = 0;
        self.status.stringValue = self.lastError ?: @"Receiver stopped.";
        NSArray<dispatch_block_t> *completions = [self.stopCompletions copy];
        self.stopCompletions = nil;
        [self updateControls];
        for (dispatch_block_t done in completions) done();
    }));
}
@end
static void ReceiverEvent(void *context, const ASCastEvent *event) {
    [(__bridge ReceiverViewController *)context receiveEvent:event];
}

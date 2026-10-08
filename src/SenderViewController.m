#import "SenderViewController.h"
#import "FormRows.h"
#import "media/FileSource.h"
#import "media/ScreenSource.h"
#include <math.h>
#include <net/if.h>

@interface SenderViewController ()
@property(nonatomic) ASCastRuntime *runtime;
@property(nonatomic) ASCastState state;
@property(nonatomic) uint64_t generation, sourceEpoch;
@property(nonatomic, strong) id<ASMediaSource> source;
@property(nonatomic, strong) NSMutableArray<dispatch_block_t> *stopCompletions;
@property(nonatomic, strong) NSArray<NSDictionary *> *receivers;
@property(nonatomic, strong) NSPopUpButton *receiverPicker, *interfacePicker, *sourcePicker, *codecPicker;
@property(nonatomic, strong) NSTextField *fileField, *caField, *status;
@property(nonatomic, strong) NSButton *connectButton, *fileButton, *caButton;
@property(nonatomic, copy) NSString *lastMessage;
@property(nonatomic) BOOL discoveryNeedsRetry;
@end

static void SenderEvent(void *context, const ASCastEvent *event);
static void DiscoveryEvent(void *context, CFArrayRef snapshot, CFStringRef error);

@implementation SenderViewController
- (instancetype)initWithRuntime:(ASCastRuntime *)runtime {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _runtime = runtime;
        _receivers = @[];
        _state = ASCastIdle;
    }
    return self;
}
- (void)loadView {
    self.receiverPicker = [[NSPopUpButton alloc] init];
    self.receiverPicker.target = self;
    self.receiverPicker.action = @selector(selectionChanged:);
    [self.receiverPicker.widthAnchor constraintGreaterThanOrEqualToConstant:260].active = YES;
    NSButton *refresh = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refresh:)];
    self.interfacePicker = ASInterfacePicker(self, @selector(interfaceChanged:));
    self.sourcePicker = [[NSPopUpButton alloc] init];
    [self.sourcePicker addItemsWithTitles:@[@"Screen", @"File (audio and/or video)"]];
    self.sourcePicker.target = self;
    self.sourcePicker.action = @selector(selectionChanged:);
    self.fileField = ASPathField(@"Select a media file");
    self.fileButton = [NSButton buttonWithTitle:@"Choose…" target:self action:@selector(chooseMedia:)];
    self.caField = ASPathField(@"Normal Cast trust (optional development CA)");
    self.caButton = [NSButton buttonWithTitle:@"Choose…" target:self action:@selector(chooseCA:)];
    self.codecPicker = [[NSPopUpButton alloc] init];
    for (NSNumber *value in @[@(ASCastVP8), @(ASCastVP9), @(ASCastAV1)]) {
        if (!ASCastSupportsCodec(value.intValue)) continue;
        [self.codecPicker addItemWithTitle:@[@"VP8", @"VP9", @"AV1"][value.unsignedIntegerValue]];
        self.codecPicker.lastItem.representedObject = value;
    }
    self.connectButton = [NSButton buttonWithTitle:@"Connect" target:self action:@selector(connectOrStop:)];
    self.status = [NSTextField wrappingLabelWithString:@"Discovering Cast receivers…"];
    self.view = ASForm(@[
        ASFieldRow(@"Receiver", ASButtons(@[self.receiverPicker, refresh])),
        ASFieldRow(@"Interface", self.interfacePicker),
        ASFieldRow(@"Source", self.sourcePicker),
        ASFieldRow(@"Media file", ASButtons(@[self.fileField, self.fileButton])),
        ASFieldRow(@"Video codec", self.codecPicker),
        ASFieldRow(@"Developer CA", ASButtons(@[self.caField, self.caButton])),
        ASButtons(@[self.connectButton]), self.status]);
    [self updateControls];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationBecameActive:)
        name:NSApplicationDidBecomeActiveNotification object:NSApp];
    [self interfaceChanged:nil];
}
- (void)updateControls {
    BOOL busy = self.source != nil || self.generation != 0;
    BOOL stopping = self.stopCompletions != nil;
    self.receiverPicker.enabled = !busy;
    self.interfacePicker.enabled = !busy;
    self.sourcePicker.enabled = !busy;
    self.codecPicker.enabled = !busy;
    self.caField.enabled = !busy;
    self.caButton.enabled = !busy;
    self.fileField.enabled = !busy && self.sourcePicker.indexOfSelectedItem == 1;
    self.fileButton.enabled = self.fileField.enabled;
    self.connectButton.title = busy ? @"Disconnect" : @"Connect";
    self.connectButton.enabled = !stopping && (busy || self.receivers.count > 0);
    if (self.lastMessage.length) self.status.stringValue = self.lastMessage;
}
- (void)selectionChanged:(id)sender { [self updateControls]; }
- (void)chooseMedia:(id)sender { ASChooseFile(self.view.window, self.fileField, nil); }
- (void)chooseCA:(id)sender { ASChooseFile(self.view.window, self.caField, @[@"pem", @"crt"]); }
- (void)refresh:(id)sender { ASCastRefresh(self.runtime); }
- (void)applicationBecameActive:(NSNotification *)notification {
    // DNSService may reject the first operation while the privacy prompt is
    // still open. Retry after the answer or after returning from Settings;
    // never poll or repeatedly prompt when permission remains denied.
    if (self.discoveryNeedsRetry) [self refresh:nil];
}
- (void)interfaceChanged:(id)sender {
    NSString *name = ASSelectedInterface(self.interfacePicker);
    unsigned index = name.length ? if_nametoindex(name.UTF8String) : 0;
    if (name.length && index == 0) {
        self.lastMessage = @"The selected interface is no longer available.";
        [self updateControls];
        return;
    }
    ASCastBrowse(self.runtime, index, DiscoveryEvent, (__bridge void *)self);
}
- (void)receiveSnapshot:(NSArray *)snapshot error:(NSString *)error {
    self.discoveryNeedsRetry = error != nil;
    NSString *selectedID = self.receiverPicker.selectedItem.representedObject;
    NSMutableDictionary<NSString *, NSMutableArray *> *groups = [NSMutableDictionary dictionary];
    for (NSDictionary *candidate in snapshot) {
        NSString *key = candidate[@"id"];
        if (!key.length) continue;
        if (!groups[key]) groups[key] = [NSMutableArray array];
        [groups[key] addObject:candidate];
    }
    NSMutableArray *receivers = [NSMutableArray array];
    for (NSString *key in groups) {
        NSArray *candidates = [groups[key] copy];
        NSDictionary *first = candidates.firstObject;
        [receivers addObject:@{@"id":key, @"name":first[@"name"] ?: key, @"candidates":candidates}];
    }
    [receivers sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult result = [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        return result == NSOrderedSame ? [a[@"id"] compare:b[@"id"]] : result;
    }];
    self.receivers = [receivers copy];
    [self.receiverPicker removeAllItems];
    for (NSDictionary *receiver in self.receivers) {
        // Friendly names need not be unique; preserve one menu item per Cast ID.
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:receiver[@"name"] action:NULL keyEquivalent:@""];
        item.representedObject = receiver[@"id"];
        [self.receiverPicker.menu addItem:item];
        if ([receiver[@"id"] isEqual:selectedID]) [self.receiverPicker selectItem:item];
    }
    if (self.receiverPicker.indexOfSelectedItem < 0 && self.receivers.count)
        [self.receiverPicker selectItemAtIndex:0];
    if (!self.source && !self.generation) self.lastMessage = error ?: (receivers.count ? @"Select a receiver and source." : @"No Cast receivers found.");
    [self updateControls];
}
- (void)connectOrStop:(id)sender {
    if (self.source || self.generation) {
        [self stopWithCompletion:^{}];
        return;
    }
    NSInteger selection = self.receiverPicker.indexOfSelectedItem;
    if (selection < 0 || selection >= (NSInteger)self.receivers.count) return;
    NSArray *candidates = self.receivers[selection][@"candidates"];
    NSString *interface = [ASSelectedInterface(self.interfacePicker) copy];
    NSString *ca = [self.caField.stringValue copy];
    ASCastCodec codec = [self.codecPicker.selectedItem.representedObject intValue];
    if (self.sourcePicker.indexOfSelectedItem == 1) {
        if (!self.fileField.stringValue.length) {
            self.lastMessage = @"Choose a media file first.";
            [self updateControls];
            return;
        }
        self.source = [[ASFileSource alloc] initWithURL:[NSURL fileURLWithPath:self.fileField.stringValue]];
    } else {
        self.source = [[ASScreenSource alloc] initWithDisplayID:0];
    }
    id<ASMediaSource> source = self.source;
    uint64_t epoch = ++self.sourceEpoch;
    self.lastMessage = @"Inspecting source…";
    [self updateControls];
    __weak SenderViewController *weakSelf = self;
    [source prepareWithCompletion:^(ASMediaSourceDescriptor descriptor, NSError *error) {
        SenderViewController *self = weakSelf;
        if (!self || self.sourceEpoch != epoch || self.source != source) return;
        if (error) {
            self.lastMessage = error.localizedDescription;
            [self stopWithCompletion:^{}];
            return;
        }
        if (descriptor.width > INT_MAX || descriptor.height > INT_MAX ||
            (descriptor.hasVideo && (!isfinite(descriptor.framesPerSecond) || descriptor.framesPerSecond <= 0))) {
            self.lastMessage = @"The source dimensions or frame rate are invalid.";
            [self stopWithCompletion:^{}];
            return;
        }
        ASCastSenderConfig config = {
            .interface_name = interface.UTF8String, .developer_ca_path = ca.UTF8String,
            .video = descriptor.hasVideo, .audio = descriptor.hasAudio,
            .width = (int)descriptor.width, .height = (int)descriptor.height,
            .fps_numerator = descriptor.hasVideo ? (int)llround(MIN(descriptor.framesPerSecond, 240) * 1000) : 0,
            .fps_denominator = 1000, .sample_rate = (int)descriptor.audioSampleRate,
            .channels = (int)descriptor.audioChannels, .max_bitrate = 8000000, .codec = codec,
        };
        self.generation = ASCastStartSender(self.runtime, config, (__bridge CFArrayRef)candidates,
                                            SenderEvent, (__bridge void *)self);
        if (!self.generation) {
            self.lastMessage = @"The sender is still stopping. Try again when it is idle.";
            [self stopWithCompletion:^{}];
        }
    }];
}
- (void)receiveEvent:(const ASCastEvent *)event {
    if (event->generation != self.generation) return;
    ASCastState previous = self.state;
    self.state = event->state;
    switch (event->state) {
        case ASCastStarting:
            self.lastMessage = @"Connecting and negotiating…";
            break;
        case ASCastReady: {
            self.lastMessage = @"Casting";
            if (previous == ASCastReady || self.stopCompletions) break;
            if ([self.source isKindOfClass:ASScreenSource.class] && event->fps_denominator > 0) {
                [(ASScreenSource *)self.source applyVideoWidth:event->width height:event->height
                    framesPerSecond:(double)event->fps_numerator / event->fps_denominator];
            }
            ASCastRuntime *runtime = self.runtime;
            uint64_t generation = self.generation;
            uint64_t epoch = self.sourceEpoch;
            __weak SenderViewController *weakSelf = self;
            [self.source startWithSubmit:^ASMediaSubmitResult(CMSampleBufferRef sample, ASMediaTrack track, ASMediaTime time) {
                CMTime host = time.domain == ASMediaTimestampHostClock ? time.presentationTime :
                    CMTimeAdd(time.hostOrigin, CMTimeSubtract(time.presentationTime, time.sourceOrigin));
                ASCastSubmission result = ASCastSubmit(runtime, generation,
                    track == ASMediaTrackVideo ? ASCastVideo : ASCastAudio, sample, host);
                switch (result) {
                    case ASCastAccepted: return ASMediaSubmitAccepted;
                    case ASCastBackpressured: return ASMediaSubmitBackpressured;
                    case ASCastNotReady: return ASMediaSubmitNotReady;
                    case ASCastSubmissionStopped: return ASMediaSubmitStopped;
                    case ASCastInvalidSample: return ASMediaSubmitError;
                }
            } completion:^(NSError *error) {
                SenderViewController *self = weakSelf;
                if (!self || self.sourceEpoch != epoch) return;
                if (error) {
                    self.lastMessage = error.localizedDescription;
                    [self stopWithCompletion:^{}];
                } else {
                    self.lastMessage = @"Finishing file…";
                    ASCastFinishSender(self.runtime, generation);
                    [self updateControls];
                }
            }];
            break;
        }
        case ASCastFailed:
            self.lastMessage = [(__bridge NSString *)event->error copy] ?: @"Cast session failed.";
            if (!self.stopCompletions) [self stopWithCompletion:^{}];
            break;
        case ASCastStopped:
            if ([self.lastMessage isEqualToString:@"Finishing file…"]) self.lastMessage = @"File completed.";
            if (!self.stopCompletions) [self stopWithCompletion:^{}];
            break;
        case ASCastStopping: break;
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
    ++self.sourceEpoch;
    [self updateControls];
    dispatch_block_t stopSession = ^{
        self.source = nil;
        ASCastStopSender(self.runtime, ASInvokeCompletion, ASCompletionContext(^{
            self.generation = 0;
            NSArray<dispatch_block_t> *completions = [self.stopCompletions copy];
            self.stopCompletions = nil;
            if ([self.lastMessage isEqualToString:@"Casting"] || [self.lastMessage hasPrefix:@"Connecting"])
                self.lastMessage = @"Disconnected.";
            [self updateControls];
            for (dispatch_block_t done in completions) done();
        }));
    };
    if (self.source) [self.source stopWithCompletion:stopSession];
    else stopSession();
}
@end
static void SenderEvent(void *context, const ASCastEvent *event) {
    [(__bridge SenderViewController *)context receiveEvent:event];
}
static void DiscoveryEvent(void *context, CFArrayRef snapshot, CFStringRef error) {
    [(__bridge SenderViewController *)context receiveSnapshot:(__bridge NSArray *)snapshot error:(__bridge NSString *)error];
}

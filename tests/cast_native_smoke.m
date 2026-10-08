#import <Cocoa/Cocoa.h>
#import "cast.h"
#import "media/FileSource.h"
#import "media/ScreenSource.h"
#import "VideoWindowController.h"
#import "FormRows.h"
#include <net/if.h>
#include <math.h>

// Separate processes exercise native DNS, authentication, negotiation, source
// admission, FFmpeg decode and timed renderers. This is a bounded integration
// fixture, not evidence of measured speaker/display skew or a second host.
@interface ASCastSmoke : NSObject
@property(nonatomic) ASCastRuntime *runtime;
@property(nonatomic, strong) NSDictionary<NSString *, NSString *> *options;
@property(nonatomic, strong) id<ASMediaSource> source;
@property(nonatomic) ASMediaSourceDescriptor descriptor;
@property(nonatomic) uint64_t generation, mediaGeneration;
@property(nonatomic) ASCastState state;
@property(nonatomic) NSUInteger completedSessions;
@property(nonatomic) NSUInteger accepted;
@property(nonatomic) BOOL stopping, finished, failed, ready;
@property(nonatomic, strong) VideoWindowController *window;
- (void)start;
- (void)stop:(NSString *)error;
- (void)event:(const ASCastEvent *)event;
- (void)snapshot:(NSArray *)snapshot error:(NSString *)error;
@end
static void Observe(void *context, const ASCastEvent *event) { [(__bridge ASCastSmoke *)context event:event]; }
static void Browse(void *context, CFArrayRef snapshot, CFStringRef error) {
    [(__bridge ASCastSmoke *)context snapshot:(__bridge NSArray *)snapshot error:(__bridge NSString *)error];
}
@implementation ASCastSmoke
- (void)start {
    self.runtime = ASCastRuntimeCreate();
    if (!self.runtime) { [self stop:@"Runtime creation failed"]; return; }
    NSString *interface = self.options[@"interface"] ?: @"";
    unsigned index = interface.length ? if_nametoindex(interface.UTF8String) : 0;
    if (interface.length && !index) { [self stop:@"Requested interface is missing"]; return; }
    if (self.options[@"receiver"]) {
        ASCastReceiverConfig config = {
            .receiver_id = "3d5cbe69a9a2491e9fd36b4112ef77a3",
            .name = [self.options[@"name"] ?: @"Applescreen native smoke" UTF8String],
            .developer_ca_path = self.options[@"ca"].UTF8String,
            .developer_key_path = self.options[@"key"].UTF8String,
            .interface_index = index, .port = (uint16_t)(self.options[@"port"] ?: @"8010").intValue,
            .display_width = 640, .display_height = 360, .max_fps = 60,
        };
        self.generation = ASCastStartReceiver(self.runtime, config, Observe, (__bridge void *)self);
    } else {
        if (self.options[@"screen"]) {
            if (!CGPreflightScreenCaptureAccess()) {
                [self stop:@"Screen Recording permission is unavailable for this test process"]; return;
            }
            self.source = [[ASScreenSource alloc] initWithDisplayID:0];
        } else self.source = [[ASFileSource alloc] initWithURL:[NSURL fileURLWithPath:self.options[@"file"]]];
        [self.source prepareWithCompletion:^(ASMediaSourceDescriptor descriptor, NSError *error) {
            if (self.stopping) return;
            if (error) { [self stop:error.localizedDescription]; return; }
            self.descriptor = descriptor;
            ASCastBrowse(self.runtime, index, Browse, (__bridge void *)self);
        }];
    }
    NSTimeInterval timeout = (self.options[@"timeout"] ?: @"30").doubleValue;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.finished && !self.stopping) [self stop:@"Integration deadline exceeded"];
    });
}
- (void)snapshot:(NSArray *)snapshot error:(NSString *)error {
    if (self.generation || self.stopping) return;
    if (error) { [self stop:error]; return; }
    NSString *name = self.options[@"name"] ?: @"Applescreen native smoke";
    NSMutableArray *candidates = [NSMutableArray array];
    for (NSDictionary *candidate in snapshot) if ([candidate[@"name"] isEqual:name]) [candidates addObject:candidate];
    if (!candidates.count) return;
    ASMediaSourceDescriptor value = self.descriptor;
    ASCastSenderConfig config = {
        .interface_name = self.options[@"interface"].UTF8String,
        .developer_ca_path = self.options[@"ca"].UTF8String,
        .video = value.hasVideo, .audio = value.hasAudio,
        .width = (int)value.width, .height = (int)value.height,
        .fps_numerator = value.hasVideo ? (int)llround(value.framesPerSecond * 1000) : 0,
        .fps_denominator = 1000, .sample_rate = (int)value.audioSampleRate,
        .channels = (int)value.audioChannels, .max_bitrate = 2000000,
        .codec = [self.options[@"codec"] isEqual:@"vp9"] ? ASCastVP9 :
                 [self.options[@"codec"] isEqual:@"av1"] ? ASCastAV1 : ASCastVP8,
    };
    self.generation = ASCastStartSender(self.runtime, config, (__bridge CFArrayRef)candidates, Observe, (__bridge void *)self);
    if (!self.generation) [self stop:@"Sender start was rejected"];
}
- (void)event:(const ASCastEvent *)event {
    if (event->generation != self.generation || self.stopping) return;
    ASCastState previous = self.state;
    self.state = event->state;
    fprintf(stderr, "%s generation=%llu media=%llu state=%d video=%d audio=%d error=%s\n",
        self.options[@"receiver"] ? "receiver" : "sender", event->generation, event->media_generation,
        event->state, event->video, event->audio, event->error ? [(__bridge NSString *)event->error UTF8String] : "none");
    if (event->error || event->state == ASCastFailed) {
        [self stop:(__bridge NSString *)event->error ?: @"Cast failure"]; return;
    }
    if (self.options[@"receiver"]) {
        if (event->state == ASCastReady) {
            self.ready = YES;
            [self.window closeWithoutStopping]; self.window = nil;
            if (previous == ASCastStreaming) ++self.completedSessions;
            NSUInteger count = (self.options[@"sessions"] ?: @"1").integerValue;
            if (self.completedSessions >= count) [self stop:nil];
        } else if (event->state == ASCastStreaming && event->video_layer && self.options[@"window"]) {
            if (self.mediaGeneration != event->media_generation) {
                [self.window closeWithoutStopping];
                self.window = [[VideoWindowController alloc] initWithLayer:(__bridge CALayer *)event->video_layer
                    title:@"Applescreen integration receiver" onClose:^{ [self stop:@"Playback window closed during integration"]; }];
                [self.window showWindow:nil];
            }
        }
        self.mediaGeneration = event->media_generation;
    } else if (event->state == ASCastReady && !self.ready) {
        self.ready = YES;
        if ([self.source isKindOfClass:ASScreenSource.class]) {
            [(ASScreenSource *)self.source applyVideoWidth:event->width height:event->height
                framesPerSecond:(double)event->fps_numerator / event->fps_denominator];
        }
        ASCastRuntime *runtime = self.runtime;
        uint64_t generation = self.generation;
        [self.source startWithSubmit:^ASMediaSubmitResult(CMSampleBufferRef sample, ASMediaTrack track, ASMediaTime time) {
            CMTime host = time.domain == ASMediaTimestampHostClock ? time.presentationTime :
                CMTimeAdd(time.hostOrigin, CMTimeSubtract(time.presentationTime, time.sourceOrigin));
            switch (ASCastSubmit(runtime, generation, track == ASMediaTrackAudio ? ASCastAudio : ASCastVideo, sample, host)) {
                case ASCastAccepted: ++self.accepted; return ASMediaSubmitAccepted;
                case ASCastBackpressured: return ASMediaSubmitBackpressured;
                case ASCastNotReady: return ASMediaSubmitNotReady;
                case ASCastSubmissionStopped: return ASMediaSubmitStopped;
                case ASCastInvalidSample: return ASMediaSubmitError;
            }
        } completion:^(NSError *error) {
            if (error) [self stop:error.localizedDescription];
            else ASCastFinishSender(self.runtime, generation);
        }];
        if (self.options[@"screen"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (!self.stopping) [self stop:nil];
            });
        }
    } else if (event->state == ASCastStopped) {
        [self stop:self.ready ? nil : @"Sender stopped before readiness"];
    }
}
- (void)stop:(NSString *)error {
    if (self.stopping) return;
    self.stopping = YES;
    self.failed = error != nil;
    if (error) fprintf(stderr, "FAIL: %s\n", error.UTF8String);
    [self.window closeWithoutStopping]; self.window = nil;
    dispatch_block_t stopRuntime = ^{
        self.source = nil;
        if (self.options[@"sender"] && self.ready && !self.accepted) {
            self.failed = YES;
            fputs("FAIL: ready sender accepted no source buffers\n", stderr);
        }
        ASCastRuntimeStop(self.runtime, ASInvokeCompletion, ASCompletionContext(^{
            ASCastRuntimeDestroy(self.runtime); self.runtime = NULL;
            self.finished = YES;
            fprintf(stderr, "Native Cast %s: %s (%lu completed receiver sessions)\n",
                self.options[@"receiver"] ? "receiver" : "sender", self.failed ? "FAIL" : "PASS",
                (unsigned long)self.completedSessions);
        }));
    };
    if (self.source) [self.source stopWithCompletion:stopRuntime]; else stopRuntime();
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableDictionary<NSString *, NSString *> *options = [NSMutableDictionary dictionary];
        for (int index = 1; index < argc; ++index) {
            NSString *option = [NSString stringWithUTF8String:argv[index]];
            if (![@[@"--receiver", @"--sender", @"--window", @"--screen"] containsObject:option]) {
                if (![option hasPrefix:@"--"] || index + 1 == argc) return 2;
                options[[option substringFromIndex:2]] = [NSString stringWithUTF8String:argv[++index]];
            } else options[[option substringFromIndex:2]] = @"yes";
        }
        if ((!options[@"receiver"] == !options[@"sender"]) || !options[@"ca"] ||
            (options[@"receiver"] && !options[@"key"]) ||
            (options[@"sender"] && (!options[@"file"] == !options[@"screen"]))) {
            fputs("Usage: cast_native_smoke --receiver --ca CERT --key KEY [--sessions N] [--window]\n"
                  "   or: cast_native_smoke --sender --ca CERT (--file MEDIA | --screen) [--name NAME] [--interface IFACE]\n", stderr);
            return 2;
        }
        if (options[@"codec"] && ![@[@"vp8", @"vp9", @"av1"] containsObject:options[@"codec"]]) return 2;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        ASCastSmoke *smoke = [ASCastSmoke new];
        smoke.options = options;
        [smoke start];
        CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + (options[@"timeout"] ?: @"30").doubleValue + 10;
        while (!smoke.finished && CFAbsoluteTimeGetCurrent() < deadline)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
        if (!smoke.finished) { fputs("FAIL: shutdown completion deadline exceeded\n", stderr); return 1; }
        return smoke.failed ? 1 : 0;
    }
}

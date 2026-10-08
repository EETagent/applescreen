#import <Foundation/Foundation.h>
#import "../native/cast.h"
#import "../src/media/FileSource.h"
#include <atomic>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <functional>
#include <net/if.h>
#include <unistd.h>

// Opt-in native test: one real runtime, normal Cast challenge with explicitly
// selected development trust, DNSService discovery, codec and native playback.
// Uses the FileSource fixtures instead of maintaining a second media generator.
// Local coexistence is not evidence of interoperability with another machine.
namespace {
void Wait(const std::function<bool()>& finished) {
  const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 20;
  while (!finished()) {
    assert(CFAbsoluteTimeGetCurrent() < deadline && "Native Cast loopback timed out");
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
  }
}
struct State {
  ASCastRuntime* runtime = nullptr;
  uint64_t sender = 0, receiver = 0;
  NSString* receiver_id = nil;
  NSArray* candidates = nil;
  bool sender_ready = false, receiver_ready = false, streaming = false;
  bool finished = false, sender_stopped = false, refresh = false;
  bool prepared = false, source_stopped = false;
  bool cancel = false;
  ASMediaSourceDescriptor descriptor{};
  int terminals = 0;
  CFAbsoluteTime eof = 0, terminal = 0;
  std::atomic<int> accepted{0};
};
void Event(void* context, const ASCastEvent* event) {
  auto& state = *static_cast<State*>(context);
  assert([NSThread isMainThread]);
  if (event->error) {
    fprintf(stderr, "Cast event error: %s\n", [(__bridge NSString*)event->error UTF8String]);
    assert(false);
  }
  (void)state;
  if (event->state == ASCastFailed) assert(false);
}
void ReceiverEvent(void* context, const ASCastEvent* event) {
  Event(context, event);
  auto& state = *static_cast<State*>(context);
  assert(event->generation == state.receiver);
  if (event->state == ASCastReady) state.receiver_ready = true;
  if (event->state == ASCastStreaming) state.streaming = true;
}
void SenderEvent(void* context, const ASCastEvent* event) {
  Event(context, event);
  auto& state = *static_cast<State*>(context);
  assert(event->generation == state.sender);
  if (event->state == ASCastReady) state.sender_ready = true;
  if (event->state == ASCastStopped) {
    assert(state.finished && !state.sender_stopped);
    state.sender_stopped = true;
    state.terminal = CFAbsoluteTimeGetCurrent();
    ++state.terminals;
  }
}
void Snapshot(void* context, CFArrayRef snapshot, CFStringRef error) {
  auto& state = *static_cast<State*>(context);
  if (error) fprintf(stderr, "Discovery error: %s\n", [(__bridge NSString*)error UTF8String]);
  assert(!error);
  NSMutableArray* matching = [NSMutableArray array];
  for (NSDictionary* candidate in (__bridge NSArray*)snapshot)
    if ([candidate[@"id"] isEqual:state.receiver_id]) [matching addObject:candidate];
  state.candidates = [matching copy];
}
}
int main(int argc, const char* argv[]) {
  if (argc != 4 && (argc != 5 || strcmp(argv[4], "--cancel"))) {
    fprintf(stderr, "Usage: %s FIXTURE DEVELOPMENT_CA DEVELOPMENT_KEY [--cancel]\n", argv[0]);
    return 2;
  }
  @autoreleasepool {
    State state;
    state.cancel = argc == 5;
    State* test = &state;
    state.runtime = ASCastRuntimeCreate();
    assert(state.runtime);
    state.receiver_id = [NSString stringWithFormat:@"applescreen-loopback-%d", getpid()];
    NSString* name = [NSString stringWithFormat:@"Applescreen loopback %d", getpid()];
    uint32_t interface = if_nametoindex("lo0");
    assert(interface);
    ASCastReceiverConfig receiver{};
    receiver.receiver_id = state.receiver_id.UTF8String;
    receiver.name = name.UTF8String;
    receiver.developer_ca_path = argv[2]; receiver.developer_key_path = argv[3];
    receiver.interface_index = interface; receiver.port = 18009;
    receiver.display_width = 640; receiver.display_height = 360; receiver.max_fps = 60;
    state.receiver = ASCastStartReceiver(state.runtime, receiver, ReceiverEvent, &state);
    assert(state.receiver);
    ASCastBrowse(state.runtime, interface, Snapshot, &state);
    ASFileSource* source = [[ASFileSource alloc] initWithURL:[NSURL fileURLWithPath:@(argv[1])]];
    [source prepareWithCompletion:^(ASMediaSourceDescriptor value, NSError* error) {
      if (error) fprintf(stderr, "Source preparation: %s\n", error.localizedDescription.UTF8String);
      assert(!error);
      test->descriptor = value; test->prepared = true;
    }];
    Wait([&] { return state.prepared && state.receiver_ready && state.candidates.count; });
    ASMediaSourceDescriptor descriptor = state.descriptor;
    ASCastSenderConfig sender{};
    sender.interface_name = "lo0"; sender.developer_ca_path = argv[2];
    sender.video = descriptor.hasVideo; sender.audio = descriptor.hasAudio;
    sender.width = descriptor.width; sender.height = descriptor.height;
    sender.fps_numerator = llround(descriptor.framesPerSecond * 1000); sender.fps_denominator = 1000;
    sender.channels = descriptor.audioChannels; sender.sample_rate = descriptor.audioSampleRate;
    sender.max_bitrate = 2000000; sender.codec = ASCastVP8;
    state.sender = ASCastStartSender(state.runtime, sender, (__bridge CFArrayRef)state.candidates, SenderEvent, &state);
    assert(state.sender);
    Wait([&] { return state.sender_ready && state.streaming; });
    [source startWithSubmit:^ASMediaSubmitResult(CMSampleBufferRef sample, ASMediaTrack track, ASMediaTime timing) {
      CMTime host = CMTimeAdd(timing.hostOrigin, CMTimeSubtract(timing.presentationTime, timing.sourceOrigin));
      auto result = ASCastSubmit(test->runtime, test->sender,
          track == ASMediaTrackVideo ? ASCastVideo : ASCastAudio, sample, host);
      if (result == ASCastAccepted && test->accepted.fetch_add(1) == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
          assert(!test->sender_stopped);
          ASCastRefresh(test->runtime); test->refresh = true;
          if (test->cancel) {
            [source stopWithCompletion:^{
              test->finished = true; test->eof = CFAbsoluteTimeGetCurrent();
              ASCastStopSender(test->runtime, nullptr, nullptr);
            }];
          }
        });
      }
      switch (result) {
        case ASCastAccepted: return ASMediaSubmitAccepted;
        case ASCastBackpressured: return ASMediaSubmitBackpressured;
        case ASCastNotReady: return ASMediaSubmitNotReady;
        case ASCastSubmissionStopped: return ASMediaSubmitStopped;
        case ASCastInvalidSample: return ASMediaSubmitError;
      }
    } completion:^(NSError* error) {
      if (error) fprintf(stderr, "Source completion: %s\n", error.localizedDescription.UTF8String);
      assert(!test->cancel && !error && test->accepted && test->refresh && !test->sender_stopped);
      test->finished = true; test->eof = CFAbsoluteTimeGetCurrent();
      ASCastFinishSender(test->runtime, test->sender);
    }];
    Wait([&] { return state.sender_stopped; });
    assert(state.terminals == 1);
    // The final decoded frame's estimated playout time is later than file EOF.
    // An immediate canceling Stop would complete too early and lose the tail.
    assert((state.cancel || state.terminal - state.eof > 0.05) && state.terminal - state.eof < 6);
    [source stopWithCompletion:^{ test->source_stopped = true; }];
    Wait([&] { return state.source_stopped; });
    bool stopped = false;
    ASCastRuntimeStop(state.runtime, [](void* value) { *static_cast<bool*>(value) = true; }, &stopped);
    Wait([&] { return stopped; });
    ASCastRuntimeDestroy(state.runtime);
    printf("One-runtime Cast: authenticated, streamed %d accepted buffers, refreshed during playback, %s %.3f s, stopped\n",
           state.accepted.load(), state.cancel ? "canceled" : "EOF drain", state.terminal - state.eof);
  }
}

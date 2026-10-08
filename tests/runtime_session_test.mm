#import <Foundation/Foundation.h>
#import "../native/cast.h"
#include <cassert>
#include <cstdio>
#include <functional>

namespace {
void Wait(const std::function<bool()>& finished) {
  const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 5;
  while (!finished()) {
    assert(CFAbsoluteTimeGetCurrent() < deadline && "Native lifecycle deadline exceeded");
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
  }
}
void Count(void* context) { ++*static_cast<int*>(context); }
struct Events {
  uint64_t generation = 0;
  unsigned callbacks = 0, terminal = 0;
  bool stop_completed = false;
};
void Observe(void* context, const ASCastEvent* event) {
  auto& events = *static_cast<Events*>(context);
  assert([NSThread isMainThread]);
  assert(!events.stop_completed);
  assert(event->generation == events.generation);
  ++events.callbacks;
  if (event->state == ASCastFailed || event->state == ASCastStopped) ++events.terminal;
}
void Stopped(void* context) { static_cast<Events*>(context)->stop_completed = true; }
ASCastSenderConfig Audio() {
  ASCastSenderConfig config{};
  config.audio = true; config.channels = 2; config.sample_rate = 48000;
  config.fps_numerator = 30; config.fps_denominator = 1;
  config.max_bitrate = 1000000; config.codec = ASCastVP8;
  return config;
}
ASCastReceiverConfig InvalidReceiver() {
  ASCastReceiverConfig config{};
  config.receiver_id = "11d75dbfbceb4fe1b2a4b3e996ca614b";
  config.name = "Lifecycle test";
  config.developer_ca_path = "/nonexistent/applescreen-test-ca.pem";
  config.developer_key_path = "/nonexistent/applescreen-test-key.pem";
  config.port = 8010; config.display_width = 640; config.display_height = 360; config.max_fps = 30;
  return config;
}
void DrainMain() {
  bool fence = false;
  bool* done = &fence;
  dispatch_async(dispatch_get_main_queue(), ^{ *done = true; });
  Wait([&] { return fence; });
}
}
int main() {
  @autoreleasepool {
    assert(ASCastSupportsCodec(ASCastVP8));
    assert(ASCastSupportsCodec(ASCastVP9));
    assert(!ASCastSupportsCodec(static_cast<ASCastCodec>(1000)));
    ASCastRuntime* runtime = ASCastRuntimeCreate();
    assert(runtime && !ASCastRuntimeCreate());
    // Actual platform runner, no signals or readiness sleeps. Exercise both
    // roles and duplicate Stop while terminal callbacks are pending on main.
    for (int iteration = 0; iteration != 30; ++iteration) {
      Events sender, receiver;
      auto config = Audio();
      if (iteration % 2) config.interface_name = "applescreen-invalid-interface";
      sender.generation = ASCastStartSender(runtime, config, (__bridge CFArrayRef)@[], Observe, &sender);
      receiver.generation = ASCastStartReceiver(runtime, InvalidReceiver(), Observe, &receiver);
      assert(sender.generation && receiver.generation);
      assert(ASCastStartSender(runtime, config, nullptr, Observe, &sender) == 0);
      int repeated = 0;
      ASCastStopSender(runtime, Stopped, &sender);
      ASCastStopSender(runtime, Count, &repeated);
      ASCastStopReceiver(runtime, Stopped, &receiver);
      ASCastStopReceiver(runtime, Count, &repeated);
      Wait([&] { return sender.stop_completed && receiver.stop_completed && repeated == 2; });
      assert(sender.terminal <= 1 && receiver.terminal <= 1);
      assert(ASCastSubmit(runtime, sender.generation, ASCastVideo, nullptr, kCMTimeZero) != ASCastAccepted);
      DrainMain(); // No queued callback can survive the session stop fence.
    }
    Events sender, receiver;
    sender.generation = ASCastStartSender(runtime, Audio(), nullptr, Observe, &sender);
    receiver.generation = ASCastStartReceiver(runtime, InvalidReceiver(), Observe, &receiver);
    int completed = 0;
    ASCastRuntimeStop(runtime, Count, &completed);
    ASCastRuntimeStop(runtime, Count, &completed);
    ASCastStopSender(runtime, Count, &completed);
    ASCastStopReceiver(runtime, Count, &completed);
    ASCastStopBrowsing(runtime, Count, &completed);
    assert(ASCastStartSender(runtime, Audio(), nullptr, Observe, &sender) == 0);
    Wait([&] { return completed == 5; });
    sender.stop_completed = receiver.stop_completed = true;
    DrainMain();
    ASCastRuntimeDestroy(runtime);
    runtime = ASCastRuntimeCreate();
    assert(runtime); // Singleton can be recreated only after the final barrier.
    completed = 0;
    ASCastRuntimeStop(runtime, Count, &completed);
    Wait([&] { return completed == 1; });
    ASCastRuntimeDestroy(runtime);
    puts("RuntimeSession: immediate/repeated stop, shared roles, failure, restart, final barrier passed");
  }
}

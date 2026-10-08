#import "cast.h"
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <net/if.h>
#include <netinet/in.h>
#include <algorithm>
#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "SenderSession.h"
#include "ReceiverSession.h"
#include "discovery/CastBonjour.h"
#include "platform/impl/platform_client_posix.h"

using applescreen::NativeSenderSession;
using applescreen::ReceiverSession;
using openscreen::TaskRunner;
namespace {
std::atomic_bool platform_owned{false};
std::string Copy(const char* value) { return value ? value : ""; }
NSString* Text(const std::string& value) {
  return [[NSString alloc] initWithBytes:value.data() length:value.size()
                               encoding:NSUTF8StringEncoding] ?: @"Invalid text";
}
std::string String(id value) {
  return [value isKindOfClass:NSString.class] ? Copy([(NSString*)value UTF8String]) : "";
}
void Main(std::function<void()> callback) {
  dispatch_async(dispatch_get_main_queue(), ^{ if (callback) callback(); });
}
std::function<void()> Completion(ASCastCompletion callback, void* context) {
  return [callback, context] { if (callback) callback(context); };
}
bool Inactive(ASCastState state) {
  return state == ASCastIdle || state == ASCastStopped || state == ASCastFailed;
}
std::optional<openscreen::IPEndpoint> Endpoint(const applescreen::CastAddress& candidate) {
  using openscreen::IPAddress;
  using openscreen::IPEndpoint;
  const auto* address = reinterpret_cast<const sockaddr*>(&candidate.address);
  if (address->sa_family == AF_INET && candidate.length >= sizeof(sockaddr_in)) {
    const auto& value = *reinterpret_cast<const sockaddr_in*>(address);
    const auto* bytes = reinterpret_cast<const uint8_t*>(&value.sin_addr);
    return IPEndpoint{IPAddress(std::span<const uint8_t, 4>(bytes, 4)), ntohs(value.sin_port)};
  }
  if (address->sa_family == AF_INET6 && candidate.length >= sizeof(sockaddr_in6)) {
    const auto& value = *reinterpret_cast<const sockaddr_in6*>(address);
    const auto* bytes = reinterpret_cast<const uint8_t*>(&value.sin6_addr);
    return IPEndpoint{IPAddress(std::span<const uint8_t, 16>(bytes, 16), value.sin6_scope_id), ntohs(value.sin6_port)};
  }
  return {};
}
struct Role {
  enum class CompletionPhase { Open, Stopping, Closed };
  CompletionPhase completion_phase = CompletionPhase::Closed; // Protocol only.
  std::atomic<uint64_t> generation{0};
  std::atomic<uint64_t> callbacks_closed{0};
  std::atomic<ASCastState> state{ASCastIdle};
  ASCastEventCallback callback = nullptr;
  void* context = nullptr;
  std::vector<std::function<void()>> completions; // Protocol sequence only.
};
}

struct ASCastRuntime {
  dispatch_queue_t lifecycle = dispatch_queue_create("app.applescreen.runtime", DISPATCH_QUEUE_SERIAL);
  TaskRunner* runner = nullptr;
  std::atomic_bool closing{false}, stopped{false};
  std::vector<std::function<void()>> stop_completions; // Main only.
  Role sending, receiving;
  std::unique_ptr<applescreen::CastBonjour> bonjour;
  // This one boundary lock prevents Submit racing destruction. Protocol state
  // remains exclusively owned by runner; no callback runs with the lock held.
  std::mutex submission_mutex;
  std::unique_ptr<NativeSenderSession> sender;
  std::unique_ptr<ReceiverSession> receiver;
  openscreen::cast::ReceiverInfo receiver_info;
  uint32_t receiver_interface = 0;
  std::atomic<uint64_t> browse_generation{0};
  ASCastDiscoveryCallback discovery_callback = nullptr; // Main only.
  void* discovery_context = nullptr;
  std::mutex snapshot_mutex;
  NSArray* latest_snapshot = nil;
  NSString* latest_discovery_error = nil;
  uint64_t latest_browse_generation = 0;
  bool snapshot_pending = false;

  void Emit(Role& role, ASCastState state, std::string error = {},
            uint64_t media = 0, CFTypeRef owned_layer = nullptr,
            bool video = false, bool audio = false,
            int width = 0, int height = 0, int fps = 0, int fps_den = 1) {
    const uint64_t generation = role.generation.load();
    const auto callback = role.callback;
    void* const context = role.context;
    Role* slot = &role;
    NSString* message = error.empty() ? nil : Text(error);
    id layer = CFBridgingRelease(owned_layer);
    Main([slot, generation, callback, context, state, message, layer, media,
          video, audio, width, height, fps, fps_den] {
      if (slot->generation != generation || slot->callbacks_closed >= generation) return;
      if ((state == ASCastReady || state == ASCastStreaming) &&
          (slot->state == ASCastStopping || Inactive(slot->state))) return;
      ASCastEvent event{generation, media, state, (__bridge CFStringRef)message,
                        (__bridge CFTypeRef)layer, video, audio, width, height, fps, fps_den};
      if (callback) callback(context, &event);
    });
  }

  void Finish(Role& role, ASCastState state, std::string error = {}) {
    role.completion_phase = Role::CompletionPhase::Closed;
    role.state = ASCastStopping;
    Emit(role, state, std::move(error));
    const uint64_t generation = role.generation.load();
    auto completions = std::move(role.completions);
    role.completions.clear();
    Role* slot = &role;
    Main([slot, generation, state, completions = std::move(completions)] {
      slot->callbacks_closed = generation;
      if (slot->generation == generation) slot->state = state;
      for (const auto& completion : completions) completion();
    });
  }

  void Snapshot(uint64_t generation, NSArray* value, NSString* error = nil) {
    if (closing || browse_generation != generation) return;
    {
      std::lock_guard lock(snapshot_mutex);
      latest_snapshot = value;
      latest_discovery_error = error;
      latest_browse_generation = generation;
      if (snapshot_pending) return;
      snapshot_pending = true;
    }
    Main([this] {
      NSArray* value;
      NSString* error;
      uint64_t generation;
      {
        std::lock_guard lock(snapshot_mutex);
        value = latest_snapshot;
        error = latest_discovery_error;
        generation = latest_browse_generation;
        latest_snapshot = nil;
        latest_discovery_error = nil;
        snapshot_pending = false;
      }
      if (!closing && browse_generation == generation && discovery_callback)
        discovery_callback(discovery_context, (__bridge CFArrayRef)value,
                           (__bridge CFStringRef)error);
    });
  }

  void SenderTerminal(uint64_t generation, std::optional<std::string> error) {
    // Engine terminal may be synchronous during Start/Stop. Destroy it in the
    // next protocol task after its callback has returned.
    runner->PostTask([this, generation, error = std::move(error)] {
      if (sending.generation != generation) return;
      {
        std::lock_guard lock(submission_mutex);
        sender.reset();
      }
      Finish(sending, error ? ASCastFailed : ASCastStopped, error.value_or(""));
    });
  }

  void ResolveSender(uint64_t generation, NativeSenderSession::Config config,
                     std::shared_ptr<std::vector<applescreen::ServiceKey>> keys,
                     size_t next, std::vector<openscreen::IPEndpoint> endpoints) {
    if (sending.generation != generation || sending.state != ASCastStarting) return;
    if (next == keys->size()) {
      if (endpoints.empty()) { Finish(sending, ASCastFailed, "Receiver is no longer reachable"); return; }
      auto ready = [this, generation](NativeSenderSession::Negotiated negotiated) {
        if (sending.generation != generation || sending.state != ASCastStarting) return;
        sending.state = ASCastReady;
        Emit(sending, ASCastReady, {}, 0, nullptr, negotiated.video, negotiated.audio,
             negotiated.width, negotiated.height, negotiated.fps_numerator,
             negotiated.fps_denominator);
      };
      auto terminal = [this, generation](std::optional<std::string> error) {
        SenderTerminal(generation, std::move(error));
      };
      {
        std::lock_guard lock(submission_mutex);
        sender = std::make_unique<NativeSenderSession>(*runner, std::move(config),
                                                       std::move(ready), std::move(terminal));
      }
      sender->Start(std::move(endpoints));
      return;
    }
    bonjour->Resolve((*keys)[next],
      [this, generation, config = std::move(config), keys, next,
       endpoints = std::move(endpoints)](DNSServiceErrorType,
                                        std::optional<applescreen::CastService> service) mutable {
        if (service) for (const auto& address : service->addresses) {
          const auto endpoint = Endpoint(address);
          if (endpoint && std::find(endpoints.begin(), endpoints.end(), *endpoint) == endpoints.end())
            endpoints.push_back(*endpoint);
        }
        runner->PostTask([this, generation, config = std::move(config), keys, next,
                          endpoints = std::move(endpoints)]() mutable {
          ResolveSender(generation, std::move(config), keys, next + 1, std::move(endpoints));
        });
      });
  }

  void StopSender(std::function<void()> completion) {
    if (sending.completion_phase == Role::CompletionPhase::Closed) {
      Main(std::move(completion)); // Ordered after the already queued terminal fence.
      return;
    }
    sending.completions.push_back(std::move(completion));
    if (sending.completion_phase == Role::CompletionPhase::Stopping) return;
    sending.completion_phase = Role::CompletionPhase::Stopping;
    sending.state = ASCastStopping;
    Emit(sending, ASCastStopping);
    if (sender) sender->Stop();
    else Finish(sending, ASCastStopped);
  }

  void StopReceiver(std::function<void()> completion, std::string failure = {}) {
    if (receiving.completion_phase == Role::CompletionPhase::Closed) {
      Main(std::move(completion));
      return;
    }
    receiving.completions.push_back(std::move(completion));
    if (receiving.completion_phase == Role::CompletionPhase::Stopping) return;
    receiving.completion_phase = Role::CompletionPhase::Stopping;
    receiving.state = ASCastStopping;
    Emit(receiving, ASCastStopping);
    bonjour->Unpublish([this, failure = std::move(failure)](DNSServiceErrorType) {
      runner->PostTask([this, failure] {
        auto done = [this, failure] {
          runner->PostTask([this, failure] {
            receiver.reset();
            Finish(receiving, failure.empty() ? ASCastStopped : ASCastFailed, failure);
          });
        };
        if (receiver) receiver->Stop(std::move(done));
        else done();
      });
    });
  }

  void ReceiverEvent(uint64_t generation, applescreen::ReceiverEvent event) {
    if (receiving.generation != generation || receiving.state == ASCastStopping || closing) {
      if (event.video_layer) CFRelease(event.video_layer);
      return;
    }
    using S = applescreen::ReceiverState;
    if (event.state == S::kFailed) {
      if (event.video_layer) CFRelease(event.video_layer);
      StopReceiver([]{}, event.error);
      return;
    }
    if (event.state == S::kListening && receiving.state == ASCastStarting) {
      applescreen::CastPublication publication;
      publication.instance_name = receiver_info.friendly_name;
      publication.port = receiver_info.port;
      publication.interface_index = receiver_interface;
      publication.info = {receiver_info.unique_id, receiver_info.friendly_name,
                          receiver_info.model_name, receiver_info.capabilities};
      bonjour->Publish(std::move(publication),
        [this, generation](DNSServiceErrorType error, std::string claimed) {
          runner->PostTask([this, generation, error, claimed = std::move(claimed)] {
            if (receiving.generation != generation || receiving.state != ASCastStarting) return;
            if (error) { StopReceiver([]{}, "Bonjour registration failed: " + std::to_string(error)); return; }
            receiver_info.friendly_name = claimed;
            receiver->UpdateReceiverInfo(receiver_info);
            receiving.state = ASCastReady;
            Emit(receiving, ASCastReady);
          });
        });
    } else if (event.state == S::kListening || event.state == S::kStreaming) {
      receiving.state = event.state == S::kListening ? ASCastReady : ASCastStreaming;
      Emit(receiving, receiving.state, event.error, event.media_generation,
           event.video_layer, event.video, event.audio);
      event.video_layer = nullptr;
    }
    if (event.video_layer) CFRelease(event.video_layer);
  }
};

ASCastRuntime* ASCastRuntimeCreate(void) {
  if (![NSThread isMainThread] || platform_owned.exchange(true)) return nullptr;
  auto* runtime = new ASCastRuntime;
  dispatch_sync(runtime->lifecycle, ^{
    openscreen::PlatformClientPosix::Create(std::chrono::milliseconds(10));
    runtime->runner = &openscreen::PlatformClientPosix::GetInstance()->GetTaskRunner();
  });
  runtime->bonjour = std::make_unique<applescreen::CastBonjour>([runtime](DNSServiceErrorType error) {
    runtime->Snapshot(runtime->browse_generation, @[],
                      [NSString stringWithFormat:@"Bonjour error: %d", error]);
  });
  return runtime;
}

void ASCastRuntimeStop(ASCastRuntime* runtime, ASCastCompletion callback, void* context) {
  if (!runtime || runtime->stopped) { Main(Completion(callback, context)); return; }
  runtime->stop_completions.push_back(Completion(callback, context));
  if (runtime->closing.exchange(true)) return;
  ++runtime->browse_generation;
  auto remaining = std::make_shared<int>(2);
  auto done = [runtime, remaining] {
    if (--*remaining) return; // Both role completions execute on main.
    runtime->bonjour->Stop([runtime](DNSServiceErrorType) {
      runtime->runner->PostTask([runtime] {
        runtime->bonjour.reset();
        // Destroyed protocol objects can post deferred deletion. Let these run
        // before asking the managed runner to drain and stop on lifecycle queue.
        runtime->runner->PostTask([runtime] {
          dispatch_async(runtime->lifecycle, ^{
            openscreen::PlatformClientPosix::ShutDown();
            runtime->stopped = true;
            platform_owned = false;
            Main([runtime] {
              auto completions = std::move(runtime->stop_completions);
              for (const auto& completion : completions) completion();
            });
          });
        });
      });
    });
  };
  runtime->runner->PostTask([runtime, done] {
    runtime->StopSender(done);
    runtime->StopReceiver(done);
  });
}
void ASCastRuntimeDestroy(ASCastRuntime* runtime) {
  if (!runtime) return;
  NSCAssert(runtime->stopped, @"Stop must complete before runtime destruction");
  delete runtime;
}

void ASCastBrowse(ASCastRuntime* runtime, uint32_t interface_index,
                  ASCastDiscoveryCallback callback, void* context) {
  if (!runtime || runtime->closing) return;
  const uint64_t generation = ++runtime->browse_generation;
  runtime->discovery_callback = callback;
  runtime->discovery_context = context;
  runtime->bonjour->StartBrowsing(interface_index,
    [runtime, generation](applescreen::CastSnapshot snapshot) {
      NSMutableArray* services = [NSMutableArray arrayWithCapacity:snapshot.services.size()];
      for (const auto& service : snapshot.services) {
        NSMutableArray* addresses = [NSMutableArray arrayWithCapacity:service.addresses.size()];
        for (const auto& address : service.addresses)
          [addresses addObject:[NSData dataWithBytes:&address.address length:address.length]];
        [services addObject:@{@"id":Text(service.info.id), @"name":Text(service.info.name),
          @"model":Text(service.info.model), @"service":Text(service.key.name),
          @"type":Text(service.key.type), @"domain":Text(service.key.domain),
          @"interface":@(service.key.interface_index), @"port":@(service.port),
          @"addresses":[addresses copy]}];
      }
      runtime->Snapshot(generation, [services copy]);
    }, [runtime, generation](DNSServiceErrorType error) {
      if (error) runtime->Snapshot(generation, @[],
          [NSString stringWithFormat:@"Cannot browse Cast services: %d", error]);
    });
}
void ASCastRefresh(ASCastRuntime* runtime) {
  if (!runtime || runtime->closing) return;
  // Refresh is discovery-only; CastBonjour starts a new native browse generation.
  runtime->bonjour->Refresh();
}
void ASCastStopBrowsing(ASCastRuntime* runtime, ASCastCompletion callback, void* context) {
  if (!runtime || runtime->stopped) { Main(Completion(callback, context)); return; }
  if (runtime->closing) { ASCastRuntimeStop(runtime, callback, context); return; }
  ++runtime->browse_generation;
  runtime->bonjour->StopBrowsing([callback, context](DNSServiceErrorType) {
    Main(Completion(callback, context));
  });
}

uint64_t ASCastStartSender(ASCastRuntime* runtime, ASCastSenderConfig input,
                           CFArrayRef candidates, ASCastEventCallback callback, void* context) {
  if (!runtime || runtime->closing || !Inactive(runtime->sending.state)) return 0;
  NativeSenderSession::Config config;
  config.interface_name = Copy(input.interface_name);
  config.developer_ca_path = Copy(input.developer_ca_path);
  config.video = input.video; config.audio = input.audio;
  config.width = input.width; config.height = input.height;
  config.fps_numerator = input.fps_numerator; config.fps_denominator = input.fps_denominator;
  config.sample_rate = input.sample_rate; config.channels = input.channels;
  config.max_bitrate = input.max_bitrate;
  config.codec = input.codec == ASCastVP8 ? openscreen::cast::VideoCodec::kVp8 :
                 input.codec == ASCastVP9 ? openscreen::cast::VideoCodec::kVp9 :
                                           openscreen::cast::VideoCodec::kAv1;
  auto keys = std::make_shared<std::vector<applescreen::ServiceKey>>();
  const uint32_t selected_interface = config.interface_name.empty() ? 0 :
                                      if_nametoindex(config.interface_name.c_str());
  if (candidates && CFGetTypeID(candidates) == CFArrayGetTypeID()) {
    for (id item in (__bridge NSArray*)candidates) {
      if (![item isKindOfClass:NSDictionary.class]) continue;
      if (![item[@"interface"] isKindOfClass:NSNumber.class]) continue;
      applescreen::ServiceKey key{String(item[@"service"]), String(item[@"type"]),
                                  String(item[@"domain"]), [item[@"interface"] unsignedIntValue]};
      if (!key.name.empty() && (key.type == "_googlecast._tcp" || key.type == "_googlecast._tcp.") &&
          !key.domain.empty() && (config.interface_name.empty() || key.interface_index == selected_interface))
        keys->push_back(std::move(key));
    }
  }
  std::sort(keys->begin(), keys->end());
  keys->erase(std::unique(keys->begin(), keys->end()), keys->end());
  Role& role = runtime->sending;
  const uint64_t generation = ++role.generation;
  role.callback = callback; role.context = context; role.state = ASCastStarting;
  runtime->runner->PostTask([runtime, generation, config, keys, codec = input.codec] {
    runtime->sending.completion_phase = Role::CompletionPhase::Open;
    runtime->Emit(runtime->sending, ASCastStarting);
    auto error = NativeSenderSession::ValidateConfig(config);
    if (!ASCastSupportsCodec(codec)) error = "Unsupported video codec";
    if (error) { runtime->Finish(runtime->sending, ASCastFailed, *error); return; }
    runtime->ResolveSender(generation, config, keys, 0, {});
  });
  return generation;
}
void ASCastStopSender(ASCastRuntime* runtime, ASCastCompletion callback, void* context) {
  if (!runtime || runtime->stopped) { Main(Completion(callback, context)); return; }
  if (runtime->closing) { ASCastRuntimeStop(runtime, callback, context); return; }
  runtime->runner->PostTask([runtime, callback, context] {
    runtime->StopSender(Completion(callback, context));
  });
}
void ASCastFinishSender(ASCastRuntime* runtime, uint64_t generation) {
  if (!runtime || runtime->closing || runtime->stopped) return;
  runtime->runner->PostTask([runtime, generation] {
    if (runtime->sending.generation != generation || runtime->sending.state != ASCastReady || !runtime->sender) return;
    runtime->sending.state = ASCastStopping;
    runtime->Emit(runtime->sending, ASCastStopping);
    // Keep completion_phase Open so an explicit Stop can cancel this drain.
    runtime->sender->FinishInput();
  });
}
ASCastSubmission ASCastSubmit(ASCastRuntime* runtime, uint64_t generation, ASCastTrack track,
                              CMSampleBufferRef sample, CMTime time) {
  if (!runtime || runtime->closing || runtime->sending.generation != generation)
    return ASCastSubmissionStopped;
  const auto state = runtime->sending.state.load();
  if (state == ASCastStopping || state == ASCastStopped || state == ASCastFailed)
    return ASCastSubmissionStopped;
  if (state != ASCastReady) return ASCastNotReady;
  if (track != ASCastVideo && track != ASCastAudio) return ASCastInvalidSample;
  std::lock_guard lock(runtime->submission_mutex);
  if (!runtime->sender) return ASCastSubmissionStopped;
  auto result = runtime->sender->Submit(track == ASCastVideo ? NativeSenderSession::Track::Video :
                                        NativeSenderSession::Track::Audio, sample, time);
  using S = NativeSenderSession::Submission;
  switch (result) {
    case S::Accepted: return ASCastAccepted;
    case S::Backpressured: return ASCastBackpressured;
    case S::NotReady: return ASCastNotReady;
    case S::Stopped: return ASCastSubmissionStopped;
    case S::Invalid: return ASCastInvalidSample;
  }
}
bool ASCastSupportsCodec(ASCastCodec codec) {
  switch (codec) {
    case ASCastVP8: case ASCastVP9: return true;
#ifdef CAST_STANDALONE_SENDER_HAVE_LIBAOM
    case ASCastAV1: return true;
#endif
    default: return false;
  }
}

uint64_t ASCastStartReceiver(ASCastRuntime* runtime, ASCastReceiverConfig input,
                             ASCastEventCallback callback, void* context) {
  if (!runtime || runtime->closing || !Inactive(runtime->receiving.state)) return 0;
  applescreen::ReceiverConfig config;
  config.info.unique_id = Copy(input.receiver_id);
  config.info.friendly_name = Copy(input.name);
  config.info.model_name = "Applescreen";
  config.info.port = input.port;
  config.info.capabilities = openscreen::cast::kHasVideoOutput | openscreen::cast::kHasAudioOutput;
  config.interface_index = input.interface_index;
  config.developer_ca_path = Copy(input.developer_ca_path);
  config.developer_key_path = Copy(input.developer_key_path);
  config.display_width = input.display_width; config.display_height = input.display_height;
  config.max_fps = input.max_fps;
  Role& role = runtime->receiving;
  const uint64_t generation = ++role.generation;
  role.callback = callback; role.context = context; role.state = ASCastStarting;
  runtime->runner->PostTask([runtime, generation, config] {
    runtime->receiving.completion_phase = Role::CompletionPhase::Open;
    runtime->receiver_info = config.info;
    runtime->receiver_interface = config.interface_index;
    runtime->Emit(runtime->receiving, ASCastStarting);
    runtime->receiver = std::make_unique<ReceiverSession>(*runtime->runner,
      [runtime, generation](applescreen::ReceiverEvent event) { runtime->ReceiverEvent(generation, std::move(event)); });
    runtime->receiver->Start(config);
  });
  return generation;
}
void ASCastStopReceiver(ASCastRuntime* runtime, ASCastCompletion callback, void* context) {
  if (!runtime || runtime->stopped) { Main(Completion(callback, context)); return; }
  if (runtime->closing) { ASCastRuntimeStop(runtime, callback, context); return; }
  runtime->runner->PostTask([runtime, callback, context] {
    runtime->StopReceiver(Completion(callback, context));
  });
}
void ASCastStopReceiverMedia(ASCastRuntime* runtime, uint64_t generation, uint64_t media_generation) {
  if (!runtime || runtime->closing) return;
  runtime->runner->PostTask([runtime, generation, media_generation] {
    if (runtime->receiving.generation == generation && runtime->receiver)
      runtime->receiver->StopMedia(media_generation);
  });
}

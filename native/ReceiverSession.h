#ifndef APPLESCREEN_NATIVE_RECEIVER_SESSION_H_
#define APPLESCREEN_NATIVE_RECEIVER_SESSION_H_

#include <CoreFoundation/CoreFoundation.h>

#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

#include "cast/common/public/receiver_info.h"
#include "cast/streaming/public/constants.h"
#include "media/PlaybackSession.h"

namespace openscreen { class TaskRunner; }

namespace applescreen {
enum class ReceiverState { kIdle, kStarting, kListening, kStreaming,
                           kStopping, kStopped, kFailed };

struct ReceiverConfig {
  // info.port is the declared/bound port (nonzero, normally 8010). The wrapper
  // supplies one stable identity to both this agent and CastBonjour publication.
  openscreen::cast::ReceiverInfo info;
  uint32_t interface_index = 0;  // Automatic; explicit unknown index fails.
  std::string developer_ca_path;
  std::string developer_key_path;
  int display_width = 1920;
  int display_height = 1080;
  int max_fps = 60;
  // Advertised only when a real software decoder is compiled; SDR 8-bit only.
  bool enable_av1 = true;
};

struct ReceiverEvent {
  ReceiverState state = ReceiverState::kIdle;
  uint64_t media_generation = 0;
  std::string error;
  bool audio = false;
  bool video = false;
  // Optional retained (+1) display layer, transferred to the callback. Release
  // after attaching/retaining it on main, including when discarding a stale event.
  // kListening after kStreaming ends that media generation without stopping the
  // listener. No window operations are performed in this engine.
  CFTypeRef video_layer = nullptr;
};

// All entry points, callbacks and destruction run on the injected protocol task
// sequence. The owner posts public calls there. Runtime/PlatformClientPosix are
// external and must outlive Stop completion plus deferred task destruction.
class ReceiverSession final {
 public:
  using EventCallback = std::function<void(ReceiverEvent)>;
  ReceiverSession(openscreen::TaskRunner& runner, EventCallback callback);
  ~ReceiverSession();
  ReceiverSession(const ReceiverSession&) = delete;
  ReceiverSession& operator=(const ReceiverSession&) = delete;

  void Start(ReceiverConfig config);
  // Idempotent, asynchronous. No further event from this service generation
  // follows completion. Retain this object until completion; no UI-thread joins.
  void Stop(std::function<void()> completion = {});
  void StopMedia(uint64_t media_generation);
  // Root forwards the claimed native Bonjour name without changing ID/port.
  void UpdateReceiverInfo(openscreen::cast::ReceiverInfo info);
  struct MediaLimits { ASPlaybackConfig playback; size_t video_buffers; };
  // Negotiated queue policy, also used by the native pipeline proof. Byte and
  // time ceilings stay fixed; counts cover present tracks and their horizon.
  static MediaLimits PlaybackLimits(bool audio, bool video, CMTime video_duration,
      std::chrono::milliseconds audio_delay, std::chrono::milliseconds video_delay);
  static std::string VideoDecoderName(openscreen::cast::VideoCodec codec);
  static bool SupportsAv1Parameter(const std::string& parameter);
  ReceiverState state() const;
  uint16_t port() const;

 private:
  struct Impl;
  std::shared_ptr<Impl> impl_;
};
}  // namespace applescreen
#endif

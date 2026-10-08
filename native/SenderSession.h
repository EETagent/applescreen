#ifndef APPLESCREEN_NATIVE_SENDER_SESSION_H_
#define APPLESCREEN_NATIVE_SENDER_SESSION_H_

#include <CoreMedia/CoreMedia.h>

#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <vector>

#include "cast/streaming/public/constants.h"
#include "platform/base/ip_address.h"
#include "platform/base/interface_info.h"

namespace openscreen { class TaskRunner; }
namespace applescreen {

class NativeSenderSession final {
 public:
  struct Config {
    std::string interface_name;  // Empty is explicitly Automatic.
    std::string developer_ca_path;  // Empty uses the normal Cast trust roots.
    bool video = false;
    bool audio = false;
    int width = 0, height = 0;
    int fps_numerator = 30, fps_denominator = 1;
    int sample_rate = 48000, channels = 2;
    int max_bitrate = 8'000'000;
    openscreen::cast::VideoCodec codec = openscreen::cast::VideoCodec::kVp8;
  };
  struct Negotiated {
    bool video = false, audio = false;
    int width = 0, height = 0;
    int fps_numerator = 0, fps_denominator = 1;
    int sample_rate = 0, channels = 0;
    openscreen::cast::VideoCodec codec = openscreen::cast::VideoCodec::kVp8;
  };
  enum class Track { Video, Audio };
  enum class Submission { Accepted, Backpressured, NotReady, Stopped, Invalid };
  using Ready = std::function<void(Negotiated)>;
  using Terminal = std::function<void(std::optional<std::string> error)>;

  // Construct/start/stop/destroy on the injected protocol sequence. The runtime
  // outlives the terminal callback and this object. No singleton or runner is
  // created here. Config strings are owned snapshots; this is a single session.
  NativeSenderSession(openscreen::TaskRunner&, Config, Ready, Terminal);
  ~NativeSenderSession();
  NativeSenderSession(const NativeSenderSession&) = delete;
  NativeSenderSession& operator=(const NativeSenderSession&) = delete;

  static std::optional<std::string> ValidateConfig(const Config&);
  // Interface inventory is supplied by the native boundary. Never bind the
  // media socket to the remote address; Automatic selects a family wildcard.
  static std::optional<openscreen::IPEndpoint> SelectLocalEndpoint(
      const openscreen::IPEndpoint& remote, const std::string& interface_name,
      std::span<const openscreen::InterfaceInfo> interfaces);
  void Start(std::vector<openscreen::IPEndpoint> ordered_candidates);
  void Stop();  // Idempotent; terminal fires once after STOP ack/deadline + drain.
  // End of file: close admission, finish accepted conversion/encoding and allow
  // queued packets to reach their estimated playout deadline before STOP.
  // Five-second bounded drain; explicit Stop still cancels immediately.
  void FinishInput();

  // Thread-safe, immediate bounded admission. Accepted retains the native sample
  // until conversion/consumption; it does not promise encoding/network delivery.
  // Capacity: two raw/converted video frames and 200 ms / 32 complete PCM buffers.
  // Full audio buffers are rejected, preserving sample alignment and timestamp
  // gaps. Admission credit remains held through paced encoding. The caller owns
  // its original reference for every return value. Frames >200 ms late can drop;
  // source timestamps more than one second ahead fail the session.
  // Host presentation time is explicit Core Media host-clock time for both
  // tracks; never pass unanchored file PTS. Zero is valid. Native video may be
  // NV12/BGRA/I420; PCM must be interleaved Float32 at negotiated 48 kHz mono/stereo.
  Submission Submit(Track, CMSampleBufferRef, CMTime host_presentation_time);

 private:
  struct State;
  std::shared_ptr<State> state_;
};

}  // namespace applescreen
#endif

#ifndef APPLESCREEN_NATIVE_MEDIA_RECEIVER_TIMELINE_H_
#define APPLESCREEN_NATIVE_MEDIA_RECEIVER_TIMELINE_H_

#include <algorithm>
#include <array>
#include <chrono>
#include <limits>
#include <optional>

#include "cast/streaming/rtp_time.h"
#include "platform/api/time.h"

namespace applescreen {
// One instance per negotiated media session, shared by both decoders on their
// serial worker. reference_time is already the receiver's target playout time.
// Track RTP epochs differ, but their absolute references share this ONE origin.
class ReceiverTimeline {
 public:
  using Clock = openscreen::Clock;
  struct Point { Clock::duration elapsed; bool discontinuity; };
  ReceiverTimeline(Clock::time_point origin, std::chrono::milliseconds audio_delay,
                   std::chrono::milliseconds video_delay)
      : origin_(origin), delays_{audio_delay, video_delay} {}
  Clock::time_point origin() const { return origin_; }

  std::optional<Point> Map(bool video, openscreen::cast::RtpTimeTicks rtp,
                          int timebase, Clock::time_point reference,
                          std::chrono::milliseconds new_delay) {
    if (timebase <= 0 || reference == Clock::time_point::min()) return {};
    const size_t index = video ? 1 : 0;
    bool discontinuity = new_delay.count() > 0 && new_delay != delays_[index];
    if (discontinuity) {
      delays_[index] = new_delay;
      anchors_ = {};  // Delay changes affect the common playback session now.
    }
    auto& anchor = anchors_[index];
    if (!anchor) anchor = Anchor{rtp, reference};
    // Use the public exact tick values in a wider rational calculation. No
    // floating conversion, signed subtraction or multiplication can overflow.
    const __int128 ticks = __int128(rtp.value()) - anchor->rtp.value();
    static_assert(Clock::duration::period::num == 1 &&
                  Clock::duration::period::den == 1000000);
    __int128 presentation = anchor->reference.time_since_epoch().count() +
                            ticks * 1000000 / timebase;
    const __int128 drift = __int128(reference.time_since_epoch().count()) - presentation;
    if (drift > 100000 || drift < -100000) {
      anchors_ = {};
      anchor = Anchor{rtp, reference};
      presentation = reference.time_since_epoch().count();
      discontinuity = true;
    } else {
      const int64_t correction = std::clamp(int64_t(drift / 128), int64_t(-200), int64_t(200));
      const __int128 corrected = __int128(anchor->reference.time_since_epoch().count()) + correction;
      if (!Fits(corrected)) return {};
      anchor->reference = Clock::time_point(Clock::duration(int64_t(corrected)));
      presentation += correction;
    }
    const __int128 elapsed = presentation - origin_.time_since_epoch().count();
    if (!Fits(presentation) || !Fits(elapsed) || elapsed < 0) return {};
    return Point{Clock::duration(int64_t(elapsed)), discontinuity};
  }
 private:
  static bool Fits(__int128 value) {
    return value >= std::numeric_limits<int64_t>::min() &&
           value <= std::numeric_limits<int64_t>::max();
  }
  struct Anchor { openscreen::cast::RtpTimeTicks rtp; Clock::time_point reference; };
  Clock::time_point origin_;
  std::array<std::optional<Anchor>, 2> anchors_;
  std::array<std::chrono::milliseconds, 2> delays_;
};
}  // namespace applescreen
#endif

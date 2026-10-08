#include "../native/media/ReceiverTimeline.h"

#include <cassert>
#include <cstdio>

int main() {
  using namespace std::chrono;
  using openscreen::Clock;
  using openscreen::cast::RtpTimeDelta;
  using openscreen::cast::RtpTimeTicks;
  using applescreen::ReceiverTimeline;
  // These pure tests complement receiver_session_test, which verifies that the
  // same mapping reaches owned native samples and the actual playback sink.
  for (auto origin : {Clock::time_point{}, Clock::time_point(seconds(12345))}) {
    for (bool audio_first : {false, true}) {
      ReceiverTimeline timeline(origin, milliseconds(400), milliseconds(400));
      Clock::duration audio{}, video{};
      for (bool is_video : {audio_first, !audio_first}) {
        auto point = timeline.Map(is_video, RtpTimeTicks(), is_video ? 90000 : 48000,
            origin + milliseconds(is_video ? 0 : 250), milliseconds(0));
        assert(point && !point->discontinuity);
        (is_video ? video : audio) = point->elapsed;
      }
      assert(audio - video == milliseconds(250));
    }
    for (int fps : {24, 30, 60}) {
      ReceiverTimeline timeline(origin, milliseconds(400), milliseconds(400));
      // Uneven frame indices exercise VFR gaps without rebasing the timeline.
      for (int64_t frame : {int64_t(0), int64_t(1), int64_t(3), int64_t(60 * 60 * 24 * 30 * fps)}) {
        const int64_t ticks = frame * 90000 / fps;
        auto elapsed = microseconds(500000 + ticks * 1000000 / 90000);
        auto point = timeline.Map(true, RtpTimeTicks() + RtpTimeDelta::FromTicks(ticks),
            90000, origin + elapsed, milliseconds(0));
        assert(point && point->elapsed == elapsed && !point->discontinuity);
      }
    }
  }
  ReceiverTimeline invalid({}, milliseconds(0), milliseconds(0));
  assert(!invalid.Map(false, RtpTimeTicks(), 0, {}, milliseconds(0)));
  assert(!invalid.Map(false, RtpTimeTicks(), 48000, Clock::time_point::min(), milliseconds(0)));
  ReceiverTimeline overflow(Clock::time_point::min(), milliseconds(0), milliseconds(0));
  assert(!overflow.Map(false, RtpTimeTicks(), 48000, Clock::time_point::max(), milliseconds(0)));
  std::puts("Portable shared-timeline tests passed");
}

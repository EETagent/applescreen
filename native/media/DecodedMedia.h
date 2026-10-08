#ifndef APPLESCREEN_NATIVE_MEDIA_DECODED_MEDIA_H_
#define APPLESCREEN_NATIVE_MEDIA_DECODED_MEDIA_H_

#include <CoreMedia/CoreMedia.h>

#include <cstddef>
#include <memory>
#include <string>

struct AVFrame;

namespace applescreen {

// Internal GN-toolchain C++ interface. One instance belongs to one decoder worker;
// calls, Reset and destruction all occur on that worker. No FFmpeg or C++ type
// crosses the app's private C/CF boundary. Inputs are borrowed only during calls.
class DecodedMedia {
 public:
  explicit DecodedMedia(size_t max_bytes = 64 * 1024 * 1024,
                        size_t max_video_buffers = 8);
  ~DecodedMedia();
  DecodedMedia(const DecodedMedia&) = delete;
  DecodedMedia& operator=(const DecodedMedia&) = delete;

  // Returns one owned (+1) native sample or nullptr with error. A successful
  // sample owns all its media independently of AVFrame lifetime/reuse. Explicit
  // receiver metadata supplies PTS/duration; AVFrame pts/time_base are ignored.
  // Video accepts SDR, 8-bit YUV420P/YUVJ420P/NV12/BGRA and normalizes to NV12.
  // Source planes must have refcounted, verifiable AVBufferRef storage. Negative
  // strides are supported. Subsampled crop origins must be chroma-aligned; visible
  // dimensions may be odd. Unknown matrix uses FFmpeg's 601 conversion default;
  // unsupported explicit color semantics/high-bit-depth/HDR fail rather than lie.
  CMSampleBufferRef CopyVideo(const AVFrame& frame, CMTime pts, CMTime duration,
                             std::string& error) CF_RETURNS_RETAINED;

  // swresample normalizes valid FFmpeg sample formats to interleaved Float32 at
  // the original sample rate, preserving channel identity and complete samples.
  // Duration is exactly nb_samples/sample_rate, never guessed from frame.pts.
  CMSampleBufferRef CopyAudio(const AVFrame& frame, CMTime pts,
                             std::string& error) CF_RETURNS_RETAINED;

  // Same color capability predicate used before AV1 negotiation and at decode.
  static bool SupportsVideoColor(const AVFrame& frame);

  // Discontinuity/format teardown: no queued data is preserved in conversion
  // state. Existing returned CMSampleBuffers remain valid after Reset/destruction.
  void Reset();

 private:
  struct State;
  std::unique_ptr<State> state_;
};
}  // namespace applescreen
#endif

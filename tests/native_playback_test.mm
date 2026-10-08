#import "../native/media/PlaybackSession.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreVideo/CoreVideo.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

// Native integration proof. It exercises real renderers and their clock/readiness,
// not physical display/speaker output. No Open Screen or network dependency.
namespace {
int failures = 0;
#define EXPECT(condition) do { if (!(condition)) { \
  std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
  ++failures; } } while (0)

CMSampleBufferRef Video(CMTime pts, int width = 32, OSType type = kCVPixelFormatType_32BGRA) {
  CVPixelBufferRef pixels = nullptr;
  if (CVPixelBufferCreate(kCFAllocatorDefault, width, 24, type, nullptr, &pixels))
    return nullptr;
  CVPixelBufferLockBaseAddress(pixels, 0);
  if (CVPixelBufferIsPlanar(pixels)) {
    for (size_t i = 0; i < CVPixelBufferGetPlaneCount(pixels); ++i)
      memset(CVPixelBufferGetBaseAddressOfPlane(pixels, i), i == 0 ? 64 : 128,
             CVPixelBufferGetBytesPerRowOfPlane(pixels, i) *
             CVPixelBufferGetHeightOfPlane(pixels, i));
  } else {
    memset(CVPixelBufferGetBaseAddress(pixels), 0x7f,
           CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels));
  }
  CVPixelBufferUnlockBaseAddress(pixels, 0);
  CMVideoFormatDescriptionRef format = nullptr;
  OSStatus error = CMVideoFormatDescriptionCreateForImageBuffer(
      kCFAllocatorDefault, pixels, &format);
  CMSampleBufferRef sample = nullptr;
  if (!error) {
    CMSampleTimingInfo timing{CMTimeMake(1, 60), pts, kCMTimeInvalid};
    error = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
        pixels, format, &timing, &sample);
  }
  if (format) CFRelease(format);
  CFRelease(pixels);
  return error ? nullptr : sample;
}

CMSampleBufferRef Audio(CMTime pts, int rate = 48000, int channels = 2,
                        size_t extra_byte_count = 0) {
  AudioStreamBasicDescription asbd{};
  asbd.mSampleRate = rate;
  asbd.mFormatID = kAudioFormatLinearPCM;
  asbd.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
  asbd.mBytesPerPacket = asbd.mBytesPerFrame = channels * sizeof(float);
  asbd.mFramesPerPacket = 1;
  asbd.mChannelsPerFrame = channels;
  asbd.mBitsPerChannel = 32;
  CMAudioFormatDescriptionRef format = nullptr;
  OSStatus error = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd,
      0, nullptr, 0, nullptr, nullptr, &format);
  CMBlockBufferRef data = nullptr;
  constexpr CMItemCount count = 480;
  size_t size = count * asbd.mBytesPerFrame + extra_byte_count;
  if (!error) error = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
      nullptr, size, kCFAllocatorDefault, nullptr, 0, size, 0, &data);
  if (!error) error = CMBlockBufferFillDataBytes(0, data, 0, size);
  CMSampleBufferRef sample = nullptr;
  if (!error) {
    CMSampleTimingInfo timing{CMTimeMake(1, rate), pts, kCMTimeInvalid};
    size_t sample_size = asbd.mBytesPerFrame;
    error = CMSampleBufferCreateReady(kCFAllocatorDefault, data, format, count,
        1, &timing, 1, &sample_size, &sample);
  }
  if (data) CFRelease(data);
  if (format) CFRelease(format);
  return error ? nullptr : sample;
}

ASPlaybackConfig Config(bool audio, bool video, size_t samples = 8) {
  return {.video = video, .audio = audio, .max_samples = samples,
          .max_bytes = 1024 * 1024, .max_ahead = CMTimeMake(2, 1),
          .late_video_tolerance = CMTimeMake(1, 30)};
}
CMTime FutureHost() {
  return CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTimeMake(1, 1));
}
void Stopped(void* context) { ++*static_cast<std::atomic<int>*>(context); }
bool WaitUntil(bool (^condition)(void), double seconds = 3) {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!condition() && deadline.timeIntervalSinceNow > 0)
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                           beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
  return condition();
}
void Finish(ASPlaybackSession* session) {
  if (!session) return;
  std::atomic<int> count{0};
  std::atomic<int>* completion_count = &count;
  ASPlaybackStop(session, Stopped, completion_count);
  ASPlaybackStop(session, Stopped, completion_count);
  EXPECT(WaitUntil(^bool { return completion_count->load() == 2; }));
  ASPlaybackStats stats = ASPlaybackGetStats(session);
  EXPECT(stats.state == ASPlaybackFinished);
  EXPECT(stats.pending_samples == 0 && stats.accounted_samples == 0 &&
         stats.accounted_bytes == 0);
  CMSampleBufferRef sample = Video(kCMTimeZero);
  EXPECT(ASPlaybackEnqueue(session, ASPlaybackVideo, sample) == ASPlaybackStopped);
  if (sample) CFRelease(sample);
  EXPECT(ASPlaybackSetAnchor(session, kCMTimeZero, FutureHost()) == ASPlaybackStopped);
  ASPlaybackDestroy(session);
}

void TrackModes() {
  for (int mode = 1; mode <= 3; ++mode) {
    bool has_audio = mode & 1;
    bool has_video = mode & 2;
    ASPlaybackSession* session = ASPlaybackCreate(Config(has_audio, has_video));
    EXPECT(session);
    if (!session) continue;
    CFTypeRef layer_ref = ASPlaybackCopyVideoLayer(session);
    EXPECT((layer_ref != nullptr) == has_video);
    CALayer* container = [CALayer layer];
    if (layer_ref) {
      AVSampleBufferDisplayLayer* layer = (__bridge AVSampleBufferDisplayLayer*)layer_ref;
      container.frame = CGRectMake(0, 0, 320, 240);
      [container addSublayer:layer];
      layer.frame = container.bounds;
      EXPECT([layer.videoGravity isEqualToString:AVLayerVideoGravityResizeAspect]);
      container.bounds = CGRectMake(0, 0, 640, 360);
      layer.frame = container.bounds;
    }
    CMSampleBufferRef first = has_audio ? Audio(kCMTimeZero) : Video(kCMTimeZero);
    EXPECT(first);
    EXPECT(ASPlaybackEnqueue(session, has_audio ? ASPlaybackAudio : ASPlaybackVideo,
                             first) == ASPlaybackNotReady);
    EXPECT(ASPlaybackSetAnchor(session, kCMTimeZero, FutureHost()) == ASPlaybackAccepted);
    if (has_audio) {
      EXPECT(ASPlaybackEnqueue(session, ASPlaybackAudio, first) == ASPlaybackAccepted);
      CFRelease(first);
      first = nullptr;
    }
    if (has_video) {
      if (first) CFRelease(first);
      first = Video(CMTimeMake(1, 4));
      EXPECT(ASPlaybackEnqueue(session, ASPlaybackVideo, first) == ASPlaybackAccepted);
      CFRelease(first);
      first = nullptr;
    }
    ASPlaybackStats stats = ASPlaybackGetStats(session);
    EXPECT(stats.state == ASPlaybackPlaying);
    EXPECT(stats.accepted == (uint64_t)(has_audio + has_video));
    if (has_audio) EXPECT(CMTimeCompare(stats.first_audio_pts, kCMTimeZero) == 0);
    if (has_video) EXPECT(CMTimeCompare(stats.first_video_pts, CMTimeMake(1, 4)) == 0);
    if (mode == 3)
      EXPECT(CMTimeCompare(CMTimeSubtract(stats.first_video_pts, stats.first_audio_pts),
                           CMTimeMake(1, 4)) == 0);
    EXPECT(stats.peak_samples <= 8 && stats.peak_bytes <= 1024 * 1024);
    if (layer_ref) {
      [(__bridge CALayer*)layer_ref removeFromSuperlayer];
      CFRelease(layer_ref);
    }
    std::printf("mode %d accepted=%llu submitted=%llu buffered=%zu\n", mode,
        stats.accepted, stats.submitted, stats.accounted_samples);
    Finish(session);
  }
}

void BoundedFramesAndFormats() {
  ASPlaybackSession* session = ASPlaybackCreate(Config(true, true, 2));
  EXPECT(session);
  if (!session) return;
  EXPECT(ASPlaybackSetAnchor(session, kCMTimeZero, FutureHost()) == ASPlaybackAccepted);
  for (int i = 0; i < 3; ++i) {
    CMSampleBufferRef sample = Audio(CMTimeMake(i, 100));
    EXPECT(sample);
    EXPECT(ASPlaybackEnqueue(session, ASPlaybackAudio, sample) ==
            (i < 2 ? ASPlaybackAccepted : ASPlaybackBackpressured));
    CFRelease(sample);  // Asynchronous renderer cannot borrow this reference.
  }
  auto stats = ASPlaybackGetStats(session);
  EXPECT(stats.accounted_samples == 2 && stats.accounted_bytes == 7680);
  EXPECT(stats.backpressured == 1);
  EXPECT(ASPlaybackSetAnchor(session, kCMTimeZero, FutureHost()) == ASPlaybackAccepted);
  stats = ASPlaybackGetStats(session);
  EXPECT(stats.accounted_samples == 0 && stats.accounted_bytes == 0);

  CMSampleBufferRef malformed = Audio(kCMTimeZero, 48000, 2, 1);
  EXPECT(malformed);
  EXPECT(ASPlaybackEnqueue(session, ASPlaybackAudio, malformed) == ASPlaybackInvalidSample);
  CFRelease(malformed);
  CMSampleBufferRef old_format = Audio(kCMTimeZero);
  EXPECT(ASPlaybackEnqueue(session, ASPlaybackAudio, old_format) == ASPlaybackAccepted);
  CFRelease(old_format);
  uint64_t before_format_change = ASPlaybackGetStats(session).flushes;
  CMSampleBufferRef audio = Audio(kCMTimeZero, 44100, 1);
  EXPECT(ASPlaybackEnqueue(session, ASPlaybackAudio, audio) == ASPlaybackAccepted);
  CFRelease(audio);
  stats = ASPlaybackGetStats(session);
  EXPECT(stats.flushes == before_format_change + 1);
  EXPECT(stats.accounted_samples == 1 && stats.accounted_bytes == 1920);
  CMSampleBufferRef video = Video(CMTimeMake(1, 4));
  EXPECT(ASPlaybackEnqueue(session, ASPlaybackVideo, video) == ASPlaybackAccepted);
  CFRelease(video);
  EXPECT(ASPlaybackSetAnchor(session, kCMTimeZero, FutureHost()) == ASPlaybackAccepted);
  before_format_change = ASPlaybackGetStats(session).flushes;
  video = Video(kCMTimeZero, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
  EXPECT(video);
  EXPECT(ASPlaybackEnqueue(session, ASPlaybackVideo, video) == ASPlaybackAccepted);
  CFRelease(video);
  stats = ASPlaybackGetStats(session);
  EXPECT(stats.flushes == before_format_change + 1);
  EXPECT(stats.flushes >= 3);  // Explicit discontinuities and real format changes.
  EXPECT(stats.peak_samples <= 2 && stats.peak_bytes <= 1024 * 1024);
  Finish(session);
}

void ClockAndValidation() {
  EXPECT(!ASPlaybackCreate(Config(false, false)));
  ASPlaybackSession* session = ASPlaybackCreate(Config(false, true));
  EXPECT(session);
  if (!session) return;
  EXPECT(ASPlaybackSetAnchor(session, kCMTimeInvalid, FutureHost()) == ASPlaybackInvalidSample);
  EXPECT(ASPlaybackSetAnchor(session, kCMTimeZero,
      CMClockGetTime(CMClockGetHostTimeClock())) == ASPlaybackAccepted);
  CMSampleBufferRef late = Video(kCMTimeZero);
  EXPECT(ASPlaybackEnqueue(session, ASPlaybackVideo, late) == ASPlaybackAccepted);
  CFRelease(late);
  EXPECT(WaitUntil(^bool {
    auto stats = ASPlaybackGetStats(session);
    return CMTimeCompare(stats.current_time, CMTimeMake(1, 20)) >= 0 ||
           stats.state == ASPlaybackError;
  }));
  auto stats = ASPlaybackGetStats(session);
  EXPECT(stats.state != ASPlaybackError);
  EXPECT(CMTimeCompare(stats.current_time, CMTimeMake(1, 20)) >= 0);
  CMSampleBufferRef future = Video(CMTimeMake(60, 1));
  EXPECT(ASPlaybackEnqueue(session, ASPlaybackVideo, future) == ASPlaybackBackpressured);
  CFRelease(future);
  EXPECT(ASPlaybackEnqueue(session, ASPlaybackAudio, nullptr) == ASPlaybackInvalidSample);
  Finish(session);
}

void ConcurrentStopAndReverseArrival() {
  ASPlaybackSession* session = ASPlaybackCreate(Config(true, true));
  EXPECT(session);
  if (!session) return;
  EXPECT(ASPlaybackSetAnchor(session, kCMTimeZero, FutureHost()) == ASPlaybackAccepted);
  CMSampleBufferRef video = Video(CMTimeMake(1, 4));
  CMSampleBufferRef audio = Audio(kCMTimeZero);
  EXPECT(ASPlaybackEnqueue(session, ASPlaybackVideo, video) == ASPlaybackAccepted);
  EXPECT(ASPlaybackEnqueue(session, ASPlaybackAudio, audio) == ASPlaybackAccepted);
  auto stats = ASPlaybackGetStats(session);
  EXPECT(CMTimeCompare(CMTimeSubtract(stats.first_video_pts, stats.first_audio_pts),
                       CMTimeMake(1, 4)) == 0);
  std::atomic<int> completion_count{0};
  std::atomic<int>* completed = &completion_count;
  std::atomic<bool> invalid_result{false};
  std::thread producer([&] {
    for (int i = 0; i < 100; ++i) {
      auto result = ASPlaybackEnqueue(session, ASPlaybackAudio, audio);
      if (result == ASPlaybackStopped) break;
      if (result != ASPlaybackAccepted && result != ASPlaybackBackpressured)
        invalid_result = true;
    }
  });
  ASPlaybackStop(session, Stopped, completed);
  EXPECT(WaitUntil(^bool { return completed->load() == 1; }));
  producer.join();
  EXPECT(!invalid_result);
  stats = ASPlaybackGetStats(session);
  EXPECT(stats.state == ASPlaybackFinished && stats.accounted_bytes == 0);
  EXPECT(stats.peak_samples <= 8 && stats.peak_bytes <= 1024 * 1024);
  CFRelease(video);
  CFRelease(audio);
  ASPlaybackDestroy(session);
}
}  // namespace

int main() {
  @autoreleasepool {
    TrackModes();
    BoundedFramesAndFormats();
    ClockAndValidation();
    ConcurrentStopAndReverseArrival();
    std::printf("Native renderer integration: %s (%d failures). Physical presentation unmeasured.\n",
                 failures ? "FAIL" : "PASS", failures);
  }
  return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}

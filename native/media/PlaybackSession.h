#ifndef APPLESCREEN_NATIVE_MEDIA_PLAYBACK_SESSION_H_
#define APPLESCREEN_NATIVE_MEDIA_PLAYBACK_SESSION_H_

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ASPlaybackSession ASPlaybackSession;
typedef enum { ASPlaybackVideo, ASPlaybackAudio } ASPlaybackTrack;
typedef enum {
  ASPlaybackAccepted,
  ASPlaybackBackpressured,
  ASPlaybackNotReady,
  ASPlaybackStopped,
  ASPlaybackInvalidSample,
  ASPlaybackFailed
} ASPlaybackResult;
typedef enum {
  ASPlaybackIdle,
  ASPlaybackPlaying,
  ASPlaybackStopping,
  ASPlaybackFinished,
  ASPlaybackError
} ASPlaybackState;

typedef struct {
  bool video;
  bool audio;
  size_t max_samples;  // Across pending and conservatively accounted renderer data.
  size_t max_bytes;
  CMTime max_ahead;  // Maximum accepted end timestamp ahead of the playhead.
  CMTime late_video_tolerance;
} ASPlaybackConfig;

typedef struct {
  ASPlaybackState state;
  size_t pending_samples;
  size_t accounted_samples;
  size_t accounted_bytes;
  size_t peak_samples;
  size_t peak_bytes;
  uint64_t accepted;
  uint64_t submitted;  // Enqueued into AVFoundation; NOT measured presentation.
  uint64_t backpressured;
  uint64_t dropped_video;
  uint64_t dropped_audio;
  uint64_t flushes;
  CMTime current_time;
  CMTime first_video_pts;
  CMTime first_audio_pts;
  int64_t renderer_error;
} ASPlaybackStats;

// Call Create/CopyVideoLayer on main. Create returns NULL for invalid configuration.
// This object must be stopped explicitly before Destroy. Each handle is destroyed
// exactly once; callers serialize Destroy against every other API invocation.
ASPlaybackSession* ASPlaybackCreate(ASPlaybackConfig config);

// Returns a retained AVSampleBufferDisplayLayer, or NULL for audio-only. Caller
// owns main-thread layer attachment/layout/removal; the sink never creates a view.
CFTypeRef ASPlaybackCopyVideoLayer(ASPlaybackSession* session) CF_RETURNS_RETAINED;

// Set the single shared timeline before enqueue. Both times must be numeric,
// nonnegative and epoch zero. Use CMClockGetTime(CMClockGetHostTimeClock()) for
// host_time. Samples retain original inter-track offsets in media_time's domain.
// Re-anchoring a playing session is an explicit discontinuity and flushes BOTH
// tracks. Native synchronizer chooses the audio device clock if audio is present,
// and host clock for video-only. No Open Screen clock assumptions are made here.
ASPlaybackResult ASPlaybackSetAnchor(ASPlaybackSession* session,
                                    CMTime media_time, CMTime host_time);

// Thread-safe synchronous admission on a small serial media queue. Accepted means
// the sample was retained and admitted; later lateness, format changes, errors or
// stop can drop it. Input remains caller-owned. Rejected input is never retained.
// Raw formats: 8-bit NV12/BGRA video; interleaved native Float32 linear PCM audio.
// All samples need valid PTS and positive duration, and nondecreasing per-track
// PTS. Decoder adapters own normalization. Audio is admitted/dropped in complete
// sample buffers, preserving sample-frame alignment. New formats flush both tracks
// while preserving the shared running timeline. Renderer readiness and all three
// count/byte/time budgets bound admission; no per-frame main-queue work is posted.
ASPlaybackResult ASPlaybackEnqueue(ASPlaybackSession* session,
                                  ASPlaybackTrack track,
                                  CMSampleBufferRef sample);
ASPlaybackStats ASPlaybackGetStats(ASPlaybackSession* session);

// Stop rejects new input immediately when its serial operation executes, cancels
// requests/timer/notifications, flushes both renderers, and invokes completion on
// the media queue after its barrier. Completion may Destroy. Repeated Stop calls
// are supported; each supplied completion runs once. There are no media callbacks
// after the first stop completion. Never synchronously wait on main for completion.
typedef void (*ASPlaybackStopCompletion)(void* context);
void ASPlaybackStop(ASPlaybackSession* session,
                    ASPlaybackStopCompletion completion, void* context);
// Only after Stop completion. Null tolerated. Does not implicitly block or stop.
void ASPlaybackDestroy(ASPlaybackSession* session);

#ifdef __cplusplus
}
#endif
#endif

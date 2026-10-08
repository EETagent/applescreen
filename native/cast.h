#ifndef APPLESCREEN_NATIVE_CAST_H_
#define APPLESCREEN_NATIVE_CAST_H_
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <stdbool.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif
#define AS_CAST_API __attribute__((visibility("default")))
typedef struct ASCastRuntime ASCastRuntime;
typedef enum { ASCastIdle, ASCastStarting, ASCastReady, ASCastStreaming,
               ASCastStopping, ASCastStopped, ASCastFailed } ASCastState;
typedef enum { ASCastVP8, ASCastVP9, ASCastAV1 } ASCastCodec;
typedef enum { ASCastVideo, ASCastAudio } ASCastTrack;
typedef enum { ASCastAccepted, ASCastBackpressured, ASCastNotReady,
               ASCastSubmissionStopped, ASCastInvalidSample } ASCastSubmission;
typedef struct {
  uint64_t generation;
  uint64_t media_generation;
  ASCastState state;
  CFStringRef error;       // Borrowed through the callback, NULL on success.
  CFTypeRef video_layer;   // Borrowed; retain to attach on main. NULL clears it.
  bool video, audio;
  int width, height, fps_numerator, fps_denominator;
} ASCastEvent;
typedef void (*ASCastEventCallback)(void*, const ASCastEvent*);
typedef void (*ASCastCompletion)(void*);

// All APIs except Submit run on main. All callbacks run on main. Config strings
// and discovery keys are copied before return. No C++/FFmpeg objects cross this
// private C/CF boundary. One runtime owns the platform and both protocol roles.
AS_CAST_API ASCastRuntime* ASCastRuntimeCreate(void);
// Stop sources first, then call this asynchronous terminal barrier. Stop rejects
// new work, stops both roles, quiesces native discovery and deferred protocol
// destruction, then joins the runner off main. Repeated Stop is supported.
AS_CAST_API void ASCastRuntimeStop(ASCastRuntime*, ASCastCompletion, void*);
// Only after Stop completion; exactly once. NULL is allowed.
AS_CAST_API void ASCastRuntimeDestroy(ASCastRuntime*);

// Snapshot is an immutable borrowed CFArray of CFDictionary service candidates.
// Keys: id/name/model/service/type/domain (CFString), interface/port (CFNumber),
// addresses (CFArray of CFData sockaddr values, including scope). Group by id in
// presentation, retaining all service candidates for connection and removals.
// At most one pending main-queue snapshot is retained; updates are coalesced.
typedef void (*ASCastDiscoveryCallback)(void*, CFArrayRef, CFStringRef error);
AS_CAST_API void ASCastBrowse(ASCastRuntime*, uint32_t interface_index,
                             ASCastDiscoveryCallback, void*);
AS_CAST_API void ASCastRefresh(ASCastRuntime*);
AS_CAST_API void ASCastStopBrowsing(ASCastRuntime*, ASCastCompletion, void*);

typedef struct {
  const char* interface_name;  // Empty/NULL explicitly means Automatic.
  const char* developer_ca_path; // Empty/NULL uses normal Cast trust.
  bool video, audio;
  int width, height, fps_numerator, fps_denominator;
  int sample_rate, channels, max_bitrate;
  ASCastCodec codec;
} ASCastSenderConfig;
// Returns a new generation, or 0 if the runtime/role is busy or stopping.
// Source inspection precedes Start. Start success (Ready) follows authentication,
// application launch and encoder negotiation. Capture must wait for that event.
AS_CAST_API uint64_t ASCastStartSender(ASCastRuntime*, ASCastSenderConfig,
                                      CFArrayRef service_candidates,
                                      ASCastEventCallback, void*);
AS_CAST_API void ASCastStopSender(ASCastRuntime*, ASCastCompletion, void*);
// EOF drains accepted media before the ordinary terminal event. The matching
// generation must already be Ready. Explicit Stop cancels an ongoing drain.
AS_CAST_API void ASCastFinishSender(ASCastRuntime*, uint64_t generation);
// Thread-safe immediate admission. Host time must use CMClockGetHostTimeClock.
// For files use ONE source origin: hostOrigin + (PTS - sourceOrigin), retaining
// original audio/video offsets. Accepted retains the sample; caller always owns
// its original reference. Later congestion/cancellation may still drop input.
AS_CAST_API ASCastSubmission ASCastSubmit(ASCastRuntime*, uint64_t generation,
                                         ASCastTrack, CMSampleBufferRef,
                                         CMTime host_presentation_time);
AS_CAST_API bool ASCastSupportsCodec(ASCastCodec);

typedef struct {
  const char* receiver_id; // Stable application UUID, shared by control and DNS.
  const char* name;
  const char* developer_ca_path;
  const char* developer_key_path;
  uint32_t interface_index;
  uint16_t port;
  int display_width, display_height, max_fps;
} ASCastReceiverConfig;
AS_CAST_API uint64_t ASCastStartReceiver(ASCastRuntime*, ASCastReceiverConfig,
                                        ASCastEventCallback, void*);
AS_CAST_API void ASCastStopReceiver(ASCastRuntime*, ASCastCompletion, void*);
// Closing a playback window ends that media generation, keeping the service up.
AS_CAST_API void ASCastStopReceiverMedia(ASCastRuntime*, uint64_t generation,
                                        uint64_t media_generation);
#if defined(__cplusplus)
}
#endif
#endif

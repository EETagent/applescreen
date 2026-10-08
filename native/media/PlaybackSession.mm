#import "PlaybackSession.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <cmath>
#include <deque>
#include <limits>
#include <memory>

namespace {
bool Numeric(CMTime time) {
  return CMTIME_IS_NUMERIC(time) && time.timescale > 0 && time.epoch == 0;
}
bool Nonnegative(CMTime time) {
  return Numeric(time) && CMTimeCompare(time, kCMTimeZero) >= 0;
}
bool Positive(CMTime time) {
  return Numeric(time) && CMTimeCompare(time, kCMTimeZero) > 0;
}
bool Multiply(size_t a, size_t b, size_t* value) {
  if (b && a > std::numeric_limits<size_t>::max() / b) return false;
  *value = a * b;
  return true;
}

struct Sample {
  CMSampleBufferRef buffer;
  ASPlaybackTrack track;
  size_t bytes;
  CMTime end;
  Sample(CMSampleBufferRef value, ASPlaybackTrack kind, size_t size, CMTime until)
      : buffer((CMSampleBufferRef)CFRetain(value)), track(kind), bytes(size), end(until) {}
  ~Sample() { CFRelease(buffer); }
  Sample(const Sample&) = delete;
  Sample& operator=(const Sample&) = delete;
};
struct Submitted {
  size_t bytes;
  CMTime end;
};

// Format normalization belongs to the decoder/source adapter, not this sink.
bool Validate(CMSampleBufferRef sample, ASPlaybackTrack track, size_t* bytes) {
  if (!sample || !CMSampleBufferDataIsReady(sample) ||
      !Nonnegative(CMSampleBufferGetPresentationTimeStamp(sample)) ||
      !Positive(CMSampleBufferGetDuration(sample))) return false;
  CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
  if (!format) return false;
  if (track == ASPlaybackVideo) {
    if (CMFormatDescriptionGetMediaType(format) != kCMMediaType_Video ||
        CMSampleBufferGetNumSamples(sample) != 1) return false;
    CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
    if (!image || CFGetTypeID(image) != CVPixelBufferGetTypeID()) return false;
    OSType type = CVPixelBufferGetPixelFormatType(image);
    size_t width = CVPixelBufferGetWidth(image);
    size_t height = CVPixelBufferGetHeight(image);
    if (!width || !height) return false;
    if (type == kCVPixelFormatType_32BGRA) {
      size_t row;
      if (!Multiply(width, 4, &row) || CVPixelBufferGetBytesPerRow(image) < row ||
          !Multiply(CVPixelBufferGetBytesPerRow(image), height, bytes)) return false;
    } else if (type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
               type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
      if (CVPixelBufferGetPlaneCount(image) != 2) return false;
      size_t y, uv, chroma_row;
      if (!Multiply(width / 2 + width % 2, 2, &chroma_row) ||
          CVPixelBufferGetHeightOfPlane(image, 0) < height ||
          CVPixelBufferGetHeightOfPlane(image, 1) < height / 2 + height % 2 ||
          CVPixelBufferGetBytesPerRowOfPlane(image, 0) < width ||
          CVPixelBufferGetBytesPerRowOfPlane(image, 1) < chroma_row ||
          !Multiply(CVPixelBufferGetBytesPerRowOfPlane(image, 0), height, &y) ||
          !Multiply(CVPixelBufferGetBytesPerRowOfPlane(image, 1),
                    height / 2 + height % 2, &uv) ||
          y > std::numeric_limits<size_t>::max() - uv) return false;
      *bytes = y + uv;
    } else {
      return false;
    }
    // Pixel buffers may include extended rows or additional alignment storage.
    *bytes = std::max(*bytes, CVPixelBufferGetDataSize(image));
    return *bytes > 0;
  }
  if (track != ASPlaybackAudio ||
      CMFormatDescriptionGetMediaType(format) != kCMMediaType_Audio) return false;
  const AudioStreamBasicDescription* asbd =
      CMAudioFormatDescriptionGetStreamBasicDescription(format);
  CMItemCount frames = CMSampleBufferGetNumSamples(sample);
  if (!asbd || frames <= 0 || asbd->mSampleRate <= 0 ||
      !std::isfinite(asbd->mSampleRate) || !asbd->mChannelsPerFrame ||
      asbd->mChannelsPerFrame > 32 || asbd->mFormatID != kAudioFormatLinearPCM ||
      asbd->mFormatFlags != kAudioFormatFlagsNativeFloatPacked ||
      asbd->mBitsPerChannel != 32 || asbd->mFramesPerPacket != 1 ||
      asbd->mBytesPerFrame != 4 * asbd->mChannelsPerFrame ||
      asbd->mBytesPerPacket != asbd->mBytesPerFrame ||
      !Multiply((size_t)frames, asbd->mBytesPerFrame, bytes)) return false;
  CMBlockBufferRef data = CMSampleBufferGetDataBuffer(sample);
  return data && CMBlockBufferGetDataLength(data) == *bytes;
}
}  // namespace

@interface ASNativePlayback : NSObject {
 @public
  dispatch_queue_t queue;
  AVSampleBufferDisplayLayer* video;
  ASPlaybackConfig config;
  ASPlaybackStats stats;
 @private
  AVSampleBufferAudioRenderer* audio;
  AVSampleBufferRenderSynchronizer* synchronizer;
  dispatch_source_t timer;
  NSMutableArray* notifications;
  std::deque<std::unique_ptr<Sample>> pending[2];
  std::deque<Submitted> submitted;
  CMFormatDescriptionRef formats[2];
  CMTime last_pts[2];
  bool requesting[2];
}
- (instancetype)initWithConfig:(ASPlaybackConfig)value;
- (void)pump;
- (void)flush;
- (void)stop;
- (void)observeAudioFlush;
- (ASPlaybackResult)anchor:(CMTime)media host:(CMTime)host;
- (ASPlaybackResult)enqueue:(CMSampleBufferRef)sample track:(ASPlaybackTrack)track;
@end

@implementation ASNativePlayback
- (instancetype)initWithConfig:(ASPlaybackConfig)value {
  if (!(self = [super init])) return nil;
  config = value;
  queue = dispatch_queue_create("org.applescreen.playback",
      dispatch_queue_attr_make_with_autorelease_frequency(
          DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
  dispatch_queue_set_specific(queue, (__bridge const void*)self,
                              (__bridge void*)self, nullptr);
  stats.state = ASPlaybackIdle;
  stats.current_time = kCMTimeZero;
  stats.first_audio_pts = stats.first_video_pts = kCMTimeInvalid;
  last_pts[0] = last_pts[1] = kCMTimeInvalid;
  @try {
    synchronizer = [AVSampleBufferRenderSynchronizer new];
    if (!synchronizer) return nil;
    synchronizer.delaysRateChangeUntilHasSufficientMediaData = NO;
    if (config.video) {
      video = [AVSampleBufferDisplayLayer new];
      if (!video) return nil;
      video.videoGravity = AVLayerVideoGravityResizeAspect;
      [synchronizer addRenderer:video];
    }
    if (config.audio) {
      audio = [AVSampleBufferAudioRenderer new];
      if (!audio) return nil;
      [synchronizer addRenderer:audio];
    }
  } @catch (NSException* exception) {
    // Media services may be unavailable (for example inside a restricted
    // process sandbox). Keep Objective-C exceptions inside this private ABI.
    (void)exception;
    return nil;
  }
  if (config.audio) [self observeAudioFlush];
  __weak ASNativePlayback* weak = self;
  timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
  dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC,
                            2 * NSEC_PER_MSEC);
  dispatch_source_set_event_handler(timer, ^{ [weak pump]; });
  dispatch_resume(timer);
  return self;
}
- (void)dealloc {
  for (auto format : formats) if (format) CFRelease(format);
}
- (id<AVQueuedSampleBufferRendering>)renderer:(ASPlaybackTrack)track {
  return track == ASPlaybackVideo ? video : audio;
}
- (void)observeAudioFlush {
  notifications = [NSMutableArray new];
  __weak ASNativePlayback* weak = self;
  for (NSNotificationName name in @[
      AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification,
      AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification]) {
    id token = [[NSNotificationCenter defaultCenter] addObserverForName:name
        object:audio queue:nil usingBlock:^(NSNotification*) {
      ASNativePlayback* owner = weak;
      if (!owner) return;
      dispatch_async(owner->queue, ^{
        if (owner->stats.state == ASPlaybackPlaying) {
          // Device clock may have changed. Discard old format/device data and
          // preserve current media time at a newly sampled common host anchor.
          CMTime media = owner->synchronizer.currentTime;
          [owner flush];
          [owner->synchronizer setRate:1 time:media
              atHostTime:CMClockGetTime(CMClockGetHostTimeClock())];
        }
      });
    }];
    [notifications addObject:token];
  }
}
- (void)flush {
  [video stopRequestingMediaData];
  [audio stopRequestingMediaData];
  requesting[0] = requesting[1] = false;
  [video flushAndRemoveImage];
  [audio flush];
  for (size_t index = 0; index < 2; ++index) {
    if (index == ASPlaybackVideo) stats.dropped_video += pending[index].size();
    else stats.dropped_audio += pending[index].size();
    pending[index].clear();
    last_pts[index] = kCMTimeInvalid;
  }
  submitted.clear();
  stats.pending_samples = stats.accounted_samples = stats.accounted_bytes = 0;
  ++stats.flushes;
}
- (void)pump {
  if (stats.state != ASPlaybackPlaying) return;
  stats.current_time = synchronizer.currentTime;
  if ((video && video.status == AVQueuedSampleBufferRenderingStatusFailed) ||
      (audio && audio.status == AVQueuedSampleBufferRenderingStatusFailed)) {
    stats.renderer_error = video.error ? video.error.code : audio.error.code;
    stats.state = ASPlaybackError;
    synchronizer.rate = 0;
    [self flush];
    return;
  }
  // A renderer does not report individual physical presentation. This is only
  // conservative budget accounting; readyForMoreMediaData also gates every send.
  for (auto it = submitted.begin(); it != submitted.end();) {
    if (CMTimeCompare(it->end, stats.current_time) <= 0) {
      --stats.accounted_samples;
      stats.accounted_bytes -= it->bytes;
      it = submitted.erase(it);
    } else ++it;
  }
  for (size_t index = 0; index < 2; ++index) {
    ASPlaybackTrack track = (ASPlaybackTrack)index;
    id<AVQueuedSampleBufferRendering> renderer = [self renderer:track];
    auto& samples = pending[index];
    while (!samples.empty()) {
      Sample& sample = *samples.front();
      CMTime deadline = track == ASPlaybackVideo
          ? CMTimeAdd(sample.end, config.late_video_tolerance) : sample.end;
      if (CMTimeCompare(deadline, stats.current_time) < 0) {
        if (track == ASPlaybackVideo) ++stats.dropped_video;
        else ++stats.dropped_audio;  // Whole PCM buffer, resulting in a gap.
        --stats.accounted_samples;
        stats.accounted_bytes -= sample.bytes;
      } else if (renderer.readyForMoreMediaData) {
        [renderer enqueueSampleBuffer:sample.buffer];
        submitted.push_back({sample.bytes, sample.end});
        ++stats.submitted;
      } else break;
      samples.pop_front();
      --stats.pending_samples;
    }
    if (samples.empty() && requesting[index]) {
      [renderer stopRequestingMediaData];
      requesting[index] = false;
    } else if (!samples.empty() && !requesting[index]) {
      requesting[index] = true;
      __weak ASNativePlayback* weak = self;
      [renderer requestMediaDataWhenReadyOnQueue:queue usingBlock:^{ [weak pump]; }];
    }
  }
}
- (ASPlaybackResult)anchor:(CMTime)media host:(CMTime)host {
  if (stats.state == ASPlaybackStopping || stats.state == ASPlaybackFinished)
    return ASPlaybackStopped;
  if (stats.state == ASPlaybackError) return ASPlaybackFailed;
  if (!Nonnegative(media) || !Nonnegative(host)) return ASPlaybackInvalidSample;
  if (stats.state == ASPlaybackPlaying) [self flush];
  [synchronizer setRate:1 time:media atHostTime:host];
  stats.state = ASPlaybackPlaying;
  return ASPlaybackAccepted;
}
- (ASPlaybackResult)enqueue:(CMSampleBufferRef)sample track:(ASPlaybackTrack)track {
  if (stats.state == ASPlaybackStopping || stats.state == ASPlaybackFinished)
    return ASPlaybackStopped;
  if (stats.state == ASPlaybackError) return ASPlaybackFailed;
  if (stats.state != ASPlaybackPlaying) return ASPlaybackNotReady;
  if ((track != ASPlaybackVideo && track != ASPlaybackAudio) ||
      ![self renderer:track]) return ASPlaybackInvalidSample;
  size_t bytes = 0;
  if (!Validate(sample, track, &bytes)) return ASPlaybackInvalidSample;
  CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
  CMTime end = CMTimeAdd(pts, CMSampleBufferGetDuration(sample));
  if (!Nonnegative(end) || CMTimeCompare(end, pts) <= 0 ||
      (Numeric(last_pts[track]) && CMTimeCompare(pts, last_pts[track]) < 0))
    return ASPlaybackInvalidSample;
  [self pump];
  if (stats.state == ASPlaybackError) return ASPlaybackFailed;
  if (stats.accounted_samples >= config.max_samples || bytes > config.max_bytes ||
      stats.accounted_bytes > config.max_bytes - bytes ||
      CMTimeCompare(end, CMTimeAdd(stats.current_time, config.max_ahead)) > 0) {
    ++stats.backpressured;
    return ASPlaybackBackpressured;
  }
  CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
  if (formats[track] && !CMFormatDescriptionEqual(formats[track], format)) {
    [self flush];
  }
  if (formats[track]) CFRelease(formats[track]);
  formats[track] = (CMFormatDescriptionRef)CFRetain(format);
  pending[track].push_back(std::make_unique<Sample>(sample, track, bytes, end));
  ++stats.pending_samples;
  ++stats.accounted_samples;
  stats.accounted_bytes += bytes;
  stats.peak_samples = std::max(stats.peak_samples, stats.accounted_samples);
  stats.peak_bytes = std::max(stats.peak_bytes, stats.accounted_bytes);
  ++stats.accepted;
  last_pts[track] = pts;
  CMTime& first = track == ASPlaybackVideo ? stats.first_video_pts : stats.first_audio_pts;
  if (!Numeric(first)) first = pts;
  [self pump];
  return ASPlaybackAccepted;
}
- (void)stop {
  if (stats.state == ASPlaybackFinished || stats.state == ASPlaybackStopping) return;
  stats.state = ASPlaybackStopping;
  for (id token in notifications) [[NSNotificationCenter defaultCenter] removeObserver:token];
  [notifications removeAllObjects];
  dispatch_source_cancel(timer);
  dispatch_source_set_event_handler(timer, nil);
  timer = nil;
  synchronizer.rate = 0;
  [self flush];
  stats.state = ASPlaybackFinished;
}
@end

struct ASPlaybackSession { ASNativePlayback* owner; };

namespace {
void OnQueue(ASNativePlayback* owner, dispatch_block_t block) {
  if (dispatch_get_specific((__bridge const void*)owner)) block();
  else dispatch_sync(owner->queue, block);
}
}  // namespace

ASPlaybackSession* ASPlaybackCreate(ASPlaybackConfig config) {
  if (![NSThread isMainThread] || (!config.video && !config.audio) ||
      !config.max_samples || !config.max_bytes || !Positive(config.max_ahead) ||
      !Nonnegative(config.late_video_tolerance)) return nullptr;
  ASNativePlayback* owner = [[ASNativePlayback alloc] initWithConfig:config];
  return owner ? new ASPlaybackSession{owner} : nullptr;
}
CFTypeRef ASPlaybackCopyVideoLayer(ASPlaybackSession* session) {
  if (!session || ![NSThread isMainThread] || !session->owner->video) return nullptr;
  return CFBridgingRetain(session->owner->video);
}
ASPlaybackResult ASPlaybackSetAnchor(ASPlaybackSession* session,
                                    CMTime media_time, CMTime host_time) {
  if (!session) return ASPlaybackStopped;
  ASNativePlayback* owner = session->owner;
  __block ASPlaybackResult result;
  OnQueue(owner, ^{ result = [owner anchor:media_time host:host_time]; });
  return result;
}
ASPlaybackResult ASPlaybackEnqueue(ASPlaybackSession* session,
                                  ASPlaybackTrack track, CMSampleBufferRef sample) {
  if (!session) return ASPlaybackStopped;
  ASNativePlayback* owner = session->owner;
  __block ASPlaybackResult result;
  OnQueue(owner, ^{ result = [owner enqueue:sample track:track]; });
  return result;
}
ASPlaybackStats ASPlaybackGetStats(ASPlaybackSession* session) {
  if (!session) return ASPlaybackStats{.state = ASPlaybackFinished};
  ASNativePlayback* owner = session->owner;
  __block ASPlaybackStats result;
  OnQueue(owner, ^{ [owner pump]; result = owner->stats; });
  return result;
}
void ASPlaybackStop(ASPlaybackSession* session,
                    ASPlaybackStopCompletion completion, void* context) {
  if (!session) {
    if (completion) completion(context);
    return;
  }
  ASNativePlayback* owner = session->owner;
  dispatch_async(owner->queue, ^{
    [owner stop];
    dispatch_async(owner->queue, ^{ if (completion) completion(context); });
  });
}
void ASPlaybackDestroy(ASPlaybackSession* session) {
  if (!session) return;
  ASNativePlayback* owner = session->owner;
  __block bool stopped;
  OnQueue(owner, ^{ stopped = owner->stats.state == ASPlaybackFinished; });
  NSCAssert(stopped, @"Playback session must finish Stop before Destroy");
  if (stopped) delete session;
}

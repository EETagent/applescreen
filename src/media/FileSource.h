#import "MediaSourceTypes.h"

NS_ASSUME_NONNULL_BEGIN

// One local-file source for audio-only, video-only and combined files. Reader,
// timer and pending samples have one serial owner. Audio is native Float32 PCM,
// 48 kHz, mono for mono input and stereo otherwise. Video is oriented NV12.
// At most one unread sample per track is held. Full audio samples are retained
// on temporary backpressure, then dropped as an explicit gap after 100 ms;
// late raw video is dropped on the original timeline, never slowed or rebased.
@interface ASFileSource : NSObject <ASMediaSource>
- (instancetype)initWithURL:(NSURL *)URL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END

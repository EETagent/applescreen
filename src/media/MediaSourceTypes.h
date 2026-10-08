#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ASMediaTrack) { ASMediaTrackVideo, ASMediaTrackAudio };
typedef NS_ENUM(NSInteger, ASMediaTimestampDomain) {
    ASMediaTimestampFilePTS,
    ASMediaTimestampHostClock,
};
typedef NS_ENUM(NSInteger, ASMediaSubmitResult) {
    ASMediaSubmitAccepted,
    ASMediaSubmitBackpressured,
    ASMediaSubmitNotReady,
    ASMediaSubmitStopped,
    ASMediaSubmitError,
};

typedef struct {
    BOOL hasVideo, hasAudio;
    size_t width, height;
    double framesPerSecond;
    double audioSampleRate;
    UInt32 audioChannels;
    // Earliest actual first sample across present file tracks. Zero is valid.
    CMTime sourceOrigin;
} ASMediaSourceDescriptor;

typedef struct {
    ASMediaTimestampDomain domain;
    CMTime presentationTime;
    CMTime sourceOrigin;
    // File PTS maps to hostOrigin + (presentationTime - sourceOrigin).
    // Screen timestamps already use the Core Media host clock.
    CMTime hostOrigin;
} ASMediaTime;

// Called synchronously on the source's serial queue. The sample is borrowed
// through this call only. Accepted means the consumer retained the sample and
// admitted it to a bounded queue; later encoding/network drops remain possible.
// Never block this callback waiting for main or for a stopped worker.
typedef ASMediaSubmitResult (^ASMediaSubmit)(CMSampleBufferRef sample,
                                           ASMediaTrack track,
                                           ASMediaTime time);
typedef void (^ASMediaPrepared)(ASMediaSourceDescriptor descriptor,
                               NSError * _Nullable error);
// Exactly once for natural EOF or failure; explicit stop instead completes its
// own barrier and suppresses the terminal callback. All completions run on main.
typedef void (^ASMediaFinished)(NSError * _Nullable error);

@protocol ASMediaSource <NSObject>
// Inspect before negotiating. A successful preparation describes real tracks.
- (void)prepareWithCompletion:(ASMediaPrepared)completion;
// Call only after the core has negotiated and its encoders are ready.
- (void)startWithSubmit:(ASMediaSubmit)submit completion:(ASMediaFinished)completion;
// Idempotent, asynchronous. After completion no previous source can submit or
// deliver a prepared/terminal callback. Retain the source until this completes.
- (void)stopWithCompletion:(dispatch_block_t)completion;
@end

NS_ASSUME_NONNULL_END

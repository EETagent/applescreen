#import "FileSource.h"
#import <AVFoundation/AVFoundation.h>
#include <math.h>

typedef NS_ENUM(NSInteger, ASFileState) { ASFileIdle, ASFileReady, ASFileRunning, ASFileStopped };

static NSError *FileError(NSString *message) {
    return [NSError errorWithDomain:@"Applescreen.FileSource" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

static CMTime FirstMediaTime(AVAssetTrack *track) {
    for (AVAssetTrackSegment *segment in track.segments)
        if (!segment.empty) return segment.timeMapping.target.start;
    return track.timeRange.start;
}

@interface ASFileSource () {
    dispatch_queue_t _queue;
    NSURL *_URL;
    ASFileState _state;
    AVAssetReader *_reader;
    AVAssetReaderOutput *_video, *_audio;
    CMSampleBufferRef _pendingVideo, _pendingAudio;
    dispatch_source_t _timer;
    ASMediaSourceDescriptor _descriptor;
    CMTime _hostOrigin, _drainDeadline;
    CMTime _videoStart, _audioStart;
    NSError *_readError;
    ASMediaSubmit _submit;
    ASMediaFinished _finished;
}
// Main deliveries check this token; every other mutable field is queue-owned.
@property(atomic) NSUInteger generation;
@end

@implementation ASFileSource

- (instancetype)initWithURL:(NSURL *)URL {
    if ((self = [super init])) {
        _URL = [URL copy];
        _queue = dispatch_queue_create("app.applescreen.file", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)clearReader {
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    [_reader cancelReading];
    _reader = nil;
    _audio = _video = nil;
    if (_pendingVideo) { CFRelease(_pendingVideo); _pendingVideo = NULL; }
    if (_pendingAudio) { CFRelease(_pendingAudio); _pendingAudio = NULL; }
    _submit = nil;
    _readError = nil;
}

- (void)prepareWithCompletion:(ASMediaPrepared)completion {
    dispatch_async(_queue, ^{
        if (self->_state == ASFileRunning) {
            const NSUInteger generation = self.generation;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.generation == generation) completion((ASMediaSourceDescriptor){0},
                    FileError(@"Stop the file before preparing it again."));
            });
            return;
        }
        [self clearReader];
        const NSUInteger generation = ++self.generation;
        self->_descriptor = (ASMediaSourceDescriptor){ .sourceOrigin = kCMTimeInvalid };
        NSError *error = [self prepareReader];
        ASMediaSourceDescriptor descriptor = self->_descriptor;
        self->_state = error ? ASFileStopped : ASFileReady;
        if (error) [self clearReader];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.generation == generation) completion(descriptor, error);
        });
    });
}

- (NSError *)prepareReader {
    if (!_URL.isFileURL) return FileError(@"Choose a local media file.");
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:_URL options:nil];
    NSError *error;
    _reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (!_reader) return error ?: FileError(@"Cannot open the media file.");

    // These synchronous local-asset accessors are available on macOS 12. They
    // execute on the file owner, never on main or the protocol sequence.
    AVAssetTrack *video = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *audio = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!video && !audio) return FileError(@"The file has no playable audio or video track.");
    if (video) {
        _videoStart = FirstMediaTime(video);
        NSDictionary *settings = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        };
        if (CGAffineTransformIsIdentity(video.preferredTransform)) {
            _video = [[AVAssetReaderTrackOutput alloc] initWithTrack:video outputSettings:settings];
        } else {
            AVMutableVideoComposition *composition = [AVMutableVideoComposition videoCompositionWithPropertiesOfAsset:asset];
            // Unlike a fixed frameDuration, this preserves source VFR timing.
            composition.sourceTrackIDForFrameTiming = video.trackID;
            AVAssetReaderVideoCompositionOutput *output = [[AVAssetReaderVideoCompositionOutput alloc]
                initWithVideoTracks:@[video] videoSettings:settings];
            output.videoComposition = composition;
            _video = output;
        }
        _video.alwaysCopiesSampleData = NO;
        if (![_reader canAddOutput:_video]) return FileError(@"Cannot decode the file's video track.");
        [_reader addOutput:_video];
        _descriptor.framesPerSecond = video.nominalFrameRate;
        if (!isfinite(_descriptor.framesPerSecond) || _descriptor.framesPerSecond < 0)
            return FileError(@"Invalid video frame rate.");
    }
    if (audio) {
        _audioStart = FirstMediaTime(audio);
        CMAudioFormatDescriptionRef format = (__bridge CMAudioFormatDescriptionRef)audio.formatDescriptions.firstObject;
        const AudioStreamBasicDescription *asbd = format ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : NULL;
        if (!asbd || !asbd->mChannelsPerFrame) return FileError(@"Invalid audio channel layout.");
        const UInt32 channels = asbd->mChannelsPerFrame == 1 ? 1 : 2;
        NSDictionary *settings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @48000,
            AVNumberOfChannelsKey: @(channels), AVLinearPCMBitDepthKey: @32,
            AVLinearPCMIsFloatKey: @YES, AVLinearPCMIsBigEndianKey: @NO,
            AVLinearPCMIsNonInterleaved: @NO,
        };
        _audio = [[AVAssetReaderTrackOutput alloc] initWithTrack:audio outputSettings:settings];
        _audio.alwaysCopiesSampleData = NO;
        if (![_reader canAddOutput:_audio]) return FileError(@"Cannot decode the file's audio track.");
        [_reader addOutput:_audio];
        _descriptor.audioSampleRate = 48000;
        _descriptor.audioChannels = channels;
    }
    CMTime first = video ? _videoStart : _audioStart;
    if (audio && CMTimeCompare(_audioStart, first) < 0) first = _audioStart;
    if (CMTIME_IS_NUMERIC(first) && CMTIME_IS_NUMERIC(asset.duration) && CMTimeCompare(first, asset.duration) < 0)
        _reader.timeRange = CMTimeRangeFromTimeToTime(first, asset.duration);
    if (![_reader startReading]) return _reader.error ?: FileError(@"Cannot start decoding the file.");
    _pendingVideo = [self copyNext:NO];
    _pendingAudio = [self copyNext:YES];
    if (_readError) return _readError;
    if (_reader.status == AVAssetReaderStatusFailed) return _reader.error ?: FileError(@"Media decoding failed.");
    _descriptor.hasVideo = _pendingVideo != NULL;
    _descriptor.hasAudio = _pendingAudio != NULL;
    if (!_pendingVideo && !_pendingAudio) return FileError(@"The file has no media samples.");
    for (NSUInteger i = 0; i < 2; ++i) {
        CMSampleBufferRef sample = i ? _pendingAudio : _pendingVideo;
        if (!sample) continue;
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
        if (!CMSampleBufferDataIsReady(sample) || !CMTIME_IS_NUMERIC(pts))
            return FileError(@"A media sample has invalid presentation timing.");
        if (!CMTIME_IS_NUMERIC(_descriptor.sourceOrigin) || CMTimeCompare(pts, _descriptor.sourceOrigin) < 0)
            _descriptor.sourceOrigin = pts;
    }
    if (_pendingVideo) {
        CVImageBufferRef image = CMSampleBufferGetImageBuffer(_pendingVideo);
        if (!image) return FileError(@"The video decoder did not produce an image.");
        _descriptor.width = CVPixelBufferGetWidth(image);
        _descriptor.height = CVPixelBufferGetHeight(image);
    }
    return nil;
}

- (CMSampleBufferRef)copyNext:(BOOL)audio {
    AVAssetReaderOutput *output = audio ? _audio : _video;
    CMTime start = audio ? _audioStart : _videoStart;
    CMSampleBufferRef sample;
    while ((sample = [output copyNextSampleBuffer])) {
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
        if (!CMTIME_IS_NUMERIC(start) || !CMTIME_IS_NUMERIC(pts) || CMTimeCompare(pts, start) >= 0)
            return sample;
        // AVAssetReader synthesizes PCM for leading empty edits. Those bytes
        // are not source audio: retain the track's deliberate start offset.
        // Trim only whole PCM sample frames, including a buffer spanning start.
        CMTime skip = CMTimeConvertScale(CMTimeSubtract(start, pts), 48000,
                                         kCMTimeRoundingMethod_RoundTowardPositiveInfinity);
        CMItemCount count = CMSampleBufferGetNumSamples(sample);
        if (audio && CMTIME_IS_NUMERIC(skip) && skip.value > 0 && skip.value < count) {
            CMSampleBufferRef trimmed = NULL;
            OSStatus status = CMSampleBufferCopySampleBufferForRange(NULL, sample,
                CFRangeMake(skip.value, count - skip.value), &trimmed);
            CFRelease(sample);
            if (status != noErr) _readError = FileError(@"Cannot trim the audio track's empty edit.");
            return trimmed;
        }
        CFRelease(sample);
    }
    return NULL;
}

- (void)startWithSubmit:(ASMediaSubmit)submit completion:(ASMediaFinished)completion {
    dispatch_async(_queue, ^{
        const NSUInteger generation = self.generation;
        if (self->_state != ASFileReady) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.generation == generation) completion(FileError(@"Prepare the file before starting it."));
            });
            return;
        }
        self->_state = ASFileRunning;
        self->_submit = [submit copy];
        self->_finished = [completion copy];
        self->_hostOrigin = CMClockGetTime(CMClockGetHostTimeClock());
        self->_drainDeadline = self->_hostOrigin;
        self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
        __weak ASFileSource *weakSelf = self;
        dispatch_source_set_event_handler(self->_timer, ^{ [weakSelf pump]; });
        dispatch_source_set_timer(self->_timer, DISPATCH_TIME_NOW, DISPATCH_TIME_FOREVER, 1000000);
        dispatch_resume(self->_timer);
    });
}

- (void)scheduleAt:(CMTime)deadline {
    CMTime delay = CMTimeSubtract(deadline, CMClockGetTime(CMClockGetHostTimeClock()));
    CMTime ns = CMTimeConvertScale(delay, NSEC_PER_SEC, kCMTimeRoundingMethod_RoundAwayFromZero);
    if (!CMTIME_IS_NUMERIC(ns)) { [self finish:FileError(@"Media time exceeds the scheduler range.")]; return; }
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, MAX((int64_t)0, ns.value)),
                              DISPATCH_TIME_FOREVER, 1000000);
}

- (void)pump {
    if (_state != ASFileRunning) return;
    // The work budget prevents a long overdue file from monopolizing its queue;
    // it is independent of source fps. No fixed one-frame-per-tick scheduler.
    for (NSUInteger budget = 0; budget < 16; ++budget) {
        if (!_pendingVideo && !_pendingAudio) {
            if (_readError) { [self finish:_readError]; return; }
            if (_reader.status == AVAssetReaderStatusFailed) { [self finish:_reader.error]; return; }
            if (_reader.status == AVAssetReaderStatusCancelled) { [self finish:FileError(@"File reading was cancelled.")]; return; }
            if (CMTimeCompare(CMClockGetTime(CMClockGetHostTimeClock()), _drainDeadline) < 0)
                [self scheduleAt:_drainDeadline];
            else [self finish:nil];
            return;
        }
        BOOL audio = !_pendingVideo || (_pendingAudio && CMTimeCompare(
            CMSampleBufferGetPresentationTimeStamp(_pendingAudio),
            CMSampleBufferGetPresentationTimeStamp(_pendingVideo)) < 0);
        CMSampleBufferRef sample = audio ? _pendingAudio : _pendingVideo;
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
        if (!CMSampleBufferDataIsReady(sample) || !CMTIME_IS_NUMERIC(pts)) {
            [self finish:FileError(@"A media sample has invalid presentation timing.")]; return;
        }
        CMTime due = CMTimeAdd(_hostOrigin, CMTimeSubtract(pts, _descriptor.sourceOrigin));
        CMTime now = CMClockGetTime(CMClockGetHostTimeClock());
        if (!CMTIME_IS_NUMERIC(due)) { [self finish:FileError(@"Invalid media timeline.")]; return; }
        if (CMTimeCompare(now, due) < 0) { [self scheduleAt:due]; return; }
        BOOL late = CMTimeCompare(CMTimeSubtract(now, due), CMTimeMake(1, 10)) > 0;
        ASMediaSubmitResult result = ASMediaSubmitBackpressured;
        if (!late) result = _submit(sample, audio ? ASMediaTrackAudio : ASMediaTrackVideo,
            (ASMediaTime){ASMediaTimestampFilePTS, pts, _descriptor.sourceOrigin, _hostOrigin});
        if (result == ASMediaSubmitStopped || result == ASMediaSubmitError) {
            [self finish:FileError(@"The Cast sender stopped accepting media.")]; return;
        }
        if (!late && (result == ASMediaSubmitNotReady || (audio && result == ASMediaSubmitBackpressured))) {
            [self scheduleAt:CMTimeAdd(now, CMTimeMake(1, 200))]; return;
        }
        CMTime duration = CMSampleBufferGetDuration(sample);
        if (audio) duration = CMTimeMake(CMSampleBufferGetNumSamples(sample), 48000);
        if (CMTIME_IS_NUMERIC(duration) && CMTimeCompare(duration, kCMTimeZero) > 0) {
            CMTime end = CMTimeAdd(due, duration);
            if (CMTIME_IS_NUMERIC(end) && CMTimeCompare(end, _drainDeadline) > 0) _drainDeadline = end;
        }
        CFRelease(sample);
        // Completed means no further reading; the other track's already-read
        // final buffer is still submitted above before reporting EOF.
        if (audio) _pendingAudio = [self copyNext:YES];
        else _pendingVideo = [self copyNext:NO];
    }
    [self scheduleAt:CMClockGetTime(CMClockGetHostTimeClock())];
}

- (void)finish:(NSError *)error {
    ASMediaFinished completion = _finished;
    _finished = nil;
    const NSUInteger generation = self.generation;
    [self clearReader];
    _state = ASFileStopped;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{
        if (self.generation == generation) completion(error);
    });
}

- (void)stopWithCompletion:(dispatch_block_t)completion {
    dispatch_async(_queue, ^{
        ++self.generation;
        self->_finished = nil;
        [self clearReader];
        self->_state = ASFileStopped;
        dispatch_async(dispatch_get_main_queue(), completion);
    });
}

- (void)dealloc {
    // No queued block captures a deallocating source. Move the final safeguard
    // to its owner using retained resources, not a reference to self.
    AVAssetReader *reader = _reader;
    dispatch_source_t timer = _timer;
    CMSampleBufferRef video = _pendingVideo, audio = _pendingAudio;
    dispatch_async(_queue, ^{
        if (timer) dispatch_source_cancel(timer);
        [reader cancelReading];
        if (video) CFRelease(video);
        if (audio) CFRelease(audio);
    });
}
@end

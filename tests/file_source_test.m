#import "media/FileSource.h"
#import <AVFoundation/AVFoundation.h>
#include <math.h>
#include <stdio.h>

#define REQUIRE(condition) do { if (!(condition)) { \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); exit(1); \
} } while (0)

// Real tiny media fixtures test the AVAssetReader boundary and scheduler, not
// private state. All waits below wait for OS completion with a failure deadline.
static CMSampleBufferRef AudioSample(CMTime pts) {
    AudioStreamBasicDescription asbd = {
        .mSampleRate = 48000, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 8, .mFramesPerPacket = 1, .mBytesPerFrame = 8,
        .mChannelsPerFrame = 2, .mBitsPerChannel = 32,
    };
    CMAudioFormatDescriptionRef format = NULL;
    REQUIRE(CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, 0, NULL, NULL, &format) == noErr);
    CMBlockBufferRef data = NULL;
    REQUIRE(CMBlockBufferCreateWithMemoryBlock(NULL, NULL, 480 * 8, NULL, NULL, 0,
        480 * 8, kCMBlockBufferAssureMemoryNowFlag, &data) == noErr);
    REQUIRE(CMBlockBufferFillDataBytes(0, data, 0, 480 * 8) == noErr);
    CMSampleBufferRef sample = NULL;
    REQUIRE(CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, data, format,
        480, pts, NULL, &sample) == noErr);
    CFRelease(data);
    CFRelease(format);
    return sample;
}

static NSURL *Fixture(BOOL video, BOOL audio, NSUInteger fps, BOOL variable, BOOL rotated) {
    NSURL *URL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"applescreen-%@.mov", NSUUID.UUID.UUIDString]]];
    NSError *error;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:URL fileType:AVFileTypeQuickTimeMovie error:&error];
    REQUIRE(writer && !error);
    AVAssetWriterInput *videoInput, *audioInput;
    AVAssetWriterInputPixelBufferAdaptor *adaptor;
    if (video) {
        videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
            AVVideoCodecKey: AVVideoCodecTypeJPEG, AVVideoWidthKey: @32, AVVideoHeightKey: @24,
        }];
        if (rotated) videoInput.transform = CGAffineTransformMake(0, 1, -1, 0, 24, 0);
        adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:videoInput
            sourcePixelBufferAttributes:@{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                (NSString *)kCVPixelBufferWidthKey: @32, (NSString *)kCVPixelBufferHeightKey: @24}];
        REQUIRE([writer canAddInput:videoInput]);
        [writer addInput:videoInput];
    }
    if (audio) {
        audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:@{
            AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @48000, AVNumberOfChannelsKey: @2,
            AVLinearPCMBitDepthKey: @32, AVLinearPCMIsFloatKey: @YES,
            AVLinearPCMIsBigEndianKey: @NO, AVLinearPCMIsNonInterleaved: @NO,
        }];
        REQUIRE([writer canAddInput:audioInput]);
        [writer addInput:audioInput];
    }
    BOOL started = [writer startWriting];
    if (!started) fprintf(stderr, "Fixture writer: %s\n", writer.error.description.UTF8String);
    REQUIRE(started);
    [writer startSessionAtSourceTime:kCMTimeZero];
    dispatch_queue_t queue = dispatch_queue_create("file-source-test.writer", DISPATCH_QUEUE_SERIAL);
    dispatch_group_t group = dispatch_group_create();
    if (video) {
        dispatch_group_enter(group);
        __block NSUInteger frame = 0;
        [videoInput requestMediaDataWhenReadyOnQueue:queue usingBlock:^{
            const NSUInteger count = variable ? 5 : fps / 2;
            while (videoInput.readyForMoreMediaData && frame < count) {
                CVPixelBufferRef pixel = NULL;
                REQUIRE(CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &pixel) == kCVReturnSuccess);
                REQUIRE(CVPixelBufferLockBaseAddress(pixel, 0) == kCVReturnSuccess);
                memset(CVPixelBufferGetBaseAddress(pixel), (int)frame, CVPixelBufferGetDataSize(pixel));
                CVPixelBufferUnlockBaseAddress(pixel, 0);
                const int ticks[] = {0, 1, 4, 5, 12};
                CMTime pts = variable ? CMTimeMake(ticks[frame], 60) : CMTimeMake(frame, (int32_t)fps);
                REQUIRE([adaptor appendPixelBuffer:pixel withPresentationTime:pts]);
                CFRelease(pixel);
                ++frame;
            }
            if (frame == count) {
                [videoInput markAsFinished];
                dispatch_group_leave(group);
                ++frame;
            }
        }];
    }
    if (audio) {
        dispatch_group_enter(group);
        __block NSUInteger frame = 0;
        [audioInput requestMediaDataWhenReadyOnQueue:queue usingBlock:^{
            while (audioInput.readyForMoreMediaData && frame < 20) {
                CMSampleBufferRef sample = AudioSample(CMTimeMake(25 + frame, 100));
                REQUIRE([audioInput appendSampleBuffer:sample]);
                CFRelease(sample);
                ++frame;
            }
            if (frame == 20) { [audioInput markAsFinished]; dispatch_group_leave(group); ++frame; }
        }];
    }
    REQUIRE(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0);
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(finished); }];
    REQUIRE(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0);
    if (writer.status != AVAssetWriterStatusCompleted) fprintf(stderr, "%s\n", writer.error.description.UTF8String);
    REQUIRE(writer.status == AVAssetWriterStatusCompleted);
    return URL;
}

typedef struct { BOOL video, audio, variable, rotated; NSUInteger fps; } Case;
static const Case cases[] = {
    {YES, NO, NO, NO, 24}, {YES, NO, NO, NO, 30}, {YES, NO, NO, NO, 60},
    {NO, YES, NO, NO, 0}, {YES, YES, NO, NO, 60}, {YES, NO, YES, YES, 60},
};

static void RunCase(NSUInteger index);

static void TestRestart(NSURL *URL, dispatch_block_t done) {
    ASFileSource *source = [[ASFileSource alloc] initWithURL:URL];
    __block NSUInteger submitted = 0, terminal = 0;
    [source prepareWithCompletion:^(ASMediaSourceDescriptor descriptor, NSError *error) {
        (void)descriptor;
        REQUIRE(!error);
        [source startWithSubmit:^ASMediaSubmitResult(CMSampleBufferRef sample, ASMediaTrack track, ASMediaTime time) {
            (void)sample; (void)track; (void)time;
            ++submitted;
            return ASMediaSubmitNotReady;
        } completion:^(NSError *failure) { (void)failure; ++terminal; }];
        [source stopWithCompletion:^{
            NSUInteger atStop = submitted;
            [source stopWithCompletion:^{
                REQUIRE(terminal == 0 && submitted == atStop);
                [source prepareWithCompletion:^(ASMediaSourceDescriptor again, NSError *failure) {
                    REQUIRE(!failure && again.hasVideo);
                    [source startWithSubmit:^ASMediaSubmitResult(CMSampleBufferRef sample, ASMediaTrack track, ASMediaTime time) {
                        (void)track; (void)time;
                        CFRetain(sample); CFRelease(sample);
                        return ASMediaSubmitAccepted;
                    } completion:^(NSError *result) {
                        REQUIRE(!result && terminal == 0 && submitted == atStop);
                        [source stopWithCompletion:done];
                    }];
                }];
            }];
        }];
    }];
}

static void RunCase(NSUInteger index) {
    if (index == sizeof(cases) / sizeof(cases[0])) { puts("file_source_test: PASS (6 native fixtures, immediate stop/restart)"); exit(0); }
    Case test = cases[index];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *URL = Fixture(test.video, test.audio, test.fps, test.variable, test.rotated);
        dispatch_async(dispatch_get_main_queue(), ^{
            ASFileSource *source = [[ASFileSource alloc] initWithURL:URL];
            [source prepareWithCompletion:^(ASMediaSourceDescriptor descriptor, NSError *error) {
                if (error) fprintf(stderr, "%s\n", error.description.UTF8String);
                REQUIRE(!error && descriptor.hasVideo == test.video && descriptor.hasAudio == test.audio);
                if (test.video) REQUIRE(descriptor.width == (test.rotated ? 24 : 32) && descriptor.height == (test.rotated ? 32 : 24));
                if (test.audio) REQUIRE(descriptor.audioChannels == 2 && descriptor.audioSampleRate == 48000);
                __block NSUInteger videos = 0, audioFrames = 0, retries = 0;
                __block CMTime firstAudio = kCMTimeInvalid, firstVideo = kCMTimeInvalid;
                __block CMSampleBufferRef retained = NULL;
                CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
                [source startWithSubmit:^ASMediaSubmitResult(CMSampleBufferRef sample, ASMediaTrack track, ASMediaTime time) {
                    REQUIRE(time.domain == ASMediaTimestampFilePTS && CMTimeCompare(time.sourceOrigin, descriptor.sourceOrigin) == 0);
                    REQUIRE(CMTIME_IS_NUMERIC(time.hostOrigin));
                    if (track == ASMediaTrackAudio && retries++ < 3) return ASMediaSubmitBackpressured;
                    CFRetain(sample);
                    if (track == ASMediaTrackVideo) {
                        if (!CMTIME_IS_NUMERIC(firstVideo)) firstVideo = time.presentationTime;
                        const int ticks[] = {0, 1, 4, 5, 12};
                        CMTime expected = test.variable ? CMTimeMake(ticks[videos], 60) : CMTimeMake(videos, (int32_t)test.fps);
                        if (CMTimeCompare(time.presentationTime, expected) != 0)
                            fprintf(stderr, "case %lu sample %lu: expected %.6f, received %.6f\n",
                                (unsigned long)index, (unsigned long)videos,
                                CMTimeGetSeconds(expected), CMTimeGetSeconds(time.presentationTime));
                        REQUIRE(CMTimeCompare(time.presentationTime, expected) == 0);
                        ++videos;
                    } else {
                        if (!CMTIME_IS_NUMERIC(firstAudio)) firstAudio = time.presentationTime;
                        const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample));
                        REQUIRE(format && (format->mFormatFlags & kAudioFormatFlagIsFloat) && format->mBytesPerFrame == 8);
                        REQUIRE(CMBlockBufferGetDataLength(CMSampleBufferGetDataBuffer(sample)) == (size_t)CMSampleBufferGetNumSamples(sample) * 8);
                        audioFrames += CMSampleBufferGetNumSamples(sample);
                    }
                    if (!retained) retained = sample;
                    else CFRelease(sample);
                    return ASMediaSubmitAccepted;
                } completion:^(NSError *failure) {
                    if (failure) fprintf(stderr, "%s\n", failure.description.UTF8String);
                    fprintf(stderr, "case %lu: video=%lu audioFrames=%lu origin=%.6f firstV=%.6f firstA=%.6f elapsed=%.3f\n",
                        (unsigned long)index, (unsigned long)videos, (unsigned long)audioFrames,
                        CMTimeGetSeconds(descriptor.sourceOrigin), CMTimeGetSeconds(firstVideo),
                        CMTimeGetSeconds(firstAudio), CFAbsoluteTimeGetCurrent() - began);
                    REQUIRE(!failure);
                    REQUIRE(videos == (test.video ? (test.variable ? 5 : test.fps / 2) : 0));
                    REQUIRE(audioFrames == (test.audio ? 9600 : 0));
                    if (test.video && test.audio) REQUIRE(CMTimeCompare(CMTimeSubtract(firstAudio, firstVideo), CMTimeMake(1, 4)) == 0);
                    if (test.video && !test.variable) REQUIRE(CFAbsoluteTimeGetCurrent() - began >= 0.45 && CFAbsoluteTimeGetCurrent() - began < 1.5);
                    REQUIRE(retained && CMSampleBufferDataIsReady(retained));
                    CFRelease(retained); retained = NULL;
                    [source stopWithCompletion:^{
                        dispatch_block_t next = ^{
                            REQUIRE([[NSFileManager defaultManager] removeItemAtURL:URL error:NULL]);
                            RunCase(index + 1);
                        };
                        if (index == 0) TestRestart(URL, next); else next();
                    }];
                }];
            }];
        });
    });
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--write-fixtures") == 0) {
            NSURL *directory = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]] isDirectory:YES];
            REQUIRE([[NSFileManager defaultManager] createDirectoryAtURL:directory
                withIntermediateDirectories:YES attributes:nil error:NULL]);
            NSArray<NSString *> *names = @[@"video-24.mov", @"video-30.mov", @"video-60.mov",
                @"audio.mov", @"combined-offset-250ms.mov", @"video-vfr-rotated.mov"];
            for (NSUInteger index = 0; index < sizeof(cases) / sizeof(cases[0]); ++index) {
                Case test = cases[index];
                NSURL *fixture = Fixture(test.video, test.audio, test.fps, test.variable, test.rotated);
                NSURL *destination = [directory URLByAppendingPathComponent:names[index]];
                REQUIRE([[NSFileManager defaultManager] moveItemAtURL:fixture toURL:destination error:NULL]);
                puts(destination.path.UTF8String);
            }
            return 0;
        }
        REQUIRE(argc == 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            fputs("FAIL: native source test completion deadline exceeded\n", stderr); exit(1);
        });
        RunCase(0);
        dispatch_main();
    }
}

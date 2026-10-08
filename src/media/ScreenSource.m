#import "ScreenSource.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <math.h>

typedef NS_ENUM(NSInteger, ASScreenState) {
    ASScreenIdle, ASScreenPreparing, ASScreenReady, ASScreenStarting,
    ASScreenCapturing, ASScreenStoppingStart, ASScreenStopping, ASScreenStopped,
};

static NSError *ScreenError(NSString *message) {
    return [NSError errorWithDomain:@"Applescreen.ScreenSource" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface ASScreenSource () <SCStreamOutput, SCStreamDelegate> {
    dispatch_queue_t _queue;
    CGDirectDisplayID _displayID;
    ASScreenState _state;
    SCContentFilter *_filter;
    SCStream *_stream;
    ASMediaSourceDescriptor _descriptor;
    ASMediaSubmit _submit;
    ASMediaFinished _finished;
    NSMutableArray<dispatch_block_t> *_stopCompletions;
}
@property(atomic) NSUInteger generation;
@end

@implementation ASScreenSource
- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID {
    if ((self = [super init])) {
        _displayID = displayID;
        _queue = dispatch_queue_create("app.applescreen.screen", DISPATCH_QUEUE_SERIAL);
        _stopCompletions = [NSMutableArray array];
    }
    return self;
}

- (void)prepareWithCompletion:(ASMediaPrepared)completion {
    dispatch_async(_queue, ^{
        const NSUInteger current = self.generation;
        if (self->_state == ASScreenPreparing || self->_state == ASScreenStarting || self->_state == ASScreenCapturing ||
            self->_state == ASScreenStoppingStart || self->_state == ASScreenStopping) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.generation == current) completion((ASMediaSourceDescriptor){0},
                    ScreenError(@"Stop screen capture before preparing it again."));
            });
            return;
        }
        const NSUInteger generation = ++self.generation;
        self->_state = ASScreenPreparing;
        self->_filter = nil;
        self->_descriptor = (ASMediaSourceDescriptor){ .sourceOrigin = kCMTimeInvalid };
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
            dispatch_async(self->_queue, ^{
                if (self.generation != generation || self->_state != ASScreenPreparing) return;
                CGDirectDisplayID requested = self->_displayID ?: CGMainDisplayID();
                SCDisplay *display;
                for (SCDisplay *candidate in content.displays)
                    if (candidate.displayID == requested) { display = candidate; break; }
                NSError *result = error;
                if (!display && !result) result = ScreenError(@"The selected display is not available.");
                if (display) {
                    self->_filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
                    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(requested);
                    double fps = mode ? CGDisplayModeGetRefreshRate(mode) : 0;
                    // Variable-refresh displays report zero: request 60 fps,
                    // allowing SCStream to emit fewer frames when unchanged.
                    if (!isfinite(fps) || fps <= 0) fps = 60;
                    self->_descriptor = (ASMediaSourceDescriptor){
                        .hasVideo = YES,
                        .width = mode ? CGDisplayModeGetPixelWidth(mode) : (size_t)display.width,
                        .height = mode ? CGDisplayModeGetPixelHeight(mode) : (size_t)display.height,
                        .framesPerSecond = fps, .sourceOrigin = kCMTimeInvalid,
                    };
                    if (mode) CGDisplayModeRelease(mode);
                    if (!self->_descriptor.width || !self->_descriptor.height)
                        result = ScreenError(@"The selected display has invalid dimensions.");
                }
                self->_state = result ? ASScreenStopped : ASScreenReady;
                ASMediaSourceDescriptor descriptor = self->_descriptor;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.generation == generation) completion(descriptor, result);
                });
            });
        }];
    });
}

- (void)applyVideoWidth:(size_t)width height:(size_t)height framesPerSecond:(double)fps {
    dispatch_async(_queue, ^{
        if (self->_state != ASScreenReady || width < 2 || height < 2 ||
            width > self->_descriptor.width || height > self->_descriptor.height ||
            !isfinite(fps) || fps <= 0 || fps > self->_descriptor.framesPerSecond) return;
        self->_descriptor.width = width;
        self->_descriptor.height = height;
        self->_descriptor.framesPerSecond = fps;
    });
}

- (void)startWithSubmit:(ASMediaSubmit)submit completion:(ASMediaFinished)completion {
    dispatch_async(_queue, ^{
        const NSUInteger generation = self.generation;
        if (self->_state != ASScreenReady) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.generation == generation) completion(ScreenError(@"Prepare the display before starting capture."));
            });
            return;
        }
        self->_submit = [submit copy];
        self->_finished = [completion copy];
        SCStreamConfiguration *configuration = [SCStreamConfiguration new];
        configuration.width = self->_descriptor.width;
        configuration.height = self->_descriptor.height;
        configuration.minimumFrameInterval = CMTimeMakeWithSeconds(1.0 / self->_descriptor.framesPerSecond, 1000000);
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        // VPX sends the app's supported SDR interpretation. Convert display P3
        // at capture, before the shared native-frame encoder boundary.
        configuration.colorSpaceName = kCGColorSpaceITUR_709;
        configuration.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4;
        configuration.queueDepth = 3;
        SCStream *stream = [[SCStream alloc] initWithFilter:self->_filter configuration:configuration delegate:self];
        self->_stream = stream;
        NSError *error;
        if (![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self->_queue error:&error]) {
            [self fail:error ?: ScreenError(@"Cannot attach screen capture output.")]; return;
        }
        self->_state = ASScreenStarting;
        [stream startCaptureWithCompletionHandler:^(NSError *startError) {
            dispatch_async(self->_queue, ^{
                if (self->_stream != stream) return;
                if (self->_state == ASScreenStoppingStart) {
                    if (startError) [self completeStop];
                    else [self requestNativeStop];
                    return;
                }
                if (self.generation != generation || self->_state != ASScreenStarting) return;
                if (startError) [self fail:startError];
                else self->_state = ASScreenCapturing;
            });
        }];
    });
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if (_stream != stream || _state != ASScreenCapturing || type != SCStreamOutputTypeScreen ||
        !CMSampleBufferIsValid(sample) || !CMSampleBufferDataIsReady(sample) ||
        !CMSampleBufferGetImageBuffer(sample)) return;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (!attachments || !CFArrayGetCount(attachments)) return;
    NSDictionary *attachment = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
    NSNumber *status = attachment[SCStreamFrameInfoStatus];
    // ScreenCaptureKit documents displayTime as mach absolute host units. Use
    // that provenance explicitly instead of guessing a sample PTS time domain.
    NSNumber *displayTime = attachment[SCStreamFrameInfoDisplayTime];
    if (!status || status.integerValue != SCFrameStatusComplete || !displayTime) return;
    CMTime pts = CMClockMakeHostTimeFromSystemUnits(displayTime.unsignedLongLongValue);
    if (!CMTIME_IS_NUMERIC(pts)) return;
    ASMediaSubmitResult result = _submit(sample, ASMediaTrackVideo,
        (ASMediaTime){ASMediaTimestampHostClock, pts, kCMTimeInvalid, kCMTimeInvalid});
    // Backpressure drops a whole raw frame; the next callback has its original
    // host timestamp. There is no source-side pixel copy or per-frame main task.
    if (result == ASMediaSubmitError || result == ASMediaSubmitStopped)
        [self fail:ScreenError(@"The Cast sender stopped accepting screen frames.")];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(_queue, ^{
        if (self->_stream != stream) return;
        if (self->_state == ASScreenStopping || self->_state == ASScreenStoppingStart)
            [self completeStop];
        else [self fail:error];
    });
}

- (void)fail:(NSError *)error {
    ASMediaFinished finished = _finished;
    _finished = nil;
    _submit = nil;
    const NSUInteger generation = self.generation;
    // Keep a possibly live stream until its native stop barrier completes.
    if (_stream && _state == ASScreenCapturing) [self requestNativeStop];
    else [self completeStop];
    if (finished) dispatch_async(dispatch_get_main_queue(), ^{
        if (self.generation == generation) finished(error);
    });
}

- (void)stopWithCompletion:(dispatch_block_t)completion {
    dispatch_async(_queue, ^{
        ++self.generation;
        self->_submit = nil;
        self->_finished = nil;
        [self->_stopCompletions addObject:[completion copy]];
        switch (self->_state) {
            case ASScreenStarting: self->_state = ASScreenStoppingStart; break;
            case ASScreenCapturing: [self requestNativeStop]; break;
            case ASScreenStoppingStart:
            case ASScreenStopping: break;
            default: [self completeStop]; break;
        }
    });
}

- (void)requestNativeStop {
    _state = ASScreenStopping;
    SCStream *stream = _stream;
    [stream stopCaptureWithCompletionHandler:^(NSError *error) {
        (void)error;
        dispatch_async(self->_queue, ^{
            if (self->_stream == stream) [self completeStop];
        });
    }];
}

- (void)completeStop {
    [_stream removeStreamOutput:self type:SCStreamOutputTypeScreen error:NULL];
    _stream = nil;
    _filter = nil;
    _submit = nil;
    _state = ASScreenStopped;
    NSArray<dispatch_block_t> *completions = [_stopCompletions copy];
    [_stopCompletions removeAllObjects];
    for (dispatch_block_t completion in completions) dispatch_async(dispatch_get_main_queue(), completion);
}

- (void)dealloc {
    SCStream *stream = _stream;
    // Explicit stop is primary. This safeguard owns no controller/self and
    // does not capture a deallocating delegate in a completion.
    if (stream) dispatch_async(_queue, ^{ [stream stopCaptureWithCompletionHandler:^(NSError *error) { (void)error; }]; });
}
@end

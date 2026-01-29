// ReceiverViewController.m

#import "ReceiverViewController.h"

static void on_window_open(void* user_data, const CastWindowConfig* config);
static void on_window_close(void* user_data);
static void on_window_resize(void* user_data, int width, int height);
static void on_video_frame(void* user_data, const CastVideoFrame* frame);
static void on_audio_frame(void* user_data, const CastAudioFrame* frame);
static void on_error(void* user_data, int error_code, const char* error_message);

@interface ReceiverViewController ()

@property (nonatomic, strong) NSTextField* interfaceField;
@property (nonatomic, strong) NSTextField* certPathField;
@property (nonatomic, strong) NSTextField* keyPathField;
@property (nonatomic, strong) NSTextField* friendlyNameField;
@property (nonatomic, strong) NSButton* startButton;
@property (nonatomic, strong) NSButton* stopButton;
@property (nonatomic, strong) NSTextField* statusLabel;

@property (nonatomic, strong) VideoWindowController* videoWindowController;
@property (nonatomic, assign) CastReceiver* receiver;
@property (nonatomic, assign) AudioRingBuffer audioBuffer;
@property (nonatomic, assign) AudioQueueRef audioQueue;
@property (nonatomic, assign) int audioSampleRate;
@property (nonatomic, assign) int audioChannels;

@end

@implementation ReceiverViewController

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
    [self setupUI];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    audio_ring_buffer_init(&_audioBuffer);
}

- (void)setupUI {
    NSView* view = self.view;
    CGFloat y = 250;
    CGFloat labelWidth = 120;
    CGFloat fieldX = 130;
    CGFloat fieldWidth = 350;

    // Interface name
    NSTextField* ifaceLabel = [NSTextField labelWithString:@"Interface:"];
    ifaceLabel.frame = NSMakeRect(10, y, labelWidth, 22);
    [view addSubview:ifaceLabel];

    self.interfaceField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, y, fieldWidth, 22)];
    self.interfaceField.stringValue = @"en0";
    self.interfaceField.placeholderString = @"e.g., en0";
    [view addSubview:self.interfaceField];
    y -= 35;

    // Certificate path
    NSTextField* certLabel = [NSTextField labelWithString:@"Certificate:"];
    certLabel.frame = NSMakeRect(10, y, labelWidth, 22);
    [view addSubview:certLabel];

    self.certPathField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, y, fieldWidth, 22)];
    self.certPathField.stringValue = @"./generated_root_cast_receiver.crt";
    self.certPathField.placeholderString = @"Path to .pem certificate";
    [view addSubview:self.certPathField];
    y -= 35;

    // Private key path
    NSTextField* keyLabel = [NSTextField labelWithString:@"Private Key:"];
    keyLabel.frame = NSMakeRect(10, y, labelWidth, 22);
    [view addSubview:keyLabel];

    self.keyPathField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, y, fieldWidth, 22)];
    self.keyPathField.stringValue = @"./generated_root_cast_receiver.key";
    self.keyPathField.placeholderString = @"Path to .pem private key";
    [view addSubview:self.keyPathField];
    y -= 35;

    // Friendly name
    NSTextField* nameLabel = [NSTextField labelWithString:@"Friendly Name:"];
    nameLabel.frame = NSMakeRect(10, y, labelWidth, 22);
    [view addSubview:nameLabel];

    self.friendlyNameField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, y, fieldWidth, 22)];
    self.friendlyNameField.stringValue = @"MacCastReceiver";
    [view addSubview:self.friendlyNameField];
    y -= 50;

    // Buttons
    self.startButton = [[NSButton alloc] initWithFrame:NSMakeRect(130, y, 100, 32)];
    self.startButton.title = @"Start";
    self.startButton.bezelStyle = NSBezelStyleRounded;
    self.startButton.target = self;
    self.startButton.action = @selector(startReceiver);
    [view addSubview:self.startButton];

    self.stopButton = [[NSButton alloc] initWithFrame:NSMakeRect(250, y, 100, 32)];
    self.stopButton.title = @"Stop";
    self.stopButton.bezelStyle = NSBezelStyleRounded;
    self.stopButton.target = self;
    self.stopButton.action = @selector(stopReceiver);
    self.stopButton.enabled = NO;
    [view addSubview:self.stopButton];
    y -= 50;

    // Status label
    self.statusLabel = [NSTextField labelWithString:@"Status: Stopped"];
    self.statusLabel.frame = NSMakeRect(10, y, 480, 22);
    self.statusLabel.alignment = NSTextAlignmentCenter;
    [view addSubview:self.statusLabel];
}

- (BOOL)isRunning {
    return self.receiver != NULL && cast_receiver_is_running(self.receiver);
}

- (void)startReceiver {
    NSString* interface = self.interfaceField.stringValue;
    NSString* certPath = self.certPathField.stringValue;
    NSString* keyPath = self.keyPathField.stringValue;
    NSString* friendlyName = self.friendlyNameField.stringValue;

    if (interface.length == 0) {
        [self showError:@"Please enter an interface name"];
        return;
    }
    if (certPath.length == 0 || keyPath.length == 0) {
        [self showError:@"Please provide certificate and private key paths"];
        return;
    }

    CastReceiverConfig config = {
        .interface_name = interface.UTF8String,
        .certificate_path = certPath.UTF8String,
        .private_key_path = keyPath.UTF8String,
        .friendly_name = friendlyName.UTF8String,
        .model_name = "mac_cast_receiver",
        .enable_discovery = true,
        .enable_dscp = true
    };

    CastReceiverCallbacks callbacks = {
        .user_data = (__bridge void*)self,
        .on_window_open = on_window_open,
        .on_window_close = on_window_close,
        .on_window_resize = on_window_resize,
        .on_video_frame = on_video_frame,
        .on_audio_frame = on_audio_frame,
        .on_error = on_error
    };

    self.receiver = cast_receiver_create(&config, &callbacks);
    if (!self.receiver) {
        [self showError:@"Failed to create receiver"];
        return;
    }

    int result = cast_receiver_start(self.receiver);
    if (result != 0) {
        cast_receiver_destroy(self.receiver);
        self.receiver = NULL;
        [self showError:@"Failed to start receiver"];
        return;
    }

    self.startButton.enabled = NO;
    self.stopButton.enabled = YES;
    [self updateStatus:@"Running - Waiting for connection..."];
}

- (void)stopReceiver {
    if (self.receiver) {
        cast_receiver_stop(self.receiver);
        cast_receiver_destroy(self.receiver);
        self.receiver = NULL;
    }

    [self stopAudio];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.videoWindowController close];
        self.videoWindowController = nil;

        self.startButton.enabled = YES;
        self.stopButton.enabled = NO;
        [self updateStatus:@"Stopped"];
    });
}

- (void)showError:(NSString*)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = @"Error";
        alert.informativeText = message;
        alert.alertStyle = NSAlertStyleWarning;
        [alert runModal];
    });
}

- (void)updateStatus:(NSString*)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Status: %@", status];
        if ([self.delegate respondsToSelector:@selector(receiverDidUpdateStatus:)]) {
            [self.delegate receiverDidUpdateStatus:status];
        }
    });
}

- (void)openVideoWindowWithWidth:(int)width height:(int)height title:(const char*)title {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* titleStr = title ? [NSString stringWithUTF8String:title] : @"Cast Video";
        self.videoWindowController = [[VideoWindowController alloc] initWithWidth:width
                                                                           height:height
                                                                            title:titleStr];
        [self.videoWindowController showWindow:nil];
        [self updateStatus:@"Streaming..."];
    });
}

- (void)closeVideoWindow {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.videoWindowController close];
        self.videoWindowController = nil;

        if ([self isRunning]) {
            [self updateStatus:@"Running - Waiting for connection..."];
        }
    });

    [self stopAudio];
}

- (void)resizeVideoWindowToWidth:(int)width height:(int)height {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.videoWindowController) {
            NSRect frame = self.videoWindowController.window.frame;
            frame.size = NSMakeSize(width, height);
            [self.videoWindowController.window setFrame:frame display:YES animate:YES];
        }
    });
}

- (void)displayVideoFrame:(const CastVideoFrame*)frame {
    if (!self.videoWindowController || frame->format != kPixelFormatYUV420P) {
        return;
    }

    // Copy frame data to avoid race conditions
    int width = frame->width;
    int height = frame->height;
    int yLineSize = frame->line_sizes[0];
    int uLineSize = frame->line_sizes[1];
    int vLineSize = frame->line_sizes[2];

    size_t ySize = yLineSize * height;
    size_t uvSize = uLineSize * (height / 2);

    uint8_t* yCopy = malloc(ySize);
    uint8_t* uCopy = malloc(uvSize);
    uint8_t* vCopy = malloc(uvSize);

    memcpy(yCopy, frame->planes[0], ySize);
    memcpy(uCopy, frame->planes[1], uvSize);
    memcpy(vCopy, frame->planes[2], uvSize);

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.videoWindowController.videoView updateTexturesWithYPlane:yCopy
                                                             yLineSize:yLineSize
                                                                uPlane:uCopy
                                                             uLineSize:uLineSize
                                                                vPlane:vCopy
                                                             vLineSize:vLineSize
                                                                 width:width
                                                                height:height];
        [self.videoWindowController.videoView render];

        free(yCopy);
        free(uCopy);
        free(vCopy);
    });
}

// Audio callback for AudioQueue
static void audioQueueCallback(void* userData, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    ReceiverViewController* self = (__bridge ReceiverViewController*)userData;

    size_t read = audio_ring_buffer_read(&self->_audioBuffer, buffer->mAudioData, buffer->mAudioDataBytesCapacity);
    buffer->mAudioDataByteSize = (UInt32)read;

    if (read < buffer->mAudioDataBytesCapacity) {
        // Fill remainder with silence
        memset((uint8_t*)buffer->mAudioData + read, 0, buffer->mAudioDataBytesCapacity - read);
        buffer->mAudioDataByteSize = buffer->mAudioDataBytesCapacity;
    }

    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

- (void)setupAudioWithSampleRate:(int)sampleRate channels:(int)channels {
    if (self.audioQueue && self.audioSampleRate == sampleRate && self.audioChannels == channels) {
        return;
    }

    [self stopAudio];

    self.audioSampleRate = sampleRate;
    self.audioChannels = channels;

    AudioStreamBasicDescription format = {
        .mSampleRate = (Float64)sampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 4 * channels,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 4 * channels,
        .mChannelsPerFrame = channels,
        .mBitsPerChannel = 32,
    };

    OSStatus status = AudioQueueNewOutput(&format, audioQueueCallback, (__bridge void*)self,
                                          NULL, NULL, 0, &_audioQueue);
    if (status != noErr) {
        NSLog(@"Failed to create audio queue: %d", (int)status);
        return;
    }

    // Create and enqueue buffers
    for (int i = 0; i < 3; i++) {
        AudioQueueBufferRef buffer;
        // Buffer for ~20ms of audio
        UInt32 bufferSize = sampleRate * channels * 4 / 50;
        AudioQueueAllocateBuffer(self.audioQueue, bufferSize, &buffer);
        buffer->mAudioDataByteSize = bufferSize;
        memset(buffer->mAudioData, 0, bufferSize);
        AudioQueueEnqueueBuffer(self.audioQueue, buffer, 0, NULL);
    }

    AudioQueueStart(self.audioQueue, NULL);
}

- (void)stopAudio {
    if (self.audioQueue) {
        AudioQueueStop(self.audioQueue, true);
        AudioQueueDispose(self.audioQueue, true);
        self.audioQueue = NULL;
    }
}

- (void)handleAudioFrame:(const CastAudioFrame*)frame {
    [self setupAudioWithSampleRate:frame->sample_rate channels:frame->channels];

    // Convert to float if needed and write to ring buffer
    if (frame->format == kAudioFormatFloat) {
        audio_ring_buffer_write(&_audioBuffer, frame->planes[0], frame->plane_sizes[0]);
    } else if (frame->format == kAudioFormatPlanarFloat) {
        // Interleave planar float data
        int samples = frame->samples_per_channel;
        int channels = frame->channels;
        size_t bufferSize = samples * channels * sizeof(float);
        float* interleaved = malloc(bufferSize);

        for (int s = 0; s < samples; s++) {
            for (int c = 0; c < channels && c < frame->plane_count; c++) {
                const float* plane = (const float*)frame->planes[c];
                interleaved[s * channels + c] = plane[s];
            }
        }

        audio_ring_buffer_write(&_audioBuffer, (uint8_t*)interleaved, bufferSize);
        free(interleaved);
    } else if (frame->format == kAudioFormatS16) {
        // Convert S16 to float
        int samples = frame->samples_per_channel * frame->channels;
        size_t bufferSize = samples * sizeof(float);
        float* floatData = malloc(bufferSize);
        const int16_t* s16Data = (const int16_t*)frame->planes[0];

        for (int i = 0; i < samples; i++) {
            floatData[i] = s16Data[i] / 32768.0f;
        }

        audio_ring_buffer_write(&_audioBuffer, (uint8_t*)floatData, bufferSize);
        free(floatData);
    } else if (frame->format == kAudioFormatPlanarS16) {
        // Convert planar S16 to interleaved float
        int samples = frame->samples_per_channel;
        int channels = frame->channels;
        size_t bufferSize = samples * channels * sizeof(float);
        float* interleaved = malloc(bufferSize);

        for (int s = 0; s < samples; s++) {
            for (int c = 0; c < channels && c < frame->plane_count; c++) {
                const int16_t* plane = (const int16_t*)frame->planes[c];
                interleaved[s * channels + c] = plane[s] / 32768.0f;
            }
        }

        audio_ring_buffer_write(&_audioBuffer, (uint8_t*)interleaved, bufferSize);
        free(interleaved);
    }
}

- (void)handleError:(int)errorCode message:(const char*)message {
    NSString* msg = message ? [NSString stringWithUTF8String:message] : @"Unknown error";
    [self updateStatus:[NSString stringWithFormat:@"Error: %@", msg]];
}

- (void)dealloc {
    [self stopReceiver];
    audio_ring_buffer_destroy(&_audioBuffer);
}

@end

// C Callback Implementations
static void on_window_open(void* user_data, const CastWindowConfig* config) {
    ReceiverViewController* vc = (__bridge ReceiverViewController*)user_data;
    [vc openVideoWindowWithWidth:config->width height:config->height title:config->title];
}

static void on_window_close(void* user_data) {
    ReceiverViewController* vc = (__bridge ReceiverViewController*)user_data;
    [vc closeVideoWindow];
}

static void on_window_resize(void* user_data, int width, int height) {
    ReceiverViewController* vc = (__bridge ReceiverViewController*)user_data;
    [vc resizeVideoWindowToWidth:width height:height];
}

static void on_video_frame(void* user_data, const CastVideoFrame* frame) {
    ReceiverViewController* vc = (__bridge ReceiverViewController*)user_data;
    [vc displayVideoFrame:frame];
}

static void on_audio_frame(void* user_data, const CastAudioFrame* frame) {
    ReceiverViewController* vc = (__bridge ReceiverViewController*)user_data;
    [vc handleAudioFrame:frame];
}

static void on_error(void* user_data, int error_code, const char* error_message) {
    ReceiverViewController* vc = (__bridge ReceiverViewController*)user_data;
    [vc handleError:error_code message:error_message];
}

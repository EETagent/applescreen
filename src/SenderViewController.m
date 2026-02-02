// SenderViewController.m

#import "SenderViewController.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>

#include "cast/standalone_sender/my_lib.h"

@interface DiscoveredReceiver : NSObject
@property (nonatomic, copy) NSString* uniqueId;
@property (nonatomic, copy) NSString* friendlyName;
@property (nonatomic, copy) NSString* ipAddress;
@property (nonatomic, assign) uint16_t port;
@end

@implementation DiscoveredReceiver
@end

static void on_receiver_discovered(void* user_data, const SenderDiscoveredReceiver* receiver);
static void on_receiver_lost(void* user_data, const char* unique_id);
static void on_connected(void* user_data);
static void on_disconnected(void* user_data);
static void on_sender_error(void* user_data, int error_code, const char* error_message);

@interface SenderViewController () <SCStreamDelegate, SCStreamOutput>

@property (nonatomic, strong) NSTableView* receiversTable;
@property (nonatomic, strong) NSButton* refreshButton;
@property (nonatomic, strong) NSButton* connectButton;
@property (nonatomic, strong) NSButton* disconnectButton;
@property (nonatomic, strong) NSPopUpButton* sourcePopup;
@property (nonatomic, strong) NSButton* browseButton;
@property (nonatomic, strong) NSTextField* filePathField;
@property (nonatomic, strong) NSTextField* statusLabel;
@property (nonatomic, strong) NSTextField* interfaceField;
@property (nonatomic, strong) NSTextField* certPathField;
@property (nonatomic, strong) NSButton* certBrowseButton;

@property (nonatomic, strong) NSMutableArray<DiscoveredReceiver*>* discoveredReceivers;
@property (nonatomic, assign) CastSender* sender;
@property (nonatomic, assign) BOOL connected;

@property (nonatomic, strong) SCStream* captureStream API_AVAILABLE(macos(12.3));
@property (nonatomic, strong) SCContentFilter* captureFilter API_AVAILABLE(macos(12.3));
@property (nonatomic, strong) dispatch_queue_t captureQueue;

@property (nonatomic, strong) AVAssetReader* assetReader;
@property (nonatomic, strong) AVAssetReaderTrackOutput* videoOutput;
@property (nonatomic, strong) AVAssetReaderTrackOutput* audioOutput;
@property (nonatomic, strong) dispatch_source_t playbackTimer;
@property (nonatomic, assign) BOOL isPlayingFile;
@property (nonatomic, assign) CMSampleBufferRef pendingVideoBuffer;
@property (nonatomic, assign) CMSampleBufferRef pendingAudioBuffer;
@property (nonatomic, assign) CMTime firstVideoPts;
@property (nonatomic, assign) CMTime firstAudioPts;
@property (nonatomic, assign) NSTimeInterval playbackStartTime;

@end

@implementation SenderViewController

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 380)];
    self.discoveredReceivers = [NSMutableArray array];
    self.captureQueue = dispatch_queue_create("com.cast.sender.capture", DISPATCH_QUEUE_SERIAL);
    [self setupUI];
}

- (void)setupUI {
    NSView* view = self.view;
    CGFloat y = 340;

    // Interface field
    NSTextField* ifaceLabel = [NSTextField labelWithString:@"Interface:"];
    ifaceLabel.frame = NSMakeRect(10, y, 80, 22);
    [view addSubview:ifaceLabel];

    self.interfaceField = [[NSTextField alloc] initWithFrame:NSMakeRect(90, y, 100, 22)];
    self.interfaceField.stringValue = @"en0";
    [view addSubview:self.interfaceField];

    self.refreshButton = [[NSButton alloc] initWithFrame:NSMakeRect(200, y, 100, 22)];
    self.refreshButton.title = @"Refresh";
    self.refreshButton.bezelStyle = NSBezelStyleRounded;
    self.refreshButton.target = self;
    self.refreshButton.action = @selector(refreshDiscovery:);
    [view addSubview:self.refreshButton];
    y -= 30;

    // Developer Certificate
    NSTextField* certLabel = [NSTextField labelWithString:@"Dev Cert:"];
    certLabel.frame = NSMakeRect(10, y, 80, 22);
    [view addSubview:certLabel];

    self.certPathField = [[NSTextField alloc] initWithFrame:NSMakeRect(90, y, 200, 22)];
    self.certPathField.placeholderString = @"Path to developer_certificate.pem";
    [view addSubview:self.certPathField];

    self.certBrowseButton = [[NSButton alloc] initWithFrame:NSMakeRect(300, y, 80, 22)];
    self.certBrowseButton.title = @"Browse...";
    self.certBrowseButton.bezelStyle = NSBezelStyleRounded;
    self.certBrowseButton.target = self;
    self.certBrowseButton.action = @selector(browseForCertificate:);
    [view addSubview:self.certBrowseButton];
    y -= 30;

    // Discovered receivers table
    NSTextField* receiversLabel = [NSTextField labelWithString:@"Discovered Receivers:"];
    receiversLabel.frame = NSMakeRect(10, y, 200, 22);
    [view addSubview:receiversLabel];
    y -= 100;

    NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, y, 480, 100)];
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSBezelBorder;

    self.receiversTable = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    self.receiversTable.dataSource = self;
    self.receiversTable.delegate = self;
    self.receiversTable.allowsMultipleSelection = NO;

    NSTableColumn* nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameColumn.title = @"Name";
    nameColumn.width = 200;
    [self.receiversTable addTableColumn:nameColumn];

    NSTableColumn* ipColumn = [[NSTableColumn alloc] initWithIdentifier:@"ip"];
    ipColumn.title = @"IP Address";
    ipColumn.width = 150;
    [self.receiversTable addTableColumn:ipColumn];

    NSTableColumn* portColumn = [[NSTableColumn alloc] initWithIdentifier:@"port"];
    portColumn.title = @"Port";
    portColumn.width = 80;
    [self.receiversTable addTableColumn:portColumn];

    scrollView.documentView = self.receiversTable;
    [view addSubview:scrollView];
    y -= 35;

    // Source selection
    NSTextField* sourceLabel = [NSTextField labelWithString:@"Source:"];
    sourceLabel.frame = NSMakeRect(10, y, 60, 22);
    [view addSubview:sourceLabel];

    self.sourcePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(70, y, 150, 22) pullsDown:NO];
    [self.sourcePopup addItemWithTitle:@"Screen Capture"];
    [self.sourcePopup addItemWithTitle:@"Video File"];
    [self.sourcePopup addItemWithTitle:@"Audio File"];
    self.sourcePopup.target = self;
    self.sourcePopup.action = @selector(sourceChanged:);
    [view addSubview:self.sourcePopup];

    self.browseButton = [[NSButton alloc] initWithFrame:NSMakeRect(230, y, 80, 22)];
    self.browseButton.title = @"Browse...";
    self.browseButton.bezelStyle = NSBezelStyleRounded;
    self.browseButton.target = self;
    self.browseButton.action = @selector(browseForFile:);
    self.browseButton.enabled = NO;
    [view addSubview:self.browseButton];
    y -= 30;

    // File path
    self.filePathField = [[NSTextField alloc] initWithFrame:NSMakeRect(70, y, 420, 22)];
    self.filePathField.placeholderString = @"Select a file...";
    self.filePathField.enabled = NO;
    [view addSubview:self.filePathField];
    y -= 40;

    // Connect/Disconnect buttons
    self.connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(130, y, 100, 32)];
    self.connectButton.title = @"Connect";
    self.connectButton.bezelStyle = NSBezelStyleRounded;
    self.connectButton.target = self;
    self.connectButton.action = @selector(connect:);
    [view addSubview:self.connectButton];

    self.disconnectButton = [[NSButton alloc] initWithFrame:NSMakeRect(250, y, 100, 32)];
    self.disconnectButton.title = @"Disconnect";
    self.disconnectButton.bezelStyle = NSBezelStyleRounded;
    self.disconnectButton.target = self;
    self.disconnectButton.action = @selector(disconnect:);
    self.disconnectButton.enabled = NO;
    [view addSubview:self.disconnectButton];
    y -= 40;

    // Status label
    self.statusLabel = [NSTextField labelWithString:@"Status: Not connected"];
    self.statusLabel.frame = NSMakeRect(10, y, 480, 22);
    self.statusLabel.alignment = NSTextAlignmentCenter;
    [view addSubview:self.statusLabel];
}

- (BOOL)isConnected {
    return self.connected;
}

- (void)updateStatus:(NSString*)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Status: %@", status];
        if ([self.delegate respondsToSelector:@selector(senderDidUpdateStatus:)]) {
            [self.delegate senderDidUpdateStatus:status];
        }
    });
}

#pragma mark - Discovery

- (void)startDiscovery {
    if (self.sender) return;

    NSString* interface = self.interfaceField.stringValue;
    NSString* certPath = self.certPathField.stringValue;

    CastSenderConfig config = {
        .interface_name = interface.UTF8String,
        .developer_certificate_path = certPath.length > 0 ? certPath.UTF8String : NULL,
    };

    CastSenderCallbacks callbacks = {
        .user_data = (__bridge void*)self,
        .on_receiver_discovered = on_receiver_discovered,
        .on_receiver_lost = on_receiver_lost,
        .on_connected = on_connected,
        .on_disconnected = on_disconnected,
        .on_error = on_sender_error,
    };

    self.sender = cast_sender_create(&config, &callbacks);
    if (!self.sender) {
        [self updateStatus:@"Failed to create sender"];
        return;
    }

    if (cast_sender_start_discovery(self.sender) != 0) {
        [self updateStatus:@"Failed to start discovery"];
        return;
    }

    [self updateStatus:@"Discovering receivers..."];
}

- (void)stopDiscovery {
    if (self.sender) {
        cast_sender_stop_discovery(self.sender);
    }
}

- (void)refreshDiscovery:(id)sender {
    [self.discoveredReceivers removeAllObjects];
    [self.receiversTable reloadData];

    if (self.sender) {
        cast_sender_stop_discovery(self.sender);
        cast_sender_destroy(self.sender);
        self.sender = NULL;
    }

    [self startDiscovery];
}

- (void)browseForCertificate:(id)sender {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.allowedContentTypes = @[ UTTypeData ]; // Allow all files, certificate extensions vary

    if ([panel runModal] == NSModalResponseOK) {
        self.certPathField.stringValue = panel.URL.path;
    }
}

#pragma mark - Connection

- (void)connect:(id)sender {
    NSInteger selectedRow = self.receiversTable.selectedRow;
    if (selectedRow < 0 || selectedRow >= (NSInteger)self.discoveredReceivers.count) {
        [self showError:@"Please select a receiver"];
        return;
    }

    DiscoveredReceiver* receiver = self.discoveredReceivers[selectedRow];

    if (!self.sender) {
        [self startDiscovery];
    }

    // Use connect_to_ip for direct connection
    if (cast_sender_connect_to_ip(self.sender, receiver.ipAddress.UTF8String, receiver.port) != 0) {
        [self updateStatus:@"Failed to connect"];
        return;
    }

    [self updateStatus:[NSString stringWithFormat:@"Connecting to %@...", receiver.friendlyName]];
}

- (void)disconnect:(id)sender {
    if (self.sender) {
        cast_sender_disconnect(self.sender);
    }

    [self stopCapture];

    self.connected = NO;
    self.connectButton.enabled = YES;
    self.disconnectButton.enabled = NO;
    [self updateStatus:@"Disconnected"];
}

#pragma mark - Source Selection

- (void)sourceChanged:(id)sender {
    NSInteger index = self.sourcePopup.indexOfSelectedItem;
    BOOL isFile = (index == 1 || index == 2);  // Video File or Audio File
    self.browseButton.enabled = isFile;
    self.filePathField.enabled = isFile;
}

- (void)browseForFile:(id)sender {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;

    NSInteger index = self.sourcePopup.indexOfSelectedItem;
    if (index == 1) {  // Video File
        panel.allowedContentTypes = @[
            UTTypeMovie,
            UTTypeMPEG4Movie,
            UTTypeQuickTimeMovie
        ];
    } else if (index == 2) {  // Audio File
        panel.allowedContentTypes = @[
            UTTypeAudio,
            UTTypeMP3,
            UTTypeMPEG4Audio
        ];
    }

    if ([panel runModal] == NSModalResponseOK) {
        self.filePathField.stringValue = panel.URL.path;
    }
}

#pragma mark - Screen Capture

- (void)startScreenCapture API_AVAILABLE(macos(12.3)) {
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent* content, NSError* error) {
        if (error) {
            [self updateStatus:[NSString stringWithFormat:@"Capture error: %@", error.localizedDescription]];
            return;
        }

        SCDisplay* mainDisplay = content.displays.firstObject;
        if (!mainDisplay) {
            [self updateStatus:@"No display found"];
            return;
        }

        self.captureFilter = [[SCContentFilter alloc] initWithDisplay:mainDisplay excludingWindows:@[]];

        SCStreamConfiguration* config = [[SCStreamConfiguration alloc] init];
        config.width = 1920;
        config.height = 1080;
        config.minimumFrameInterval = CMTimeMake(1, 30);  // 30 fps
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;

        self.captureStream = [[SCStream alloc] initWithFilter:self.captureFilter
                                                configuration:config
                                                     delegate:self];

        NSError* addOutputError = nil;
        [self.captureStream addStreamOutput:self
                                       type:SCStreamOutputTypeScreen
                         sampleHandlerQueue:self.captureQueue
                                      error:&addOutputError];

        if (addOutputError) {
            [self updateStatus:[NSString stringWithFormat:@"Add output error: %@", addOutputError.localizedDescription]];
            return;
        }

        [self.captureStream startCaptureWithCompletionHandler:^(NSError* startError) {
            if (startError) {
                [self updateStatus:[NSString stringWithFormat:@"Start capture error: %@", startError.localizedDescription]];
            } else {
                [self updateStatus:@"Streaming screen..."];
            }
        }];
    }];
}

- (void)stopCapture {
    if (@available(macOS 12.3, *)) {
        if (self.captureStream) {
            [self.captureStream stopCaptureWithCompletionHandler:^(NSError* error) {
                self.captureStream = nil;
            }];
        }
    }
    
    [self stopFilePlayback];
}

- (void)stopFilePlayback {
    self.isPlayingFile = NO;
    
    if (self.playbackTimer) {
        dispatch_source_cancel(self.playbackTimer);
        self.playbackTimer = nil;
    }
    
    if (self.assetReader) {
        [self.assetReader cancelReading];
        self.assetReader = nil;
    }
    
    self.videoOutput = nil;
    self.audioOutput = nil;
    [self clearPendingBuffers];
}

- (void)clearPendingBuffers {
    if (self.pendingVideoBuffer) {
        CFRelease(self.pendingVideoBuffer);
        self.pendingVideoBuffer = NULL;
    }
    if (self.pendingAudioBuffer) {
        CFRelease(self.pendingAudioBuffer);
        self.pendingAudioBuffer = NULL;
    }
}

- (BOOL)shouldSendSampleBuffer:(CMSampleBufferRef)sampleBuffer
                     firstPts:(CMTime*)firstPts {
    if (!sampleBuffer) {
        return NO;
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (!CMTIME_IS_VALID(pts)) {
        return YES;
    }

    if (!CMTIME_IS_VALID(*firstPts)) {
        *firstPts = pts;
    }

    double offset = CMTimeGetSeconds(pts) - CMTimeGetSeconds(*firstPts);
    if (offset < 0) {
        offset = 0;
    }

    double now = CACurrentMediaTime();
    double target = self.playbackStartTime + offset;
    const double lead_seconds = 0.02;
    return (now + lead_seconds) >= target;
}

#pragma mark - Video File Playback

- (void)startVideoFilePlayback:(NSString*)filePath {
    NSURL* fileURL = [NSURL fileURLWithPath:filePath];
    AVAsset* asset = [AVAsset assetWithURL:fileURL];
    
    NSError* error = nil;
    self.assetReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (error) {
        [self updateStatus:[NSString stringWithFormat:@"Failed to open video: %@", error.localizedDescription]];
        return;
    }
    
    NSArray<AVAssetTrack*>* videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count > 0) {
        AVAssetTrack* videoTrack = videoTracks.firstObject;
        
        NSDictionary* videoSettings = @{
            (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            (NSString*)kCVPixelBufferWidthKey: @(1920),
            (NSString*)kCVPixelBufferHeightKey: @(1080),
        };
        
        self.videoOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:videoSettings];
        self.videoOutput.alwaysCopiesSampleData = NO;
        
        if ([self.assetReader canAddOutput:self.videoOutput]) {
            [self.assetReader addOutput:self.videoOutput];
        }
        
        NSLog(@"Video track: %.0fx%.0f, fps=%.2f", 
              videoTrack.naturalSize.width, videoTrack.naturalSize.height,
              videoTrack.nominalFrameRate);
    }
    
    NSArray<AVAssetTrack*>* audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count > 0) {
        AVAssetTrack* audioTrack = audioTracks.firstObject;
        
        NSDictionary* audioSettings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @(48000),
            AVNumberOfChannelsKey: @(2),
            AVLinearPCMBitDepthKey: @(32),
            AVLinearPCMIsFloatKey: @YES,
            AVLinearPCMIsBigEndianKey: @NO,
            AVLinearPCMIsNonInterleaved: @NO,
        };
        
        self.audioOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:audioSettings];
        self.audioOutput.alwaysCopiesSampleData = NO;
        
        if ([self.assetReader canAddOutput:self.audioOutput]) {
            [self.assetReader addOutput:self.audioOutput];
        }
        
        NSLog(@"Audio track found");
    }
    
    if (![self.assetReader startReading]) {
        [self updateStatus:[NSString stringWithFormat:@"Failed to start reading: %@", self.assetReader.error.localizedDescription]];
        return;
    }

    self.isPlayingFile = YES;
    self.firstVideoPts = kCMTimeInvalid;
    self.firstAudioPts = kCMTimeInvalid;
    self.playbackStartTime = CACurrentMediaTime();
    [self clearPendingBuffers];
    
    [self updateStatus:@"Streaming video file..."];
    
    // Start playback timer - process frames at ~30fps for video
    self.playbackTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.captureQueue);
    dispatch_source_set_timer(self.playbackTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 30, NSEC_PER_SEC / 60);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.playbackTimer, ^{
        [weakSelf processNextFrames];
    });
    
    dispatch_resume(self.playbackTimer);
}

- (void)processNextFrames {
    if (!self.isPlayingFile || !self.connected || !self.sender) {
        return;
    }

    // Process video frame
    if (self.videoOutput && self.assetReader.status == AVAssetReaderStatusReading) {
        if (!self.pendingVideoBuffer) {
            self.pendingVideoBuffer = [self.videoOutput copyNextSampleBuffer];
        }
        if (self.pendingVideoBuffer) {
            if ([self shouldSendSampleBuffer:self.pendingVideoBuffer firstPts:&_firstVideoPts]) {
                [self processVideoSampleBuffer:self.pendingVideoBuffer];
                CFRelease(self.pendingVideoBuffer);
                self.pendingVideoBuffer = NULL;
            }
        }
    }

    if (self.audioOutput && self.assetReader.status == AVAssetReaderStatusReading) {
        for (int i = 0; i < 5; i++) {
            if (!self.pendingAudioBuffer) {
                self.pendingAudioBuffer = [self.audioOutput copyNextSampleBuffer];
            }
            if (!self.pendingAudioBuffer) {
                break;
            }
            if ([self shouldSendSampleBuffer:self.pendingAudioBuffer firstPts:&_firstAudioPts]) {
                [self processAudioSampleBuffer:self.pendingAudioBuffer];
                CFRelease(self.pendingAudioBuffer);
                self.pendingAudioBuffer = NULL;
            } else {
                break;
            }
        }
    }
    
    if (self.assetReader.status == AVAssetReaderStatusCompleted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStatus:@"Video playback completed"];
            [self stopFilePlayback];
        });
    } else if (self.assetReader.status == AVAssetReaderStatusFailed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStatus:[NSString stringWithFormat:@"Playback failed: %@", self.assetReader.error.localizedDescription]];
            [self stopFilePlayback];
        });
    }
}

- (void)processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    static int frameCount = 0;
    frameCount++;
    
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return;
    
    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
    
    if (frameCount <= 5) {
        NSLog(@"Video file frame %d: %zux%zu format=0x%x", frameCount, width, height, (unsigned int)pixelFormat);
    }
    
    if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        
        // Get Y plane
        uint8_t* yPlane = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0);
        size_t yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0);
        
        uint8_t* uvPlane = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 1);
        size_t uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1);
        
        size_t uvWidth = width / 2;
        size_t uvHeight = height / 2;
        uint8_t* uPlane = malloc(uvWidth * uvHeight);
        uint8_t* vPlane = malloc(uvWidth * uvHeight);
        
        for (size_t row = 0; row < uvHeight; row++) {
            uint8_t* uvRow = uvPlane + row * uvBytesPerRow;
            uint8_t* uRow = uPlane + row * uvWidth;
            uint8_t* vRow = vPlane + row * uvWidth;
            for (size_t col = 0; col < uvWidth; col++) {
                uRow[col] = uvRow[col * 2];      // Cb (U)
                vRow[col] = uvRow[col * 2 + 1];  // Cr (V)
            }
        }
        
        uint64_t now_us = (uint64_t)(CACurrentMediaTime() * 1000000.0);
        CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
        int64_t duration_us = CMTIME_IS_VALID(duration) ? (int64_t)(CMTimeGetSeconds(duration) * 1000000) : 33333;
        
        SenderVideoFrame frame = {
            .width = (int)width,
            .height = (int)height,
            .y_plane = yPlane,
            .u_plane = uPlane,
            .v_plane = vPlane,
            .y_stride = (int)yBytesPerRow,
            .u_stride = (int)uvWidth,
            .v_stride = (int)uvWidth,
            .duration_us = duration_us,
            .capture_begin_time_us = now_us,
            .capture_end_time_us = now_us + duration_us,
        };
        
        int result = cast_sender_send_video_frame(self.sender, &frame);
        if (frameCount <= 5 || frameCount % 30 == 1) {
            NSLog(@"Video file frame %d: sent to cast, result=%d", frameCount, result);
        }
        
        free(uPlane);
        free(vPlane);
    }
    
    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
}

- (void)processAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    static int audioFrameCount = 0;
    audioFrameCount++;

    uint64_t now_us = (uint64_t)(CACurrentMediaTime() * 1000000.0);

    CMItemCount numSamples = CMSampleBufferGetNumSamples(sampleBuffer);
    if (numSamples <= 0) return;

    CMAudioFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription* asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc);
    if (!asbd) return;

    if (audioFrameCount <= 5) {
        NSLog(@"Audio frame %d: samples=%ld rate=%.0f channels=%u format=0x%x",
              audioFrameCount, (long)numSamples, asbd->mSampleRate,
              (unsigned int)asbd->mChannelsPerFrame, (unsigned int)asbd->mFormatID);
    }

    AudioBufferList bufferList;
    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        NULL,
        &bufferList,
        sizeof(bufferList),
        NULL,
        NULL,
        0,
        &blockBuffer);
    if (status != noErr) {
        if (blockBuffer) CFRelease(blockBuffer);
        return;
    }

    if (bufferList.mNumberBuffers < 1) {
        if (blockBuffer) CFRelease(blockBuffer);
        return;
    }

    AudioBuffer audioBuffer = bufferList.mBuffers[0];
    if (!audioBuffer.mData) {
        if (blockBuffer) CFRelease(blockBuffer);
        return;
    }

    float* floatSamples = (float*)audioBuffer.mData;
    int numSamplesPerChannel = (int)numSamples;
    int64_t duration_us = (int64_t)numSamplesPerChannel * 1000000 / (int64_t)asbd->mSampleRate;

    SenderAudioSamples audioSamples = {
        .samples = floatSamples,
        .num_samples = numSamplesPerChannel,
        .capture_begin_time_us = now_us,
        .capture_end_time_us = now_us + duration_us,
    };

    cast_sender_send_audio_samples(self.sender, &audioSamples);

    if (blockBuffer) CFRelease(blockBuffer);
}

#pragma mark - Audio File Playback

- (void)startAudioFilePlayback:(NSString*)filePath {
    NSURL* fileURL = [NSURL fileURLWithPath:filePath];
    AVAsset* asset = [AVAsset assetWithURL:fileURL];
    
    NSError* error = nil;
    self.assetReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (error) {
        [self updateStatus:[NSString stringWithFormat:@"Failed to open audio: %@", error.localizedDescription]];
        return;
    }
    
    NSArray<AVAssetTrack*>* audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) {
        [self updateStatus:@"No audio track found in file"];
        return;
    }
    
    AVAssetTrack* audioTrack = audioTracks.firstObject;
    
    NSDictionary* audioSettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(48000),
        AVNumberOfChannelsKey: @(2),
        AVLinearPCMBitDepthKey: @(32),
        AVLinearPCMIsFloatKey: @YES,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO,
    };
    
    self.audioOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:audioSettings];
    self.audioOutput.alwaysCopiesSampleData = NO;
    
    if ([self.assetReader canAddOutput:self.audioOutput]) {
        [self.assetReader addOutput:self.audioOutput];
    }
    
    if (![self.assetReader startReading]) {
        [self updateStatus:[NSString stringWithFormat:@"Failed to start reading: %@", self.assetReader.error.localizedDescription]];
        return;
    }

    self.isPlayingFile = YES;
    self.videoOutput = nil;  // No video for audio-only
    self.firstVideoPts = kCMTimeInvalid;
    self.firstAudioPts = kCMTimeInvalid;
    self.playbackStartTime = CACurrentMediaTime();
    [self clearPendingBuffers];
    
    [self updateStatus:@"Streaming audio file..."];
    
    self.playbackTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.captureQueue);
    dispatch_source_set_timer(self.playbackTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 100, NSEC_PER_SEC / 200);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.playbackTimer, ^{
        [weakSelf processAudioOnlyFrames];
    });
    
    dispatch_resume(self.playbackTimer);
}

- (void)processAudioOnlyFrames {
    if (!self.isPlayingFile || !self.connected || !self.sender) {
        return;
    }

    if (self.audioOutput && self.assetReader.status == AVAssetReaderStatusReading) {
        for (int i = 0; i < 5; i++) {
            if (!self.pendingAudioBuffer) {
                self.pendingAudioBuffer = [self.audioOutput copyNextSampleBuffer];
            }
            if (!self.pendingAudioBuffer) {
                break;
            }
            if ([self shouldSendSampleBuffer:self.pendingAudioBuffer firstPts:&_firstAudioPts]) {
                [self processAudioSampleBuffer:self.pendingAudioBuffer];
                CFRelease(self.pendingAudioBuffer);
                self.pendingAudioBuffer = NULL;
            } else {
                break;
            }
        }
    }
    
    if (self.assetReader.status == AVAssetReaderStatusCompleted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStatus:@"Audio playback completed"];
            [self stopFilePlayback];
        });
    } else if (self.assetReader.status == AVAssetReaderStatusFailed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStatus:[NSString stringWithFormat:@"Playback failed: %@", self.assetReader.error.localizedDescription]];
            [self stopFilePlayback];
        });
    }
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream*)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
    static int frameCount = 0;
    frameCount++;
    
    if (frameCount <= 5 || frameCount % 30 == 1) {
        NSLog(@"SCStream frame %d: type=%d connected=%d sender=%p", 
              frameCount, (int)type, self.connected, self.sender);
    }
    
    if (type != SCStreamOutputTypeScreen || !self.connected || !self.sender) {
        return;
    }

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        NSLog(@"SCStream frame %d: no imageBuffer!", frameCount);
        return;
    }

    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);

    // Handle NV12 (biplanar) to YUV420P conversion
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
    
    if (frameCount <= 5) {
        NSLog(@"SCStream frame %d: %zux%zu format=0x%x", frameCount, width, height, (unsigned int)pixelFormat);
    }

    if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {

        // Get Y plane
        uint8_t* yPlane = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0);
        size_t yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0);

        // Get UV plane (interleaved)
        uint8_t* uvPlane = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 1);
        size_t uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1);

        // Allocate separate U and V planes
        size_t uvWidth = width / 2;
        size_t uvHeight = height / 2;
        uint8_t* uPlane = malloc(uvWidth * uvHeight);
        uint8_t* vPlane = malloc(uvWidth * uvHeight);

        // Deinterleave UV to separate U and V
        for (size_t row = 0; row < uvHeight; row++) {
            uint8_t* uvRow = uvPlane + row * uvBytesPerRow;
            uint8_t* uRow = uPlane + row * uvWidth;
            uint8_t* vRow = vPlane + row * uvWidth;
            for (size_t col = 0; col < uvWidth; col++) {
                uRow[col] = uvRow[col * 2];      // Cb (U)
                vRow[col] = uvRow[col * 2 + 1];  // Cr (V)
            }
        }

        // Send to Cast sender using the sender's video frame type
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        int64_t pts_us = (int64_t)(CMTimeGetSeconds(pts) * 1000000);

        SenderVideoFrame frame = {
            .width = (int)width,
            .height = (int)height,
            .y_plane = yPlane,
            .u_plane = uPlane,
            .v_plane = vPlane,
            .y_stride = (int)yBytesPerRow,
            .u_stride = (int)uvWidth,
            .v_stride = (int)uvWidth,
            .duration_us = 33333,  // ~30fps
            .capture_begin_time_us = pts_us,
            .capture_end_time_us = pts_us,
        };

        int result = cast_sender_send_video_frame(self.sender, &frame);
        if (frameCount <= 5 || frameCount % 30 == 1) {
            NSLog(@"SCStream frame %d: sent to cast, result=%d", frameCount, result);
        }

        free(uPlane);
        free(vPlane);
    }

    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
}

#pragma mark - SCStreamDelegate

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error API_AVAILABLE(macos(12.3)) {
    [self updateStatus:[NSString stringWithFormat:@"Stream stopped: %@", error.localizedDescription]];
}

#pragma mark - Callbacks from C

- (void)receiverDiscovered:(NSString*)uniqueId
              friendlyName:(NSString*)friendlyName
                 ipAddress:(NSString*)ipAddress
                      port:(uint16_t)port {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Check if already exists
        for (DiscoveredReceiver* r in self.discoveredReceivers) {
            if ([r.uniqueId isEqualToString:uniqueId]) {
                r.friendlyName = friendlyName;
                r.ipAddress = ipAddress;
                r.port = port;
                [self.receiversTable reloadData];
                return;
            }
        }

        DiscoveredReceiver* receiver = [[DiscoveredReceiver alloc] init];
        receiver.uniqueId = uniqueId;
        receiver.friendlyName = friendlyName;
        receiver.ipAddress = ipAddress;
        receiver.port = port;
        [self.discoveredReceivers addObject:receiver];
        [self.receiversTable reloadData];
    });
}

- (void)receiverLost:(NSString*)uniqueId {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSInteger i = 0; i < (NSInteger)self.discoveredReceivers.count; i++) {
            if ([self.discoveredReceivers[i].uniqueId isEqualToString:uniqueId]) {
                [self.discoveredReceivers removeObjectAtIndex:i];
                [self.receiversTable reloadData];
                return;
            }
        }
    });
}

- (void)didConnect {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.connected = YES;
        self.connectButton.enabled = NO;
        self.disconnectButton.enabled = YES;
        [self updateStatus:@"Connected"];

        // Start streaming based on source
        NSInteger sourceIndex = self.sourcePopup.indexOfSelectedItem;
        if (sourceIndex == 0) {  // Screen Capture
            if (@available(macOS 12.3, *)) {
                [self startScreenCapture];
            } else {
                [self updateStatus:@"Screen capture requires macOS 12.3+"];
            }
        } else if (sourceIndex == 1) {  // Video File
            NSString* filePath = self.filePathField.stringValue;
            if (filePath.length == 0) {
                [self updateStatus:@"Please select a video file first"];
                return;
            }
            [self startVideoFilePlayback:filePath];
        } else if (sourceIndex == 2) {  // Audio File
            NSString* filePath = self.filePathField.stringValue;
            if (filePath.length == 0) {
                [self updateStatus:@"Please select an audio file first"];
                return;
            }
            [self startAudioFilePlayback:filePath];
        }
    });
}

- (void)didDisconnect {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.connected = NO;
        self.connectButton.enabled = YES;
        self.disconnectButton.enabled = NO;
        [self stopCapture];
        [self updateStatus:@"Disconnected"];
    });
}

- (void)didReceiveError:(int)errorCode message:(NSString*)message {
    [self updateStatus:[NSString stringWithFormat:@"Error: %@", message]];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    return self.discoveredReceivers.count;
}

- (id)tableView:(NSTableView*)tableView objectValueForTableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.discoveredReceivers.count) return nil;

    DiscoveredReceiver* receiver = self.discoveredReceivers[row];
    NSString* identifier = tableColumn.identifier;

    if ([identifier isEqualToString:@"name"]) {
        return receiver.friendlyName;
    } else if ([identifier isEqualToString:@"ip"]) {
        return receiver.ipAddress;
    } else if ([identifier isEqualToString:@"port"]) {
        return @(receiver.port);
    }
    return nil;
}

#pragma mark - Helpers

- (void)showError:(NSString*)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = @"Error";
        alert.informativeText = message;
        alert.alertStyle = NSAlertStyleWarning;
        [alert runModal];
    });
}

- (void)dealloc {
    [self stopCapture];
    if (self.sender) {
        cast_sender_disconnect(self.sender);
        cast_sender_destroy(self.sender);
    }
}

@end

// C Callback Implementations
static void on_receiver_discovered(void* user_data, const SenderDiscoveredReceiver* receiver) {
    SenderViewController* vc = (__bridge SenderViewController*)user_data;
    NSString* uniqueId = [NSString stringWithUTF8String:receiver->unique_id];
    NSString* friendlyName = [NSString stringWithUTF8String:receiver->friendly_name];
    NSString* ipAddress = [NSString stringWithUTF8String:receiver->ip_address];
    [vc receiverDiscovered:uniqueId friendlyName:friendlyName ipAddress:ipAddress port:receiver->port];
}

static void on_receiver_lost(void* user_data, const char* unique_id) {
    SenderViewController* vc = (__bridge SenderViewController*)user_data;
    NSString* uid = unique_id ? [NSString stringWithUTF8String:unique_id] : @"";
    [vc receiverLost:uid];
}

static void on_connected(void* user_data) {
    SenderViewController* vc = (__bridge SenderViewController*)user_data;
    [vc didConnect];
}

static void on_disconnected(void* user_data) {
    SenderViewController* vc = (__bridge SenderViewController*)user_data;
    [vc didDisconnect];
}

static void on_sender_error(void* user_data, int error_code, const char* error_message) {
    SenderViewController* vc = (__bridge SenderViewController*)user_data;
    NSString* msg = error_message ? [NSString stringWithUTF8String:error_message] : @"Unknown error";
    [vc didReceiveError:error_code message:msg];
}

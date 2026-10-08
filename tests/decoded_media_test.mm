#import "../native/media/DecodedMedia.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

extern "C" {
#include <libavutil/buffer.h>
#include <libavutil/channel_layout.h>
#include <libavutil/frame.h>
#include <libavutil/samplefmt.h>
}

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>

namespace {
int failures = 0;
#define EXPECT(condition) do { if (!(condition)) { \
  std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
  ++failures; } } while (0)

AVFrame* Video(int width = 5, int height = 3, bool reverse = false) {
  AVFrame* frame = av_frame_alloc();
  frame->format = AV_PIX_FMT_YUV420P;
  frame->width = width; frame->height = height;
  frame->colorspace = AVCOL_SPC_BT709;
  frame->color_range = AVCOL_RANGE_MPEG;
  frame->color_primaries = AVCOL_PRI_BT709;
  frame->color_trc = AVCOL_TRC_BT709;
  frame->sample_aspect_ratio = {2, 1};
  for (int i = 0; i < 3; ++i) {
    int rows = i ? (height + 1) / 2 : height;
    int columns = i ? (width + 1) / 2 : width;
    int stride = width * 2 + 16 + i * 8;  // U and V have independent padding.
    frame->buf[i] = av_buffer_alloc(rows * stride + 64);
    frame->data[i] = frame->buf[i]->data;
    frame->linesize[i] = stride;
    for (int y = 0; y < rows; ++y)
      memset(frame->data[i] + y * stride, i ? 100 + i * 20 : 20 + y * 20, columns);
    if (reverse) {
      frame->data[i] += (rows - 1) * stride;
      frame->linesize[i] = -stride;
    }
  }
  // Deliberately meaningless decoder PTS must never influence native timing.
  frame->pts = INT64_MIN;
  return frame;
}
uint8_t Luma(CMSampleBufferRef sample, int row = 0) {
  CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
  CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
  uint8_t result = ((uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixels, 0))[
      row * CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)];
  CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
  return result;
}

void VideoOwnershipAndFormats() {
  applescreen::DecodedMedia converter(1024 * 1024, 2);
  std::string error;
  AVFrame* frame = Video();
  CMSampleBufferRef sample = converter.CopyVideo(*frame, CMTimeMake(1, 4),
                                                 CMTimeMake(1, 60), error);
  EXPECT(sample && error.empty());
  av_frame_free(&frame);
  if (!sample) return;
  EXPECT(Luma(sample) == 20 && Luma(sample, 2) == 60);
  EXPECT(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTimeMake(1, 4)) == 0);
  CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
  EXPECT(CVPixelBufferGetWidth(pixels) == 5 && CVPixelBufferGetHeight(pixels) == 3);
  EXPECT(CVPixelBufferGetWidthOfPlane(pixels, 1) >= 3 &&
         CVPixelBufferGetHeightOfPlane(pixels, 1) >= 2);
  id matrix = CFBridgingRelease(CVBufferCopyAttachment(pixels, kCVImageBufferYCbCrMatrixKey, nullptr));
  id primaries = CFBridgingRelease(CVBufferCopyAttachment(pixels, kCVImageBufferColorPrimariesKey, nullptr));
  NSDictionary* aspect = CFBridgingRelease(CVBufferCopyAttachment(pixels, kCVImageBufferPixelAspectRatioKey, nullptr));
  EXPECT([matrix isEqual:(__bridge id)kCVImageBufferYCbCrMatrix_ITU_R_709_2]);
  EXPECT([primaries isEqual:(__bridge id)kCVImageBufferColorPrimaries_ITU_R_709_2]);
  EXPECT([aspect[(__bridge id)kCVImageBufferPixelAspectRatioHorizontalSpacingKey] intValue] == 2);
  EXPECT([aspect[(__bridge id)kCVImageBufferPixelAspectRatioVerticalSpacingKey] intValue] == 1);
  converter.Reset();
  EXPECT(Luma(sample, 2) == 60);  // Owned sample survives converter/pool teardown.
  CFRelease(sample);

  frame = Video(5, 3, true);
  sample = converter.CopyVideo(*frame, kCMTimeZero, CMTimeMake(1, 30), error);
  EXPECT(sample);
  if (sample) { EXPECT(Luma(sample) == 60 && Luma(sample, 2) == 20); CFRelease(sample); }
  av_frame_free(&frame);
  frame = Video(8, 6);
  frame->crop_left = frame->crop_top = 2;
  frame->crop_right = frame->crop_bottom = 1;
  sample = converter.CopyVideo(*frame, kCMTimeZero, CMTimeMake(1, 24), error);
  EXPECT(sample);
  if (sample) {
    EXPECT(CVPixelBufferGetWidth(CMSampleBufferGetImageBuffer(sample)) == 5);
    EXPECT(CVPixelBufferGetHeight(CMSampleBufferGetImageBuffer(sample)) == 3);
    EXPECT(Luma(sample) == 60);
    CFRelease(sample);
  }
  frame->crop_left = 1;
  EXPECT(!converter.CopyVideo(*frame, kCMTimeZero, CMTimeMake(1, 24), error));
  av_frame_free(&frame);

  for (AVPixelFormat format : {AV_PIX_FMT_NV12, AV_PIX_FMT_BGRA, AV_PIX_FMT_YUVJ420P}) {
    frame = av_frame_alloc();
    frame->format = format; frame->width = 16; frame->height = 8;
    EXPECT(av_frame_get_buffer(frame, 32) == 0);
    memset(frame->buf[0]->data, 128, frame->buf[0]->size);
    sample = converter.CopyVideo(*frame, kCMTimeZero, CMTimeMake(1, 30), error);
    EXPECT(sample);
    if (sample) {
      OSType expected = format == AV_PIX_FMT_NV12
          ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
          : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
      EXPECT(CVPixelBufferGetPixelFormatType(CMSampleBufferGetImageBuffer(sample)) == expected);
      CFRelease(sample);
    }
    av_frame_free(&frame);
  }
}

void VideoRejectionAndPressure() {
  applescreen::DecodedMedia converter(1024 * 1024, 2);
  std::string error;
  AVFrame* frame = Video();
  auto copy = [&] { return converter.CopyVideo(*frame, kCMTimeZero, CMTimeMake(1, 60), error); };
  CMSampleBufferRef first = copy(), second = copy();
  EXPECT(first && second);
  EXPECT(!copy() && error == "native video pool backpressured");
  if (first) CFRelease(first);
  CMSampleBufferRef third = copy();
  EXPECT(third);
  if (second) CFRelease(second);
  if (third) CFRelease(third);
  frame->color_primaries = AVCOL_PRI_UNSPECIFIED;
  frame->color_trc = AVCOL_TRC_UNSPECIFIED;
  frame->sample_aspect_ratio = {0, 1};
  third = copy();
  EXPECT(third);
  if (third) {
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(third);
    id old_primaries = CFBridgingRelease(CVBufferCopyAttachment(
        pixels, kCVImageBufferColorPrimariesKey, nullptr));
    id old_aspect = CFBridgingRelease(CVBufferCopyAttachment(
        pixels, kCVImageBufferPixelAspectRatioKey, nullptr));
    EXPECT(!old_primaries && !old_aspect);  // Pool reuse must not inherit metadata.
    CFRelease(third);
  }
  frame->color_trc = AVCOL_TRC_SMPTE2084;
  EXPECT(!copy());
  frame->color_trc = AVCOL_TRC_BT709;
  frame->format = AV_PIX_FMT_YUV420P10LE;
  EXPECT(!copy());
  frame->format = AV_PIX_FMT_YUV420P;
  size_t size = frame->buf[2]->size;
  frame->buf[2]->size = 1;
  EXPECT(!copy());
  frame->buf[2]->size = size;
  frame->linesize[2] = INT_MIN;
  EXPECT(!copy());
  EXPECT(!converter.CopyVideo(*frame, kCMTimeInvalid, CMTimeMake(1, 60), error));
  frame->width = INT_MAX;
  EXPECT(!copy());
  av_frame_free(&frame);
}

AVFrame* Audio(AVSampleFormat format, int channels = 2, int rate = 48000) {
  AVFrame* frame = av_frame_alloc();
  frame->format = format; frame->sample_rate = rate; frame->nb_samples = 3;
  if (channels == 9) av_channel_layout_from_mask(&frame->ch_layout, (1 << 9) - 1);
  else av_channel_layout_default(&frame->ch_layout, channels);
  EXPECT(av_frame_get_buffer(frame, 32) == 0);
  EXPECT(av_samples_set_silence(frame->extended_data, 0, frame->nb_samples,
                                channels, format) == 0);
  return frame;
}

void AudioNormalization() {
  applescreen::DecodedMedia converter;
  std::string error;
  for (int format = 0; format < AV_SAMPLE_FMT_NB; ++format) {
    AVFrame* frame = Audio((AVSampleFormat)format);
    CMSampleBufferRef sample = converter.CopyAudio(*frame, CMTimeMake(1, 4), error);
    if (!sample) std::fprintf(stderr, "format %s: %s\n", av_get_sample_fmt_name((AVSampleFormat)format), error.c_str());
    EXPECT(sample && error.empty());
    av_frame_free(&frame);
    converter.Reset();
    if (!sample) continue;
    EXPECT(CMSampleBufferGetNumSamples(sample) == 3);
    EXPECT(CMTimeCompare(CMSampleBufferGetDuration(sample), CMTimeMake(3, 48000)) == 0);
    EXPECT(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTimeMake(1, 4)) == 0);
    CMBlockBufferRef data = CMSampleBufferGetDataBuffer(sample);
    EXPECT(CMBlockBufferGetDataLength(data) == 24);
    float values[6] = {1, 1, 1, 1, 1, 1};
    EXPECT(CMBlockBufferCopyDataBytes(data, 0, sizeof(values), values) == 0);
    for (float value : values) EXPECT(value == 0);
    CFRelease(sample);
  }
  AVFrame* frame = Audio(AV_SAMPLE_FMT_S32P);
  for (int i = 0; i < 3; ++i) {
    ((int32_t*)frame->extended_data[0])[i] = 1 << 30;
    ((int32_t*)frame->extended_data[1])[i] = -(1 << 30);
  }
  CMSampleBufferRef sample = converter.CopyAudio(*frame, kCMTimeZero, error);
  EXPECT(sample);
  if (sample) {
    float values[6];
    CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(sample), 0, sizeof(values), values);
    for (int i = 0; i < 6; ++i) EXPECT(values[i] == (i % 2 ? -0.5f : 0.5f));
    CFRelease(sample);
  }
  av_frame_free(&frame);
  frame = Audio(AV_SAMPLE_FMT_FLTP, 9, 44100);
  ((float*)frame->extended_data[8])[1] = 0.25f;
  sample = converter.CopyAudio(*frame, kCMTimeZero, error);
  EXPECT(sample);
  if (sample) {
    float value = 0;
    CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(sample), (9 + 8) * sizeof(float),
                               sizeof(value), &value);
    EXPECT(value == 0.25f);
    const AudioStreamBasicDescription* asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
        CMSampleBufferGetFormatDescription(sample));
    EXPECT(asbd->mChannelsPerFrame == 9 && asbd->mSampleRate == 44100);
    CFRelease(sample);
  }
  av_frame_free(&frame);
  frame = Audio(AV_SAMPLE_FMT_FLT);
  ((float*)frame->data[0])[0] = std::numeric_limits<float>::quiet_NaN();
  EXPECT(!converter.CopyAudio(*frame, kCMTimeZero, error));
  frame->nb_samples = INT_MAX;
  EXPECT(!converter.CopyAudio(*frame, kCMTimeZero, error));
  frame->nb_samples = 0;
  EXPECT(!converter.CopyAudio(*frame, kCMTimeZero, error));
  av_frame_free(&frame);
}
}  // namespace

int main() {
  @autoreleasepool {
    VideoOwnershipAndFormats();
    VideoRejectionAndPressure();
    AudioNormalization();
    std::printf("Decoded media ownership/format regression: %s (%d failures)\n",
                 failures ? "FAIL" : "PASS", failures);
  }
  return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}

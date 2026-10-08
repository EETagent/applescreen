#import "DecodedMedia.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

extern "C" {
#include <libavutil/buffer.h>
#include <libavutil/channel_layout.h>
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

namespace applescreen {
namespace {
bool Time(CMTime value, bool positive = false) {
  return CMTIME_IS_NUMERIC(value) && value.timescale > 0 && value.epoch == 0 &&
         CMTimeCompare(value, kCMTimeZero) >= (positive ? 1 : 0);
}
CMSampleBufferRef Fail(std::string& error, const char* reason) {
  error = reason;
  return nullptr;
}
template <typename T> struct CFReleaseObject {
  void operator()(T* value) const { if (value) CFRelease(value); }
};
template <typename T> using OwnedCF = std::unique_ptr<T, CFReleaseObject<T>>;
using Pixel = OwnedCF<__CVBuffer>;
using Block = OwnedCF<OpaqueCMBlockBuffer>;
using Format = OwnedCF<const opaqueCMFormatDescription>;
struct FreeFrame { void operator()(AVFrame* f) const { av_frame_free(&f); } };

// Validate the entire touched plane, including backwards rows, before handing a
// pointer to swscale/swresample. Integer addresses avoid undefined pointer math
// when rejecting an untrusted oversized stride or extent.
bool Plane(const AVFrame& frame, int index, size_t rows, size_t row_bytes,
           int64_t stride, size_t budget) {
  if (!frame.extended_data || !rows || !row_bytes || stride == INT64_MIN)
    return false;
  AVBufferRef* buffer = av_frame_get_plane_buffer(&frame, index);
  if (!buffer || !buffer->data || !frame.extended_data[index]) return false;
  uint64_t step = stride < 0 ? -stride : stride;
  if (step < row_bytes || step > budget ||
      rows - 1 > (budget - std::min(budget, row_bytes)) / step) return false;
  uint64_t delta = step * (rows - 1);
  uintptr_t data = reinterpret_cast<uintptr_t>(frame.extended_data[index]);
  uintptr_t base = reinterpret_cast<uintptr_t>(buffer->data);
  if (buffer->size > UINTPTR_MAX - base || data < base) return false;
  uintptr_t limit = base + buffer->size;
  if (stride < 0) {
    if (data - base < delta) return false;
    data -= delta;
  }
  return data <= limit && delta <= limit - data &&
         row_bytes <= limit - data - delta;
}

bool VideoPlanes(const AVFrame& frame, size_t budget) {
  if (frame.width <= 0 || frame.height <= 0 ||
      av_image_check_size2(frame.width, frame.height, budget / 2,
                          AV_PIX_FMT_NV12, 0, nullptr) < 0) return false;
  size_t width = frame.width, height = frame.height;
  if (frame.format == AV_PIX_FMT_BGRA)
    return Plane(frame, 0, height, width * 4, frame.linesize[0], budget);
  if (!Plane(frame, 0, height, width, frame.linesize[0], budget)) return false;
  size_t cw = (width + 1) / 2, ch = (height + 1) / 2;
  if (frame.format == AV_PIX_FMT_NV12)
    return Plane(frame, 1, ch, cw * 2, frame.linesize[1], budget);
  return Plane(frame, 1, ch, cw, frame.linesize[1], budget) &&
         Plane(frame, 2, ch, cw, frame.linesize[2], budget);
}

struct Color {
  int coefficients = SWS_CS_ITU601;
  CFStringRef matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4;
  CFStringRef primaries = nullptr;
  CFStringRef transfer = nullptr;
  bool full = false;
};
bool GetColor(const AVFrame& frame, Color& color) {
  if (frame.color_range != AVCOL_RANGE_UNSPECIFIED &&
      frame.color_range != AVCOL_RANGE_MPEG && frame.color_range != AVCOL_RANGE_JPEG)
    return false;
  color.full = frame.color_range == AVCOL_RANGE_JPEG ||
               frame.format == AV_PIX_FMT_YUVJ420P || frame.format == AV_PIX_FMT_BGRA;
  switch (frame.colorspace) {
    case AVCOL_SPC_RGB: if (frame.format != AV_PIX_FMT_BGRA) return false; break;
    case AVCOL_SPC_UNSPECIFIED: case AVCOL_SPC_BT470BG: case AVCOL_SPC_SMPTE170M: break;
    case AVCOL_SPC_BT709:
      color.coefficients = SWS_CS_ITU709;
      color.matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2; break;
    case AVCOL_SPC_SMPTE240M:
      color.coefficients = SWS_CS_SMPTE240M;
      color.matrix = kCVImageBufferYCbCrMatrix_SMPTE_240M_1995; break;
    case AVCOL_SPC_BT2020_NCL:
      color.coefficients = SWS_CS_BT2020;
      color.matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020; break;
    default: return false;
  }
  switch (frame.color_primaries) {
    case AVCOL_PRI_UNSPECIFIED: break;
    case AVCOL_PRI_BT709: color.primaries = kCVImageBufferColorPrimaries_ITU_R_709_2; break;
    case AVCOL_PRI_BT470BG: color.primaries = kCVImageBufferColorPrimaries_EBU_3213; break;
    case AVCOL_PRI_SMPTE170M: case AVCOL_PRI_SMPTE240M:
      color.primaries = kCVImageBufferColorPrimaries_SMPTE_C; break;
    case AVCOL_PRI_BT2020: color.primaries = kCVImageBufferColorPrimaries_ITU_R_2020; break;
    case AVCOL_PRI_SMPTE432: color.primaries = kCVImageBufferColorPrimaries_P3_D65; break;
    default: return false;
  }
  switch (frame.color_trc) {
    case AVCOL_TRC_UNSPECIFIED: break;
    case AVCOL_TRC_BT709: case AVCOL_TRC_SMPTE170M:
    case AVCOL_TRC_BT2020_10: case AVCOL_TRC_BT2020_12:
      color.transfer = kCVImageBufferTransferFunction_ITU_R_709_2; break;
    case AVCOL_TRC_SMPTE240M:
      color.transfer = kCVImageBufferTransferFunction_SMPTE_240M_1995; break;
    case AVCOL_TRC_IEC61966_2_1: color.transfer = kCVImageBufferTransferFunction_sRGB; break;
    case AVCOL_TRC_LINEAR: color.transfer = kCVImageBufferTransferFunction_Linear; break;
    default: return false;  // Includes PQ/HLG; no unimplemented HDR claim.
  }
  return !av_frame_get_side_data(&frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA) &&
         !av_frame_get_side_data(&frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);
}

AudioChannelLabel Channel(AVChannel channel) {
  // Explicit identity preserves FFmpeg's order; side and back surrounds differ.
  static const AudioChannelLabel labels[] = {
      kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
      kAudioChannelLabel_LFEScreen, kAudioChannelLabel_RearSurroundLeft,
      kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_LeftCenter,
      kAudioChannelLabel_RightCenter, kAudioChannelLabel_CenterSurround,
      kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
      kAudioChannelLabel_TopCenterSurround, kAudioChannelLabel_VerticalHeightLeft,
      kAudioChannelLabel_VerticalHeightCenter, kAudioChannelLabel_VerticalHeightRight,
      kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_TopBackCenter,
      kAudioChannelLabel_TopBackRight};
  return channel >= 0 && static_cast<size_t>(channel) < std::size(labels)
      ? labels[channel] : kAudioChannelLabel_Unknown;
}
}  // namespace

struct DecodedMedia::State {
  const size_t max_bytes;
  const size_t max_video_buffers;
  SwsContext* video = nullptr;
  SwrContext* audio = nullptr;
  CVPixelBufferPoolRef pool = nullptr;
  int width = 0, height = 0;
  OSType pixel_format = 0;
  AVChannelLayout layout{};
  int sample_format = AV_SAMPLE_FMT_NONE, rate = 0;
  State(size_t bytes, size_t buffers) : max_bytes(bytes), max_video_buffers(buffers) {}
  ~State() {
    sws_freeContext(video);
    swr_free(&audio);
    av_channel_layout_uninit(&layout);
    if (pool) CVPixelBufferPoolRelease(pool);
  }
};

DecodedMedia::DecodedMedia(size_t max_bytes, size_t max_video_buffers)
    : state_(std::make_unique<State>(max_bytes, max_video_buffers)) {}
DecodedMedia::~DecodedMedia() = default;
bool DecodedMedia::SupportsVideoColor(const AVFrame& frame) {
  Color color;
  return GetColor(frame, color);
}
void DecodedMedia::Reset() {
  state_ = std::make_unique<State>(state_->max_bytes, state_->max_video_buffers);
}

CMSampleBufferRef DecodedMedia::CopyVideo(const AVFrame& input, CMTime pts,
                                         CMTime duration, std::string& error) {
  error.clear();
  State& s = *state_;
  if (!Time(pts) || !Time(duration, true) || !Time(CMTimeAdd(pts, duration)))
    return Fail(error, "invalid video timing");
  if (input.format != AV_PIX_FMT_YUV420P && input.format != AV_PIX_FMT_YUVJ420P &&
      input.format != AV_PIX_FMT_NV12 && input.format != AV_PIX_FMT_BGRA)
    return Fail(error, "unsupported video pixel format");
  Color color;
  if (!GetColor(input, color)) return Fail(error, "unsupported video color semantics");
  if (!s.max_video_buffers || !VideoPlanes(input, s.max_bytes))
    return Fail(error, "invalid video size, plane extent or allocation budget");
  if (input.crop_left >= static_cast<size_t>(input.width) ||
      input.crop_right >= static_cast<size_t>(input.width) - input.crop_left ||
      input.crop_top >= static_cast<size_t>(input.height) ||
      input.crop_bottom >= static_cast<size_t>(input.height) - input.crop_top ||
      (input.format != AV_PIX_FMT_BGRA && ((input.crop_left | input.crop_top) & 1)))
    return Fail(error, "invalid or chroma-unaligned visible crop");
  if (input.sample_aspect_ratio.num < 0 || input.sample_aspect_ratio.den < 0 ||
      (input.sample_aspect_ratio.num && !input.sample_aspect_ratio.den))
    return Fail(error, "invalid sample aspect ratio");
  std::unique_ptr<AVFrame, FreeFrame> frame(av_frame_clone(&input));
  if (!frame || av_frame_apply_cropping(frame.get(), AV_FRAME_CROP_UNALIGNED) < 0 ||
      !VideoPlanes(*frame, s.max_bytes)) return Fail(error, "invalid cropped video storage");
  OSType type = color.full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                          : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  if (!s.pool || s.width != frame->width || s.height != frame->height || s.pixel_format != type) {
    if (s.pool) CVPixelBufferPoolRelease(s.pool);
    s.pool = nullptr;
    NSDictionary* attributes = @{
      (id)kCVPixelBufferWidthKey: @(frame->width),
      (id)kCVPixelBufferHeightKey: @(frame->height),
      (id)kCVPixelBufferPixelFormatTypeKey: @(type),
      (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    if (CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr,
        (__bridge CFDictionaryRef)attributes, &s.pool) != kCVReturnSuccess)
      return Fail(error, "could not create native video pool");
    s.width = frame->width; s.height = frame->height; s.pixel_format = type;
  }
  NSDictionary* limits = @{(id)kCVPixelBufferPoolAllocationThresholdKey: @(s.max_video_buffers)};
  CVPixelBufferRef raw_pixels = nullptr;
  CVReturn status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
      kCFAllocatorDefault, s.pool, (__bridge CFDictionaryRef)limits, &raw_pixels);
  if (status) return Fail(error, status == kCVReturnWouldExceedAllocationThreshold
      ? "native video pool backpressured" : "could not allocate native video buffer");
  Pixel pixels(raw_pixels);
  if (CVPixelBufferGetDataSize(pixels.get()) > s.max_bytes ||
      CVPixelBufferLockBaseAddress(pixels.get(), 0) != kCVReturnSuccess)
    return Fail(error, "native video allocation exceeds budget or cannot be mapped");
  s.video = sws_getCachedContext(s.video, s.width, s.height,
      frame->format == AV_PIX_FMT_YUVJ420P ? AV_PIX_FMT_YUV420P
                                         : static_cast<AVPixelFormat>(frame->format),
      s.width, s.height, AV_PIX_FMT_NV12,
      SWS_BILINEAR, nullptr, nullptr, nullptr);
  uint8_t* output[4] = {
      (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixels.get(), 0),
      (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixels.get(), 1), nullptr, nullptr};
  int strides[4] = {(int)CVPixelBufferGetBytesPerRowOfPlane(pixels.get(), 0),
                    (int)CVPixelBufferGetBytesPerRowOfPlane(pixels.get(), 1), 0, 0};
  const int* coefficients = sws_getCoefficients(color.coefficients);
  int rows = s.video && sws_setColorspaceDetails(s.video, coefficients, color.full,
      coefficients, color.full, 0, 1 << 16, 1 << 16) >= 0
      ? sws_scale(s.video, frame->data, frame->linesize, 0, s.height, output, strides) : -1;
  CVPixelBufferUnlockBaseAddress(pixels.get(), 0);
  if (rows != s.height) return Fail(error, "video conversion failed");
  // Pools reuse buffers: remove prior frame metadata before attaching this frame.
  CVBufferRemoveAllAttachments(pixels.get());
  CVBufferSetAttachment(pixels.get(), kCVImageBufferYCbCrMatrixKey, color.matrix,
                         kCVAttachmentMode_ShouldPropagate);
  if (color.primaries) CVBufferSetAttachment(pixels.get(), kCVImageBufferColorPrimariesKey,
      color.primaries, kCVAttachmentMode_ShouldPropagate);
  if (color.transfer) CVBufferSetAttachment(pixels.get(), kCVImageBufferTransferFunctionKey,
      color.transfer, kCVAttachmentMode_ShouldPropagate);
  if (frame->sample_aspect_ratio.num > 0) {
    NSDictionary* aspect = @{
      (id)kCVImageBufferPixelAspectRatioHorizontalSpacingKey: @(frame->sample_aspect_ratio.num),
      (id)kCVImageBufferPixelAspectRatioVerticalSpacingKey: @(frame->sample_aspect_ratio.den)};
    CVBufferSetAttachment(pixels.get(), kCVImageBufferPixelAspectRatioKey,
        (__bridge CFDictionaryRef)aspect, kCVAttachmentMode_ShouldPropagate);
  }
  CMVideoFormatDescriptionRef raw_format = nullptr;
  if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixels.get(),
      &raw_format)) return Fail(error, "native video format creation failed");
  Format format(raw_format);
  CMSampleTimingInfo timing{duration, pts, kCMTimeInvalid};
  CMSampleBufferRef sample = nullptr;
  if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixels.get(),
      format.get(), &timing, &sample)) return Fail(error, "native video sample creation failed");
  return sample;
}

CMSampleBufferRef DecodedMedia::CopyAudio(const AVFrame& frame, CMTime pts,
                                         std::string& error) {
  error.clear();
  State& s = *state_;
  int channels = frame.ch_layout.nb_channels;
  AVSampleFormat sample_format = static_cast<AVSampleFormat>(frame.format);
  int bytes_per_sample = av_get_bytes_per_sample(sample_format);
  if (!Time(pts) || frame.nb_samples <= 0 || frame.sample_rate <= 0 ||
      frame.sample_rate > 384000 || channels <= 0 || channels > 32 ||
      !av_channel_layout_check(&frame.ch_layout) || !bytes_per_sample ||
      static_cast<size_t>(frame.nb_samples) > s.max_bytes / (sizeof(float) * channels))
    return Fail(error, "invalid audio timing, samples, format, layout or budget");
  CMTime end = CMTimeAdd(pts, CMTimeMake(frame.nb_samples, frame.sample_rate));
  if (!Time(end) || CMTimeCompare(end, pts) <= 0)
    return Fail(error, "audio timestamp overflow");
  bool planar = av_sample_fmt_is_planar(sample_format);
  int planes = planar ? channels : 1;
  if (planes > AV_NUM_DATA_POINTERS &&
      (frame.extended_data == frame.data || frame.nb_extended_buf < planes - AV_NUM_DATA_POINTERS))
    return Fail(error, "invalid extended audio planes");
  size_t input_bytes = static_cast<size_t>(frame.nb_samples) * bytes_per_sample *
                       (planar ? 1 : channels);
  for (int i = 0; i < planes; ++i)
    if (!Plane(frame, i, 1, input_bytes, input_bytes, s.max_bytes))
      return Fail(error, "invalid audio plane extent");
  size_t layout_bytes = offsetof(AudioChannelLayout, mChannelDescriptions) +
                         channels * sizeof(AudioChannelDescription);
  std::vector<uint8_t> layout_storage(layout_bytes);
  auto* native_layout = reinterpret_cast<AudioChannelLayout*>(layout_storage.data());
  native_layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
  native_layout->mNumberChannelDescriptions = channels;
  for (int i = 0; i < channels; ++i) {
    AudioChannelLabel label = Channel(av_channel_layout_channel_from_index(&frame.ch_layout, i));
    if (label == kAudioChannelLabel_Unknown) return Fail(error, "unsupported audio channel identity");
    native_layout->mChannelDescriptions[i].mChannelLabel = label;
  }
  if (!s.audio || s.sample_format != frame.format || s.rate != frame.sample_rate ||
      av_channel_layout_compare(&s.layout, &frame.ch_layout) != 0) {
    swr_free(&s.audio);
    av_channel_layout_uninit(&s.layout);
    if (av_channel_layout_copy(&s.layout, &frame.ch_layout) < 0 ||
        swr_alloc_set_opts2(&s.audio, &s.layout, AV_SAMPLE_FMT_FLT, frame.sample_rate,
            &s.layout, sample_format, frame.sample_rate, 0, nullptr) < 0 || swr_init(s.audio) < 0) {
      swr_free(&s.audio);
      return Fail(error, "audio converter initialization failed");
    }
    s.sample_format = frame.format; s.rate = frame.sample_rate;
  }
  size_t bytes = static_cast<size_t>(frame.nb_samples) * channels * sizeof(float);
  CMBlockBufferRef raw_data = nullptr;
  if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, bytes,
      kCFAllocatorDefault, nullptr, 0, bytes, 0, &raw_data))
    return Fail(error, "native PCM allocation failed");
  Block data(raw_data);
  char* destination = nullptr;
  if (CMBlockBufferAssureBlockMemory(data.get()) ||
      CMBlockBufferGetDataPointer(data.get(), 0, nullptr, nullptr, &destination))
    return Fail(error, "native PCM mapping failed");
  uint8_t* output[] = {reinterpret_cast<uint8_t*>(destination)};
  int converted = swr_convert(s.audio, output, frame.nb_samples,
      const_cast<const uint8_t**>(frame.extended_data), frame.nb_samples);
  if (converted != frame.nb_samples) {
    swr_free(&s.audio);
    return Fail(error, "audio conversion did not preserve the complete sample count");
  }
  const float* samples = reinterpret_cast<const float*>(destination);
  for (size_t i = 0; i < bytes / sizeof(float); ++i)
    if (!std::isfinite(samples[i])) return Fail(error, "non-finite decoded PCM");
  AudioStreamBasicDescription asbd{};
  asbd.mSampleRate = frame.sample_rate;
  asbd.mFormatID = kAudioFormatLinearPCM;
  asbd.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
  asbd.mFramesPerPacket = 1;
  asbd.mBytesPerPacket = asbd.mBytesPerFrame = channels * sizeof(float);
  asbd.mChannelsPerFrame = channels;
  asbd.mBitsPerChannel = 32;
  CMAudioFormatDescriptionRef raw_format = nullptr;
  if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, layout_bytes,
      native_layout, 0, nullptr, nullptr, &raw_format))
    return Fail(error, "native PCM format creation failed");
  Format format(raw_format);
  CMSampleTimingInfo timing{CMTimeMake(1, frame.sample_rate), pts, kCMTimeInvalid};
  size_t frame_bytes = asbd.mBytesPerFrame;
  CMSampleBufferRef sample = nullptr;
  if (CMSampleBufferCreateReady(kCFAllocatorDefault, data.get(), format.get(),
      frame.nb_samples, 1, &timing, 1, &frame_bytes, &sample))
    return Fail(error, "native PCM sample creation failed");
  return sample;
}
}  // namespace applescreen

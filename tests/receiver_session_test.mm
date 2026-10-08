#include "../native/ReceiverSession.h"
#include "../native/cast.h"
#include "../native/media/DecodedMedia.h"
#include "../native/media/PlaybackSession.h"
#include "../native/media/ReceiverTimeline.h"
#import <Foundation/Foundation.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/samplefmt.h>
}

#include <cstdlib>
#include <cstring>
#include <condition_variable>
#include <cstdio>
#include <ctime>
#include <deque>
#include <fstream>
#include <mutex>
#include <unistd.h>
#include <sys/stat.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include "cast/common/public/trust_store.h"
#include "cast/receiver/channel/static_credentials.h"

#include "platform/api/task_runner.h"

namespace {
#define CHECK(condition) do { if (!(condition)) { \
  std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
  std::abort(); } } while (false)
using applescreen::ReceiverConfig;
using applescreen::ReceiverSession;
using applescreen::ReceiverState;

// The real credential worker posts to this protocol executor. Waiting has a
// deadline, never an arbitrary sleep or an assumption about worker readiness.
class Executor final : public openscreen::TaskRunner {
 public:
  void PostPackagedTask(Task task) override {
    { std::lock_guard lock(mutex_); tasks_.push_back(std::move(task)); }
    available_.notify_one();
  }
  void PostPackagedTaskWithDelay(Task task, openscreen::Clock::duration) override {
    delayed_.push_back(std::move(task));
  }
  bool IsRunningOnTaskRunner() override { return true; }
  void Until(const std::function<bool()>& done) {
    while (!done()) {
      Task task;
      {
        std::unique_lock lock(mutex_);
        CHECK(available_.wait_for(lock, std::chrono::seconds(5), [&] { return !tasks_.empty(); }));
        task = std::move(tasks_.front()); tasks_.pop_front();
      }
      task();
    }
  }
  void Drain() {
    for (;;) {
      Task task;
      {
        std::lock_guard lock(mutex_);
        if (tasks_.empty()) return;
        task = std::move(tasks_.front()); tasks_.pop_front();
      }
      task();
    }
  }
 private:
  std::mutex mutex_;
  std::condition_variable available_;
  std::deque<Task> tasks_;
  std::vector<Task> delayed_;
};

ReceiverConfig Config() {
  ReceiverConfig value;
  value.info.unique_id = "receiver-test-id";
  value.info.friendly_name = "Applescreen Test";
  value.info.model_name = "Applescreen";
  value.info.port = 8010;
  value.developer_ca_path = "/private/tmp/applescreen-deliberately-missing-ca";
  value.developer_key_path = "/private/tmp/applescreen-deliberately-missing-key";
  return value;
}

void DeveloperCredentialsAreUsableAndNeverOverwrite() {
  auto generate = [](NSURL* directory) {
    struct Result { bool done = false; NSString* error = nil; } result;
    ASCastGenerateDeveloperCA((__bridge CFURLRef)directory,
      [](void* context, CFStringRef error) {
        CHECK(NSThread.isMainThread);
        auto& result = *static_cast<Result*>(context);
        CHECK(!result.done);
        result.error = [(__bridge NSString*)error copy];
        result.done = true;
      }, &result);
    CHECK(!result.done);
    const auto deadline = CFAbsoluteTimeGetCurrent() + 10;
    while (!result.done) {
      CHECK(CFAbsoluteTimeGetCurrent() < deadline);
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    }
    return result.error;
  };
  CHECK(generate([NSURL URLWithString:@"https://example.invalid/credentials"]));
  NSURL* directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
      URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
  CHECK(generate([directory URLByAppendingPathComponent:@"missing-parent"]));
  CHECK(!generate(directory));
  NSURL* certificate_url = [directory URLByAppendingPathComponent:@"development-ca.crt"];
  NSURL* key_url = [directory URLByAppendingPathComponent:@"development-ca.key"];
  NSData* certificate_data = [NSData dataWithContentsOfURL:certificate_url];
  NSData* key_data = [NSData dataWithContentsOfURL:key_url];
  CHECK(certificate_data.length && key_data.length);
  for (NSURL* url in @[directory, certificate_url, key_url]) {
    struct stat status{};
    CHECK(stat(url.fileSystemRepresentation, &status) == 0);
    CHECK((status.st_mode & 0777) == (url == directory ? 0700 : 0600));
  }
  bssl::UniquePtr<BIO> cert_input(BIO_new_mem_buf(certificate_data.bytes, certificate_data.length));
  bssl::UniquePtr<BIO> key_input(BIO_new_mem_buf(key_data.bytes, key_data.length));
  bssl::UniquePtr<X509> cert(PEM_read_bio_X509(cert_input.get(), nullptr, nullptr, nullptr));
  bssl::UniquePtr<EVP_PKEY> key(PEM_read_bio_PrivateKey(key_input.get(), nullptr, nullptr, nullptr));
  CHECK(cert && key && EVP_PKEY_bits(key.get()) >= 2048);
  CHECK(X509_check_private_key(cert.get(), key.get()) == 1 && X509_check_ca(cert.get()));
  CHECK(X509_verify(cert.get(), key.get()) == 1);
  CHECK(X509_cmp_current_time(X509_get0_notBefore(cert.get())) < 0);
  CHECK(X509_cmp_current_time(X509_get0_notAfter(cert.get())) > 0);
  const std::string_view certificate_pem(static_cast<const char*>(certificate_data.bytes), certificate_data.length);
  auto trust = openscreen::cast::TrustStore::CreateInstanceFromPem(certificate_pem);
  CHECK(trust);
  auto credentials = openscreen::cast::GenerateCredentialsFromPem("generated-ca-test-device",
      std::string_view(static_cast<const char*>(key_data.bytes), key_data.length), certificate_pem);
  CHECK(credentials);
  const time_t now = time(nullptr);
  struct tm utc{};
  CHECK(gmtime_r(&now, &utc));
  const openscreen::cast::DateTime date{static_cast<uint16_t>(utc.tm_year + 1900),
      static_cast<uint8_t>(utc.tm_mon + 1), static_cast<uint8_t>(utc.tm_mday),
      static_cast<uint8_t>(utc.tm_hour), static_cast<uint8_t>(utc.tm_min), static_cast<uint8_t>(utc.tm_sec)};
  CHECK(trust.value()->FindCertificatePath(credentials.value().provider->device_creds.certs, date));
  CHECK(generate(directory));
  CHECK([certificate_data isEqual:[NSData dataWithContentsOfURL:certificate_url]]);
  CHECK([key_data isEqual:[NSData dataWithContentsOfURL:key_url]]);
  CHECK([NSFileManager.defaultManager removeItemAtURL:directory error:nil]);
}

void InvalidStartIsOneFailureAndStoppable() {
  const std::vector<std::function<void(ReceiverConfig&)>> cases{
      [](auto& c) { c.info.port = 0; },
      [](auto& c) { c.info.friendly_name.clear(); },
      [](auto& c) { c.display_width = INT_MAX; },
      [](auto& c) { c.max_fps = 0; },
      [](auto& c) { c.interface_index = UINT32_MAX; },
      [](auto& c) { c.developer_ca_path.clear(); },
      [](auto&) {}};
  for (const auto& change : cases) {
    Executor runner;
    int failed = 0, stopped = 0, completed = 0, events = 0;
    ReceiverSession session(runner, [&](auto event) {
      ++events;
      CHECK(!event.video_layer);
      CHECK(event.state != ReceiverState::kListening && event.state != ReceiverState::kStreaming);
      if (event.state == ReceiverState::kFailed) { ++failed; CHECK(!event.error.empty()); }
      if (event.state == ReceiverState::kStopped) ++stopped;
    });
    auto config = Config(); change(config);
    session.Start(config);
    runner.Until([&] { return failed == 1; });
    session.Stop([&] { ++completed; });
    session.Stop([&] { ++completed; });
    runner.Until([&] { return completed == 2; });
    CHECK(stopped == 1 && failed == 1);
    const int terminal_events = events;
    runner.Drain();
    CHECK(events == terminal_events);
  }
}

void StopBeforeReadyAndImmediateRestart() {
  Executor runner;
  int starting = 0, stopped = 0, completed = 0;
  ReceiverSession session(runner, [&](auto event) {
    if (event.state == ReceiverState::kStarting) ++starting;
    else { CHECK(event.state == ReceiverState::kStopped); ++stopped; }
  });
  for (int generation = 1; generation <= 8; ++generation) {
    auto config = Config();
    session.Start(config);
    config.developer_ca_path.clear();  // The async operation has its owned snapshot.
    session.Stop([&] { ++completed; });
    CHECK(completed == generation - 1);  // Worker/callback barrier is outstanding.
    runner.Until([&] { return completed == generation; });
    CHECK(session.state() == ReceiverState::kStopped);
    CHECK(starting == generation && stopped == generation);
    runner.Drain();
  }
}

void ReentrantStopDuringStarting() {
  Executor runner;
  int starting = 0, stopped = 0, completed = 0;
  ReceiverSession* handle = nullptr;
  ReceiverSession session(runner, [&](auto event) {
    if (event.state == ReceiverState::kStarting) {
      ++starting;
      handle->Stop([&] { ++completed; });
    } else { CHECK(event.state == ReceiverState::kStopped); ++stopped; }
  });
  handle = &session;
  session.Start(Config());
  CHECK(starting == 1 && stopped == 1 && completed == 1);
  session.Stop([&] { ++completed; });
  runner.Drain();
  CHECK(stopped == 1 && completed == 2);
}

void InvalidOwnedCredentialFile() {
  char path[] = "/private/tmp/applescreen-receiver-pem-XXXXXX";
  const int descriptor = mkstemp(path);
  CHECK(descriptor >= 0); close(descriptor);
  for (const std::string pem : {"garbage", "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"}) {
    { std::ofstream output(path); output << pem; }
    Executor runner;
    int failed = 0, completed = 0;
    ReceiverSession session(runner, [&](auto event) {
      CHECK(event.state != ReceiverState::kListening);
      if (event.state == ReceiverState::kFailed) ++failed;
    });
    auto config = Config(); config.developer_ca_path = config.developer_key_path = path;
    session.Start(config);
    runner.Until([&] { return failed == 1; });
    session.Stop([&] { ++completed; });
    runner.Until([&] { return completed == 1; });
    runner.Drain();
    CHECK(failed == 1);
  }
  unlink(path);
}
void ReceiverTimingReachesNativeSamples() {
  using namespace std::chrono;
  using openscreen::Clock;
  using openscreen::cast::RtpTimeTicks;
  using openscreen::cast::RtpTimeDelta;
  const Clock::time_point origin(milliseconds(1000));
  for (bool audio_first : {false, true}) {
    applescreen::ReceiverTimeline timeline(origin, milliseconds(400), milliseconds(400));
    applescreen::DecodedMedia converter;
    ASPlaybackSession* sink = ASPlaybackCreate({true, true, 8, 1024 * 1024,
                                                CMTimeMake(2, 1), CMTimeMake(1, 30)});
    CHECK(sink);
    CHECK(ASPlaybackSetAnchor(sink, kCMTimeZero,
        CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTimeMake(1, 1))) == ASPlaybackAccepted);
    for (bool video : {audio_first, !audio_first}) {
      auto point = timeline.Map(video, RtpTimeTicks(), video ? 90000 : 48000,
          origin + milliseconds(video ? 500 : 750), milliseconds(0));
      CHECK(point && !point->discontinuity);
      AVFrame* frame = av_frame_alloc();
      CHECK(frame);
      if (video) {
        frame->format = AV_PIX_FMT_YUV420P;
        frame->width = 4; frame->height = 4;
        frame->color_range = AVCOL_RANGE_MPEG;
      } else {
        frame->format = AV_SAMPLE_FMT_S32P;
        frame->sample_rate = 48000; frame->nb_samples = 480;
        av_channel_layout_default(&frame->ch_layout, 2);
      }
      CHECK(av_frame_get_buffer(frame, 32) == 0);
      for (int plane = 0; plane < AV_NUM_DATA_POINTERS; ++plane)
        if (frame->buf[plane]) memset(frame->buf[plane]->data, 0, frame->buf[plane]->size);
      frame->pts = INT64_MAX;  // Decoder timestamps cannot override Cast timing.
      std::string error;
      CMTime pts = CMTimeMake(point->elapsed.count(), 1000000);
      CMSampleBufferRef sample = video ? converter.CopyVideo(*frame, pts, CMTimeMake(1, 60), error)
                                      : converter.CopyAudio(*frame, pts, error);
      CHECK(sample && error.empty());
      av_frame_free(&frame);  // Borrowed FFmpeg storage ends before native enqueue.
      CHECK(ASPlaybackEnqueue(sink, video ? ASPlaybackVideo : ASPlaybackAudio, sample) == ASPlaybackAccepted);
      CFRelease(sample);
    }
    auto stats = ASPlaybackGetStats(sink);
    CHECK(CMTimeCompare(CMTimeSubtract(stats.first_audio_pts, stats.first_video_pts), CMTimeMake(1, 4)) == 0);
    // A small explicit delay update is an immediate shared discontinuity; it
    // must not be mistaken for clock drift and smoothed over many frames.
    auto update = timeline.Map(true, RtpTimeTicks() + RtpTimeDelta::FromTicks(1500), 90000,
        origin + microseconds(541666), milliseconds(425));
    CHECK(update && update->discontinuity && update->elapsed == microseconds(541666));
    const auto old_flushes = stats.flushes;
    CHECK(ASPlaybackSetAnchor(sink, kCMTimeZero,
        CMClockGetTime(CMClockGetHostTimeClock())) == ASPlaybackAccepted);
    CHECK(ASPlaybackGetStats(sink).flushes == old_flushes + 1);
    // The other track re-establishes its absolute target after that shared reset.
    auto audio = timeline.Map(false, RtpTimeTicks() + RtpTimeDelta::FromTicks(480), 48000,
                              origin + milliseconds(785), milliseconds(425));
    CHECK(audio && audio->elapsed == milliseconds(785));
    Executor runner;
    bool stopped = false;
    struct Stop { Executor* runner; bool* done; } context{&runner, &stopped};
    ASPlaybackStop(sink, [](void* opaque) {
      auto* stop = static_cast<Stop*>(opaque);
      stop->runner->PostTask([done = stop->done] { *done = true; });
    }, &context);
    runner.Until([&] { return stopped; });
    ASPlaybackDestroy(sink);
  }
  // Long-running rational and invalid-time cases live in media_timeline_test;
  // this native group keeps the end-to-end sample/renderer timing assertions.
}

void NegotiatedStartupBudgetPreservesPresentTracks() {
  using namespace std::chrono;
  // A 400 ms Cast delay needs 24 video frames at 60 Hz and forty 10 ms
  // audio packets before any sample is due. The old fixed 16-slot sink could
  // drop valid startup audio even though its byte and time budgets had space.
  auto limits = ReceiverSession::PlaybackLimits(true, true, CMTimeMake(1, 60),
      milliseconds(400), milliseconds(400));
  applescreen::DecodedMedia converter(limits.playback.max_bytes, limits.video_buffers);
  ASPlaybackSession* sink = ASPlaybackCreate(limits.playback);
  CHECK(sink);
  CHECK(ASPlaybackSetAnchor(sink, kCMTimeZero,
      CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTimeMake(1, 1))) == ASPlaybackAccepted);
  for (int index = 0; index < 40; ++index) {
    for (bool video : {false, true}) {
      if (video && index >= 24) continue;
      AVFrame* frame = av_frame_alloc();
      CHECK(frame);
      if (video) {
        frame->format = AV_PIX_FMT_YUV420P;
        frame->width = frame->height = 16;
        frame->color_range = AVCOL_RANGE_MPEG;
      } else {
        frame->format = AV_SAMPLE_FMT_FLTP;
        frame->sample_rate = 48000; frame->nb_samples = 480;
        av_channel_layout_default(&frame->ch_layout, 2);
      }
      CHECK(av_frame_get_buffer(frame, 32) == 0);
      for (auto* buffer : frame->buf)
        if (buffer) memset(buffer->data, 0, buffer->size);
      CMTime pts = CMTimeAdd(CMTimeMake(2, 5), CMTimeMake(index, video ? 60 : 100));
      std::string error;
      CMSampleBufferRef sample = video ? converter.CopyVideo(*frame, pts, CMTimeMake(1, 60), error)
                                      : converter.CopyAudio(*frame, pts, error);
      av_frame_free(&frame);
      CHECK(sample && error.empty());
      CHECK(ASPlaybackEnqueue(sink, video ? ASPlaybackVideo : ASPlaybackAudio, sample) == ASPlaybackAccepted);
      CFRelease(sample);
    }
  }
  auto stats = ASPlaybackGetStats(sink);
  CHECK(stats.accounted_samples == 64);
  CHECK(stats.accounted_bytes < limits.playback.max_bytes);
  CHECK(stats.dropped_audio == 0 && stats.dropped_video == 0);
  Executor runner;
  bool stopped = false;
  struct Stop { Executor* runner; bool* done; } context{&runner, &stopped};
  ASPlaybackStop(sink, [](void* opaque) {
    auto* stop = static_cast<Stop*>(opaque);
    stop->runner->PostTask([done = stop->done] { *done = true; });
  }, &context);
  runner.Until([&] { return stopped; });
  CHECK(ASPlaybackGetStats(sink).accounted_samples == 0);
  ASPlaybackDestroy(sink);
}

void Av1UsesARealSoftwareDecoder() {
  using openscreen::cast::VideoCodec;
  for (const auto* parameter : {"av01.0.04M.08", "av01.0.04M.08.0.110.01.01.01.0"})
    CHECK(ReceiverSession::SupportsAv1Parameter(parameter));
  for (const auto* parameter : {"av01.0.04M.10", "av01.0.04M.12", "av01.2.04M.08",
      "av01.0.04M.08.0.110.09.16.09.0", "av01.0.04M.08.truncated", "av01.0.04M.08."})
    CHECK(!ReceiverSession::SupportsAv1Parameter(parameter));
  auto name = ReceiverSession::VideoDecoderName(VideoCodec::kAv1);
  CHECK(name == "libaom-av1" || name == "libdav1d");
  const AVCodec* codec = avcodec_find_decoder_by_name(name.c_str());
  AVCodecContext* context = avcodec_alloc_context3(codec);
  CHECK(context && avcodec_open2(context, codec, nullptr) == 0);
  // One 16x16 gray SDR 8-bit frame, generated with FFmpeg/libaom (-f obu).
  const uint8_t bytes[] = {0x12,0x00,0x0a,0x0a,0x00,0x00,0x00,0x01,0x9f,0xf9,0xb5,0xf2,0x00,
      0x80,0x32,0x0b,0x10,0x00,0xc0,0x00,0x00,0x02,0x80,0x00,0x00,0x00,0x9c};
  AVPacket* packet = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  CHECK(packet && frame && av_new_packet(packet, sizeof(bytes)) == 0);
  memcpy(packet->data, bytes, sizeof(bytes));
  CHECK(avcodec_send_packet(context, packet) == 0);
  av_packet_free(&packet);
  CHECK(avcodec_receive_frame(context, frame) == 0);
  CHECK(frame->width == 16 && frame->height == 16 && frame->format == AV_PIX_FMT_YUV420P);
  applescreen::DecodedMedia converter;
  std::string error;
  CMSampleBufferRef sample = converter.CopyVideo(*frame, kCMTimeZero, CMTimeMake(1, 30), error);
  av_frame_free(&frame);
  avcodec_free_context(&context);
  CHECK(sample && error.empty());
  CFRelease(sample);
}
}  // namespace

int main() {
  @autoreleasepool {
  DeveloperCredentialsAreUsableAndNeverOverwrite();
  InvalidStartIsOneFailureAndStoppable();
  StopBeforeReadyAndImmediateRestart();
  ReentrantStopDuringStarting();
  InvalidOwnedCredentialFile();
  ReceiverTimingReachesNativeSamples();
  NegotiatedStartupBudgetPreservesPresentTracks();
  Av1UsesARealSoftwareDecoder();
  std::puts("Receiver lifecycle and Cast-to-native media timing tests passed");
  }
}

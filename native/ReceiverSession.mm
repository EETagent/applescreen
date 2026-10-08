#include "ReceiverSession.h"

#include "media/DecodedMedia.h"
#include "media/PlaybackSession.h"
#include "media/ReceiverTimeline.h"

#import <Foundation/Foundation.h>

extern "C" {
#include <libavcodec/avcodec.h>
}

#include <algorithm>
#include <chrono>
#include <fstream>
#include <map>
#include <optional>
#include <utility>
#include <vector>

#include "cast/common/channel/cast_socket_message_port.h"
#include "cast/common/public/cast_streaming_app_ids.h"
#include "cast/receiver/application_agent.h"
#include "cast/receiver/channel/static_credentials.h"
#include "cast/receiver/public/receiver_socket_factory.h"
#include "cast/standalone_receiver/decoder.h"
#include "cast/streaming/message_fields.h"
#include "cast/streaming/public/environment.h"
#include "cast/streaming/public/receiver.h"
#include "cast/streaming/public/receiver_session.h"
#include "platform/api/task_runner.h"
#include "platform/api/tls_connection_factory.h"
#include "platform/base/interface_info.h"
#include "platform/base/tls_listen_options.h"
#include "platform/impl/network_interface.h"
#include "util/alarm.h"
#include "util/osp_logging.h"

namespace applescreen {
namespace {
namespace cast = openscreen::cast;
using openscreen::Clock;
using openscreen::Error;
using openscreen::IPAddress;
using openscreen::IPEndpoint;
using openscreen::TaskRunner;
using OpenSession = cast::ReceiverSession;
constexpr size_t kMaxDecodeFrames = 16;
constexpr size_t kMaxEncodedBytes = 16 * 1024 * 1024;
constexpr size_t kMaxDecodedBytes = 64 * 1024 * 1024;

std::string DecoderName(cast::VideoCodec codec) {
  if (codec == cast::VideoCodec::kAv1) {
    for (const char* name : {"libdav1d", "libaom-av1"})
      if (avcodec_find_decoder_by_name(name)) return name;
    return {};
  }
  const char* name = cast::CodecToString(codec);
  return avcodec_find_decoder_by_name(name) ? name : "";
}
std::string DecoderName(cast::AudioCodec codec) {
  const char* name = cast::CodecToString(codec);
  return avcodec_find_decoder_by_name(name) ? name : "";
}

// Explicitly selected developer CA signs a normal Cast device chain. It is not
// the ephemeral TLS certificate, and does not bypass the device auth challenge.
openscreen::ErrorOr<cast::GeneratedCredentials> Credentials(const ReceiverConfig& c) {
  auto invalid = [](const char* message) {
    return Error(Error::Code::kParameterInvalid, message);
  };
  if (c.developer_ca_path.empty() || c.developer_key_path.empty())
    return invalid("Select a developer CA certificate and its private key");
  // Read each path once into bounded owned storage. The same immutable bytes
  // are validated and used by credential generation, so replacing a file cannot
  // change the authority after validation or trigger a passphrase prompt.
  auto read = [](const std::string& path) -> std::optional<std::string> {
    std::ifstream input(path, std::ios::binary);
    if (!input) return std::nullopt;
    std::string bytes(1024 * 1024 + 1, '\0');
    input.read(bytes.data(), bytes.size());
    if (input.bad() || input.gcount() > 1024 * 1024) return std::nullopt;
    bytes.resize(static_cast<size_t>(input.gcount()));
    return bytes;
  };
  auto ca = read(c.developer_ca_path);
  auto key = read(c.developer_key_path);
  if (!ca || !key) return invalid("Cannot read developer CA/key or file exceeds 1 MiB");
  return cast::GenerateCredentialsFromPem(c.info.unique_id, *key, *ca);
}

struct NativeSample {
  CMSampleBufferRef value;
  explicit NativeSample(CMSampleBufferRef sample) : value(sample) {}
  ~NativeSample() { if (value) CFRelease(value); }
};
}  // namespace

struct ReceiverSession::Impl final : std::enable_shared_from_this<Impl>,
    cast::ApplicationAgent::Application, OpenSession::Client,
    cast::ReceiverSocketFactory::Client {
  struct Track;
  struct Decode final : cast::Decoder::Client {
    struct Metadata {
      Clock::time_point reference_time;
      cast::RtpTimeTicks rtp;
      int rtp_timebase;
      std::chrono::milliseconds delay;
    };
    TaskRunner& runner;
    std::weak_ptr<Track> track;
    cast::Decoder decoder;
    DecodedMedia converter;
    std::map<cast::FrameId, Metadata> metadata;
    std::shared_ptr<ReceiverTimeline> timeline;
    CMTime video_duration;
    bool video;
    bool failed = false;

    Decode(TaskRunner& task_runner, std::weak_ptr<Track> owner,
           std::string codec, std::shared_ptr<ReceiverTimeline> time, CMTime duration, bool is_video, size_t video_buffers)
        : runner(task_runner), track(std::move(owner)), decoder(codec),
          converter(kMaxDecodedBytes, video_buffers), timeline(std::move(time)),
          video_duration(duration), video(is_video) { decoder.set_client(this); }
    void Input(cast::FrameId id, const cast::Decoder::Buffer& data, Metadata timing);
    void Result(cast::FrameId id, CMSampleBufferRef sample, std::string error, bool fatal,
                bool decode_error = false, bool discontinuity = false);
    void OnFrameDecoded(cast::FrameId id, const AVFrame& frame) override;
    void OnDecodeError(cast::FrameId id, const std::string& error) override;
    void OnFatalError(const std::string& error) override;
  };

  struct Track final : cast::Receiver::Consumer, std::enable_shared_from_this<Track> {
    std::weak_ptr<Impl> owner;
    cast::Receiver* receiver;  // Protocol sequence only; cleared synchronously on detach.
    const uint64_t generation;
    const bool video;
    const std::string codec;
    const CMTime duration;
    std::shared_ptr<Decode> decoder;  // Used/destructed only on the media worker.
    struct Pending { size_t bytes; Clock::time_point started; };
    std::map<cast::FrameId, Pending> pending;
    size_t pending_bytes = 0;
    Clock::duration processing{};
    Clock::time_point origin;

    Track(std::weak_ptr<Impl> service, cast::Receiver* input, uint64_t gen,
          bool is_video, std::string name, CMTime frame_duration)
        : owner(std::move(service)), receiver(input), generation(gen), video(is_video),
          codec(std::move(name)), duration(frame_duration) {}
    void Enable(std::shared_ptr<ReceiverTimeline> timeline, size_t video_buffers);
    void OnFramesReady(size_t bytes) override;
    void Resume();
    void Complete(cast::FrameId id, std::shared_ptr<NativeSample> sample,
                  std::string error, bool fatal, bool decode_error, bool discontinuity);
    void Detach() { if (receiver) receiver->SetConsumer(nullptr); receiver = nullptr; }
  };

  TaskRunner& runner;
  EventCallback callback;
  ReceiverConfig config;
  ReceiverState state = ReceiverState::kIdle;
  uint64_t service_generation = 0;
  uint64_t media_generation = 0;
  size_t asynchronous = 0;
  bool creating_playback = false;
  bool media_end_pending = false;
  std::optional<std::string> media_error;
  std::vector<std::function<void()>> stop_completions;
  dispatch_queue_t worker;
  openscreen::Alarm maintenance;
  std::optional<openscreen::InterfaceInfo> interface;
  std::optional<cast::GeneratedCredentials> credentials;
  std::unique_ptr<cast::ApplicationAgent> agent;
  std::unique_ptr<cast::ReceiverSocketFactory> sockets;
  std::unique_ptr<openscreen::TlsConnectionFactory> tls;
  struct Peer { IPEndpoint endpoint; openscreen::WeakPtr<cast::CastSocket> socket; };
  std::map<int, Peer> peers;
  const std::vector<std::string> app_ids = cast::GetCastStreamingAppIds();
  std::unique_ptr<cast::Environment> environment;
  std::unique_ptr<OpenSession> session;
  std::shared_ptr<Track> audio;
  std::shared_ptr<Track> video;
  ASPlaybackSession* playback = nullptr;

  Impl(TaskRunner& task_runner, EventCallback events)
      : runner(task_runner), callback(std::move(events)),
        worker(dispatch_queue_create("org.applescreen.receiver.decode",
            dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL,
                DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM))),
        maintenance(&Clock::now, task_runner) {}
  ~Impl() {
    OSP_DCHECK(!agent && !session && !playback && asynchronous == 0);
  }
  void CheckSequence() { OSP_DCHECK(runner.IsRunningOnTaskRunner()); }
  void Emit(std::string error = {}, CFTypeRef layer = nullptr) {
    ReceiverEvent event{state, media_generation, std::move(error), audio != nullptr,
                         video != nullptr, layer};
    if (callback) callback(std::move(event));
    else if (layer) CFRelease(layer);
  }
  void FailStart(std::string error) {
    if (state != ReceiverState::kStarting) return;
    tls.reset(); sockets.reset();
    if (agent) agent->UnregisterApplication(this);
    agent.reset(); credentials.reset(); peers.clear();
    state = ReceiverState::kFailed;
    Emit(std::move(error));
  }
  void Start(ReceiverConfig value);
  void Ready(cast::GeneratedCredentials value);
  void StopService(std::function<void()> completion);
  void FinishAsync();
  void TryFinishStop();
  void RetireMedia();
  void MaybeCreatePlayback();
  void DisposePlayback(ASPlaybackSession* old);
  void MediaError(std::string error);
  void Tick();

  const std::vector<std::string>& GetAppIds() const override { return app_ids; }
  bool Launch(const std::string& id, const Json::Value&, cast::MessagePort* port) override;
  std::string GetSessionId() override { return session ? session->session_id() : ""; }
  std::string GetDisplayName() override { return config.info.friendly_name; }
  std::vector<std::string> GetSupportedNamespaces() override { return {cast::kCastWebrtcNamespace}; }
  void Stop() override {
    bool had_media = session || audio || video || playback || creating_playback;
    RetireMedia();
    session.reset(); environment.reset();
    if (had_media && state != ReceiverState::kStopping && state != ReceiverState::kStopped) {
      state = ReceiverState::kListening;
      media_end_pending = true;
      if (!asynchronous) {
        media_end_pending = false;
        Emit(media_error.value_or(""));
      }
    }
  }
  bool SupportsCodecParameter(const std::string& parameter) override {
    return !parameter.starts_with("av01") || ReceiverSession::SupportsAv1Parameter(parameter);
  }
  void OnNegotiated(const OpenSession*, OpenSession::ConfiguredReceivers receivers) override;
  void OnReceiversDestroying(const OpenSession*, ReceiversDestroyingReason) override {
    RetireMedia();  // Renegotiation never tears down the listening service.
  }
  void OnError(const OpenSession*, const Error& error) override { MediaError(error.message()); }
  void OnConnected(cast::ReceiverSocketFactory* factory, const IPEndpoint& endpoint,
                   std::unique_ptr<cast::CastSocket> socket) override {
    std::erase_if(peers, [](const auto& pair) { return !pair.second.socket; });
    peers.emplace(socket->socket_id(), Peer{endpoint, socket->GetWeakPtr()});
    static_cast<cast::ReceiverSocketFactory::Client*>(agent.get())->OnConnected(
        factory, endpoint, std::move(socket));
  }
  void OnError(cast::ReceiverSocketFactory*, const Error& error) override {
    if (state == ReceiverState::kStarting) FailStart(error.message());
    // Failed peer authentication/acceptance does not stop an otherwise healthy listener.
  }
};

void ReceiverSession::Impl::Start(ReceiverConfig value) {
  CheckSequence();
  if (state != ReceiverState::kIdle && state != ReceiverState::kStopped &&
      state != ReceiverState::kFailed) return;
  config = std::move(value);
  ++service_generation;
  state = ReceiverState::kStarting;
  Emit();
  if (state != ReceiverState::kStarting) return;  // Reentrant Stop from event client.
  if (!config.info.IsValid() || config.display_width <= 0 || config.display_height <= 0 ||
      config.max_fps <= 0 || config.max_fps > 240 ||
      int64_t(config.display_width) * config.display_height > INT_MAX / config.max_fps) {
    FailStart("Invalid receiver identity, port or display constraints"); return;
  }
  interface.reset();
  if (config.interface_index) {
    for (const auto& item : openscreen::GetNetworkInterfaces())
      if (item.index == config.interface_index) interface = item;
    if (!interface || interface->addresses.empty()) {
      FailStart("Selected network interface is unavailable"); return;
    }
  }
  if (DecoderName(cast::VideoCodec::kVp8).empty() || DecoderName(cast::VideoCodec::kH264).empty() ||
      DecoderName(cast::AudioCodec::kOpus).empty() || DecoderName(cast::AudioCodec::kAac).empty()) {
    FailStart("This build lacks a required VP8, H.264, Opus or AAC receiver decoder"); return;
  }
  auto weak = weak_from_this();
  TaskRunner* task_runner = &runner;
  const uint64_t generation = service_generation;
  const ReceiverConfig snapshot = config;
  ++asynchronous;
  dispatch_async(worker, ^{
    auto result = std::make_shared<openscreen::ErrorOr<cast::GeneratedCredentials>>(Credentials(snapshot));
    task_runner->PostTask([weak, generation, result] {
      auto self = weak.lock();
      if (!self) return;
      if (self->service_generation == generation && self->state == ReceiverState::kStarting) {
        if (*result) self->Ready(std::move(result->value()));
        else self->FailStart(result->error().message());
      }
      self->FinishAsync();
    });
  });
}

void ReceiverSession::Impl::Ready(cast::GeneratedCredentials value) {
  credentials.emplace(std::move(value));
  agent = std::make_unique<cast::ApplicationAgent>(runner, *credentials->provider,
                                                  config.info.unique_id);
  agent->SetReceiverInfo(config.info);
  agent->RegisterApplication(this);
  sockets = std::make_unique<cast::ReceiverSocketFactory>(*this, *agent->cast_socket_client());
  tls = openscreen::TlsConnectionFactory::CreateFactory(*sockets, runner);
  Error error = tls->SetListenCredentials(credentials->tls_credentials);
  if (!error.ok()) { FailStart(error.message()); return; }
  std::vector<IPAddress> addresses;
  if (interface) {
    for (const auto& subnet : interface->addresses)
      if (std::find(addresses.begin(), addresses.end(), subnet.address) == addresses.end())
        addresses.push_back(subnet.address);
  } else addresses.push_back(IPAddress::kAnyV6());
  for (const auto& address : addresses) {
    error = tls->Listen({address, config.info.port}, {64});
    if (!error.ok()) { FailStart(error.message()); return; }
  }
  state = ReceiverState::kListening;
  Emit();  // All synchronous checked binds succeeded; root may now publish.
}

bool ReceiverSession::Impl::Launch(const std::string& id, const Json::Value&,
                                    cast::MessagePort* port) {
  if (!cast::IsCastStreamingAppId(id) || !port || session ||
      state != ReceiverState::kListening) return false;
  // ApplicationAgent always supplies its own CastSocketMessagePort. The socket
  // factory records structured peer endpoints before transferring sockets to it.
  auto* socket_port = static_cast<cast::CastSocketMessagePort*>(port);
  auto peer = peers.find(socket_port->GetSocketId());
  if (peer == peers.end()) return false;
  IPAddress local = peer->second.endpoint.address.IsV4() ? IPAddress::kAnyV4() : IPAddress::kAnyV6();
  if (interface) {
    auto candidate = std::find_if(interface->addresses.begin(), interface->addresses.end(),
        [&peer](const auto& subnet) {
          return subnet.address.version() == peer->second.endpoint.address.version() &&
              (subnet.address.IsV4() || subnet.address.IsLinkLocal() == peer->second.endpoint.address.IsLinkLocal());
        });
    if (candidate == interface->addresses.end()) return false;
    local = candidate->address;
  }
  environment = std::make_unique<cast::Environment>(&Clock::now, runner, IPEndpoint{local, 0});
  cast::ReceiverConstraints constraints;
  constraints.video_codecs.clear(); constraints.audio_codecs.clear();
  for (auto codec : {cast::VideoCodec::kVp8, cast::VideoCodec::kVp9, cast::VideoCodec::kH264})
    if (!DecoderName(codec).empty()) constraints.video_codecs.push_back(codec);
  if (config.enable_av1 && !DecoderName(cast::VideoCodec::kAv1).empty())
    constraints.video_codecs.push_back(cast::VideoCodec::kAv1);
  for (auto codec : {cast::AudioCodec::kOpus, cast::AudioCodec::kAac})
    if (!DecoderName(codec).empty()) constraints.audio_codecs.push_back(codec);
  constraints.display_description = std::make_unique<cast::Display>(cast::Display{
      {config.display_width, config.display_height, {config.max_fps, 1}}, true});
  constraints.remoting.reset();
  session = std::make_unique<OpenSession>(*this, *environment, *port, std::move(constraints));
  return true;
}

void ReceiverSession::Impl::OnNegotiated(const OpenSession*, OpenSession::ConfiguredReceivers r) {
  RetireMedia();
  media_end_pending = false;
  media_error.reset();
  if ((r.audio_receiver && DecoderName(r.audio_config.codec).empty()) ||
      (r.video_receiver && DecoderName(r.video_config.codec).empty())) {
    MediaError("Negotiation selected an unavailable decoder"); return;
  }
  if (r.audio_receiver)
    audio = std::make_shared<Track>(weak_from_this(), r.audio_receiver.get(), media_generation,
        false, DecoderName(r.audio_config.codec), kCMTimeInvalid);
  if (r.video_receiver) {
    auto fps = r.video_config.max_frame_rate;
    if (fps.numerator() <= 0 || fps.denominator() <= 0) {
      MediaError("Invalid negotiated video frame rate"); return;
    }
    video = std::make_shared<Track>(weak_from_this(), r.video_receiver.get(), media_generation,
        true, DecoderName(r.video_config.codec), CMTimeMake(fps.denominator(), fps.numerator()));
  }
  MaybeCreatePlayback();
}

void ReceiverSession::Impl::MaybeCreatePlayback() {
  if (creating_playback || asynchronous || playback || !session || (!audio && !video) ||
      (state != ReceiverState::kListening && state != ReceiverState::kStreaming)) return;
  creating_playback = true;
  ++asynchronous;
  auto weak = weak_from_this();
  TaskRunner* task_runner = &runner;
  uint64_t generation = media_generation;
  const auto limits = ReceiverSession::PlaybackLimits(audio != nullptr, video != nullptr,
      video ? video->duration : kCMTimeInvalid,
      audio ? audio->receiver->config().target_playout_delay : std::chrono::milliseconds{},
      video ? video->receiver->config().target_playout_delay : std::chrono::milliseconds{});
  const ASPlaybackConfig options = limits.playback;
  dispatch_async(dispatch_get_main_queue(), ^{
    ASPlaybackSession* native = ASPlaybackCreate(options);
    Clock::time_point before = Clock::now();
    CMTime host = CMClockGetTime(CMClockGetHostTimeClock());
    Clock::time_point origin = before + (Clock::now() - before) / 2;
    CFTypeRef layer = native ? ASPlaybackCopyVideoLayer(native) : nullptr;
    if (native) ASPlaybackSetAnchor(native, kCMTimeZero, host);
    task_runner->PostTask([weak, generation, native, layer, origin, limits] {
      auto self = weak.lock();
      OSP_DCHECK(self);  // Public owner retains the service through Stop completion.
      self->creating_playback = false;
      if (self->media_generation != generation || !self->session ||
          self->state == ReceiverState::kStopping) {
        if (layer) CFRelease(layer);
        if (native) self->DisposePlayback(native);
      } else if (!native) {
        self->MediaError("AVFoundation playback initialization failed");
      } else {
        self->playback = native;
        auto timeline = std::make_shared<ReceiverTimeline>(origin,
            self->audio ? self->audio->receiver->config().target_playout_delay : std::chrono::milliseconds{},
            self->video ? self->video->receiver->config().target_playout_delay : std::chrono::milliseconds{});
        if (self->audio) self->audio->Enable(timeline, 0);
        if (self->video) self->video->Enable(timeline, limits.video_buffers);
        self->state = ReceiverState::kStreaming;
        self->Tick();
        self->Emit({}, layer);
      }
      self->FinishAsync();
    });
  });
}

void ReceiverSession::Impl::DisposePlayback(ASPlaybackSession* old) {
  ++asynchronous;
  struct Context { std::weak_ptr<Impl> owner; TaskRunner* runner; ASPlaybackSession* native; };
  auto* context = new Context{weak_from_this(), &runner, old};
  ASPlaybackStop(old, [](void* opaque) {
    std::unique_ptr<Context> context(static_cast<Context*>(opaque));
    ASPlaybackDestroy(context->native);
    auto weak = context->owner;
    context->runner->PostTask([weak] { if (auto self = weak.lock()) self->FinishAsync(); });
  }, context);
}

void ReceiverSession::Impl::RetireMedia() {
  ++media_generation;
  maintenance.Cancel();
  auto decoders = std::make_shared<std::vector<std::shared_ptr<Decode>>>();
  for (auto* track : {&audio, &video}) {
    if (!*track) continue;
    (*track)->Detach();
    if ((*track)->decoder) decoders->push_back(std::move((*track)->decoder));
    track->reset();
  }
  if (!decoders->empty()) {
    ++asynchronous;
    auto weak = weak_from_this();
    TaskRunner* task_runner = &runner;
    dispatch_async(worker, ^{
      decoders->clear();  // Prior decode tasks completed; destroy on their owner.
      task_runner->PostTask([weak] { if (auto self = weak.lock()) self->FinishAsync(); });
    });
  }
  if (playback) {
    ASPlaybackSession* old = std::exchange(playback, nullptr);
    DisposePlayback(old);
  }
}

void ReceiverSession::Impl::MediaError(std::string error) {
  if (media_error || state == ReceiverState::kStopping || state == ReceiverState::kStopped) return;
  media_error = std::move(error);
  auto weak = weak_from_this();
  uint64_t generation = media_generation;
  runner.PostTask([weak, generation] {
    if (auto self = weak.lock(); self && self->media_generation == generation && self->agent) {
      self->agent->StopApplicationIfRunning(self.get());
    }
  });
}

void ReceiverSession::Impl::Tick() {
  if (!playback || state != ReceiverState::kStreaming) return;
  if (ASPlaybackGetStats(playback).state == ASPlaybackError) {
    MediaError("Native playback renderer failed"); return;
  }
  for (auto track : {audio, video}) {
    if (!track) continue;
    if (!track->pending.empty() && Clock::now() - track->pending.begin()->second.started >
        std::chrono::seconds(3)) {
      MediaError("Decoder made no progress within its bounded pipeline deadline"); return;
    }
    track->Resume();
  }
  auto weak = weak_from_this();
  uint64_t generation = media_generation;
  maintenance.ScheduleFromNow([weak, generation] {
    if (auto self = weak.lock(); self && self->media_generation == generation) self->Tick();
  }, std::chrono::milliseconds(100));
}

void ReceiverSession::Impl::StopService(std::function<void()> completion) {
  CheckSequence();
  if (completion) stop_completions.push_back(std::move(completion));
  if (state == ReceiverState::kStopping) return;
  if (state == ReceiverState::kStopped) { TryFinishStop(); return; }
  ++service_generation;
  state = ReceiverState::kStopping;
  media_end_pending = false;
  tls.reset(); sockets.reset();
  if (agent) agent->UnregisterApplication(this);
  Stop();
  agent.reset(); credentials.reset(); peers.clear();
  TryFinishStop();
}
void ReceiverSession::Impl::FinishAsync() {
  OSP_DCHECK(asynchronous > 0);
  --asynchronous;
  TryFinishStop();
  if (!asynchronous && media_end_pending && state == ReceiverState::kListening) {
    media_end_pending = false;
    Emit(media_error.value_or(""));
  }
  MaybeCreatePlayback();
}
void ReceiverSession::Impl::TryFinishStop() {
  if (asynchronous || (state != ReceiverState::kStopping && state != ReceiverState::kStopped)) return;
  if (state != ReceiverState::kStopped) {
    state = ReceiverState::kStopped;
    Emit();
  }
  auto callbacks = std::move(stop_completions);
  stop_completions.clear();
  for (auto& completion : callbacks) completion();
}

void ReceiverSession::Impl::Track::Enable(std::shared_ptr<ReceiverTimeline> timeline, size_t video_buffers) {
  auto service = owner.lock();
  if (!service || !receiver || codec.empty()) return;
  origin = timeline->origin();
  decoder = std::make_shared<Decode>(service->runner, weak_from_this(), codec, timeline, duration, video, video_buffers);
  receiver->SetConsumer(this);
  Resume();
}
void ReceiverSession::Impl::Track::Resume() {
  if (!receiver || !decoder || pending.size() >= kMaxDecodeFrames) return;
  auto size = receiver->AdvanceToNextFrame();
  if (size) OnFramesReady(*size);
}
void ReceiverSession::Impl::Track::OnFramesReady(size_t bytes) {
  auto service = owner.lock();
  if (!service || !receiver || !decoder || service->media_generation != generation ||
      pending.size() >= kMaxDecodeFrames) return;
  if (!bytes || bytes > kMaxEncodedBytes || bytes > INT_MAX - AV_INPUT_BUFFER_PADDING_SIZE) {
    service->MediaError("Encoded frame exceeds receiver budget"); return;
  }
  if (pending_bytes > kMaxEncodedBytes - bytes) return;
  auto buffer = std::make_shared<cast::Decoder::Buffer>();
  buffer->Resize(static_cast<int>(bytes));
  cast::EncodedFrame frame = receiver->ConsumeNextFrame(buffer->AsByteBuffer());
  Clock::time_point now = Clock::now();
  pending.emplace(frame.frame_id, Pending{bytes, now});
  pending_bytes += bytes;
  Decode::Metadata metadata{frame.reference_time, frame.rtp_timestamp,
                            receiver->config().rtp_timebase, frame.new_playout_delay};
  auto worker_decoder = decoder;
  const cast::FrameId id = frame.frame_id;
  dispatch_async(service->worker, ^{ worker_decoder->Input(id, *buffer, metadata); });
}
void ReceiverSession::Impl::Track::Complete(cast::FrameId id,
    std::shared_ptr<NativeSample> sample, std::string error, bool fatal, bool decode_error,
    bool discontinuity) {
  auto service = owner.lock();
  auto found = pending.find(id);
  if (!service || !receiver || service->media_generation != generation || found == pending.end()) return;
  processing = (processing * 7 + Clock::now() - found->second.started) / 8;
  pending_bytes -= found->second.bytes;
  pending.erase(found);
  receiver->SetPlayerProcessingTime(processing);
  if (fatal) { service->MediaError(std::move(error)); return; }
  if (!sample->value) {
    if (video && decode_error) receiver->RequestKeyFrame();
  } else if (service->playback) {
    if (discontinuity) {
      auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - origin);
      ASPlaybackSetAnchor(service->playback, CMTimeMake(elapsed.count(), 1000000),
                           CMClockGetTime(CMClockGetHostTimeClock()));
    }
    ASPlaybackResult result = ASPlaybackEnqueue(service->playback,
        video ? ASPlaybackVideo : ASPlaybackAudio, sample->value);
    // Decoded video is independent storage; a native queue drop does not discard
    // an encoded dependency chain. Audio drops whole sample buffers, leaving a gap.
    if (result == ASPlaybackFailed || result == ASPlaybackInvalidSample)
      service->MediaError("Native playback rejected decoded media");
  }
  Resume();
}

void ReceiverSession::Impl::Decode::Input(cast::FrameId id,
    const cast::Decoder::Buffer& data, Metadata timing) {
  metadata.emplace(id, timing);
  if (failed) Result(id, nullptr, "Decoder has failed", true);
  else decoder.Decode(id, data);
}
void ReceiverSession::Impl::Decode::Result(cast::FrameId id, CMSampleBufferRef sample,
                                          std::string error, bool fatal, bool decode_error,
                                          bool discontinuity) {
  metadata.erase(id);
  auto owned = std::make_shared<NativeSample>(sample);
  auto weak = track;
  runner.PostTask([weak, id, owned, error = std::move(error), fatal, decode_error, discontinuity] {
    if (auto target = weak.lock()) target->Complete(id, owned, error, fatal, decode_error, discontinuity);
  });
}
void ReceiverSession::Impl::Decode::OnFrameDecoded(cast::FrameId id, const AVFrame& frame) {
  auto found = metadata.find(id);
  if (found == metadata.end()) return;
  const Metadata& timing = found->second;
  auto point = timeline->Map(video, timing.rtp, timing.rtp_timebase,
                             timing.reference_time, timing.delay);
  // Invalid/stale targets are dropped without borrowing raw decoder timestamps.
  if (!point) {
    Result(id, nullptr, "Decoded frame has an invalid/stale target time", false); return;
  }
  CMTime pts = CMTimeMake(point->elapsed.count(), 1000000);
  std::string error;
  CMSampleBufferRef native = video ? converter.CopyVideo(frame, pts, video_duration, error)
                                  : converter.CopyAudio(frame, pts, error);
  bool fatal = !native && error != "native video pool backpressured";
  Result(id, native, std::move(error), fatal, false, point->discontinuity);
}
void ReceiverSession::Impl::Decode::OnDecodeError(cast::FrameId id, const std::string& error) {
  Result(id, nullptr, error, false, true);
}
void ReceiverSession::Impl::Decode::OnFatalError(const std::string& error) {
  failed = true;
  while (!metadata.empty()) Result(metadata.begin()->first, nullptr, error, true);
}

ReceiverSession::MediaLimits ReceiverSession::PlaybackLimits(bool audio, bool video,
    CMTime video_duration, std::chrono::milliseconds audio_delay,
    std::chrono::milliseconds video_delay) {
  // Count ceilings follow the negotiated startup horizon plus scheduling margin.
  // Retain the independent 64 MiB and 2 s ceilings: large frames still backpressure.
  const int64_t horizon = std::clamp<int64_t>(
      std::max(audio_delay.count(), video_delay.count()), 0, 1900) + 100;
  size_t video_buffers = 0;
  if (video && CMTIME_IS_NUMERIC(video_duration) && video_duration.value > 0 &&
      video_duration.timescale > 0) {
    const __int128 divisor = __int128(1000) * video_duration.value;
    const __int128 count = (__int128(horizon) * video_duration.timescale + divisor - 1) / divisor;
    video_buffers = static_cast<size_t>(std::min<__int128>(count + kMaxDecodeFrames, 512));
  }
  // Opus can carry 2.5 ms packets. AAC is coarser. Small PCM packets should consume
  // only their byte/time budget, not crowd healthy video out of 16 shared slots.
  const size_t audio_buffers = audio ? (horizon * 2 + 4) / 5 + kMaxDecodeFrames : 0;
  return {{video, audio, audio_buffers + video_buffers, kMaxDecodedBytes,
           CMTimeMake(2, 1), CMTimeMake(1, 30)}, video_buffers};
}
std::string ReceiverSession::VideoDecoderName(cast::VideoCodec codec) {
  return DecoderName(codec);
}

bool ReceiverSession::SupportsAv1Parameter(const std::string& parameter) {
  // AOM AV1 ISO binding: mandatory 4 fields, or all 10 fields with color metadata.
  // https://aomediacodec.github.io/av1-isobmff/#codecsparam
  std::vector<std::string_view> fields;
  if (parameter.empty() || parameter.back() == '.') return false;
  std::string_view rest(parameter);
  while (!rest.empty() && fields.size() <= 10) {
    const size_t dot = rest.find('.');
    fields.push_back(rest.substr(0, dot));
    if (dot == rest.npos) break;
    rest.remove_prefix(dot + 1);
  }
  auto number = [](std::string_view value) {
    if (value.size() != 2 || value[0] < '0' || value[0] > '9' ||
        value[1] < '0' || value[1] > '9') return -1;
    return (value[0] - '0') * 10 + value[1] - '0';
  };
  if ((fields.size() != 4 && fields.size() != 10) || fields[0] != "av01" ||
      fields[1] != "0" || fields[2].size() != 3 ||
      number(fields[2].substr(0, 2)) < 0 || number(fields[2].substr(0, 2)) > 23 ||
      (fields[2][2] != 'M' && fields[2][2] != 'H') || fields[3] != "08") return false;
  if (fields.size() == 4) return true;
  if (fields[4] != "0" || (fields[5] != "110" && fields[5] != "111" && fields[5] != "112") ||
      number(fields[6]) < 0 || number(fields[7]) < 0 || number(fields[8]) < 0 ||
      (fields[9] != "0" && fields[9] != "1")) return false;
  AVFrame color{};
  color.format = AV_PIX_FMT_YUV420P;
  color.color_primaries = static_cast<AVColorPrimaries>(number(fields[6]));
  color.color_trc = static_cast<AVColorTransferCharacteristic>(number(fields[7]));
  color.colorspace = static_cast<AVColorSpace>(number(fields[8]));
  color.color_range = fields[9] == "1" ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG;
  return DecodedMedia::SupportsVideoColor(color);
}

ReceiverSession::ReceiverSession(TaskRunner& runner, EventCallback callback)
    : impl_(std::make_shared<Impl>(runner, std::move(callback))) {}
ReceiverSession::~ReceiverSession() = default;
void ReceiverSession::Start(ReceiverConfig config) {
  auto self = impl_; self->Start(std::move(config));
}
void ReceiverSession::Stop(std::function<void()> completion) {
  auto self = impl_; self->StopService(std::move(completion));
}
void ReceiverSession::StopMedia(uint64_t generation) {
  auto self = impl_;
  self->CheckSequence();
  if (self->agent && self->media_generation == generation)
    self->agent->StopApplicationIfRunning(self.get());
}
void ReceiverSession::UpdateReceiverInfo(cast::ReceiverInfo info) {
  auto self = impl_;
  self->CheckSequence();
  if (!info.IsValid() || info.unique_id != self->config.info.unique_id ||
      info.port != self->config.info.port) return;
  self->config.info = std::move(info);
  if (self->agent) self->agent->SetReceiverInfo(self->config.info);
}
ReceiverState ReceiverSession::state() const { return impl_->state; }
uint16_t ReceiverSession::port() const { return impl_->config.info.port; }
}  // namespace applescreen

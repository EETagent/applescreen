#include "SenderSession.h"

#include <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>
#include <net/if.h>

#include <algorithm>
#include <cassert>
#include <cmath>
#include <deque>
#include <fstream>
#include <limits>
#include <mutex>
#include <utility>

extern "C" {
#include <libavutil/pixfmt.h>
#include <libswscale/swscale.h>
}

#include "cast/common/channel/cast_socket_message_port.h"
#include "cast/common/channel/connection_namespace_handler.h"
#include "cast/common/channel/message_util.h"
#include "cast/common/channel/virtual_connection_router.h"
#include "cast/common/public/cast_streaming_app_ids.h"
#include "cast/common/public/trust_store.h"
#include "cast/sender/public/sender_socket_factory.h"
#include "cast/standalone_sender/streaming_opus_encoder.h"
#include "cast/standalone_sender/streaming_vpx_encoder.h"
#ifdef CAST_STANDALONE_SENDER_HAVE_LIBAOM
#include "cast/standalone_sender/streaming_av1_encoder.h"
#endif
#include "cast/streaming/public/environment.h"
#include "cast/streaming/public/sender_session.h"
#include "platform/api/network_interface.h"
#include "platform/api/task_runner.h"
#include "platform/api/tls_connection_factory.h"
#include "util/alarm.h"
#include "util/json/json_helpers.h"

namespace applescreen {
namespace {
using namespace openscreen;
using namespace openscreen::cast;
using Session = NativeSenderSession;
constexpr size_t kVideoBudget = 2;
constexpr int kAudioBudget = 48000 / 5;
constexpr size_t kAudioBufferBudget = 32;
constexpr size_t kMaxPixelBytes = 64 * 1024 * 1024;

bool Supported(VideoCodec codec) {
  switch (codec) {
    case VideoCodec::kVp8:
    case VideoCodec::kVp9: return true;
#ifdef CAST_STANDALONE_SENDER_HAVE_LIBAOM
    case VideoCodec::kAv1: return true;
#endif
    default: return false;
  }
}

std::optional<int64_t> Microseconds(CMTime time) {
  if (!CMTIME_IS_NUMERIC(time) || time.timescale <= 0 || time.epoch != 0) return {};
  __int128 value = static_cast<__int128>(time.value) * 1'000'000 / time.timescale;
  if (value < INT64_MIN || value > INT64_MAX) return {};
  return static_cast<int64_t>(value);
}


std::unique_ptr<TrustStore> LoadTrust(const std::string& path, std::string& error) {
  if (path.empty()) return CastTrustStore::Create();
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  auto size = input ? input.tellg() : std::streampos{-1};
  if (size <= 0 || size > 1024 * 1024) {
    error = "The selected development CA is unreadable, empty, or too large.";
    return {};
  }
  std::string pem(static_cast<size_t>(size), '\0');
  input.seekg(0);
  if (!input.read(pem.data(), pem.size())) {
    error = "Cannot read the selected development CA.";
    return {};
  }
  auto trust = TrustStore::CreateInstanceFromPem(pem);
  if (trust.is_error()) {
    error = "Invalid development CA: " + trust.error().message();
    return {};
  }
  return std::move(trust.value());
}

struct Converted {
  Session::Track track;
  int samples = 0;
  std::vector<uint8_t> video;
  std::vector<float> audio;
  CMTime host_time, duration;
  Clock::time_point measured_capture;
  std::string error;
};

bool AudioFormat(CMSampleBufferRef sample, const Session::Config& config, int& frames) {
  auto description = CMSampleBufferGetFormatDescription(sample);
  const auto* format = description ? CMAudioFormatDescriptionGetStreamBasicDescription(description) : nullptr;
  CMItemCount count = CMSampleBufferGetNumSamples(sample);
  if (!format || count <= 0 || count > kAudioBudget || format->mFormatID != kAudioFormatLinearPCM ||
      !(format->mFormatFlags & kAudioFormatFlagIsFloat) || !(format->mFormatFlags & kAudioFormatFlagIsPacked) ||
      (format->mFormatFlags & (kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian)) ||
      format->mBitsPerChannel != 32 || format->mChannelsPerFrame != static_cast<unsigned>(config.channels) ||
      format->mSampleRate != config.sample_rate || format->mBytesPerFrame != config.channels * sizeof(float) ||
      CMSampleBufferGetTotalSampleSize(sample) != static_cast<size_t>(count) * format->mBytesPerFrame) return false;
  frames = static_cast<int>(count);
  return CMSampleBufferGetDataBuffer(sample) != nullptr;
}

bool VideoFormat(CVPixelBufferRef pixels) {
  if (!pixels) return false;
  size_t width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels);
  if (width < 2 || height < 2 || width > 8192 || height > 8192 ||
      CVPixelBufferGetDataSize(pixels) > kMaxPixelBytes) return false;
  switch (CVPixelBufferGetPixelFormatType(pixels)) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_420YpCbCr8Planar:
    case kCVPixelFormatType_32BGRA: return true;
    default: return false;
  }
}

bool ConvertVideo(CVPixelBufferRef pixels, const Session::Negotiated& target,
                  SwsContext*& scaler, std::vector<uint8_t>& output) {
  if (CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return false;
  struct Unlock { CVPixelBufferRef pixels; ~Unlock() { CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly); } } unlock{pixels};
  int width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels);
  OSType type = CVPixelBufferGetPixelFormatType(pixels);
  AVPixelFormat format = type == kCVPixelFormatType_32BGRA ? AV_PIX_FMT_BGRA :
      type == kCVPixelFormatType_420YpCbCr8Planar ? AV_PIX_FMT_YUV420P : AV_PIX_FMT_NV12;
  int planes = format == AV_PIX_FMT_BGRA ? 1 : format == AV_PIX_FMT_NV12 ? 2 : 3;
  if (planes > 1 && CVPixelBufferGetPlaneCount(pixels) != static_cast<size_t>(planes)) return false;
  const uint8_t* input[4]{};
  int strides[4]{};
  size_t total = 0;
  for (int plane = 0; plane < planes; ++plane) {
    size_t rows = plane ? (height + 1) / 2 : height;
    size_t columns = plane ? (width + 1) / 2 : width;
    if (format == AV_PIX_FMT_BGRA) columns *= 4;
    if (plane && format == AV_PIX_FMT_NV12) columns *= 2;
    size_t stride = planes > 1 ? CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) : CVPixelBufferGetBytesPerRow(pixels);
    input[plane] = static_cast<uint8_t*>(planes > 1 ? CVPixelBufferGetBaseAddressOfPlane(pixels, plane) : CVPixelBufferGetBaseAddress(pixels));
    if (!input[plane] || stride < columns || stride > INT_MAX || rows > kMaxPixelBytes / stride ||
        (planes > 1 && CVPixelBufferGetHeightOfPlane(pixels, plane) < rows)) return false;
    total += stride * rows;
    strides[plane] = static_cast<int>(stride);
  }
  if (total > CVPixelBufferGetDataSize(pixels)) return false;
  const CGRect clean = CVImageBufferGetCleanRect(pixels);
  const CGSize display = CVImageBufferGetDisplaySize(pixels);
  const double coordinates[] = {clean.origin.x, clean.origin.y, clean.size.width, clean.size.height};
  for (double value : coordinates)
    if (!std::isfinite(value) || value != std::floor(value) || value < 0 || value > 8192) return false;
  const int crop_x = clean.origin.x, crop_y = clean.origin.y;
  if (clean.size.width < 2 || clean.size.height < 2 || crop_x + clean.size.width > width ||
      crop_y + clean.size.height > height || (format != AV_PIX_FMT_BGRA && ((crop_x | crop_y) & 1)) ||
      !std::isfinite(display.width) || !std::isfinite(display.height) || display.width <= 0 || display.height <= 0)
    return false;
  // Core Video's display size includes clean aperture and pixel aspect ratio.
  // Cropping changes plane origins; scaling applies display aspect exactly once.
  const double aspect = display.width / display.height;
  if (!std::isfinite(aspect) || aspect < 1.0 / 8192 || aspect > 8192) return false;
  width = clean.size.width; height = clean.size.height;
  input[0] += crop_y * strides[0] + crop_x * (format == AV_PIX_FMT_BGRA ? 4 : 1);
  for (int plane = 1; plane < planes; ++plane)
    input[plane] += (crop_y / 2) * strides[plane] + (crop_x / 2) * (format == AV_PIX_FMT_NV12 ? 2 : 1);
  auto primaries = CVBufferCopyAttachment(pixels, kCVImageBufferColorPrimariesKey, nullptr);
  const bool unsupported_gamut = primaries && !CFEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_709_2) &&
      !CFEqual(primaries, kCVImageBufferColorPrimaries_SMPTE_C) && !CFEqual(primaries, kCVImageBufferColorPrimaries_EBU_3213);
  if (primaries) CFRelease(primaries);
  if (unsupported_gamut) return false;  // No unimplemented P3/2020 gamut mapping.
  auto transfer = CVBufferCopyAttachment(pixels, kCVImageBufferTransferFunctionKey, nullptr);
  bool hdr = transfer && (CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) ||
                          CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG));
  if (transfer) CFRelease(transfer);
  if (hdr) return false;
  int matrix = SWS_CS_ITU601;
  auto attachment = CVBufferCopyAttachment(pixels, kCVImageBufferYCbCrMatrixKey, nullptr);
  if (attachment) {
    if (CFEqual(attachment, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) matrix = SWS_CS_ITU709;
    else if (!CFEqual(attachment, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) { CFRelease(attachment); return false; }
    CFRelease(attachment);
  }
  // Preserve aspect on source changes by letterboxing within negotiated bounds.
  int visible_width = target.width;
  int visible_height = static_cast<int>(visible_width / aspect) & ~1;
  if (visible_height > target.height) {
    visible_height = target.height;
    visible_width = static_cast<int>(visible_height * aspect) & ~1;
  }
  if (visible_width < 2 || visible_height < 2) return false;
  scaler = sws_getCachedContext(scaler, width, height, format, visible_width, visible_height,
                               AV_PIX_FMT_YUV420P, SWS_BILINEAR, nullptr, nullptr, nullptr);
  if (!scaler) return false;
  bool full_range = type == kCVPixelFormatType_32BGRA || type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  // These sample encoders do not expose color signalling; use the receiver's
  // documented unspecified-SDR fallback (limited-range 601) deliberately.
  if (sws_setColorspaceDetails(scaler, sws_getCoefficients(matrix), full_range,
      sws_getCoefficients(SWS_CS_ITU601), 0, 0, 1 << 16, 1 << 16) < 0) return false;
  size_t luma = static_cast<size_t>(target.width) * target.height;
  output.assign(luma + luma / 2, 128);
  std::fill_n(output.begin(), luma, 16);
  int x = ((target.width - visible_width) / 2) & ~1, y = ((target.height - visible_height) / 2) & ~1;
  uint8_t* destination[4] = {output.data() + y * target.width + x,
      output.data() + luma + (y / 2) * (target.width / 2) + x / 2,
      output.data() + luma + luma / 4 + (y / 2) * (target.width / 2) + x / 2, nullptr};
  int destination_strides[4] = {target.width, target.width / 2, target.width / 2, 0};
  return sws_scale(scaler, input, strides, 0, height, destination, destination_strides) == visible_height;
}
}  // namespace

std::optional<IPEndpoint> NativeSenderSession::SelectLocalEndpoint(
    const IPEndpoint& remote, const std::string& name, std::span<const InterfaceInfo> interfaces) {
  if (name.empty()) return IPEndpoint{remote.address.IsV6() ? IPAddress::kAnyV6() : IPAddress::kAnyV4(), 0};
  for (const auto& interface : interfaces) {
    if (interface.name != name) continue;
    for (const auto& subnet : interface.addresses) {
      if (subnet.address.version() != remote.address.version()) continue;
      if (remote.address.IsLinkLocal() &&
          (remote.address.GetScopeId() != static_cast<uint32_t>(interface.index) || !subnet.address.IsLinkLocal())) continue;
      if (!remote.address.IsLinkLocal() && subnet.address.IsLinkLocal()) continue;
      return IPEndpoint{subnet.address, 0};
    }
  }
  return {};
}

std::optional<std::string> NativeSenderSession::ValidateConfig(const Config& config) {
  if (!config.video && !config.audio) return "The source has no audio or video track.";
  if (!config.interface_name.empty() && !if_nametoindex(config.interface_name.c_str())) return "The selected network interface is invalid.";
  int minimum_bitrate = (config.video ? 300'000 : 0) + (config.audio ? 192'000 : 0);
  if (config.max_bitrate < minimum_bitrate || config.max_bitrate > 100'000'000) return "The bitrate is outside the supported range.";
  if (config.video && (!Supported(config.codec) || config.width < 2 || config.height < 2 ||
      config.width > 8192 || config.height > 8192 || config.fps_numerator <= 0 || config.fps_denominator <= 0 ||
      int64_t(config.fps_numerator) > 240LL * config.fps_denominator ||
      int64_t(config.width) * config.height * 3 / 2 > static_cast<int64_t>(kMaxPixelBytes))) return "Unsupported video codec, dimensions, or frame rate.";
  if (config.audio && (config.sample_rate != 48000 || (config.channels != 1 && config.channels != 2)))
    return "Audio must be normalized to 48 kHz mono or stereo Float32.";
  return {};
}

struct NativeSenderSession::State : std::enable_shared_from_this<State>,
    SenderSocketFactory::Client, VirtualConnectionRouter::SocketErrorHandler,
    ConnectionNamespaceHandler::VirtualConnectionPolicy, CastMessageHandler, SenderSession::Client,
    Environment::SocketSubscriber {
  enum class Phase { Idle, Connecting, Launching, Negotiating, Ready, Draining, Stopping, Stopped };
  State(TaskRunner& runner, Config config, Ready ready, Terminal terminal)
      : runner(runner), config(std::move(config)), ready(std::move(ready)), terminal(std::move(terminal)),
        deadline(&Clock::now, runner), attempt_deadline(&Clock::now, runner), congestion(&Clock::now, runner), audio_pump(&Clock::now, runner),
        conversion(dispatch_queue_create("app.applescreen.sender.convert", DISPATCH_QUEUE_SERIAL)) {}

  TaskRunner& runner;
  const Config config;
  Ready ready;
  Terminal terminal;
  Phase phase = Phase::Idle;
  std::shared_ptr<State> active_lifetime;
  std::optional<std::string> failure;
  std::vector<IPEndpoint> candidates;
  size_t candidate_index = 0;
  IPEndpoint endpoint, local_endpoint;
  std::unique_ptr<VirtualConnectionRouter> router;
  std::unique_ptr<ConnectionNamespaceHandler> connections;
  std::unique_ptr<SenderSocketFactory> sockets;
  std::unique_ptr<TlsConnectionFactory> tls;
  std::unique_ptr<CastSocketMessagePort> port;
  std::optional<VirtualConnection> platform_connection, app_connection;
  std::string app_session;
  std::unique_ptr<Environment> environment;
  std::unique_ptr<SenderSession> session;
  std::unique_ptr<StreamingVideoEncoder> video;
  std::unique_ptr<StreamingOpusEncoder> audio;
  Sender* video_sender = nullptr;  // Owned by its encoder; protocol sequence only.
  Sender* audio_sender = nullptr;
  Negotiated negotiated;
  Alarm deadline, attempt_deadline, congestion, audio_pump;
  int request_id = 0, bitrate = 0, video_bitrate_limit = 0;
  CMTime host_anchor = kCMTimeInvalid;
  Clock::time_point clock_anchor;
  std::optional<Clock::time_point> next_video_reference;
  std::optional<Clock::time_point> final_playout;
  bool media_drained = false, protocol_done = false;
  bool input_drained = false, audio_flushed = false;
  struct PendingAudio { Converted frame; int consumed = 0; };
  std::deque<PendingAudio> pending_audio;
  dispatch_queue_t conversion;
  SwsContext* scaler = nullptr;  // Conversion queue only; released at its stop barrier.
  std::mutex admission_mutex;
  Submission admission = Submission::NotReady;
  bool discard_media = false;  // Admission mutex; EOF closes admission without canceling.
  size_t video_pending = 0;
  size_t audio_buffers_pending = 0;
  int audio_pending = 0;

  const char* AppId() const { return config.video ? GetCastStreamingAudioVideoAppId() : GetCastStreamingAudioOnlyAppId(); }
  void Start(std::vector<IPEndpoint> values) {
    assert(runner.IsRunningOnTaskRunner());
    if (phase != Phase::Idle) return;
    active_lifetime = shared_from_this();
    if (auto error = ValidateConfig(config)) return Fail(*error);
    for (const auto& value : values)
      if (value.port && value.address && (!value.address.IsLinkLocal() || value.address.GetScopeId()) &&
          std::find(candidates.begin(), candidates.end(), value) == candidates.end() && candidates.size() < 8)
        candidates.push_back(value);
    if (candidates.empty()) return Fail("No usable receiver addresses were resolved.");
    std::string error;
    auto trust = LoadTrust(config.developer_ca_path, error);
    if (!trust) return Fail(std::move(error));
    router = std::make_unique<VirtualConnectionRouter>();
    connections = std::make_unique<ConnectionNamespaceHandler>(*router, *this);
    port = std::make_unique<CastSocketMessagePort>(*router);
    sockets = std::make_unique<SenderSocketFactory>(*this, runner, std::move(trust), CastCRLTrustStore::Create());
    tls = TlsConnectionFactory::CreateFactory(*sockets, runner);
    sockets->set_factory(tls.get());
    router->AddHandlerForLocalId(kPlatformSenderId, this);
    phase = Phase::Connecting;
    auto weak = weak_from_this();
    deadline.ScheduleFromNow([weak] { if (auto self = weak.lock()) self->Fail("Cast startup timed out."); }, std::chrono::seconds(15));
    ConnectNext();
  }
  void ConnectNext() {
    while (candidate_index < candidates.size()) {
      endpoint = candidates[candidate_index++];
      auto local = SelectLocalEndpoint(endpoint, config.interface_name, GetNetworkInterfaces());
      if (!local) continue;
      local_endpoint = *local;
      auto weak = weak_from_this();
      attempt_deadline.ScheduleFromNow([weak] {
        if (auto self = weak.lock(); self && self->phase == Phase::Connecting) self->ConnectNext();
      }, std::chrono::seconds(3));
      sockets->Connect(endpoint, config.video ? SenderSocketFactory::DeviceMediaPolicy::kIncludesVideo :
                                               SenderSocketFactory::DeviceMediaPolicy::kAudioOnly, router.get());
      return;
    }
    Fail("The receiver cannot be reached on the selected interface/address candidates.");
  }
  void OnConnected(SenderSocketFactory*, const IPEndpoint& connected, std::unique_ptr<CastSocket> socket) override {
    if (phase != Phase::Connecting || connected != endpoint) return;
    attempt_deadline.Cancel();
    port->SetSocket(socket->GetWeakPtr());
    router->TakeSocket(this, std::move(socket));
    phase = Phase::Launching;
    platform_connection = VirtualConnection{kPlatformSenderId, kPlatformReceiverId, port->GetSocketId()};
    auto weak = weak_from_this();
    connections->OpenRemoteConnection(*platform_connection, [weak](bool success) {
      auto self = weak.lock();
      if (!self || self->phase != Phase::Launching) return;
      if (!success) return self->Fail("Cannot open the Cast platform channel.");
      Json::Value message;
      message["type"] = "LAUNCH";
      message["requestId"] = ++self->request_id;
      message["appId"] = self->AppId();
      message["language"] = "en-US";
      message["supportedAppTypes"].append("WEB");
      auto json = openscreen::json::Stringify(message);
      if (json.is_error()) return self->Fail("Cannot serialize the Cast launch request.");
      auto error = self->router->Send(*self->platform_connection, MakeSimpleUTF8Message(kReceiverNamespace, json.value()));
      if (!error.ok()) self->Fail(error.message());
    });
  }
  void OnError(SenderSocketFactory*, const IPEndpoint& failed, const Error& error) override {
    if (phase != Phase::Connecting || failed != endpoint) return;
    attempt_deadline.Cancel();
    if (candidate_index < candidates.size()) ConnectNext();
    else Fail("Cast connection/authentication failed: " + error.message());
  }
  void OnClose(CastSocket*) override {
    if (phase == Phase::Stopped) return;
    protocol_done = true;
    if (phase != Phase::Stopping) Stop();
    ProtocolDone();
  }
  void OnError(CastSocket*, const Error& error) override {
    if (phase == Phase::Stopped) return;
    protocol_done = true;
    if (phase != Phase::Stopping) Fail("Cast transport failed: " + error.message());
    ProtocolDone();
  }
  bool IsConnectionAllowed(const VirtualConnection& connection) const override {
    return phase != Phase::Stopping && phase != Phase::Stopped && port && connection.socket_id == port->GetSocketId();
  }
  void OnMessage(VirtualConnectionRouter*, CastSocket* socket, proto::CastMessage message) override {
    if (!port || ToCastSocketId(socket) != port->GetSocketId() || message.namespace_() != kReceiverNamespace ||
        message.payload_type() != proto::CastMessage::STRING ||
        (message.destination_id() != kPlatformSenderId && message.destination_id() != kBroadcastId)) return;
    auto payload = openscreen::json::Parse(GetPayload(message));
    if (payload.is_error() || !payload.value().isObject()) return;
    if (HasType(payload.value(), CastMessageType::kLaunchError)) return Fail("The receiver could not launch the streaming app.");
    if (!HasType(payload.value(), CastMessageType::kReceiverStatus)) return;
    const auto& status = payload.value()["status"];
    if (!status.isObject()) return Fail("Invalid Cast receiver status.");
    const auto& applications = status["applications"];
    if (!applications.isNull() && !applications.isArray()) return Fail("Invalid Cast application list.");
    const Json::Value* current = nullptr;
    if (applications.isArray()) for (const auto& application : applications)
      if (application.isObject() && application["appId"].isString() && application["appId"].asString() == AppId()) { current = &application; break; }
    if (!current) {
      if (!app_session.empty()) { protocol_done = true; if (phase != Phase::Stopping) Stop(); ProtocolDone(); }
      return;
    }
    if (phase == Phase::Stopping || phase == Phase::Stopped) return;
    if (!(*current)["sessionId"].isString() || !(*current)["transportId"].isString()) return Fail("The receiver returned incomplete streaming application details.");
    auto id = (*current)["sessionId"].asString(), destination = (*current)["transportId"].asString();
    if (id.empty() || destination.empty()) return Fail("The receiver returned empty streaming application details.");
    if (!app_session.empty() && app_session != id) return Fail("The receiver replaced the active streaming session.");
    app_session = id;
    if (app_connection) return;
    app_connection = VirtualConnection{MakeUniqueSessionId("applescreen"), destination, port->GetSocketId()};
    auto weak = weak_from_this();
    connections->OpenRemoteConnection(*app_connection, [weak](bool success) {
      auto self = weak.lock();
      if (!self || self->phase != Phase::Launching) return;
      if (!success) return self->Fail("Cannot open the Cast streaming channel.");
      self->Negotiate();
    });
  }
  void Negotiate() {
    phase = Phase::Negotiating;
    environment = std::make_unique<Environment>(&Clock::now, runner, local_endpoint);
    environment->SetSocketSubscriber(this);
    if (environment->socket_state() == Environment::SocketState::kReady) OnSocketReady();
    else if (environment->socket_state() == Environment::SocketState::kInvalid) Fail("The local media socket could not bind.");
  }
  void OnSocketInvalid(const Error& error) override { Fail("Local media socket failed: " + error.message()); }
  void OnSocketReady() override {
    if (phase != Phase::Negotiating || session) return;
    session = std::make_unique<SenderSession>(SenderSession::Configuration{
        endpoint.address, *this, environment.get(), port.get(), app_connection->local_id, app_connection->peer_id,
        true, false, {}, {}});
    std::vector<AudioCaptureConfig> audio_offers;
    std::vector<VideoCaptureConfig> video_offers;
    if (config.audio) {
      AudioCaptureConfig offer;
      offer.channels = config.channels;
      offer.sample_rate = config.sample_rate;
      offer.bit_rate = 192'000;
      audio_offers.push_back(offer);
    }
    if (config.video) {
      VideoCaptureConfig offer;
      offer.codec = config.codec;
      offer.max_frame_rate = {config.fps_numerator, config.fps_denominator};
      offer.max_bit_rate = config.max_bitrate - (config.audio ? 192'000 : 0);
      // The upstream Cast offer has a 320x240 minimum, while native input can
      // be smaller. The one conversion stage scales/letterboxes into this canvas.
      offer.resolutions.push_back({std::max(config.width, kMinVideoWidth),
                                   std::max(config.height, kMinVideoHeight)});
      video_offers.push_back(offer);
    }
    auto error = session->Negotiate(std::move(audio_offers), std::move(video_offers));
    if (!error.ok()) Fail("Cast negotiation failed: " + error.message());
  }
  void OnNegotiated(const SenderSession*, SenderSession::ConfiguredSenders senders,
                    capture_recommendations::Recommendations recommendations) override {
    if (phase != Phase::Negotiating) return;
    if (bool(senders.video_sender) != config.video || bool(senders.audio_sender) != config.audio)
      return Fail("The receiver did not negotiate all source tracks.");
    negotiated.video = config.video;
    negotiated.audio = config.audio;
    if (config.audio) {
      if (senders.audio_config.codec != AudioCodec::kOpus || senders.audio_config.channels != config.channels ||
          senders.audio_config.sample_rate != config.sample_rate || config.channels > recommendations.audio.max_channels ||
          config.sample_rate > recommendations.audio.max_sample_rate || config.sample_rate < recommendations.audio.min_sample_rate)
        return Fail("Unsupported negotiated audio format.");
      negotiated.channels = config.channels;
      negotiated.sample_rate = config.sample_rate;
      audio_sender = senders.audio_sender.get();
      audio = std::make_unique<StreamingOpusEncoder>(config.channels, 100, std::move(senders.audio_sender));
    }
    if (config.video) {
      if (!Supported(senders.video_config.codec)) return Fail("The receiver selected an unavailable video encoder.");
      const auto& maximum = recommendations.video.maximum;
      const int canvas_width = std::max(config.width, kMinVideoWidth);
      const int canvas_height = std::max(config.height, kMinVideoHeight);
      int width = std::min(canvas_width, maximum.width), height = static_cast<int>(int64_t(canvas_height) * width / canvas_width);
      if (height > maximum.height) { height = maximum.height; width = static_cast<int>(int64_t(canvas_width) * height / canvas_height); }
      negotiated.width = width & ~1;
      negotiated.height = height & ~1;
      auto fps = senders.video_config.max_frame_rate;
      if (static_cast<double>(maximum.frame_rate) > 0 && static_cast<double>(maximum.frame_rate) < static_cast<double>(fps)) fps = maximum.frame_rate;
      if (negotiated.width < 2 || negotiated.height < 2 || !fps.is_positive() || !fps.numerator()) return Fail("Invalid negotiated video capture limits.");
      int pixels = negotiated.width * negotiated.height;
      if (recommendations.video.max_pixels_per_second <= 0) return Fail("Invalid receiver pixel rate limit.");
      if (int64_t(pixels) * fps.numerator() > int64_t(recommendations.video.max_pixels_per_second) * fps.denominator()) {
        const double scale = std::sqrt(double(recommendations.video.max_pixels_per_second) * fps.denominator() /
                                      (double(pixels) * fps.numerator()));
        negotiated.width = std::max(2, static_cast<int>(negotiated.width * scale) & ~1);
        negotiated.height = std::max(2, static_cast<int>(negotiated.height * scale) & ~1);
        pixels = negotiated.width * negotiated.height;
        if (int64_t(pixels) * fps.numerator() > int64_t(recommendations.video.max_pixels_per_second) * fps.denominator())
          fps = SimpleFraction(recommendations.video.max_pixels_per_second, pixels);
      }
      video_bitrate_limit = recommendations.video.bit_rate_limits.maximum;
      if (video_bitrate_limit <= 0) return Fail("Invalid receiver bitrate limit.");
      negotiated.fps_numerator = fps.numerator();
      negotiated.fps_denominator = fps.denominator();
      negotiated.codec = senders.video_config.codec;
      StreamingVideoEncoder::Parameters parameters;
      parameters.codec = negotiated.codec;
      video_sender = senders.video_sender.get();
#ifdef CAST_STANDALONE_SENDER_HAVE_LIBAOM
      if (negotiated.codec == VideoCodec::kAv1)
        video = std::make_unique<StreamingAv1Encoder>(parameters, runner, std::move(senders.video_sender));
      else
#endif
        video = std::make_unique<StreamingVpxEncoder>(parameters, runner, std::move(senders.video_sender));
    }
    auto before = Clock::now();
    host_anchor = CMClockGetTime(CMClockGetHostTimeClock());
    clock_anchor = before + (Clock::now() - before) / 2;
    deadline.Cancel();
    attempt_deadline.Cancel();
    phase = Phase::Ready;
    bitrate = config.max_bitrate;
    AdjustBitrate();
    { std::lock_guard lock(admission_mutex); admission = Submission::Accepted; }
    if (ready) ready(negotiated);
  }
  void OnError(const SenderSession*, const Error& error) override { Fail("Cast session failed: " + error.message()); }
  void AdjustBitrate() {
    if (phase != Phase::Ready) return;
    int estimate = session->GetEstimatedNetworkBandwidth();
    if (estimate > 0) bitrate = std::min(config.max_bitrate, std::max(300'000, std::min(bitrate + bitrate / 10, estimate - estimate / 5)));
    if (audio) { if (bitrate > 2'000'000) audio->UseHighQuality(); else audio->UseStandardQuality(); }
    if (video) video->SetTargetBitrate(std::max(1000, std::min(video_bitrate_limit, bitrate - (audio ? audio->GetBitrate() : 0))));
    auto weak = weak_from_this();
    congestion.ScheduleFromNow([weak] { if (auto self = weak.lock()) self->AdjustBitrate(); }, std::chrono::milliseconds(500));
  }
  void Fail(std::string error) {
    if (phase == Phase::Stopping || phase == Phase::Stopped) return;
    failure = std::move(error);
    Stop();
  }
  void FinishInput() {
    assert(runner.IsRunningOnTaskRunner());
    if (phase == Phase::Draining || phase == Phase::Stopping || phase == Phase::Stopped) return;
    if (phase != Phase::Ready) return Stop();
    phase = Phase::Draining;
    { std::lock_guard lock(admission_mutex); admission = Submission::Stopped; }
    congestion.Cancel();
    auto weak = weak_from_this();
    deadline.ScheduleFromNow([weak] {
      if (auto self = weak.lock()) self->Fail("Timed out draining the final Cast media.");
    }, std::chrono::seconds(5));
    auto self = shared_from_this();
    // Admission and dispatch enqueue share one lock, so this barrier follows
    // every accepted sample. Their Consume tasks are ahead of this task too.
    dispatch_async(conversion, ^{
      self->runner.PostTask([self] {
        if (self->phase != Phase::Draining) return;
        self->input_drained = true;
        self->Drain();
      });
    });
  }
  void Drain() {
    if (phase != Phase::Draining) return;
    if (input_drained && pending_audio.empty() && !audio_flushed) {
      if (audio) audio->Flush();
      audio_flushed = true;
    }
    const bool pending = !input_drained || !pending_audio.empty() || (video && video->pending_frames()) ||
        (video_sender && video_sender->GetInFlightFrameCount()) ||
        (audio_sender && audio_sender->GetInFlightFrameCount());
    // Receipt/expiry is not physical presentation. The final presentation time
    // is an estimate from source timing + negotiated delay, with 20 ms for the
    // Opus tail. Keep transport alive until both this time and packet drain.
    if (!pending && (!final_playout || Clock::now() >= *final_playout)) return Stop();
    auto weak = weak_from_this();
    attempt_deadline.ScheduleFromNow([weak] {
      if (auto self = weak.lock()) self->Drain();
    }, std::chrono::milliseconds(10));
  }
  void Stop() {
    assert(runner.IsRunningOnTaskRunner());
    if (phase == Phase::Stopping || phase == Phase::Stopped) return;
    phase = Phase::Stopping;
    { std::lock_guard lock(admission_mutex); admission = Submission::Stopped; discard_media = true; }
    ready = {};
    deadline.Cancel();
    video_sender = audio_sender = nullptr;
    attempt_deadline.Cancel();
    congestion.Cancel();
    audio_pump.Cancel();
    for (const auto& queued : pending_audio) Release(Track::Audio, queued.frame.samples);
    pending_audio.clear();
    auto self = shared_from_this();
    dispatch_async(conversion, ^{
      sws_freeContext(self->scaler);
      self->scaler = nullptr;
      self->runner.PostTask([self] { self->media_drained = true; self->Cleanup(); });
    });
    if (!protocol_done && !app_session.empty() && platform_connection && port && port->GetSocketId() != ToCastSocketId(nullptr)) {
      Json::Value message;
      message["type"] = "STOP";
      message["requestId"] = ++request_id;
      message["sessionId"] = app_session;
      auto json = openscreen::json::Stringify(message);
      if (!json.is_error() && router->Send(*platform_connection, MakeSimpleUTF8Message(kReceiverNamespace, json.value())).ok() && !protocol_done) {
        auto weak = weak_from_this();
        deadline.ScheduleFromNow([weak] { if (auto owner = weak.lock()) owner->ProtocolDone(); }, std::chrono::milliseconds(500));
        return;
      }
    }
    ProtocolDone();
  }
  void ProtocolDone() {
    protocol_done = true;
    deadline.Cancel();
    auto weak = weak_from_this();
    runner.PostTask([weak] { if (auto self = weak.lock()) self->Cleanup(); });
  }
  void Cleanup() {
    if (phase != Phase::Stopping || !media_drained || !protocol_done) return;
    // Enter the terminal state before a CLOSE can synchronously re-enter us.
    phase = Phase::Stopped;
    deadline.Cancel();
    video.reset();
    audio.reset();
    session.reset();
    if (environment) environment->SetSocketSubscriber(nullptr);
    environment.reset();
    auto remote = std::exchange(app_connection, {}), platform = std::exchange(platform_connection, {});
    if (remote) connections->CloseRemoteConnection(*remote);
    if (platform) connections->CloseRemoteConnection(*platform);
    if (port) {
      int socket = port->GetSocketId();
      port->SetSocket({});
      if (socket != ToCastSocketId(nullptr)) router->CloseSocket(socket);
    }
    port.reset();
    sockets.reset();
    tls.reset();
    connections.reset();
    router.reset();
    // Encoder completions and transport deferred deletions queued during teardown
    // run on the still-live runner before the one terminal callback.
    auto self = shared_from_this();
    runner.PostTask([self] {
      self->runner.PostTask([self] {
        auto callback = std::move(self->terminal);
        if (callback) callback(self->failure);
        self->active_lifetime.reset();
      });
    });
  }
  std::optional<Clock::time_point> Reference(CMTime host_time) const {
    auto offset = Microseconds(CMTimeSubtract(host_time, host_anchor));
    if (!offset) return {};
    __int128 ticks = static_cast<__int128>(clock_anchor.time_since_epoch().count()) + *offset;
    if (ticks < INT64_MIN || ticks > INT64_MAX) return {};
    return Clock::time_point(Clock::duration(static_cast<int64_t>(ticks)));
  }
  void Release(Track track, int samples) {
    std::lock_guard lock(admission_mutex);
    if (track == Track::Video) --video_pending;
    else { audio_pending -= samples; --audio_buffers_pending; }
  }
  void PumpAudio() {
    if ((phase != Phase::Ready && phase != Phase::Draining) || pending_audio.empty()) return;
    auto& queued = pending_audio.front();
    auto& frame = queued.frame;
    auto reference = Reference(CMTimeAdd(frame.host_time, CMTimeMake(queued.consumed, config.sample_rate)));
    if (!reference) return Fail("Invalid audio timestamp.");
    auto weak = weak_from_this();
    if (*reference > Clock::now()) {
      audio_pump.Schedule([weak] { if (auto self = weak.lock()) self->PumpAudio(); }, *reference);
      return;
    }
    if (Clock::now() - *reference > std::chrono::milliseconds(200)) {
      queued.consumed = frame.samples;  // Whole remaining sample frames form a gap.
    } else {
      // AVAssetReader can return >80 ms at once. Encode one 10 ms packet per
      // owner task at its original due time so RTCP/UDP can progress between
      // packets; a burst must not overrun the sender's ~66 ms flight budget.
      int count = std::min(480, frame.samples - queued.consumed);
      audio->EncodeAndSend(frame.audio.data() + queued.consumed * config.channels, count,
                           frame.measured_capture, frame.measured_capture, *reference);
      queued.consumed += count;
    }
    if (queued.consumed == frame.samples) {
      Release(Track::Audio, frame.samples);
      pending_audio.pop_front();
    }
    if (pending_audio.empty()) { Drain(); return; }
    // One outstanding alarm, even if the entire 200 ms admission budget is
    // filled. Credits remain held through pacing, not just through conversion.
    const auto& next = pending_audio.front();
    auto due = Reference(CMTimeAdd(next.frame.host_time, CMTimeMake(next.consumed, config.sample_rate)));
    if (!due) return Fail("Invalid audio timestamp.");
    audio_pump.Schedule([weak] { if (auto self = weak.lock()) self->PumpAudio(); }, *due);
  }
  void Consume(Converted frame) {
    struct Credit {
      State& owner;
      Track track;
      int samples;
      bool release = true;
      ~Credit() {
        if (release) owner.Release(track, samples);
      }
    } credit{*this, frame.track, frame.samples};
    if (phase != Phase::Ready && phase != Phase::Draining) return;
    if (!frame.error.empty()) return Fail(std::move(frame.error));
    auto reference = Reference(frame.host_time);
    if (!reference) return Fail("Invalid or overflowing source timestamp.");
    const __int128 delta = static_cast<__int128>(reference->time_since_epoch().count()) - Clock::now().time_since_epoch().count();
    if (delta < -200'000) return;
    if (delta > 1'000'000) return Fail("Source timestamp is outside the host-clock admission window.");
    auto duration = Microseconds(frame.duration);
    const int64_t interval = int64_t(negotiated.fps_denominator) * 1'000'000 /
        std::max(1, negotiated.fps_numerator);
    Sender* stream = frame.track == Track::Audio ? audio_sender : video_sender;
    const int64_t media_duration = frame.track == Track::Audio ?
        int64_t(frame.samples) * 1'000'000 / config.sample_rate + 20'000 :
        (duration && *duration > 0 ? *duration : interval);
    __int128 end = static_cast<__int128>(reference->time_since_epoch().count()) + media_duration +
        std::chrono::duration_cast<Clock::duration>(stream->config().target_playout_delay).count();
    if (end > INT64_MAX || end < INT64_MIN) return Fail("Media timestamp overflow.");
    auto playout = Clock::time_point(Clock::duration(static_cast<int64_t>(end)));
    if (!final_playout || playout > *final_playout) final_playout = playout;
    if (frame.track == Track::Audio) {
      bool empty = pending_audio.empty();
      pending_audio.push_back({std::move(frame), 0});
      credit.release = false;
      if (empty) PumpAudio();
    } else {
      if (next_video_reference && *reference < *next_video_reference) return;
      if (reference->time_since_epoch().count() > INT64_MAX - interval) return Fail("Video timestamp overflow.");
      next_video_reference = *reference + Clock::duration(interval);
      StreamingVideoEncoder::VideoFrame input;
      input.width = negotiated.width;
      input.height = negotiated.height;
      size_t luma = static_cast<size_t>(input.width) * input.height;
      input.yuv_planes[0] = frame.video.data();
      input.yuv_planes[1] = frame.video.data() + luma;
      input.yuv_planes[2] = frame.video.data() + luma + luma / 4;
      input.yuv_strides[0] = input.width;
      input.yuv_strides[1] = input.yuv_strides[2] = input.width / 2;
      input.duration = Clock::duration(duration && *duration > 0 ? *duration : 0);
      // This is a measured admission instant, not duration fabricated as capture.
      input.capture_begin_time = input.capture_end_time = frame.measured_capture;
      video->EncodeAndSend(input, *reference, {});
    }
  }
  Submission Submit(Track track, CMSampleBufferRef sample, CMTime time) {
    { std::lock_guard lock(admission_mutex); if (admission != Submission::Accepted) return admission; }
    if ((track != Track::Video && track != Track::Audio) || !sample || !CMSampleBufferDataIsReady(sample) || !Microseconds(time)) return Submission::Invalid;
    int frames = 0;
    if (track == Track::Video) {
      if (!config.video || !VideoFormat(CMSampleBufferGetImageBuffer(sample))) return Submission::Invalid;
    } else if (!config.audio || !AudioFormat(sample, config, frames)) return Submission::Invalid;
    // Enqueue under this lock so Stop's barrier cannot overtake accepted input.
    std::lock_guard submission_lock(admission_mutex);
    if (admission != Submission::Accepted) return admission;
    if (track == Track::Video) { if (video_pending == kVideoBudget) return Submission::Backpressured; ++video_pending; }
    else {
      if (audio_pending + frames > kAudioBudget || audio_buffers_pending == kAudioBufferBudget) return Submission::Backpressured;
      audio_pending += frames;
      ++audio_buffers_pending;
    }
    CFRetain(sample);
    auto owned = std::shared_ptr<const void>(sample, [](const void* value) { CFRelease(value); });
    auto self = shared_from_this();
    auto measured = Clock::now();
    dispatch_async(conversion, ^{
      Converted frame{track, frames, {}, {}, time, CMSampleBufferGetDuration(sample), measured, {}};
      bool accepting;
      { std::lock_guard lock(self->admission_mutex); accepting = !self->discard_media; }
      if (accepting) {
        if (track == Track::Video) {
          if (!ConvertVideo(CMSampleBufferGetImageBuffer(sample), self->negotiated, self->scaler, frame.video))
            frame.error = "Unsupported or invalid native video frame.";
        } else {
          frame.audio.resize(static_cast<size_t>(frames) * self->config.channels);
          if (CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(sample), 0, frame.audio.size() * sizeof(float), frame.audio.data()) ||
              !std::all_of(frame.audio.begin(), frame.audio.end(), [](float value) { return std::isfinite(value); }))
            frame.error = "Invalid Float32 audio sample storage.";
        }
      }
      (void)owned;  // Retained until conversion is done; never borrowed by a task.
      self->runner.PostTask([self, frame = std::move(frame)]() mutable { self->Consume(std::move(frame)); });
    });
    return Submission::Accepted;
  }
};

NativeSenderSession::NativeSenderSession(TaskRunner& runner, Config config, Ready ready, Terminal terminal)
    : state_(std::make_shared<State>(runner, std::move(config), std::move(ready), std::move(terminal))) {}
NativeSenderSession::~NativeSenderSession() {
  state_->ready = {};
  state_->terminal = {};
  state_->Stop();
}
void NativeSenderSession::Start(std::vector<IPEndpoint> candidates) { state_->Start(std::move(candidates)); }
void NativeSenderSession::Stop() { state_->Stop(); }
void NativeSenderSession::FinishInput() { state_->FinishInput(); }
NativeSenderSession::Submission NativeSenderSession::Submit(Track track, CMSampleBufferRef sample, CMTime time) {
  return state_->Submit(track, sample, time);
}
}  // namespace applescreen

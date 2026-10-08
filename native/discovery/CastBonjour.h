#ifndef APPLESCREEN_NATIVE_DISCOVERY_CAST_BONJOUR_H_
#define APPLESCREEN_NATIVE_DISCOVERY_CAST_BONJOUR_H_

#include <dns_sd.h>
#include <sys/socket.h>

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <tuple>
#include <vector>

namespace applescreen {

// Missing optional value is a flag; an empty vector is an explicit empty value.
// Keys are ASCII case-folded. Unknown values remain binary.
using TxtRecord = std::map<std::string, std::optional<std::vector<uint8_t>>>;
std::optional<TxtRecord> ParseCastTxt(std::span<const uint8_t> bytes);
std::optional<std::vector<uint8_t>> SerializeCastTxt(const TxtRecord& record);

struct CastInfo {
  std::string id;
  std::string name;
  std::string model;
  uint64_t capabilities = 0;
  uint8_t version = 2;
  uint8_t status = 0;
};
std::optional<CastInfo> CastInfoFromTxt(const TxtRecord& record);
TxtRecord CastInfoToTxt(const CastInfo& info);

struct ServiceKey {
  std::string name;
  std::string type = "_googlecast._tcp";
  std::string domain = "local.";
  uint32_t interface_index = 0;
  auto values() const { return std::tie(name, type, domain, interface_index); }
  bool operator<(const ServiceKey& other) const { return values() < other.values(); }
  bool operator==(const ServiceKey& other) const { return values() == other.values(); }
};

struct CastAddress {
  sockaddr_storage address{};  // Includes network-order port and IPv6 scope.
  socklen_t length = 0;
  uint32_t interface_index = 0;
  bool operator<(const CastAddress& other) const;
  bool operator==(const CastAddress& other) const;
};

struct CastService {
  ServiceKey key;
  CastInfo info;
  uint16_t port = 0;  // Host byte order.
  std::vector<CastAddress> addresses;  // Deterministic IPv4, then IPv6 order.
};

struct CastSnapshot {
  uint64_t generation = 0;
  std::vector<CastService> services;  // Aggregate by TXT id only in presentation.
};

struct CastPublication {
  std::string instance_name;
  uint32_t interface_index = 0;
  uint16_t port = 0;
  CastInfo info;  // Same stable identity used by the Cast receiver/control agent.
};

// Only the native DNS-SD boundary is substitutable; production uses these defaults.
struct DnsServiceApi {
  decltype(&DNSServiceBrowse) browse = DNSServiceBrowse;
  decltype(&DNSServiceResolve) resolve = DNSServiceResolve;
  decltype(&DNSServiceGetAddrInfo) addresses = DNSServiceGetAddrInfo;
  decltype(&DNSServiceQueryRecord) query = DNSServiceQueryRecord;
  decltype(&DNSServiceRegister) publish = DNSServiceRegister;
  decltype(&DNSServiceUpdateRecord) update = DNSServiceUpdateRecord;
  decltype(&DNSServiceSetDispatchQueue) schedule = DNSServiceSetDispatchQueue;
  decltype(&DNSServiceRefDeallocate) cancel = DNSServiceRefDeallocate;
};

class CastBonjour final {
 public:
  using Completion = std::function<void(DNSServiceErrorType)>;
  using SnapshotCallback = std::function<void(CastSnapshot)>;
  using ErrorCallback = std::function<void(DNSServiceErrorType)>;
  using ResolveCompletion =
      std::function<void(DNSServiceErrorType, std::optional<CastService>)>;
  using RegistrationCallback =
      std::function<void(DNSServiceErrorType, std::string claimed_name)>;

  explicit CastBonjour(ErrorCallback error = {}, DnsServiceApi api = {});
  ~CastBonjour();
  CastBonjour(const CastBonjour&) = delete;
  CastBonjour& operator=(const CastBonjour&) = delete;

  // Thread-safe entry points. Every callback runs on the single discovery queue,
  // without locks, and owns its payload. Callbacks must not block or throw.
  // 0 explicitly means Automatic; invalid nonzero interface indices fail.
  void StartBrowsing(uint32_t interface_index, SnapshotCallback, Completion = {});
  void Refresh(Completion = {});
  void StopBrowsing(Completion = {});

  // Resolve SRV/TXT again before connecting. Returns the currently available
  // address batch, not a claim that all future addresses have arrived. Try the
  // ordered candidates; reconnect may resolve again. Deadline is five seconds.
  void Resolve(ServiceKey key, ResolveCompletion);

  // The caller must already listen on every family advertised by the system host.
  // Port/name/interface changes re-register; pure TXT changes update in place.
  void Publish(CastPublication, RegistrationCallback);
  void Unpublish(Completion = {});

  // Terminal barrier: cancels children before parents and pending resolutions
  // before completion. No discovery/publication callbacks follow completion.
  // Retain through completion before shutting down the protocol task runner.
  void Stop(Completion = {});

 private:
  struct State;
  std::shared_ptr<State> state_;
};

}  // namespace applescreen
#endif

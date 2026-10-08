#include "CastBonjour.h"

#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <net/if.h>

#include <algorithm>
#include <charconv>
#include <cstring>
#include <set>
#include <utility>

namespace applescreen {
namespace {
std::optional<std::string> Key(std::string value) {
  if (value.empty()) return {};
  for (char& character : value) {
    unsigned char byte = character;
    if (byte < 0x20 || byte > 0x7e || byte == '=') return {};
    if (byte >= 'A' && byte <= 'Z') character += 'a' - 'A';
  }
  return value;
}

std::optional<std::string> Text(const TxtRecord& record, const char* key) {
  auto found = record.find(key);
  if (found == record.end() || !found->second) return {};
  const auto& bytes = *found->second;
  if (std::find(bytes.begin(), bytes.end(), 0) != bytes.end()) return {};
  CFStringRef string = CFStringCreateWithBytes(kCFAllocatorDefault, bytes.data(),
                                             bytes.size(), kCFStringEncodingUTF8, false);
  if (!string) return {};
  CFRelease(string);
  return std::string(bytes.begin(), bytes.end());
}

bool Number(const TxtRecord& record, const char* key, uint64_t& number) {
  auto text = Text(record, key);
  if (!text || text->empty()) return false;
  auto parsed = std::from_chars(text->data(), text->data() + text->size(), number);
  return parsed.ec == std::errc{} && parsed.ptr == text->data() + text->size();
}

bool ValidInterface(uint32_t index) {
  char name[IF_NAMESIZE];
  return index == 0 || if_indextoname(index, name) != nullptr;
}

void Complete(const CastBonjour::Completion& completion, DNSServiceErrorType error = 0) {
  if (completion) completion(error);
}
}  // namespace

std::optional<TxtRecord> ParseCastTxt(std::span<const uint8_t> bytes) {
  TxtRecord result;
  while (!bytes.empty()) {
    size_t length = bytes.front();
    bytes = bytes.subspan(1);
    if (length > bytes.size()) return {};
    auto field = bytes.first(length);
    bytes = bytes.subspan(length);
    if (field.empty()) continue;  // DNS's single empty TXT string.
    auto equals = std::find(field.begin(), field.end(), '=');
    auto key = Key(std::string(field.begin(), equals));
    if (!key) return {};
    if (result.contains(*key)) continue;  // RFC 6763: first occurrence wins.
    if (equals == field.end()) result.emplace(*key, std::nullopt);
    else result.emplace(*key, std::vector<uint8_t>(equals + 1, field.end()));
  }
  return result;
}

std::optional<std::vector<uint8_t>> SerializeCastTxt(const TxtRecord& record) {
  std::vector<uint8_t> bytes;
  std::set<std::string> keys;
  for (const auto& [name, value] : record) {
    auto key = Key(name);
    if (!key || !keys.insert(*key).second) return {};
    size_t length = key->size() + (value ? 1 + value->size() : 0);
    if (length > 255 || bytes.size() + 1 + length > UINT16_MAX) return {};
    bytes.push_back(static_cast<uint8_t>(length));
    bytes.insert(bytes.end(), key->begin(), key->end());
    if (value) {
      bytes.push_back('=');
      bytes.insert(bytes.end(), value->begin(), value->end());
    }
  }
  if (bytes.empty()) bytes.push_back(0);
  return bytes;
}

std::optional<CastInfo> CastInfoFromTxt(const TxtRecord& record) {
  // Matches ReceiverInfo's public Cast v2 requirements without manufacturing a
  // generic DnsSdInstanceEndpoint (which requires an already resolved address).
  auto id = Text(record, "id"), name = Text(record, "fn"), model = Text(record, "md");
  auto status = Text(record, "st");
  uint64_t version = 0, capabilities = 0;
  if (!id || id->empty() || !name || name->empty() || (record.contains("md") && !model) ||
      !Number(record, "ve", version) || version < 2 || version > 99 ||
      !Number(record, "ca", capabilities) || !status || (*status != "0" && *status != "1"))
    return {};
  return CastInfo{*id, *name, model.value_or(""), capabilities,
                  static_cast<uint8_t>(version), static_cast<uint8_t>(*status == "1")};
}

TxtRecord CastInfoToTxt(const CastInfo& info) {
  TxtRecord result;
  for (const auto& [key, value] : std::map<std::string, std::string>{
           {"id", info.id}, {"fn", info.name}, {"md", info.model},
           {"ve", std::to_string(info.version)}, {"ca", std::to_string(info.capabilities)},
           {"st", std::to_string(info.status)}})
    result.emplace(key, std::vector<uint8_t>(value.begin(), value.end()));
  return result;
}

bool CastAddress::operator<(const CastAddress& other) const {
  if (address.ss_family != other.address.ss_family)
    return address.ss_family < other.address.ss_family;
  // Both values originate in zero-initialized storage and have validated lengths.
  int order = std::memcmp(&address, &other.address, std::min(length, other.length));
  return order != 0 ? order < 0
                    : std::tie(length, interface_index) < std::tie(other.length, other.interface_index);
}
bool CastAddress::operator==(const CastAddress& other) const {
  return !(*this < other) && !(other < *this);
}

struct CastBonjour::State : std::enable_shared_from_this<State> {
  struct Entry : std::enable_shared_from_this<Entry> {
    State* owner;
    CastService service;
    std::string host;
    uint64_t generation = 0;
    uint64_t request = 0;
    DNSServiceRef resolve = nullptr, addresses = nullptr, txt = nullptr, srv = nullptr;
    std::vector<uint8_t> srv_record;
    dispatch_source_t deadline = nullptr;
    ResolveCompletion completion;
  };

  explicit State(ErrorCallback error, DnsServiceApi api)
      : error(std::move(error)), api(api), queue(dispatch_queue_create("app.applescreen.bonjour", DISPATCH_QUEUE_SERIAL)) {}
  ErrorCallback error;
  DnsServiceApi api;
  dispatch_queue_t queue;
  DNSServiceRef browse = nullptr, publication = nullptr;
  SnapshotCallback snapshot;
  RegistrationCallback registered;
  CastPublication published;
  std::string claimed_name;
  uint32_t interface_index = 0;
  uint64_t generation = 0, next_request = 0;
  bool stopped = false;
  std::map<ServiceKey, std::shared_ptr<Entry>> entries;
  std::map<uint64_t, std::shared_ptr<Entry>> pending;

  void Cancel(DNSServiceRef& reference) {
    if (auto old = std::exchange(reference, nullptr)) api.cancel(old);
  }
  DNSServiceErrorType Schedule(DNSServiceErrorType result, DNSServiceRef& reference) {
    if (!result) result = api.schedule(reference, queue);
    if (result) Cancel(reference);
    return result;
  }
  void CancelEntry(const std::shared_ptr<Entry>& entry) {
    if (entry->deadline) {
      dispatch_source_cancel(entry->deadline);
      entry->deadline = nullptr;
    }
    Cancel(entry->addresses);
    Cancel(entry->txt);
    Cancel(entry->srv);
    Cancel(entry->resolve);
  }
  bool Active(const Entry& entry) const {
    if (stopped) return false;
    if (entry.request) return pending.contains(entry.request);
    auto found = entries.find(entry.service.key);
    return entry.generation == generation && found != entries.end() && found->second.get() == &entry;
  }
  void Emit() {
    if (!snapshot || stopped) return;
    CastSnapshot value{generation, {}};
    for (const auto& [key, entry] : entries)
      if (!entry->service.info.id.empty() && !entry->service.addresses.empty())
        value.services.push_back(entry->service);
    snapshot(std::move(value));
  }
  void Finish(std::shared_ptr<Entry> entry, DNSServiceErrorType result) {
    CancelEntry(entry);
    pending.erase(entry->request);
    auto callback = std::move(entry->completion);
    if (callback) callback(result, result ? std::nullopt : std::optional(entry->service));
  }
  void Failed(const std::shared_ptr<Entry>& entry, DNSServiceErrorType result) {
    if (entry->request) return Finish(entry, result);
    CancelEntry(entry);
    entries.erase(entry->service.key);
    Emit();
    if (error) error(result);
  }
  void EndBrowse() {
    ++generation;
    for (auto& [key, entry] : entries) CancelEntry(entry);
    entries.clear();
    Cancel(browse);
  }
  DNSServiceErrorType BeginBrowse() {
    if (!ValidInterface(interface_index)) return kDNSServiceErr_BadInterfaceIndex;
    return Schedule(api.browse(&browse, 0, interface_index, "_googlecast._tcp", "local.",
        [](DNSServiceRef, DNSServiceFlags flags, uint32_t interface,
           DNSServiceErrorType result, const char* name, const char* type,
           const char* domain, void* context) {
          auto& self = *static_cast<State*>(context);
          if (self.stopped) return;
          if (result) {
            self.EndBrowse();
            self.Emit();
            if (self.error) self.error(result);
            return;
          }
          ServiceKey key{name, type, domain, interface};
          auto found = self.entries.find(key);
          if (!(flags & kDNSServiceFlagsAdd)) {
            if (found != self.entries.end()) {
              self.CancelEntry(found->second);
              self.entries.erase(found);
            }
          } else if (found == self.entries.end()) {
            auto entry = std::make_shared<Entry>();
            entry->owner = &self;
            entry->generation = self.generation;
            entry->service.key = key;
            self.entries.emplace(key, entry);
            if (auto error = self.BeginResolve(entry)) self.Failed(entry, error);
          }
          if (!(flags & kDNSServiceFlagsMoreComing)) self.Emit();
        }, this), browse);
  }
  DNSServiceErrorType BeginResolve(const std::shared_ptr<Entry>& entry) {
    Cancel(entry->resolve);
    const auto& key = entry->service.key;
    return Schedule(api.resolve(&entry->resolve, 0, key.interface_index,
        key.name.c_str(), key.type.c_str(), key.domain.c_str(),
        [](DNSServiceRef, DNSServiceFlags, uint32_t, DNSServiceErrorType result,
           const char* full_name, const char* host, uint16_t port, uint16_t length,
           const unsigned char* txt, void* context) {
          auto entry = static_cast<Entry*>(context)->shared_from_this();
          auto& self = *entry->owner;
          if (!self.Active(*entry)) return;
          if (result) return self.Failed(entry, result);
          self.Cancel(entry->resolve);
          auto record = ParseCastTxt({txt, length});
          auto info = record ? CastInfoFromTxt(*record) : std::nullopt;
          if (!info || port == 0) return self.Failed(entry, kDNSServiceErr_Invalid);
          entry->service.info = *info;
          if (entry->host != host || entry->service.port != ntohs(port)) {
            self.Cancel(entry->addresses);
            entry->service.addresses.clear();
          }
          entry->host = host;
          entry->service.port = ntohs(port);
          if (!entry->request && !entry->txt) {
            if (auto error = self.Monitor(entry, full_name, kDNSServiceType_TXT, entry->txt))
              return self.Failed(entry, error);
            if (auto error = self.Monitor(entry, full_name, kDNSServiceType_SRV, entry->srv))
              return self.Failed(entry, error);
          }
          if (!entry->addresses)
            if (auto error = self.FindAddresses(entry)) return self.Failed(entry, error);
          self.Emit();
        }, entry.get()), entry->resolve);
  }
  DNSServiceErrorType Monitor(const std::shared_ptr<Entry>& entry, const char* name,
                             uint16_t type, DNSServiceRef& reference) {
    return Schedule(api.query(&reference, kDNSServiceFlagsLongLivedQuery,
        entry->service.key.interface_index, name, type, kDNSServiceClass_IN,
        [](DNSServiceRef, DNSServiceFlags flags, uint32_t, DNSServiceErrorType result,
           const char*, uint16_t type, uint16_t, uint16_t length, const void* bytes,
           uint32_t, void* context) {
          auto entry = static_cast<Entry*>(context)->shared_from_this();
          auto& self = *entry->owner;
          if (!self.Active(*entry)) return;
          if (result) return self.Failed(entry, result);
          auto data = std::span(static_cast<const uint8_t*>(bytes), length);
          if (type == kDNSServiceType_TXT) {
            auto record = ParseCastTxt(data);
            auto info = record ? CastInfoFromTxt(*record) : std::nullopt;
            entry->service.info = (flags & kDNSServiceFlagsAdd) && info ? *info : CastInfo{};
          } else if (!(flags & kDNSServiceFlagsAdd)) {
            entry->srv_record.clear();
            self.Cancel(entry->addresses);
            entry->service.addresses.clear();
          } else {
            std::vector<uint8_t> next(data.begin(), data.end());
            bool changed = entry->srv_record != next;
            entry->srv_record = std::move(next);
            if (changed || !entry->addresses)
              if (auto error = self.BeginResolve(entry)) return self.Failed(entry, error);
          }
          if (!(flags & kDNSServiceFlagsMoreComing)) self.Emit();
        }, entry.get()), reference);
  }
  DNSServiceErrorType FindAddresses(const std::shared_ptr<Entry>& entry) {
    return Schedule(api.addresses(&entry->addresses, 0,
        entry->service.key.interface_index, kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6,
        entry->host.c_str(),
        [](DNSServiceRef, DNSServiceFlags flags, uint32_t interface, DNSServiceErrorType result,
           const char*, const sockaddr* address, uint32_t, void* context) {
          auto entry = static_cast<Entry*>(context)->shared_from_this();
          auto& self = *entry->owner;
          if (!self.Active(*entry)) return;
          if (result) return self.Failed(entry, result);
          if (!address || (address->sa_family != AF_INET && address->sa_family != AF_INET6)) return;
          CastAddress candidate;
          candidate.interface_index = interface;
          candidate.length = address->sa_family == AF_INET ? sizeof(sockaddr_in) : sizeof(sockaddr_in6);
          if (address->sa_len < candidate.length) return;
          if (address->sa_family == AF_INET) {
            auto& ipv4 = *reinterpret_cast<sockaddr_in*>(&candidate.address);
            ipv4.sin_len = sizeof(ipv4);
            ipv4.sin_family = AF_INET;
            ipv4.sin_addr = reinterpret_cast<const sockaddr_in*>(address)->sin_addr;
            ipv4.sin_port = htons(entry->service.port);
          } else {
            auto& ipv6 = *reinterpret_cast<sockaddr_in6*>(&candidate.address);
            const auto& input = *reinterpret_cast<const sockaddr_in6*>(address);
            ipv6.sin6_len = sizeof(ipv6);
            ipv6.sin6_family = AF_INET6;
            ipv6.sin6_addr = input.sin6_addr;
            ipv6.sin6_scope_id = input.sin6_scope_id;
            ipv6.sin6_port = htons(entry->service.port);
            if (!ipv6.sin6_scope_id && IN6_IS_ADDR_LINKLOCAL(&ipv6.sin6_addr)) ipv6.sin6_scope_id = interface;
          }
          auto& addresses = entry->service.addresses;
          if (flags & kDNSServiceFlagsAdd) {
            if (std::find(addresses.begin(), addresses.end(), candidate) == addresses.end())
              addresses.push_back(candidate);
            std::sort(addresses.begin(), addresses.end());
          } else std::erase(addresses, candidate);
          if (!(flags & kDNSServiceFlagsMoreComing)) {
            if (entry->request && !addresses.empty()) self.Finish(entry, 0);
            else self.Emit();
          }
        }, entry.get()), entry->addresses);
  }
  void EndPublication() {
    Cancel(publication);
    registered = {};
    claimed_name.clear();
  }
};

CastBonjour::CastBonjour(ErrorCallback error, DnsServiceApi api)
    : state_(std::make_shared<State>(std::move(error), api)) {}
CastBonjour::~CastBonjour() { Stop(); }

void CastBonjour::StartBrowsing(uint32_t index, SnapshotCallback callback, Completion completion) {
  auto self = state_;
  dispatch_async(self->queue, ^{
    if (self->stopped) return Complete(completion, kDNSServiceErr_BadState);
    self->snapshot = callback;
    if (self->browse && self->interface_index == index) {
      self->Emit();
      return Complete(completion);
    }
    self->EndBrowse();
    self->interface_index = index;
    auto result = self->BeginBrowse();
    self->Emit();
    Complete(completion, result);
  });
}
void CastBonjour::Refresh(Completion completion) {
  auto self = state_;
  dispatch_async(self->queue, ^{
    if (self->stopped) return Complete(completion, kDNSServiceErr_BadState);
    self->EndBrowse();
    auto result = self->BeginBrowse();
    self->Emit();
    Complete(completion, result);
  });
}
void CastBonjour::StopBrowsing(Completion completion) {
  auto self = state_;
  dispatch_async(self->queue, ^{
    self->EndBrowse();
    self->Emit();
    self->snapshot = {};
    Complete(completion);
  });
}
void CastBonjour::Resolve(ServiceKey key, ResolveCompletion completion) {
  auto self = state_;
  dispatch_async(self->queue, ^{
    if (self->stopped || !ValidInterface(key.interface_index)) {
      if (completion) completion(self->stopped ? kDNSServiceErr_BadState : kDNSServiceErr_BadInterfaceIndex, {});
      return;
    }
    auto entry = std::make_shared<State::Entry>();
    entry->owner = self.get();
    entry->service.key = key;
    entry->request = ++self->next_request;
    entry->completion = completion;
    self->pending.emplace(entry->request, entry);
    auto weak = std::weak_ptr<State>(self);
    uint64_t request = entry->request;
    entry->deadline = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->queue);
    dispatch_source_set_timer(entry->deadline, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(entry->deadline, ^{
      if (auto owner = weak.lock()) {
        auto found = owner->pending.find(request);
        if (found != owner->pending.end()) owner->Finish(found->second, kDNSServiceErr_Timeout);
      }
    });
    dispatch_resume(entry->deadline);
    if (auto error = self->BeginResolve(entry)) self->Finish(entry, error);
  });
}
void CastBonjour::Publish(CastPublication value, RegistrationCallback callback) {
  auto self = state_;
  dispatch_async(self->queue, ^{
    auto next = value;
    const bool same_service = self->publication && next.port == self->published.port &&
        next.instance_name == self->published.instance_name &&
        next.interface_index == self->published.interface_index;
    if (same_service && !self->claimed_name.empty()) next.info.name = self->claimed_name;
    auto record = CastInfoToTxt(next.info);
    auto bytes = SerializeCastTxt(record);
    DNSServiceErrorType result = 0;
    if (self->stopped) result = kDNSServiceErr_BadState;
    else if (!ValidInterface(next.interface_index)) result = kDNSServiceErr_BadInterfaceIndex;
    else if (!next.port || next.instance_name.empty() || !bytes || !CastInfoFromTxt(record)) result = kDNSServiceErr_BadParam;
    if (result) {
      if (callback) callback(result, {});
      return;
    }
    if (same_service) {
      result = self->api.update(self->publication, nullptr, 0, static_cast<uint16_t>(bytes->size()), bytes->data(), 0);
      if (!result) {
        self->published = next;
        self->registered = callback;
      }
      if (callback && (result || !self->claimed_name.empty())) callback(result, self->claimed_name);
      return;
    }
    self->EndPublication();
    self->published = next;
    self->registered = callback;
    result = self->Schedule(self->api.publish(&self->publication, 0, next.interface_index,
        next.instance_name.c_str(), "_googlecast._tcp", "local.", nullptr, htons(next.port),
        static_cast<uint16_t>(bytes->size()), bytes->data(),
        [](DNSServiceRef, DNSServiceFlags flags, DNSServiceErrorType error, const char* name,
           const char*, const char*, void* context) {
          auto& owner = *static_cast<State*>(context);
          if (owner.stopped) return;
          if (!error && !(flags & kDNSServiceFlagsAdd)) error = kDNSServiceErr_NoSuchRecord;
          auto callback = owner.registered;
          if (!error) {
            auto updated = owner.published;
            updated.info.name = name ? name : "";
            auto record = CastInfoToTxt(updated.info);
            auto bytes = SerializeCastTxt(record);
            if (!bytes || !CastInfoFromTxt(record)) error = kDNSServiceErr_BadParam;
            else error = owner.api.update(owner.publication, nullptr, 0,
                static_cast<uint16_t>(bytes->size()), bytes->data(), 0);
            if (!error) {
              owner.claimed_name = updated.info.name;
              owner.published = std::move(updated);
            }
          }
          // The claimed instance name and advertised/control friendly name
          // become visible together, or the registration is rolled back.
          if (error) owner.EndPublication();
          if (callback) callback(error, error ? std::string{} : owner.claimed_name);
        }, self.get()), self->publication);
    if (result) {
      self->EndPublication();
      if (callback) callback(result, {});
    }
  });
}
void CastBonjour::Unpublish(Completion completion) {
  auto self = state_;
  dispatch_async(self->queue, ^{
    self->EndPublication();
    Complete(completion);
  });
}
void CastBonjour::Stop(Completion completion) {
  auto self = state_;
  dispatch_async(self->queue, ^{
    self->stopped = true;
    self->snapshot = {};
    self->EndBrowse();
    while (!self->pending.empty()) self->Finish(self->pending.begin()->second, kDNSServiceErr_ServiceNotRunning);
    self->EndPublication();
    self->error = {};
    Complete(completion);
  });
}

}  // namespace applescreen

#include "../native/discovery/CastBonjour.h"

#include <arpa/inet.h>
#include <net/if.h>
#include <unistd.h>
#include <cassert>
#include <cstdio>
#include <memory>

using namespace applescreen;

namespace {
struct NativeRef {
  enum Kind { Browse, Resolve, Address, Query, Register } kind;
  void* context = nullptr;
  dispatch_queue_t queue = nullptr;
  uint32_t interface = 0;
  uint16_t type = 0, port = 0;
  bool cancelled = false;
  std::vector<uint8_t> txt;
  DNSServiceBrowseReply browse = nullptr;
  DNSServiceResolveReply resolve = nullptr;
  DNSServiceGetAddrInfoReply address = nullptr;
  DNSServiceQueryRecordReply query = nullptr;
  DNSServiceRegisterReply registered = nullptr;
};

struct FakeDns {
  static FakeDns* current;
  std::vector<std::unique_ptr<NativeRef>> refs;
  std::vector<NativeRef::Kind> cancellations;
  DNSServiceErrorType create_error = 0, schedule_error = 0, update_error = 0;
  int updates = 0;

  FakeDns() { current = this; }
  NativeRef* Make(DNSServiceRef* output, NativeRef::Kind kind, uint32_t interface, void* context) {
    if (create_error) return nullptr;
    refs.push_back(std::make_unique<NativeRef>());
    auto& ref = *refs.back();
    ref.kind = kind;
    ref.interface = interface;
    ref.context = context;
    *output = reinterpret_cast<DNSServiceRef>(&ref);
    return &ref;
  }
  NativeRef* Last(NativeRef::Kind kind, uint32_t interface = UINT32_MAX, uint16_t type = 0) {
    for (auto it = refs.rbegin(); it != refs.rend(); ++it)
      if ((*it)->kind == kind && !(*it)->cancelled &&
          (interface == UINT32_MAX || (*it)->interface == interface) && (!type || (*it)->type == type))
        return it->get();
    assert(false && "Expected live DNS operation");
    return nullptr;
  }
  DnsServiceApi Api() {
    DnsServiceApi api;
    api.browse = [](DNSServiceRef* out, DNSServiceFlags, uint32_t interface,
                    const char*, const char*, DNSServiceBrowseReply callback, void* context) {
      if (auto ref = current->Make(out, NativeRef::Browse, interface, context)) ref->browse = callback;
      return current->create_error;
    };
    api.resolve = [](DNSServiceRef* out, DNSServiceFlags, uint32_t interface, const char*,
                     const char*, const char*, DNSServiceResolveReply callback, void* context) {
      if (auto ref = current->Make(out, NativeRef::Resolve, interface, context)) ref->resolve = callback;
      return current->create_error;
    };
    api.addresses = [](DNSServiceRef* out, DNSServiceFlags, uint32_t interface, DNSServiceProtocol,
                       const char*, DNSServiceGetAddrInfoReply callback, void* context) {
      if (auto ref = current->Make(out, NativeRef::Address, interface, context)) ref->address = callback;
      return current->create_error;
    };
    api.query = [](DNSServiceRef* out, DNSServiceFlags, uint32_t interface, const char*,
                   uint16_t type, uint16_t, DNSServiceQueryRecordReply callback, void* context) {
      if (auto ref = current->Make(out, NativeRef::Query, interface, context)) {
        ref->query = callback;
        ref->type = type;
      }
      return current->create_error;
    };
    api.publish = [](DNSServiceRef* out, DNSServiceFlags, uint32_t interface, const char*, const char*,
                     const char*, const char*, uint16_t port, uint16_t length, const void* bytes,
                     DNSServiceRegisterReply callback, void* context) {
      if (auto ref = current->Make(out, NativeRef::Register, interface, context)) {
        ref->registered = callback;
        ref->port = ntohs(port);
        ref->txt.assign(static_cast<const uint8_t*>(bytes), static_cast<const uint8_t*>(bytes) + length);
      }
      return current->create_error;
    };
    api.update = [](DNSServiceRef reference, DNSRecordRef, DNSServiceFlags, uint16_t length, const void* bytes, uint32_t) {
      ++current->updates;
      auto* ref = reinterpret_cast<NativeRef*>(reference);
      assert(!ref->cancelled);
      if (!current->update_error)
        ref->txt.assign(static_cast<const uint8_t*>(bytes), static_cast<const uint8_t*>(bytes) + length);
      return current->update_error;
    };
    api.schedule = [](DNSServiceRef reference, dispatch_queue_t queue) {
      reinterpret_cast<NativeRef*>(reference)->queue = queue;
      return current->schedule_error;
    };
    api.cancel = [](DNSServiceRef reference) {
      auto& ref = *reinterpret_cast<NativeRef*>(reference);
      assert(!ref.cancelled);
      ref.cancelled = true;
      current->cancellations.push_back(ref.kind);
    };
    return api;
  }
  static void Deliver(NativeRef* ref, const std::function<void()>& callback) {
    // DNSServiceRefDeallocate on this queue guarantees no later callback. Keep
    // fake refs allocated so a queued native event can explicitly test that rule.
    dispatch_sync(ref->queue, ^{ if (!ref->cancelled) callback(); });
  }
  void Browse(NativeRef* ref, uint32_t interface, bool add, const char* name = "receiver") {
    Deliver(ref, [=] {
      ref->browse(reinterpret_cast<DNSServiceRef>(ref), add ? kDNSServiceFlagsAdd : 0,
                  interface, 0, name, "_googlecast._tcp", "local.", ref->context);
    });
  }
  void Resolve(NativeRef* ref, const CastInfo& info, uint16_t port = 8010) {
    auto bytes = *SerializeCastTxt(CastInfoToTxt(info));
    Deliver(ref, [=] {
      ref->resolve(reinterpret_cast<DNSServiceRef>(ref), 0, ref->interface, 0,
                   "receiver._googlecast._tcp.local.", "host.local.", htons(port),
                   bytes.size(), bytes.data(), ref->context);
    });
  }
  void Address(NativeRef* ref, bool ipv6, bool add = true, DNSServiceFlags extra = 0) {
    Deliver(ref, [=] {
      sockaddr_in ipv4{};
      ipv4.sin_len = sizeof(ipv4);
      ipv4.sin_family = AF_INET;
      inet_pton(AF_INET, "192.0.2.45", &ipv4.sin_addr);
      sockaddr_in6 address6{};
      address6.sin6_len = sizeof(address6);
      address6.sin6_family = AF_INET6;
      inet_pton(AF_INET6, "fe80::1234", &address6.sin6_addr);
      const sockaddr* address = ipv6 ? reinterpret_cast<sockaddr*>(&address6) : reinterpret_cast<sockaddr*>(&ipv4);
      ref->address(reinterpret_cast<DNSServiceRef>(ref), (add ? kDNSServiceFlagsAdd : 0) | extra,
                   ref->interface, 0, "host.local.", address, 120, ref->context);
    });
  }
};
FakeDns* FakeDns::current;

DNSServiceErrorType Await(const std::function<void(CastBonjour::Completion)>& operation) {
  auto semaphore = dispatch_semaphore_create(0);
  DNSServiceErrorType result = kDNSServiceErr_Unknown;
  operation([&](DNSServiceErrorType error) { result = error; dispatch_semaphore_signal(semaphore); });
  assert(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
  return result;
}
void Stop(CastBonjour& discovery) {
  assert(Await([&](auto completion) { discovery.Stop(completion); }) == 0);
}
CastInfo Info() { return {"abcd1234", "Living room", "Applescreen", 5, 2, 0}; }

void TxtTest() {
  auto record = CastInfoToTxt(Info());
  record["flag"] = std::nullopt;
  record["empty"] = std::vector<uint8_t>{};
  record["binary"] = std::vector<uint8_t>{0, 255, 0x80};
  record["long"] = std::vector<uint8_t>(250, 'x');
  auto bytes = SerializeCastTxt(record);
  assert(bytes && ParseCastTxt(*bytes) == record);
  assert(CastInfoFromTxt(*ParseCastTxt(*bytes))->name == "Living room");
  auto duplicate = *bytes;
  const std::string second = "FN=Ignored";
  duplicate.push_back(second.size());
  duplicate.insert(duplicate.end(), second.begin(), second.end());
  assert(CastInfoFromTxt(*ParseCastTxt(duplicate))->name == "Living room");
  duplicate.push_back(20);
  duplicate.push_back('x');
  assert(!ParseCastTxt(duplicate));
  record["long"] = std::vector<uint8_t>(251, 'x');
  assert(!SerializeCastTxt(record));
  for (const std::string invalid : {"", "-1", "1x", "18446744073709551616"}) {
    auto bad = CastInfoToTxt(Info());
    bad["ca"] = std::vector<uint8_t>(invalid.begin(), invalid.end());
    assert(!CastInfoFromTxt(bad));
  }
  for (const char* required : {"id", "fn", "ve", "ca", "st"}) {
    auto bad = CastInfoToTxt(Info());
    bad.erase(required);
    assert(!CastInfoFromTxt(bad));
  }
  TxtRecord excessive;
  for (int index = 0; index < 300; ++index)
    excessive["key" + std::to_string(index)] = std::vector<uint8_t>(240, 'x');
  assert(!SerializeCastTxt(excessive));
}

void BrowserTest() {
  FakeDns fake;
  CastBonjour discovery({}, fake.Api());
  CastSnapshot snapshot;
  int notifications = 0;
  auto observer = [&](CastSnapshot value) { snapshot = std::move(value); ++notifications; };
  assert(Await([&](auto done) { discovery.StartBrowsing(0, observer, done); }) == 0);
  auto browser = fake.Last(NativeRef::Browse);
  for (uint32_t interface : {4, 5}) {
    fake.Browse(browser, interface, true);
    fake.Browse(browser, interface, true);  // Duplicate add does not restart resolution.
    fake.Resolve(fake.Last(NativeRef::Resolve, interface), Info());
    auto address = fake.Last(NativeRef::Address, interface);
    fake.Address(address, false);
    fake.Address(address, true);  // Later batch is still accepted.
    fake.Address(address, true);
  }
  assert(snapshot.services.size() == 2);
  for (const auto& service : snapshot.services) {
    assert(service.addresses.size() == 2);
    const auto& address = *reinterpret_cast<const sockaddr_in6*>(&service.addresses[1].address);
    assert(address.sin6_scope_id == service.key.interface_index);
    assert(ntohs(address.sin6_port) == 8010);
  }
  fake.Address(fake.Last(NativeRef::Address, 4), true, false);
  assert(snapshot.services[0].addresses.size() == 1);
  fake.Browse(browser, 4, false);
  fake.Browse(browser, 99, false);
  assert(snapshot.services.size() == 1 && snapshot.services[0].key.interface_index == 5);

  auto txt = fake.Last(NativeRef::Query, 5, kDNSServiceType_TXT);
  auto changed = Info();
  changed.name = "Renamed";
  auto bytes = *SerializeCastTxt(CastInfoToTxt(changed));
  FakeDns::Deliver(txt, [&] {
    txt->query(reinterpret_cast<DNSServiceRef>(txt), kDNSServiceFlagsAdd, 5, 0, "full", kDNSServiceType_TXT,
               kDNSServiceClass_IN, bytes.size(), bytes.data(), 120, txt->context);
  });
  assert(snapshot.services[0].info.name == "Renamed");
  FakeDns::Deliver(txt, [&] {
    txt->query(reinterpret_cast<DNSServiceRef>(txt), 0, 5, 0, "full", kDNSServiceType_TXT,
               kDNSServiceClass_IN, bytes.size(), bytes.data(), 0, txt->context);
  });
  assert(snapshot.services.empty());
  FakeDns::Deliver(txt, [&] {
    txt->query(reinterpret_cast<DNSServiceRef>(txt), kDNSServiceFlagsAdd, 5, 0, "full", kDNSServiceType_TXT,
               kDNSServiceClass_IN, bytes.size(), bytes.data(), 120, txt->context);
  });
  auto srv = fake.Last(NativeRef::Query, 5, kDNSServiceType_SRV);
  auto old_address = fake.Last(NativeRef::Address, 5);
  FakeDns::Deliver(srv, [&] {
    const uint8_t changed_srv[] = {0, 0, 0, 0, 0x1f, 0x4c, 0};
    srv->query(reinterpret_cast<DNSServiceRef>(srv), kDNSServiceFlagsAdd, 5, 0, "full", kDNSServiceType_SRV,
               kDNSServiceClass_IN, sizeof(changed_srv), changed_srv, 120, srv->context);
  });
  fake.Resolve(fake.Last(NativeRef::Resolve, 5), changed, 9000);
  assert(old_address->cancelled && snapshot.services.empty());
  fake.Address(fake.Last(NativeRef::Address, 5), false);
  assert(snapshot.services[0].port == 9000);
  auto generation = snapshot.generation;
  assert(Await([&](auto done) { discovery.StartBrowsing(0, observer, done); }) == 0);
  assert(snapshot.services.size() == 1 && snapshot.generation == generation);  // Snapshot replay.
  assert(Await([&](auto done) { discovery.Refresh(done); }) == 0);
  assert(snapshot.services.empty() && snapshot.generation > generation);
  int previous = notifications;
  fake.Browse(browser, 5, true);  // A cancelled native event cannot reach its old context.
  assert(notifications == previous);
  Stop(discovery);
  previous = notifications;
  fake.Browse(fake.refs.front().get(), 4, true);
  assert(notifications == previous);
  assert(fake.cancellations.back() == NativeRef::Browse);
}

void FreshResolutionTest() {
  FakeDns fake;
  CastBonjour discovery({}, fake.Api());
  uint32_t interface = if_nametoindex("lo0");
  assert(interface != 0);
  assert(Await([&](auto done) { discovery.StartBrowsing(interface, {}, done); }) == 0);
  auto browse = fake.Last(NativeRef::Browse);
  assert(browse->interface == interface);
  fake.Browse(browse, interface, true);
  auto initial = fake.Last(NativeRef::Resolve);
  fake.Resolve(initial, Info());
  fake.Address(fake.Last(NativeRef::Address), false);
  int completions = 0;
  std::optional<CastService> result;
  discovery.Resolve({"receiver", "_googlecast._tcp", "local.", interface},
      [&](DNSServiceErrorType error, std::optional<CastService> service) {
        assert(!error);
        result = std::move(service);
        ++completions;
      });
  FakeDns::Deliver(browse, [] {});  // Drain the public Resolve request.
  auto fresh = fake.Last(NativeRef::Resolve);
  assert(fresh != initial && fresh->interface == interface);
  fake.Resolve(fresh, Info(), 9002);
  auto addresses = fake.Last(NativeRef::Address);
  fake.Address(addresses, true, true, kDNSServiceFlagsMoreComing);
  assert(completions == 0);
  fake.Address(addresses, false);
  assert(completions == 1 && result && result->port == 9002 && result->addresses.size() == 2);
  assert(result->addresses[0].address.ss_family == AF_INET);
  fake.Address(addresses, true);  // Cancelled lookup cannot complete again.
  assert(completions == 1);
  Stop(discovery);
}

void FailureAndPublicationTest() {
  for (bool fail_schedule : {false, true}) {
    FakeDns fake;
    if (fail_schedule) fake.schedule_error = kDNSServiceErr_NoMemory;
    else fake.create_error = kDNSServiceErr_ServiceNotRunning;
    CastBonjour discovery({}, fake.Api());
    assert(Await([&](auto done) { discovery.StartBrowsing(0, {}, done); }) != 0);
    assert(fake.cancellations.size() == (fail_schedule ? 1 : 0));
    Stop(discovery);
  }
  FakeDns fake;
  CastBonjour discovery({}, fake.Api());
  assert(Await([&](auto done) { discovery.StartBrowsing(UINT32_MAX, {}, done); }) == kDNSServiceErr_BadInterfaceIndex);
  assert(fake.refs.empty());
  CastPublication publication{"Applescreen", if_nametoindex("lo0"), 8010, Info()};
  int registrations = 0;
  DNSServiceErrorType registration_error = 0;
  std::string name;
  auto callback = [&](DNSServiceErrorType error, std::string claimed) {
    registration_error = error;
    name = std::move(claimed);
    ++registrations;
  };
  discovery.Publish(publication, callback);
  assert(Await([&](auto done) { discovery.StopBrowsing(done); }) == 0);  // Queue barrier only.
  auto first = fake.Last(NativeRef::Register);
  FakeDns::Deliver(first, [=] {
    first->registered(reinterpret_cast<DNSServiceRef>(first), kDNSServiceFlagsAdd, 0,
                      "Applescreen (2)", "_googlecast._tcp", "local.", first->context);
  });
  assert(registrations == 1 && name == "Applescreen (2)");
  assert(CastInfoFromTxt(*ParseCastTxt(first->txt))->name == name);
  publication.info.name = "Updated";
  publication.info.model = "Updated model";
  fake.update_error = kDNSServiceErr_NoMemory;
  discovery.Publish(publication, callback);
  assert(Await([&](auto done) { discovery.StopBrowsing(done); }) == 0);
  assert(registration_error == kDNSServiceErr_NoMemory && !first->cancelled);
  fake.update_error = 0;
  discovery.Publish(publication, callback);
  assert(Await([&](auto done) { discovery.StopBrowsing(done); }) == 0);
  auto updated = CastInfoFromTxt(*ParseCastTxt(first->txt));
  assert(updated->name == "Applescreen (2)" && updated->model == "Updated model");
  publication.port = 8011;
  discovery.Publish(publication, callback);
  assert(Await([&](auto done) { discovery.StopBrowsing(done); }) == 0);
  assert(first->cancelled && fake.Last(NativeRef::Register)->port == 8011);
  Stop(discovery);
  for (const auto& ref : fake.refs) assert(ref->cancelled);
}


void ClaimedNameFailureTest() {
  for (bool invalid_name : {false, true}) {
    FakeDns fake;
    CastBonjour discovery({}, fake.Api());
    int callbacks = 0;
    DNSServiceErrorType failure = 0;
    discovery.Publish({"Applescreen", 0, 8010, Info()}, [&](DNSServiceErrorType error, std::string name) {
      ++callbacks;
      failure = error;
      assert(name.empty());
    });
    assert(Await([&](auto done) { discovery.StopBrowsing(done); }) == 0);
    auto* registration = fake.Last(NativeRef::Register);
    fake.update_error = invalid_name ? 0 : kDNSServiceErr_NoMemory;
    auto deliver = [=] {
      registration->registered(reinterpret_cast<DNSServiceRef>(registration), kDNSServiceFlagsAdd, 0,
          invalid_name ? "" : "Applescreen (2)", "_googlecast._tcp", "local.", registration->context);
    };
    FakeDns::Deliver(registration, deliver);
    assert(callbacks == 1 && registration->cancelled);
    assert(failure == (invalid_name ? kDNSServiceErr_BadParam : kDNSServiceErr_NoMemory));
    FakeDns::Deliver(registration, deliver);  // Cancellation makes late results harmless.
    Stop(discovery);
    assert(callbacks == 1 && fake.cancellations.size() == 1);
  }
}

void ResolveCancellationTest() {
  FakeDns fake;
  CastBonjour discovery({}, fake.Api());
  int terminal = 0;
  discovery.Resolve({"receiver", "_googlecast._tcp", "local.", if_nametoindex("lo0")},
      [&](DNSServiceErrorType result, std::optional<CastService> service) {
        assert(result != 0 && !service);
        ++terminal;
      });
  Stop(discovery);
  assert(terminal == 1);
  Stop(discovery);
  assert(terminal == 1);
  for (const auto& ref : fake.refs) assert(ref->cancelled);
}

// Opt-in integration proof against the real daemon. A dual-stack listening
// socket matches the system-host registration; this does not test another device.
int NativeSmoke() {
  int listener = socket(AF_INET6, SOCK_STREAM, 0);
  int ipv6_only = 0;
  sockaddr_in6 local{};
  local.sin6_len = sizeof(local);
  local.sin6_family = AF_INET6;
  if (listener < 0 || setsockopt(listener, IPPROTO_IPV6, IPV6_V6ONLY, &ipv6_only, sizeof(ipv6_only)) ||
      bind(listener, reinterpret_cast<sockaddr*>(&local), sizeof(local)) || listen(listener, 2)) {
    std::perror("native smoke listener");
    if (listener >= 0) close(listener);
    return 1;
  }
  socklen_t length = sizeof(local);
  assert(getsockname(listener, reinterpret_cast<sockaddr*>(&local), &length) == 0);
  auto publication = CastPublication{"Applescreen validation " + std::to_string(getpid()),
                                     0, ntohs(local.sin6_port), Info()};
  publication.info.id += "-" + std::to_string(getpid());
  auto ready = dispatch_semaphore_create(0);
  DNSServiceErrorType failure = 0;
  bool found = false, removal_requested = false, disappeared = false;
  CastBonjour discovery([&](DNSServiceErrorType error) {
    failure = error;
    dispatch_semaphore_signal(ready);
  });
  auto error = Await([&](auto done) {
    discovery.StartBrowsing(0, [&](CastSnapshot snapshot) {
      bool present = false;
      for (const auto& service : snapshot.services) {
        if (service.info.id != publication.info.id) continue;
        present = true;
        if (!found) {
          found = true;
          std::printf("Native Cast service: %s, port %u, interface %u, %zu addresses\n",
                      service.key.name.c_str(), service.port, service.key.interface_index, service.addresses.size());
          dispatch_semaphore_signal(ready);
        }
      }
      if (removal_requested && !present && !disappeared) {
        disappeared = true;
        dispatch_semaphore_signal(ready);
      }
    }, done);
  });
  if (!error) {
    discovery.Publish(publication, [&](DNSServiceErrorType result, std::string name) {
      if (result) {
        failure = result;
        dispatch_semaphore_signal(ready);
      } else std::printf("Native claimed name: %s\n", name.c_str());
    });
    if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)))
      error = kDNSServiceErr_Timeout;
  }
  if (!error && !failure && found) {
    error = Await([&](auto done) {
      discovery.Unpublish([&, done](DNSServiceErrorType result) {
        removal_requested = true;
        done(result);
      });
    });
    if (!error && dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)))
      error = kDNSServiceErr_Timeout;
  }
  Stop(discovery);
  close(listener);
  if (error || failure || !found || !disappeared) {
    std::fprintf(stderr, "Native DNS smoke failed: %d\n", error ? error : failure);
    return 1;
  }
  std::puts("Native DNS browse/publication/disappearance and stop barrier passed");
  return 0;
}
}  // namespace

int main(int argc, char** argv) {
  if (argc == 2 && std::string(argv[1]) == "--native-smoke") return NativeSmoke();
  TxtTest();
  BrowserTest();
  FreshResolutionTest();
  FailureAndPublicationTest();
  ClaimedNameFailureTest();
  ResolveCancellationTest();
  std::puts("Bonjour behavior tests passed");
}

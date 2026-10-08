#include "../native/SenderSession.h"

#include <cassert>
#include <array>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <fstream>
#include <mutex>
#include <unistd.h>

#include "platform/api/task_runner.h"

using applescreen::NativeSenderSession;
using openscreen::IPEndpoint;
using openscreen::IPAddress;

namespace {
// Runs actual asynchronous stop work without process signals, PlatformClient,
// network access or sleeps. Delayed alarms remain canceled tasks on teardown.
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
  void Until(const std::function<bool()>& completed) {
    while (!completed()) {
      Task task;
      {
        std::unique_lock lock(mutex_);
        assert(available_.wait_for(lock, std::chrono::seconds(2), [&] { return !tasks_.empty(); }));
        task = std::move(tasks_.front());
        tasks_.pop_front();
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

NativeSenderSession::Config Audio() {
  NativeSenderSession::Config config;
  config.audio = true;
  return config;
}

void ValidateFactoriesAndTracks() {
  using Codec = openscreen::cast::VideoCodec;
  auto config = Audio();
  assert(!NativeSenderSession::ValidateConfig(config));
  config.audio = false;
  assert(NativeSenderSession::ValidateConfig(config));
  config.video = true;
  config.width = 1920;
  config.height = 1080;
  for (Codec codec : {Codec::kVp8, Codec::kVp9}) {
    config.codec = codec;
    assert(!NativeSenderSession::ValidateConfig(config));
  }
  config.codec = static_cast<Codec>(999);
  assert(NativeSenderSession::ValidateConfig(config));
#ifndef CAST_STANDALONE_SENDER_HAVE_LIBAOM
  config.codec = Codec::kAv1;
  assert(NativeSenderSession::ValidateConfig(config));
#endif
  config = Audio();
  config.channels = 3;
  assert(NativeSenderSession::ValidateConfig(config));
  config = Audio();
  config.interface_name = "applescreen-nonexistent-interface";
  assert(NativeSenderSession::ValidateConfig(config));
}

void StartStopBeforeReadiness() {
  for (bool start : {false, true}) {
    Executor runner;
    int ready = 0, terminal = 0;
    std::optional<std::string> result;
    NativeSenderSession session(runner, Audio(), [&](auto) { ++ready; },
        [&](std::optional<std::string> error) { result = std::move(error); ++terminal; });
    assert(session.Submit(NativeSenderSession::Track::Audio, nullptr, kCMTimeZero) == NativeSenderSession::Submission::NotReady);
    if (start) session.Start({});  // Coherent creation failure with no endpoints.
    session.Stop();
    session.Stop();
    session.FinishInput();
    assert(terminal == 0);  // Terminal is after the conversion barrier, never optimistic.
    runner.Until([&] { return terminal == 1; });
    session.Stop();
    assert(ready == 0 && terminal == 1 && bool(result) == start);
    assert(session.Submit(NativeSenderSession::Track::Audio, nullptr, kCMTimeZero) == NativeSenderSession::Submission::Stopped);
  }
}

void MediaBindsLocallyAndKeepsScope() {
  openscreen::InterfaceInfo interface;
  interface.name = "test-interface";
  interface.index = 7;
  const IPAddress local4(192, 0, 2, 11), remote4(192, 0, 2, 99);
  std::array<uint8_t, 16> bytes{0xfe, 0x80};
  bytes.back() = 1;
  const IPAddress local6(bytes, 7);
  bytes.back() = 2;
  const IPAddress remote6(bytes, 7), wrong_scope(bytes, 8);
  interface.addresses.emplace_back(local4, 24);
  interface.addresses.emplace_back(local6, 64);
  const std::array<openscreen::InterfaceInfo, 1> interfaces{interface};
  for (const auto& remote : {remote4, remote6}) {
    auto automatic = NativeSenderSession::SelectLocalEndpoint({remote, 8009}, "", interfaces);
    assert(automatic && automatic->port == 0);
    assert(automatic->address == (remote.IsV6() ? IPAddress::kAnyV6() : IPAddress::kAnyV4()));
    auto selected = NativeSenderSession::SelectLocalEndpoint({remote, 8009}, interface.name, interfaces);
    assert(selected && selected->port == 0 && selected->address != remote);
    assert(selected->address == (remote.IsV6() ? local6 : local4));
    if (remote.IsV6()) assert(selected->address.GetScopeId() == remote.GetScopeId());
    assert(!NativeSenderSession::SelectLocalEndpoint({remote, 8009}, "missing", interfaces));
  }
  assert(!NativeSenderSession::SelectLocalEndpoint({wrong_scope, 8009}, interface.name, interfaces));
}

void InvalidDevelopmentRootsNeverConnect() {
  char path[] = "/private/tmp/applescreen-ca-test-XXXXXX";
  int descriptor = mkstemp(path);
  assert(descriptor >= 0);
  close(descriptor);
  for (const std::string contents : {"", "garbage", "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"}) {
    { std::ofstream file(path); file << contents; }
    Executor runner;
    auto config = Audio();
    config.developer_ca_path = path;
    int terminals = 0;
    NativeSenderSession session(runner, config, [](auto) { assert(false); }, [&](auto error) {
      assert(error && !error->empty());
      ++terminals;
    });
    config.developer_ca_path.clear();  // Caller mutations cannot replace the selected trust.
    session.Start({IPEndpoint{IPAddress::kV4LoopbackAddress(), 8009}});
    runner.Until([&] { return terminals == 1; });
    session.Stop();
    assert(terminals == 1);
  }
  unlink(path);
  Executor runner;
  auto config = Audio();
  config.developer_ca_path = path;  // Removed path must not fall back to Cast roots.
  int terminals = 0;
  NativeSenderSession session(runner, config, [](auto) { assert(false); }, [&](auto error) {
    assert(error && !error->empty()); ++terminals;
  });
  session.Start({IPEndpoint{IPAddress::kV4LoopbackAddress(), 8009}});
  runner.Until([&] { return terminals == 1; });
}
}  // namespace

int main() {
  ValidateFactoriesAndTracks();
  StartStopBeforeReadiness();
  MediaBindsLocallyAndKeepsScope();
  InvalidDevelopmentRootsNeverConnect();
  std::puts("Sender configuration and asynchronous stop tests passed");
}

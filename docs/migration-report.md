# Native Cast migration results

Implementation and validation performed on 2026-10-08 in `/Users/mac/shano`, on
arm64 macOS 27.2 with Xcode/SDK 27. The deployment target remains **12.7.6**.
The universal application builds and the native regression suite passes. The
remaining hardware, permission and upstream-test limitations below are open
validation work; this report does not mark every requested gate complete.

## Upstream first, and where it lives

The supplied Applescreen snapshot was
`e440fc709d6e29ce33831e4f58ade3a5b1665284`. The local migration branch's parent,
`226801dca2571a380a73abf5b710a498897dc09f`, has the same source tree. The first
implementation stage preserved the dirty Open Screen checkout and synchronized
official upstream before changing the application engine:

| Item | Revision / location |
| --- | --- |
| Old Open Screen | `1f070e8b01b063fd1dcc6827a9ea1b62301c3d1a` |
| Official main fetched at 2026-10-08 14:48:37.066198 UTC | `bbe3f57202748d19b2bf400417c9b2e087b12e2b` |
| Pristine solution | `out/openscreen-baseline` |
| Pristine source | `out/openscreen-baseline/openscreen` |
| Final derived integration solution | `out/openscreen-integration-v5` |
| Preserved owner checkout | `openscreen`, still on its original base/branch |
| Recoverable staged, unstaged and untracked snapshot | `.migration-backups/20261008T144358Z` |

The first commit, `35fbb75`, records the lock, preparation and pristine baseline.
`28ebc09` adds native adapters and their behavioral tests; `11fe197` adds the
remaining decoder/sanitizer seams. `91c9503` migrates the engine, Cocoa consumers,
build graph and universal packaging together. No shared `.gclient`, sibling project or owner's dirty Open Screen
tree was reset. The backup includes saved indices, binary diffs, untracked files,
build arguments, remotes and patch order; all 19 archived files and staged trees
were verified. The [baseline report](upstream-baseline.md) records the successful
gclient sync/hooks and exact pristine commands.

All maintained changes are in **applescreen**. The pristine tracked diff is
empty. The derived checkout contains only the manifest's eight generic patches
and a symlink to this application's GN entry. The DEPS-pinned GN accepts
`--root-target=//applescreen:cast_core`; neither upstream `.gn` nor root
`BUILD.gn` is edited. Preparation checks SHA, ordered patch hashes and exact
staged state, applies each patch with `git apply --index --check`, and refuses a
dirty/mismatched input. Repeated unchanged preparation and builds do not apply
patches again or recompile codecs/core/app. Python preparation tests cover those
refusals and idempotence.

The locked external versions are Opus 1.6.1 (`22244de5a79bd1d6d623c32e72bf1954b56235be`),
libvpx 1.15.2 (`d168454ecd099805c675d4a98c66f4891373302a`), libaom 3.13.1
(`d772e334cc724105040382a977ebb10dfd393293`), and FFmpeg 8.0.1
(`894da5ca7d742e4429ffb2af534fcda0103ef593`). Isolated depot_tools is
`c3d79a03349c210945359154daf703854b8f76c0`; GN, Clang, Ninja, BoringSSL, Protobuf
and the other Open Screen dependencies come from the selected DEPS. SDL is no
longer an application dependency. AV1 sending is opt-in; receiving AV1 remains
enabled. H.264/HEVC sender options were not added.

## Architecture and ownership

One GN-produced `libapplescreen_cast.dylib` contains both protocol roles and one
managed Open Screen runtime. CMake builds the Cocoa application against the
98-line private [C/CF interface](../native/cast.h). No STL, FFmpeg object or C++
exception crosses toolchains. Configuration strings and service keys are copied.
Accepted submissions retain `CMSampleBufferRef`; rejected submissions retain
nothing. Acceptance means bounded admission, with later congestion or
cancellation drops still possible.

Protocol objects belong to one managed task sequence. Receiver decode and native
source work have bounded serial owners; DNSService refs belong to one dispatch
queue. UI work stays on main. Generations invalidate old source, resolution,
decode and window deliveries. Stop closes admission, stops sources/consumers and
sessions, awaits native discovery's barrier, destroys protocol objects and their
deferred work while the runner is alive, then shuts down/joins the platform off
main. Ordinary session stop keeps the runtime and discovery alive. Runtime stop
completion is the barrier before freeing its handle. Cocoa uses asynchronous
application termination.

The sender waits for authentication, app launch, negotiation and actual encoder
readiness before capture. It offers only source-present tracks. One host-clock
origin preserves file offsets and explicit timestamp domains. File scheduling
follows PTS, including VFR and 60 fps, drains final pending samples, and shares the
same native submission path as video-only ScreenCaptureKit capture.

The receiver preserves FrameId and RTP/reference metadata through decode.
`EncodedFrame.reference_time` already includes playout delay; it is not added
again. An explicit clock mapping yields native sample timestamps shared by both
tracks. FFmpeg's borrowed output becomes owned NV12 video/Float32 PCM before the
decoder callback returns. One `AVSampleBufferRenderSynchronizer` coordinates only
the negotiated present renderers. Playback feedback is an enqueue/clock estimate,
not a claim of physical presentation measurement.

Queue budgets include two admitted raw video frames, 200 ms/32 whole PCM buffers,
16 encoded decode inputs/16 MiB, and 64 MiB decoded/native budgets with a two-second
native time ceiling. Startup sample counts derive from negotiated delay, frame
rate and minimum audio packet duration. Late video is dropped; audio gaps retain
whole sample frames and flush/re-anchor on discontinuity. Main discovery updates
coalesce into one pending snapshot. There is no per-frame AppKit dispatch queue.

## Defects and retained regression coverage

| Behavior corrected | Regression evidence |
| --- | --- |
| Startup/stop races, joinable failed threads, duplicate singleton ownership, stale callbacks | `runtime_session_test`: repeated creation, simultaneous roles, stop before readiness, invalid start, immediate restart, exactly-once stop barriers; `runtime_loopback_test`: both roles, refresh during sending, EOF and cancel; ASan/UBSan core run |
| Sender remote address used as local media bind; lost scoped endpoint | `sender_session_test::MediaBindsLocallyAndKeepsScope`: distinct synthetic local/remote hosts, selected interface, automatic wildcard, IPv6 scope and invalid interface; current upstream scope-conversion tests retained; second physical host remains untested |
| Invalid codec/factory, trust fallback and shallow config | `sender_session_test`: real factory/present-track validation, unsupported enums, invalid development roots, async stop; generic trust/credential tests authenticate a chain after source PEM storage is released and reject malformed, mismatched and expired credentials |
| Sender teardown without usable STOP/ack deadline, reentrant close | Real Cast loopback/separate processes exercise STOP and EOF drain; bounded 500 ms deadline follows current upstream lifecycle; upstream application-agent/router tests retained. Not every peer-disappearance timing permutation has a dedicated app fixture |
| Unbounded encoder admission and lost audio tail | Generic real VP8/VP9 pending-work tests, mono/stereo Opus flush/decode tests with audible tail; source/native queue tests; ten-minute process memory sampling |
| TXT dangling storage, truncated/duplicate/binary handling; deletion invariant; interface/address loss | `bonjour_test`: strict TXT tables, duplicate adds/removes, per-interface candidates, delayed resolution, refresh/snapshot, selected interface, scoped sockaddr, publication failures/name/port updates and cancellation barriers |
| Independent media origins, 30 Hz file slowdown and EOF loss | `file_source_test`: six real AVAssetWriter/Reader fixtures (24/30/60 fps, VFR/orientation, audio-only, combined 250 ms offset), final sample counts, cancel/restart; portable `media_timeline_test`: zero, offsets, differing order, month-long rational conversions, invalid/overflow and delay changes |
| Decoder FrameId shifted by buffering/reordering; fabricated PTS | Generic decoder fixture with real H.264 B frames; `receiver_session_test::ReceiverTimingReachesNativeSamples`: actual decode to native samples preserves 250 ms track offset and target time; negotiated startup-budget and actual AV1 software-decode tests |
| Borrowed/reused decoded planes, odd dimensions/independent strides, unsupported color/audio formats | `decoded_media_test`: released/reused input ownership, odd/padded/negative stride policy, crop/color/SAR, allocation/format rejection and real swresample conversion including planar S32 |
| Byte-truncated/stale audio ring and unsynchronized Metal storage | Old sinks removed; `native_playback_test`: audio/video/both, readiness, queue pressure, whole-sample behavior, format/discontinuity flush, stop, invalid clocks and reverse arrival; adapter sanitizer runs |
| UI's optimistic state, refresh destroying active sender, incomplete quit | Runtime-driven controllers, source snapshot/generation, coalesced discovery; real loopback refresh and source/runtime barriers. Manual fullscreen, output-device and active dual-role GUI termination checks remain outstanding |
| Source generation/cancellation, pending 60 fps/VFR data | Native file-source ASan/UBSan and TSan runs passed; source stop barrier prevents submission after completion. ScreenCaptureKit permission currently blocks actual capture validation |

These tests run real codecs/native media where needed, with a thin fake DNS API at
its external boundary. Pure timeline/preparation tests remain separate from
AppKit. The portable C++ GN entry is `//applescreen/tests:media_timeline_test`;
Linux execution of that entry was not performed. Upstream tests were not removed
or rewritten to hide failures.

## Removed code and API evidence

The original whole-workspace source/link audit found custom glue consumers only
in `applescreen/src`, the identical `openscreen/CastApp`, and the old prototype.
The original executable's imported symbols corroborated its 13 used functions.
`rg -n 'cast_(sender|receiver|frame_pool)_|mylib|my_lib|CastApp|CastReceiverApp' shanocast`
returned no matches. Shanocast builds its own upstream CLI/SDL2, and was untouched.

| Removed or consolidated | Caller evidence and disposition |
| --- | --- |
| Two `my_lib` engines/headers, stale `.hh`, window/frame callbacks | Active Cocoa calls migrated atomically to the single private core; no external consumer found. Window ownership now belongs to Cocoa |
| All eight `cast_frame_pool_*`, receiver active query/unused flag | No source/prototype caller; retained native samples replace borrowed integer handles |
| Discovery polling/getters, connect-by-id, string/IP shim, bandwidth/bitrate/status wrappers | No external callers; the GUI's used discovery/endpoint path migrated to service snapshots and fresh structured resolution. No separate direct-IP UI was found |
| Encoding-stat translation, redundant locks/time origins, unused options/stubs | Only custom glue declarations/implementation; real upstream congestion feedback and factories remain |
| Ignore Certificate option/authentication bypass | Deliberately retired; explicit developer CA and normal Cast challenge replace it, with invalid PEM rejected |
| Custom remoting namespace/constraints | Incomplete RPC handshake was not a supported app feature; ordinary mirroring/file/audio/video remain. Upstream remoting source/tests remain original |
| Six generic Bonjour adapter files and discovery factory/DEPS/framework edits | Replaced by one app-owned direct CastBonjour service; used start/stop discovery behavior retained |
| SDL3 port and its floating dependency | No real external consumer of this app's port; native timed renderer replaces the Cocoa dependency, untouched upstream SDL2 remains |
| MetalVideoView, AudioRingBuffer, manual AudioQueue/conversion loops | Native playback/conversion proof passed before deletion. Complete-sample, lifetime and bounded-queue tests cover retained behavior |
| Separate Audio File and Video File execution paths | One optional-track File source retains both, with timestamp-driven scheduling and a shared conversion path |
| Per-architecture dependency CMake copies/generated shell programs | Parameterized checked-in scripts, exact byproducts/imported core dependencies and real universal lipo replace them; codecs are still built statically |
| CastApp/prototype/Makefile/copied executable and dylibs | Removed from every supported build/launch path. Historical originals remain in the preserved dirty owner checkout and backup; this report takes **no physical deletion credit** |

There were no original app-owned tests to delete. New timeline cases were moved
from the native receiver test into the portable test without removing the native
end-to-end offset assertion. No upstream parser/session/authentication tests were
deleted. The residual [integration series](../patches/integration/README.md)
documents each patch's exact purpose, affected targets, regression and drop
condition: reusable codec targets, checked TLS listen, encoder bounds, owned PEM
trust, Opus EOF flush, owned receiver credentials, decoder identity and standalone
UBSan defaults. It contains zero application implementation patches, no wildcard
visibility, no `nogncheck`, no global testonly removal and no suppression entries.

## Builds, tests and native execution

Commands below ran from `/Users/mac/shano`, unless stated otherwise. Dependencies
and integration were prepared with successful sync/hooks before these builds.

```sh
cmake -S applescreen -B out/applescreen-arm64-debug -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DAPPLESCREEN_DEPOT_TOOLS=/Users/mac/shano/out/depot_tools \
  -DAPPLESCREEN_PRISTINE=/Users/mac/shano/out/openscreen-baseline \
  -DAPPLESCREEN_INTEGRATION=/Users/mac/shano/out/openscreen-integration-v5 \
  -DAPPLESCREEN_CODEC_ROOT=/Users/mac/shano/out/applescreen-codecs
cmake --build out/applescreen-arm64-debug --target Applescreen applescreen_tests --parallel 4
ctest --test-dir out/applescreen-arm64-debug --output-on-failure

cmake -S applescreen -B out/applescreen-universal-release -G Ninja \
  -DCMAKE_BUILD_TYPE=Release '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64' \
  -DAPPLESCREEN_DEPOT_TOOLS=/Users/mac/shano/out/depot_tools \
  -DAPPLESCREEN_PRISTINE=/Users/mac/shano/out/openscreen-baseline \
  -DAPPLESCREEN_INTEGRATION=/Users/mac/shano/out/openscreen-integration-v5 \
  -DAPPLESCREEN_CODEC_ROOT=/Users/mac/shano/out/applescreen-codecs
cmake --build out/applescreen-universal-release --target Applescreen --parallel 4
```

Results: native Debug build passed; **9/9 CTest groups passed** in the final run
(13.36 seconds). Full arm64 Release and x86_64 Release core/codec/Cocoa slices built
through the explicit universal configuration. The final repeated universal
build reported codec cache hits and `ninja: no work to do` for both architectures,
with no app relink. GN generation and header checks passed with unused-argument
checking enabled. An earlier test run under concurrent heavy builds exposed a
missing test rpath (fixed) and a file-timing deadline miss; the same timing test
subsequently passed repeatedly without loosening its assertions.

Pristine upstream: **1,174/1,174 tests in 159 suites passed**. Codec-enabled full
integration: **1,203/1,205 in 170 suites passed** using the separate validation
FFmpeg profile with native H.264/HEVC encoder factories. The unchanged
`StreamingFfmpegEncoderTest.EncodeAndSendH264Frame` and
`StreamingFfmpegEncoderTest.EncodeAndSendHevcFrame` still fail because their short
input produces no enqueued encoded packet on this VideoToolbox environment; the
isolated rerun also fails. Neither test was skipped or deleted, and these codecs
are not product sender options. Test lists and full logs are
`out/openscreen-baseline/upstream-test-list.txt`, `out/validation-test-list.txt`,
`out/openscreen-baseline/upstream-tests.log`, `out/validation-upstream-tests.log`
and `out/validation-ffmpeg-focused.log`.

For sanitizer execution, the core's generated args were reused with
`is_debug=false`, `is_asan=true`, `is_ubsan=true`, `is_ubsan_no_recover=true`,
`symbol_level=1`, and `is_component_build=false`. From the v5 source root:

```sh
buildtools/mac/gn gen /Users/mac/shano/out/applescreen-core-arm64-asan-ubsan \
  --root-target=//applescreen:cast_core --check --fail-on-unused-args
third_party/ninja/ninja -C /Users/mac/shano/out/applescreen-core-arm64-asan-ubsan \
  cast_library sender_session_test receiver_session_test
/Users/mac/shano/out/applescreen-core-arm64-asan-ubsan/sender_session_test
/Users/mac/shano/out/applescreen-core-arm64-asan-ubsan/receiver_session_test
/Users/mac/shano/out/runtime-session-sanitized
```

All passed, including repeated C API lifecycle runs. Codec archives in this run
are not sanitizer-instrumented. Native Bonjour/playback/conversion/source adapters
also passed ASan/UBSan and supported system-Clang TSan runs; the final source
fixtures passed `/private/tmp/applescreen-file-source-test-asan` and `-tsan`.
Full DEPS core TSan is unsupported on macOS by this revision's explicit
`build/config/sanitizers/BUILD.gn:566` Linux/ChromeOS assertion. It was not bypassed.
Sanitizer commands/results are retained under `.migration-audit/*proof.txt` and
`*sanitizer*.log`, `*asan-ubsan*.log`, `file-source-final-*.log` and
`core-tsan-gen.log`.

Actual native network/media checks used the explicitly generated shared CA in
`out/applescreen-test-credentials`, with no authentication bypass. All six file
fixtures passed the one-runtime test, including refresh while connected; audio
and combined fixtures also passed immediate cancellation. Separate sender and
native receiver processes passed audio-only, video-only and combined streams.
The optional AV1 sender built and passed a three-second combined stream to the
default native receiver (`out/cast-av1-{sender,receiver}.log`). The following
ten-minute run used visible flash/timecode plus audio marker content:

```sh
out/applescreen-arm64-debug/cast_native_smoke --receiver \
  --ca out/applescreen-test-credentials/development-ca.crt \
  --key out/applescreen-test-credentials/development-ca.key \
  --interface lo0 --port 18011 --name 'Applescreen ten minute validation' \
  --window --timeout 660
# Concurrently, in a second terminal:
out/applescreen-arm64-debug/cast_native_smoke --sender \
  --ca out/applescreen-test-credentials/development-ca.crt \
  --file out/applescreen-smoke-fixtures/ten-minute-offset-250ms.mov \
  --interface lo0 --name 'Applescreen ten minute validation' --timeout 640
dns-sd -B _googlecast._tcp local.
dns-sd -L 'Applescreen ten minute validation' _googlecast._tcp local.
```

Both media processes exited successfully after EOF/drain/STOP. The fixture has
600 seconds of 60 fps video at PTS 0 and 600 seconds of audio starting at 250 ms.
Actual Bonjour browse/resolve showed the stable id, claimed name, system host,
interface 1, port 18011 and capability TXT. Logs are
`out/cast-ten-minute-{sender,receiver}.log` and `out/dns-sd-ten-minute-*.log`.
During the last approximately 7m40s, 47 ten-second RSS samples ranged from
55.23–63.80 MiB for the sender and 82.50–95.22 MiB for the receiver. The run logged
1,394 upstream congestion/flight-duration video drops during concurrent builds;
it is not evidence of drop-free playback. Physical A/V skew/latency was not
measured. Queue-bound assertions and memory observations establish bounded
software behavior, not a universal latency guarantee.

Upstream CLI interoperability also ran with this CA: codec-enabled upstream
`cast_sender -d CA -c vp8 -n 127.0.0.1:18012 FILE` sent a three-second H.264/PCM
file to the native receiver successfully. Applescreen discovered and sent to
pristine upstream `cast_receiver -d CA -p KEY -f 'Open Screen CLI validation'
-r 18013 lo0`, including media reception and STOP; that minimal receiver has a
dummy sink, so this direction proves transport, not playback. The CLI sender
aborted on the tiny MJPEG fixture's YUVJ420P format assertion; the native receiver
recovered. The installed SDL2 2.32.74 dylib requires macOS 27 and cannot link the
SDL receiver at the 12.7.6 floor. The floor/warnings were not weakened to force
that optional CLI backend. Logs: `out/cast-upstream-cli-sender-h264file.log`,
`out/cast-cli-peer-receiver-h264file.log`, `out/cast-upstream-cli-receiver.log`,
and `out/cast-app-to-upstream-cli.log`.

## Packaging and code measurements

Final artifact: `out/applescreen-universal-release/src/Applescreen.app`.
`file`, `lipo`, `otool -L/-l`, `nm` and `codesign --verify --deep --strict` confirm:
both application and core have arm64/x86_64 slices and minOS 12.7.6; the core's
install name is `@rpath/libapplescreen_cast.dylib`; the app's rpath is
`@executable_path/../Frameworks`. Both slices define the linked FFmpeg, libaom,
VPX and Opus code. There are no external codec/Homebrew/SDL/mylib/custom-libc++
dylib dependencies. System frameworks and `/usr/lib` libraries remain dynamic.
The app launched from `/private/tmp` with all `DYLD_*` variables removed and
stayed alive until the harness terminated it. This is linkage/startup evidence,
not a Finder interaction or normal GUI-quit test. Inspection command outputs are
in `out/applescreen-universal-package-inspection.json`.

Physical line counts include blank lines/comments and count moved implementation
once. No upstream dependency churn, omitted archive files, patch context or
generated binary is counted as an application-code saving.
These measurements describe migration commit `91c9503`; later requested features,
including the in-app developer CA generator, are not part of that snapshot.

| Category | Before | After |
| --- | ---: | ---: |
| Unique app production (Cocoa plus app implementation previously in patches) | 6,369 | 5,311 |
| Of final production: Cocoa/source adapters; native core/adapters | — | 1,381; 3,930 |
| App behavioral tests | 0 | 2,478 |
| Generic upstream regression additions | 0 | 427 |
| App build/scripts/GN/CMake | 522 | 880 |
| New dependency lock and bundle template | 0 | 117 |
| Generic upstream production delta (added / removed) | 227 / 91 | 328 / 131 |
| Generic upstream build delta (added / removed) | 233 / 13 | 103 / 40 |
| Historical duplicates/prototype outside maintained workflow | 3,348 | 3,348 preserved |

Unique application production fell by **1,058 lines (16.61%)**. Charging all 328
new upstream production additions against that baseline, with no credit for any
upstream removed lines or old upstream modifications, still yields **730 fewer
lines (11.46%)**. The 5,172 old raw patch lines versus 1,732 residual patch lines
are not a net-code saving measure. Build/configuration grew to support real
dependency preparation, architecture packaging and tests; this is reported
separately. New regression coverage totals 2,905 lines. The 3,348 historical
duplicate/prototype lines earn **zero physical removal credit**.

## Remaining gates

- A second host/real Cast device, available scoped IPv6, interface changes and
  physical speaker/display timing have not been exercised. The fake/local bind
  regression does not substitute for that network test.
- The screen source probe failed because Screen Recording permission is absent
  for the test process. No permission settings were changed and no computer-use
  automation was used for final validation. Actual screen capture remains a gate.
- Intel hardware, macOS 12.7.6, manual resize/fullscreen/backing-scale changes,
  default audio-device changes, UI starvation and active dual-role GUI termination
  still need native manual/device validation. Unit/native queue/lifecycle tests
  cover parts of those paths, not the full physical scenarios.
- Physical ten-minute A/V skew and latency acceptance measurements are still
  needed; no numerical guarantee is inferred from timestamp tests.
- The two unchanged upstream VideoToolbox encoder tests fail as described above.
  Full-core macOS TSan is unsupported at this pinned revision. No tests or
  assertions were removed to conceal either limitation.

# Open Screen migration baseline — 2026-10-08

The first implementation stage preserved the owner's work and synchronized an
isolated official upstream checkout. It did not rebase or reset the owner's
working checkout. All maintained application changes belong in this repository;
`out/` contains disposable dependency/build state.

## Source and preservation

- Applescreen original commit: `e440fc709d6e29ce33831e4f58ade3a5b1665284`.
- Original Open Screen commit: `1f070e8b01b063fd1dcc6827a9ea1b62301c3d1a`.
- Official repository: `https://chromium.googlesource.com/openscreen`.
- Fetched `refs/heads/main`: `bbe3f57202748d19b2bf400417c9b2e087b12e2b`.
- Fetch completed at `2026-10-08T14:48:37.066198+00:00` (UTC).
- Native workspace: workspace root; original checkouts are `applescreen/`
  and `openscreen/`, with `depot_tools/`, `ffmpeg/`, `gn/`, and `shanocast/` siblings.
- Recoverable snapshot: `.migration-backups/20261008T144358Z/`. Its `RESTORE.txt`
  describes the binary staged/unstaged diffs, saved indices, archived untracked
  application sources/binaries, repository metadata, DEPS, `.gclient`, build
  arguments, and ordered patch hashes. Temporary-index reconstruction matched
  the staged trees; all 19 archived files matched the originals. The Open Screen
  preservation branch is `preserve/pre-sync-20261008`.
- Pristine synchronized solution: `out/openscreen-baseline/`, source checkout
  `out/openscreen-baseline/openscreen/`. The original shared `.gclient` and dirty
  Open Screen working sources were preserved. The old checkout's branch therefore
  still identifies the old base; the new baseline is the isolated checkout above.

The dependency lock records immutable revisions independently from repository
URLs. The official Open Screen history contains both migration bases. Initial
full-history downloads of pybind11 and zlib failed/stalled; their exact DEPS
revisions were fetched separately before successful gclient synchronization.
This did not shallow the Open Screen migration history.

## Commands and observed baseline

Run from the workspace's `out/openscreen-baseline` directory:

```sh
env DEPOT_TOOLS_UPDATE=0 PYTHONUNBUFFERED=1 \
  PATH=../depot_tools:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  ../depot_tools/gclient sync \
  --revision openscreen@bbe3f57202748d19b2bf400417c9b2e087b12e2b --nohooks
env DEPOT_TOOLS_UPDATE=0 \
  PATH=../depot_tools:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  ../depot_tools/gclient runhooks
```

Both completed successfully. The hooks supplied the revision's toolchain and
other DEPS artifacts. Isolated depot_tools revision:
`c3d79a03349c210945359154daf703854b8f76c0`. GN version:
`2527 (58933a7cdbc9)`.

Run from the pristine source checkout:

```sh
buildtools/mac/gn gen out/pristine-debug --check --fail-on-unused-args \
  --args='is_debug=true target_cpu="arm64" mac_deployment_target="12.7.6" mac_min_system_version="12.7.6" use_system_xcode=true'
third_party/ninja/ninja -C out/pristine-debug openscreen_unittests cast_sender cast_receiver
out/pristine-debug/openscreen_unittests --gtest_list_tests
out/pristine-debug/openscreen_unittests
```

GN generated 1,004 targets. Ninja completed all 2,205 build steps. All **1,174
upstream tests from 159 suites passed** (2.387 seconds of test execution). Full
logs and test names are in the solution root. This baseline uses minimal external
libraries: the sample binaries built here do not establish media codec playback.
It preserves the original upstream tests and verifies the new toolchain and core
source before app integration. Native media, sanitizer, packaging, and device
validation are separate gates.

## Migration inventory

Current upstream already preserves link-local IPv6 scope in `IPAddress` and
`SocketAddressPosix`; the old scope-loss patch is unnecessary. The decoder now
reports its `FrameId` on failure, but parser timestamps are still unspecified.
Receiver `EncodedFrame.reference_time` is a target playout time, including the
receiver's delay calculation; the app must not add that delay again.

`PlatformClientPosix` provides a managed task runner. One application runtime
owns it. The sample Python binding is an implementation reference, not a runtime
dependency. `LoopingFileCastAgent` now sends STOP and uses a 500 ms acknowledgement
timeout; its file/source policies still do not meet the app's audio-only/native
source contract. The app reuses protocol objects and real encoders through a
narrow production target, preserving the upstream sample targets and tests.

| Existing patch | Required disposition |
| --- | --- |
| 1, FFmpeg frameworks | App-owned core linkage. |
| 2, generic Bonjour service | Replace with app-owned direct DNSService component; restore upstream discovery. |
| 3, SDL3 migration | Remove from Cocoa dependency graph; preserve original upstream SDL2 samples. |
| 4, frameworks/static libraries | One explicit app-owned core link graph. |
| 5, two glue libraries | One GN core with private C/CF boundary. |
| 6, SDL/window shutdown | Replace with session lifetime and native playback shutdown. |
| 7, application glue | Ordinary app-owned runtime/session/media sources, with corrected ownership. |
| 8, certificate bypass | Remove bypass; explicit validated development roots with normal device challenge. |

At baseline, `shanocast` uses upstream executables/SDL2 and does not consume the
custom `cast_*` glue API. Its independent checkout/build files are not modified.
The canonical Cocoa controller calls discovery start/stop and direct endpoint
connection; those must migrate atomically. No actual caller was found for the
frame pool, polling discovery, bitrate/stat wrappers, or active receiver query.
The audit's symbol evidence is recorded separately; absence in the archive alone
was not used as proof.

## Counting rules and initial measurements

Unique app-owned production implementation at baseline: **6,369 lines**
(2,352 Cocoa source/header lines plus 4,017 implementation/header lines carried
by patches). Build files: **522 lines**. Application tests: **0 lines**. The eight
raw patch files total 5,172 lines; patch context is not implementation reduction.

`openscreen/CastApp` is byte-identical to `applescreen/src`: 2,419 lines including
its build file. The separate prototype is 858 lines and obsolete Makefile 71,
for **3,348 duplicate/obsolete lines**, accounted separately from unique logic.
Generated binaries and third-party files are excluded from production savings.
These are baseline numbers, not a claim that the migration has already removed
all duplicate code or achieved its final reduction.

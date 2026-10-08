# Building Applescreen

Requires macOS, Xcode command-line tools, CMake 3.24+, Python 3.9+, Git, Ninja,
pkg-config, make, and nasm/yasm for x86 assembly. Supply an existing depot_tools
checkout; preparation does not self-update it. All external source revisions are
in `dependencies.lock.json`. GN and the compiler come from Open Screen's DEPS.
The minimum deployment target remains macOS 12.7.6.

```sh
cmake -S applescreen -B out/applescreen-arm64-debug -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DAPPLESCREEN_DEPOT_TOOLS=/absolute/path/to/depot_tools
cmake --build out/applescreen-arm64-debug --target Applescreen applescreen_tests --parallel
ctest --test-dir out/applescreen-arm64-debug --output-on-failure
```

Omit `CMAKE_OSX_ARCHITECTURES` to use the development host's architecture. An Intel
release uses `-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64`. Explicit
universal packaging uses `-DCMAKE_OSX_ARCHITECTURES='arm64;x86_64'`; it builds each
core slice independently, combines them with `lipo`, and makes a universal Cocoa
executable. `APPLESCREEN_AV1_SENDER=ON` enables the optional AV1 encoder. AV1
receiver decoding remains available through the pinned FFmpeg/libaom build.

`APPLESCREEN_DEPENDENCY_ROOT` selects the isolated dependency directory. Advanced
users may supply separately prepared `APPLESCREEN_PRISTINE`,
`APPLESCREEN_INTEGRATION`, and `APPLESCREEN_CODEC_ROOT` paths to reuse completed
work. Preparation refuses unrelated configurations and unexpected edits. Change
the preparation directory after changing the upstream revision or patch series.
Each codec has a separate immutable source checkout, architecture/configuration
build, and install. A repeated unchanged invocation verifies artifacts without
reapplying patches or rebuilding codecs. GN/Ninja tracks ordinary app changes.

The CMake application depends explicitly on the single GN core library. The
bundle contains that dylib in `Contents/Frameworks`, uses an `@executable_path`
rpath, and is ad-hoc signed for local development. No `DYLD_LIBRARY_PATH` is part
of the supported launch workflow. Production distribution signing/notarization
requires the distributor's own identity.

The old per-dependency CMake modules have been replaced by
`cmake/CastCore.cmake` calling `scripts/build_codecs.py`. That script still runs
the libraries' own CMake/configure builds. Opus and libaom use
`BUILD_SHARED_LIBS=OFF`; libvpx and FFmpeg disable shared output. Each architecture
links its static `.a` archives into the single Cast core; universal packaging then
combines the completed core slices. The bundle needs no separate codec, Open
Screen, BoringSSL, Protobuf or custom C++ runtime dylibs. macOS frameworks and
system libraries remain dynamic. This keeps the GN C++ runtime inside the core
and the system Cocoa toolchain across its private C/CF boundary.

Inspect an explicit universal build with:

```sh
file out/applescreen-universal-release/src/Applescreen.app/Contents/MacOS/Applescreen
xcrun lipo out/applescreen-universal-release/src/Applescreen.app/Contents/Frameworks/libapplescreen_cast.dylib -info
otool -L out/applescreen-universal-release/src/Applescreen.app/Contents/Frameworks/libapplescreen_cast.dylib
codesign --verify --deep --strict out/applescreen-universal-release/src/Applescreen.app
```

Native playback/file fixture tests require the OS media services; a restrictive
automation sandbox may prevent initialization. They do not prove physical
speaker/display timing. Cross-compilation is not execution on the other CPU or
on macOS 12.7.6. Actual packaging and hardware results belong in the migration
report and must not be inferred from these commands.

## Local development receivers

In the Receiver tab, **Generate CA & Key…** creates a new private subfolder at the
location you choose, writes a one-year RSA CA and private key, and selects both
files. Existing credentials are never overwritten. Generation uses the core's
statically linked crypto library and runs off the UI thread. Only paths are
remembered in preferences; the private key stays in its owner-only file. Share
`development-ca.crt` with senders; keep `development-ca.key` on the receiver.

Create a new local development CA explicitly. This never runs as a build hook,
never overwrites an existing credential directory, and does not touch credentials
in a sibling project:

```sh
python3 applescreen/scripts/create_development_credentials.py \
  --directory out/applescreen-development-credentials
```

The command above is an alternative to the in-app action, for CLI workflows.

In the receiver UI select `development-ca.crt` and `development-ca.key`. In an
Applescreen sender select that same **certificate** in Developer CA; leave the
field empty for normal Cast trust. The private key belongs only to the receiver.
The CA is a one-year RSA signing root with explicit CA/key-usage extensions. The
receiver derives its device-authentication identity from it; this is separate
from transport TLS credentials. Invalid, expired, mismatched or unreadable
selected credentials must fail rather than fall back to normal trust.

For upstream CLI interoperability, use the freshly built executable's `--help`
to locate that revision's certificate/private-key/development-root flags. Share
the generated CA between the test processes while retaining the normal Cast
device-authentication challenge. A CLI on this Mac can exercise protocol and
media paths, but a separate host is still needed to prove non-loopback local
socket binding and network interoperability.

## Native Cast integration fixtures

### Local Network permission

Bonjour error `-65570` is `kDNSServiceErr_PolicyDenied`: allow Applescreen in
**System Settings → Privacy & Security → Local Network**, then click **Refresh**
(or **Start Receiver** for publication). The app now displays these instructions
and retries failed discovery when it becomes active again. It does not poll or
change privacy settings. The first request can fail before the user answers the
OS prompt. The bundle already declares its usage description and
`_googlecast._tcp` service.

For reliable permission identity across rebuilds, set
`-DAPPLESCREEN_CODESIGN_IDENTITY='Apple Development: …'` to an installed
Apple-issued signing identity. The default remains ad-hoc (`-`) when none is
available. This workspace had no valid signing identity installed, so actual
privacy consent still needs to be granted by the user for the built application.
See [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

### Running native fixtures

After building `applescreen_tests`, the existing file-source fixture writer can
materialize its six small files for interoperability tests:

```sh
out/applescreen-arm64-debug/file_source_test --write-fixtures out/cast-fixtures
out/applescreen-arm64-debug/cast_native_smoke --receiver \
  --ca out/applescreen-development-credentials/development-ca.crt \
  --key out/applescreen-development-credentials/development-ca.key \
  --sessions 3 --timeout 60 --window
```

In a second terminal, run one sender process per fixture while the receiver is
listening. Run these commands before its timeout:

```sh
out/applescreen-arm64-debug/cast_native_smoke --sender \
  --ca out/applescreen-development-credentials/development-ca.crt \
  --file out/cast-fixtures/audio.mov
out/applescreen-arm64-debug/cast_native_smoke --sender \
  --ca out/applescreen-development-credentials/development-ca.crt \
  --file out/cast-fixtures/video-60.mov
out/applescreen-arm64-debug/cast_native_smoke --sender \
  --ca out/applescreen-development-credentials/development-ca.crt \
  --file out/cast-fixtures/combined-offset-250ms.mov
```

The receiver keeps listening between streams and exits after three completed
sessions; the sender waits for source EOF, core drain, STOP and final runtime
shutdown. Both roles use the real native discovery and Cast authentication path.
Use `--interface en0` (or another actual interface) explicitly when desired.
The optional `--window` attaches the received native display layer to a real
resizable/fullscreen-capable AppKit window. The tiny fixtures include silence;
these tests therefore establish neither measured A/V skew nor audible fidelity.

`runtime_loopback_test FIXTURE DEVELOPMENT_CA DEVELOPMENT_KEY` exercises both
roles in one runtime, refresh during an active connection, and shutdown. It is
opt-in because credentials and fixture paths are required. Loopback and separate
processes on one Mac do not replace a two-host connectivity test.

## Dependency validation recorded during this migration

The locked Opus, libvpx, libaom and FFmpeg recipes have built with the DEPS clang
for arm64 Debug, arm64 Release and x86_64 Release. Archive load-command inspection
of the first two-architecture builds found only macOS **12.7.6** deployment
versions. Unchanged arm64 Debug/x86_64 Release reruns did not fetch, configure or
compile any codec. The universal app and core have since built, passed slice,
deployment-version, dependency and signature inspection, and launched on arm64
outside the build directory. Intel hardware execution remains unverified.

The untouched upstream `StreamingFfmpegEncoderTest` also exercises H.264/HEVC
factories that are not Applescreen sender options. A separate validation profile
can provide those two native VideoToolbox encoders without enabling them in the
product's sender capability table:

```sh
python3 applescreen/scripts/build_codecs.py \
  --workspace out/applescreen-validation-codecs \
  --openscreen out/openscreen-baseline/openscreen \
  --arch arm64 --configuration Debug --upstream-encoder-tests
```

Use that profile's manifest/library paths for the full codec-enabled upstream
validation target. Keep the normal app profile separate. A test failure from an
unavailable native hardware encoder must be reported, not hidden by deleting or
skipping the upstream test.

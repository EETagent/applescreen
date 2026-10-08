# Applescreen

A native macOS Cast sender and receiver. Send a screen or an audio/video file;
receive media using FFmpeg decoding and synchronized AVFoundation playback.
The minimum deployment target is macOS 12.7.6.

The Cocoa application and all maintained integration code live here. One GN-built
Cast core owns Open Screen for both roles, behind a private C/CF interface. CMake
builds the application and orchestrates the pinned dependencies. FFmpeg, libaom,
libvpx and Opus are built as static archives and linked into the core. Explicit
universal packaging produces arm64 and x86_64 slices in both the app and core.

- [Build, package, and run native tests](docs/build.md)
- [Dependency lock](dependencies.lock.json)
- [Upstream preservation and synchronization baseline](docs/upstream-baseline.md)
- [Migration results, regression coverage, and remaining validation](docs/migration-report.md)
- [Small generic upstream integration patches](patches/integration/README.md)

Development receivers use an explicitly selected development CA with the normal
Cast authentication challenge. See the build guide for credential generation;
credentials are never generated automatically during a build.

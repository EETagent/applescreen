# Small Open Screen integration seams

All patches are based on the exact revision in `dependencies.lock.json` and apply
in that manifest's order. `scripts/prepare_openscreen.py` checks their SHA-256,
checks applicability, and applies them once with the Git index in an independent
derived checkout. The canonical upstream source stays pristine. App code is a
symlink to this repository, not code copied into these patches.

| Patch | Purpose / affected targets | Regression / drop condition |
| --- | --- | --- |
| 0001 | Extract existing FFmpeg glue, decoder, and streaming encoders into source-only production targets. Grant only the named app core access to the existing platform and receiver agent. Original demo targets remain test-only. | DEPS GN generation and explicit app header check; upstream tests and app core link. Drop when equivalent upstream embedder targets are public. |
| 0002 | Return errors from TLS credential setup and Listen, including bind failure, so publication follows actual listener readiness. | TLS missing/invalid credentials and occupied-port tests. Drop when upstream offers checked listener readiness. |
| 0003 | Bound pending raw and undelivered encoder work before allocation/copy, retaining existing congestion and keyframe handling. | Actual VP8/VP9 encoder work with an intentionally undrained owner queue. Drop when upstream admission has an equivalent bound. |
| 0004 | Parse a nonempty owned PEM trust bundle, rejecting malformed/partial input without falling back to normal roots. | Valid roots authenticate an existing chain after input release; malformed/empty/trailing bundles fail. Existing normal Cast authentication suite remains. Drop when upstream has an owned, error-returning trust factory. |
| 0005 | Flush partial PCM and Opus codec lookahead at EOF without rebasing timestamps. | Actual mono/stereo encode/decode fixtures preserve final audible samples for exact and partial packets. Drop when upstream exposes equivalent end-of-input behavior. |
| 0006 | Generate normal device and TLS credentials from owned validated PEM instead of reopening selected paths; return generation errors. | Invalid/mismatched/non-CA/expired/future roots and valid owned credentials. Drop when upstream accepts owned credentials and reports these failures. |

These are generic build/API/correctness seams. No application implementation,
Bonjour factory substitution, SDL migration, certificate bypass, blanket
visibility grant or include-check suppression is carried here. The earlier
eight-patch application remains only during the migration checkpoint and is
removed from the completed native build workflow.

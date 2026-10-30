# Agent notes for Loopbacker

Loopbacker is a macOS 26+ virtual audio loopback driver (`Driver/`, C++17, CMake) plus a SwiftUI
app (`App/Loopbacker`, Swift 6). Read `docs/architecture/ARCHITECTURE.md` before touching the
audio path, and `PRODUCT.md` / `DESIGN.md` before touching UI.

## Build and test

```bash
make bundle                            # driver + app → build/Loopbacker.app
cd App/Loopbacker && swift test        # DSP tests (noise suppression, meters); CI runs these
cd App/Loopbacker && swift build -c release
```

- Code that runs in a CoreAudio IO callback must not allocate, lock, call Objective-C, or block.
  `scripts/bench/model-bench.sh` and `count.c` check for allocations.
- A bundled resource (models, licenses) has to be copied in **both** the Makefile `bundle` step
  and the "Create .app bundle" step of `.github/workflows/release.yml`, which builds the app
  without the Makefile.
- The app ships for Apple silicon only, but GitHub's CodeQL Swift analysis builds the package
  as x86_64. `swift build -c release --arch x86_64` has to compile, vendored C included.

## The maintainer's machine

The installed `/Applications/Loopbacker.app` usually has live routes: their mic in calls.
Killing, relaunching, or `make install-app` drops their audio for a few seconds. Batch changes
and do it as few times as possible, and tell them when you did.

## Releasing

1. `swift test` passes, and the change has been checked in the running app.
2. Bump `App/Loopbacker/Resources/Info.plist`: `CFBundleShortVersionString` (semver) and
   `CFBundleVersion` (build number, +1). Commit as `bump version to X.Y.Z (build N)`.
3. Push `main`, then tag and push the tag: `git tag vX.Y.Z && git push origin vX.Y.Z`.
   `release.yml` builds the DMG and driver zip, signs and notarizes them when the secrets are
   set, generates an SBOM and checksums, and creates the GitHub release.
4. **Write the release notes.** The workflow only uses `--generate-notes`, which on this repo is
   just a "Full Changelog" link. Once the release exists, replace the body:
   `gh release edit vX.Y.Z --notes-file notes.md`. A release without notes isn't done.

## Release notes

Follow the earlier releases (`gh release view v4.3.0`, `v4.4.0`). Write for users, not for
reviewers of the diff.

- **Opening line:** one sentence on what this release is about.
- **`## Highlights`:** one bullet per user-visible change, starting with a bold summary, then
  what changed and why it matters. Name the UI where it lives ("each source's Options").
- **`## Benchmarks`, for any performance change.** Before/after tables with the previous
  release as one column and this release as the other. Say the machine (e.g. M4 Max), what was
  running (routes, noise suppression on/off, window visible or covered), the method (e.g.
  per-thread CPU from `ps -M` over 20 s, or `scripts/bench/app-bench.sh`) and the unit (% of
  one core, ms per hop). Measure both builds the same way and never reuse numbers from a
  different setup. `scripts/bench/` has the tooling.
- **Tables for anything that changed a table-shaped fact.** For example, when noise engines
  change, include the engine table (latency, CPU, what it cleans up, license). When latency
  changes, include old vs new.
- **`## Fixes`:** user-visible bugs, described by symptom.
- **`## Under the hood`:** tests, refactors, vendored code, tooling. Keep it short.
- **`## Upgrading`:** what happens to existing settings, and anything the user must do.
- End with `**Full Changelog**: https://github.com/JacobCoffee/loopbacker/compare/vPREV...vX.Y.Z`.

Every number must come from a measurement you ran or a cited source. Don't estimate.

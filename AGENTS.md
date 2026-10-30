# Agent notes for Loopbacker

Loopbacker is a macOS 26+ virtual audio loopback driver (`Driver/`, C++17, CMake) plus a SwiftUI
app (`App/Loopbacker`, Swift 6). Read `docs/architecture/ARCHITECTURE.md` before touching the
audio path, and `PRODUCT.md` / `DESIGN.md` before touching UI.

## Build and test

```bash
make bundle                                    # driver + app → build/Loopbacker.app
cd App/Loopbacker && swift test                # fast; skips the factory-preset matrix
cd App/Loopbacker && swift test -c release     # everything; what CI runs
cd App/Loopbacker && swift build -c release
LOOPBACKER_RENDER_SNAPSHOTS=1 swift test --filter EffectsRenderTests  # Effects page PNGs in /tmp
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

### Sparkle auto-update signing

Updates are signed with an EdDSA (ed25519) key pair. The private key lives in the maintainer's
login keychain (generated with Sparkle's `generate_keys` tool, account `ed25519`) and as the
repo secret `SPARKLE_ED_PRIVATE_KEY` (the base64 export from `generate_keys -x`), which
`release.yml` pipes into `generate_appcast --ed-key-file -` to sign each release's appcast entry
-- it's never written to disk or echoed. The matching public key is committed in
`App/Loopbacker/Resources/Info.plist` as `SUPublicEDKey`; it isn't secret.

If the secret is missing, the release still completes; `release.yml` logs a warning and skips
publishing `appcast.xml`, so already-installed apps won't see that release until a later one
re-signs with a working key.

**Rotating the key** (compromise, or replacing the maintainer's machine): run
`generate_keys` again to create a new keychain entry, export it with `-x`, update the
`SPARKLE_ED_PRIVATE_KEY` secret, and replace `SUPublicEDKey` in `Info.plist` with the new public
key printed alongside it. Existing installs validate updates against the public key baked into
*their own* binary, so they won't trust appcast entries signed with the new key until they first
update to a build that ships the new `SUPublicEDKey` -- cut one last release signed with the old
key that also carries the new public key in its `Info.plist` before fully switching over.

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

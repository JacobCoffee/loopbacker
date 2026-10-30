# CAirwindows

Vendored subset of [baconpaul/airwin2rack](https://github.com/baconpaul/airwin2rack)
(MIT, `LICENSE.md`), pinned at commit `a1eb817579e86215f76aa22dfcccecd49b103368`.

Vendored verbatim:

- `AirwinRegistry.{h,cpp}` — the effect registry (names, categories, summaries,
  per-effect factory functions). `documentationStringFor` is modified (see
  below) to drop the CMakeRC dependency.
- `airwin_consolidated_base.{h,cpp}` — the shared VST-era base class every
  effect implements (`processReplacing`, `get/setParameter`, ...).
- `ModuleAdd.h` — includes every effect header and registers it with
  `AirwinRegistry::registerAirwindow`; the last line completes the registry.
- `autogen_airwin/*.{h,cpp}` — the ~528 generated effect implementations
  (Pressure5, Air, PurestGain, Galactic, ...), one namespace per effect.
- `awpdoc/*.txt` — upstream's per-effect long-form documentation
  (`res/awpdoc/*.txt`), used only to generate `AirwinDocs.generated.cpp`
  below; not compiled directly and not shipped as an app resource.

Not vendored: `src-rack/`, `src-juce/`, the CMake/RackSDK build glue, and
`cmake/CmakeRC.cmake` — none of it applies to a SwiftPM C++ target.

## Doc embedding instead of CMakeRC

Upstream serves `res/awpdoc/*.txt` through a CMakeRC resource library baked
into the binary as a virtual filesystem. That needs a build step Swift
Package Manager doesn't have, and would otherwise require shipping ~2.4 MB of
loose text files as an app-bundle resource. Instead, `Scripts/generate_airwin_docs.py`
reads `awpdoc/*.txt` and emits `AirwinDocs.generated.cpp`: a static
name→base64 table plus a tiny decoder, compiled straight into the target.
`AirwinRegistry::documentationStringFor` calls `airwinDocTextFor` (declared in
`AirwinDocs.generated.h`) instead of opening a CMakeRC filesystem. Base64
avoids escaping concerns entirely (the docs are full of curly quotes,
backslashes, and the occasional literal `"`).

Re-run `python3 Scripts/generate_airwin_docs.py` and commit the regenerated
`.cpp` after updating `awpdoc/`.

## C shim (`include/aw_shim.h`, `shim.cpp`)

Swift cannot call C++ directly. `aw_shim.h` is a pure-C header (opaque
`AWInstance*` handle) that Swift imports as a normal C target module;
`shim.cpp` implements it against `AirwinRegistry`/`AirwinConsolidatedBase`.
`aw_process`/`aw_get_param`/`aw_set_param` touch only plain data on an
already-constructed effect and never allocate, so `AirwindowsNode` may call
them from the IO thread; everything else (`aw_create`, `aw_destroy`, name/doc
lookups) must run off it.

## Known limits

Airwindows effects expose no native "reset" — internal state (filters, delay
taps, the `fpdL`/`fpdR` dither seeds) is only ever initialized in the
constructor. `AirwindowsNode.reset()` is therefore a documented no-op: state
settles from near-silent input within a block or two, and the alternative
(reconstructing the instance) would allocate/deallocate on the IO thread,
which the contract forbids.

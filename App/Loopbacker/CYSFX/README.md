# CYSFX

Vendored subset of [JoepVanlier/ysfx](https://github.com/JoepVanlier/ysfx) (the maintained fork
of jpcima/ysfx), pinned at commit `5c3452fee62583aa3d1b7e877d0c758c4024af89` (2026-08-19). ysfx
is a JSFX (REAPER's scripting-language audio effect format) compiler and runtime: it embeds
Cockos WDL's EEL2 expression-language JIT compiler and (for `@gfx` scripts) WDL's LICE software
rasterizer and SWELL Win32-on-Cocoa shim.

Licenses: ysfx itself is **Apache-2.0** (`../Resources/YSFX-LICENSE.txt`, copied verbatim from
upstream `LICENSE`, with stb's dual MIT/public-domain notice appended since stb is vendored
alongside it — see below). WDL (EEL2, LICE, SWELL) is **zlib-style**
(`../Resources/WDL-LICENSE.txt`, copied verbatim from upstream `thirdparty/WDL/LICENSE.txt`).
The GAS port of EEL2's x86-64 JIT glue (`ysfx-sources/eel2-gas/asm-nseel-x64-sse.S`) is zlib
("SPDX-License-Identifier: Zlib" in its header), covered by the same WDL license text; its own
`ysfx-sources/eel2-gas/LICENSE.txt` copy is excluded from the SwiftPM target (not a source file)
but kept for reference.

## Layout
- `include/ysfx.h` — the public C API (unmodified).
- `ysfx-sources/` — ysfx's own `sources/*.cpp/.hpp` (unmodified except `ysfx_config.cpp`, see
  below), `sources/lice_stb/*`, `sources/base64/Base64.hpp`, `sources/utility/sync_bitset.hpp`,
  `sources/eel2-gas/asm-nseel-x64-sse.S` — all exactly as upstream ships them.
- `WDL/` — the subset of `thirdparty/WDL/source/WDL` that `ysfx-sources` and `swell-gdi.mm`
  actually `#include`, traced by hand from upstream's own `cmake.wdl.txt`/`cmake.ysfx.txt`:
  - `eel2/`: the 7 `nseel-*.c` compiler/VM translation units, `ns-eel*.h`, `y.tab.c/.h` (the
    pre-generated bison parser — the `.l`/`.y` grammar sources and the flex/bison toolchain are
    not vendored, only their checked-in C output), `glue_aarch64.h` (arm64 JIT codegen, a header
    textually `#include`d by `nseel-compiler.c`), `glue_x86_64_sse.h`, `asm-nseel-aarch64-gcc.c`
    (textually `#include`d by `nseel-cfunc.c` on `__aarch64__` — **excluded from the SwiftPM
    target's compiled sources** via `Package.swift`'s `exclude:` to avoid a duplicate-symbol
    link error; it is still present on disk because `nseel-compiler.c`/`nseel-cfunc.c` `#include`
    it directly), `eel_pproc.h/misc.h/strings.h/fft.h/mdct.h/atomic.h` (the optional EEL2
    extension headers ysfx actually uses). `y.tab.c` is excluded the same way (textually
    `#include`d by `nseel-yylex.c`). Not vendored: `eel_lice.h`, `eel_net.h`, `eel_import.h`,
    `eelscript.h`, `eel_files.h`, `ns-eel-func-ref.h`, the ppc/arm32/x86-32/MSVC glue and asm
    files — none of these are reachable on our build (arm64 + x86_64 Apple, GCC/Clang only).
  - `lice/`: the 9 `.cpp` files upstream's `cmake.wdl.txt` lists for the `lice` target, plus
    their headers.
  - `swell/`: the **macOS** backend only (`swell.cpp`, `swell-ini.cpp`, `swell-gdi.mm`,
    `swell-appstub.mm`, `swell-dlg.mm`, `swell-kb.mm`, `swell-menu.mm`, `swell-misc.mm`,
    `swell-miscdlg.mm`, `swell-modstub.mm`, `swell-wnd.mm`, plus `swell.h`/`swell-types.h`/
    `swell-internal.h`/`swell-functions.h`/`swell-win32.h`/`swell-dlggen.h`/`swell-menugen.h`/
    `swell-gdi-internalpool.h`) — exactly upstream's own Apple file list for the `lice` target in
    `cmake.wdl.txt`. SWELL's Linux/generic backend (`swell-*-generic.cpp`, fontconfig/freetype,
    GDK) is not vendored. SWELL is needed because `LICE_CachedFont`'s glyph rasterizer renders
    each glyph once through a native HDC (`LICE_SysBitmap::getDC()` → `SWELL_CreateMemContext` →
    a CGBitmapContext, text drawn via SWELL's CoreText-backed `DrawText`) and caches the bitmap —
    there is no built-in vector/bitmap font, so `@gfx`'s `gfx_drawstr` genuinely needs this.
    `swell-wnd.mm`/`swell-dlg.mm`/`swell-menu.mm` etc. are compiled (ysfx's own `lice` target
    links all of them as one unit) but never exercised by `JSFXEditorViewController`, which owns
    its own `NSView` and never creates a SWELL window/dialog/menu.
  - Top-level headers used transitively: `assocarray.h`, `denormal.h`, `fft.c/.h`, `heapbuf.h`,
    `lineparse.h`, `mergesort.h`, `mutex.h`, `ptrlist.h`, `queue.h`, `utf8_extended.h`,
    `wdlatomic.h`, `wdlcstring.h`, `wdlstring.h`, `wdltypes.h`, `wdlutf8.h`, `win32_utf8.h`.
- `stb/stb_image.h`, `stb/stb_image_write.h` — upstream's `thirdparty/stb`, used by
  `lice_stb_loaders.cpp`/`lice_stb_write.cpp` for `gfx_loadimg`/screenshotting. `stb/LICENSE` is
  excluded from the target (not a source file) but kept for reference; its text is folded into
  `YSFX-LICENSE.txt`.

## Omitted on purpose
- **`dr_libs`** (`dr_wav.h`/`dr_flac.h`, a git submodule upstream doesn't vendor directly) is not
  fetched, so `ysfx_audio_wav.cpp`/`ysfx_audio_flac.cpp` are not built. `ysfx_config.cpp` is
  patched (the only modification to any ysfx core source) to drop the two `#include`s and make
  `ysfx_register_builtin_audio_formats` a no-op instead of registering the wav/flac format
  objects — `ysfx_detect_file_type`'s `audio_formats` loop (`ysfx.cpp`) just finds nothing and
  returns `ysfx_file_type_none`, which is safe (checked by reading the call site). Effect: the
  `file_*` EEL opcodes still work for an effect's own data files (text/raw), but loading an
  external `.wav`/`.flac` as a named audio format does not. No JSFX fixture here needs it, and
  it keeps the vendoring surface smaller.
- ysfx's own test/plugin/tool CMake targets, JUCE wrapper, CLAP/VST3/AU3 plugin glue, `thirdparty/
  json`, `thirdparty/clap-juce-extensions` — none of that is part of the hosting library.

## arm64 JIT: the `com.apple.security.cs.allow-jit` patch
Upstream's EEL2 JIT (`nseel-compiler.c`) allocates its code buffer with a plain anonymous
`mmap(PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE)` and toggles it to `PROT_READ|PROT_EXEC` with
`mprotect()` right before running compiled code (`eel_set_blocks_allow_execute`). That is exactly
the pattern the macOS hardened runtime forbids: without `MAP_JIT`, the kernel refuses to grant a
mapping both write and execute permission at different times. Two call sites in
`WDL/eel2/nseel-compiler.c` are patched for `__APPLE__` (both patches are isolated under
`#elif defined(__APPLE__)`/`#ifdef __APPLE__` branches so non-Apple builds, and the file's own
`EEL_TARGET_PORTABLE` fallback, are untouched):
1. `__newBlock_align`'s code-block `mmap` now requests
   `PROT_READ|PROT_WRITE|PROT_EXEC` with `MAP_ANON|MAP_PRIVATE|MAP_JIT` up front.
2. `eel_set_blocks_allow_execute` now calls `pthread_jit_write_protect_np(exec)` instead of
   `mprotect()`. A `MAP_JIT` page keeps one fixed RWX mapping; Apple Silicon enforces write-xor-
   execute **per thread** via this call (an undocumented-to-userspace privileged register, not a
   page-table permission bit), so `mprotect()` on the same page is a no-op on the actual
   enforcement and would leave the compiled EEL code unexecutable (or, on Intel, would work by
   accident since Intel doesn't have the per-thread restriction — so the bug would only surface
   on Apple Silicon, which is Loopbacker's only target).

**Entitlement needed: exactly `com.apple.security.cs.allow-jit`.** This is the entitlement that
permits `MAP_JIT` mappings at all; it is necessary and sufficient here — the broader
`com.apple.security.cs.allow-unsigned-executable-memory` (which would also have papered over the
unpatched `mprotect()`-only code, at the cost of disabling a much wider set of code-integrity
checks) is not needed once the code goes through the proper `MAP_JIT` +
`pthread_jit_write_protect_np` path. Confirmed by building and exercising the JIT compiler from
Swift unit tests in this worktree (no App Sandbox/hardened-runtime wrapper is present in `swift
test`, so this does not by itself prove the entitlement is sufficient under a notarized, hardened
runtime build — that requires the AU slice's actual signed `.app` to be tested with
`com.apple.security.cs.allow-jit` present, since `swift test` binaries aren't the hardened,
notarized target `.app`). No other JIT-related entitlement, Info.plist key, or sandbox exception
is required by ysfx/EEL2 itself.


## LB-JIT-001: restore write-protect on every `NSEEL_code_compile_ex` exit
`eel_set_blocks_allow_execute(handle->blocks_code, 1)` (the call that flips this thread's JIT
pages back to execute-only) only runs on the success path, inside the `if (startpts || ...)`
branch. A compile that fails after `__newBlock_align` has already mapped at least one code
block (e.g. a syntax error in a later section/function, after an earlier one allocated) left
the thread's `pthread_jit_write_protect_np` flag in write mode with nothing to restore it.
Swift's cooperative-pool threads are reused across unrelated script compiles, so a thread left
writable this way could still modify every other already-compiled script's JIT code until it
next compiled successfully. `WDL/eel2/nseel-compiler.c`'s `NSEEL_code_compile_ex` now calls
`pthread_jit_write_protect_np(1)` unconditionally, under `#if defined(__APPLE__) &&
!defined(EEL_DOESNT_NEED_EXEC_PERMS)`, right after the `freeBlocks` calls near the end of the
function — after every path (success or failure) has released this call's own code/data
blocks, and before the function returns.

## LB-JSFX-002: a real EEL host mutex
Upstream's `NSEEL_HOSTSTUB_EnterMutex`/`LeaveMutex` (`ysfx_api_eel.cpp`) are empty stubs
("DSP and UI should not mutex each other"), but EEL2 itself relies on them for more than DSP/UI
coordination: lazy RAM/gmem block allocation (`WDL/eel2/nseel-ram.c`), the process-wide
global-variable list and VM refcount, and function-table sorting (`WDL/eel2/nseel-compiler.c`)
are all guarded only by these two calls. Loopbacker runs one `ysfx_t*`'s code on three threads
(`@sample` on the IO thread, `@gfx` on the main thread, `@serialize` via `ysfx_save_state` from
`JSFXNode.captureState` on the main actor) with no host-side lock otherwise, so the empty stubs
left a real data race. `ysfx_api_eel.cpp` now implements both stubs with a process-wide
recursive `WDL_Mutex` (already vendored, pthread `PTHREAD_MUTEX_RECURSIVE` on this platform).
`JSFXNode` additionally serializes `ysfx_save_state` against `process()` itself with an
IO-thread-never-blocks atomic try-lock (see `JSFXNode.swift`): if `process()` can't acquire it
because a capture is in flight, it skips that one block's `ysfx_process_float` call entirely
(passes the block through dry) rather than waiting. `@gfx` running concurrently with `@sample`
with no *VM-state* lock between them is unchanged and is JSFX's own upstream concurrency model,
not a gap introduced here (see "`@gfx` (main thread) runs concurrently with `@sample`" below).

## LB-PRESET-001: JSFX file access confined to relative paths under the data root
`ysfx_find_data_file` (`ysfx.cpp`) is the backing implementation for the `file_*` EEL opcodes a
script calls with `file_open()`. Upstream honors any absolute path a script's own string data
names (`accept_absolute`/`ysfx_string_get`), which let a script read any file the user's TCC
grants allow under Loopbacker's identity and feed the bytes into the voice chain's output — the
virtual mic other call participants hear, and whatever records it. `ysfx_find_data_file` no
longer honors `accept_absolute` at all: only the two relative candidates (next to the script,
and under `fx->config->data_root`) are tried, and a new `ysfx::path_contains_dotdot` check
(`ysfx_utils.cpp`/`.hpp`) rejects any candidate with a `..` path component before it is built,
closing parent-directory traversal out of the data root too. `JSFXNode.load` (Swift side) sets
`ysfx_set_data_root` explicitly to the resolved catalog root the effect was loaded from (rather
than relying only on `ysfx_guess_file_roots`'s heuristic), and independently validates
`ref.identifier` resolves (after symlink resolution) under one of the two known catalog roots
before ever calling into ysfx — see `JSFXNode.swift` and `FXNodeConfig.swift`'s
`FXPluginRef.identifier` doc comment for the on-disk/persisted format.

## EEL2 RAM/gmem allocation on the IO thread
EEL2's implicit per-script "memory" array (`x[123] = ...`) and the cross-script shared `gmem()`
pool are both backed by `WDL/eel2/nseel-ram.c`'s `__NSEEL_RAMAlloc`/`__NSEEL_RAMAllocGMEM`: each
is divided into 128 blocks of 65536 `EEL_F` (8 bytes) = 512 KiB, and **a block is `calloc`'d the
first time any index inside it is read or written — from inside the JIT-compiled code itself**,
i.e. potentially from `@sample` on the IO thread, exactly as flagged in the task brief.
`ysfx_read_vmem`/`ysfx_find_var`-style host APIs go through the same allocating path (confirmed
by reading `nseel-ram.c`; the `_noalloc` variant exists but is only used internally by
`ysfx_calculate_used_mem`, not by anything a host calls to pre-fault memory).

**Built in to ysfx, and used automatically by `load()`:** a script can declare
`options:prealloc=N` (or `prealloc=*` for all 128 blocks) in its header; `ysfx_compile`
(`ysfx.cpp:460`) then calls `NSEEL_VM_preallocram`, which calls the same allocating
`__NSEEL_RAMAlloc` for every requested block of the **main memory array** up front, during
compilation — i.e. off the IO thread, inside `load()`. This does not cover named `gmem()` pools
(a separate allocation table per name, outside `ram_state`), only the implicit `x[]` array.

Mitigation actually in place: `JSFXNode.load()` (see `Services/FX/Hosted/JSFX/JSFXNode.swift`)
is `async` and compiles **and runs `@init` off the IO thread**, per the host contract — this is
the primary mitigation for everything `options:prealloc` doesn't already cover, because it's
standard JSFX idiom for a script to pre-touch its own buffers in `@init` (e.g.
`i=0; loop(buflen, buf[i]=0; i+=1;)`), and when it does, the allocation happens during `load()`,
not `process()`. `load()` additionally reads index 0 of the main memory array once after `@init`
(`ysfx_read_vmem`, one `EEL_F`) to force-allocate block 0 unconditionally — this covers the
common case of small buffers/delay lines starting near index 0 even for scripts that declare no
`prealloc` option and don't bother pre-touching.

What is **not** mitigated, and can't be without pre-touching all 128 possible blocks of both the
main array and every named `gmem` pool (up to 128 × 512 KiB = 64 MiB per instance, for memory the
script may never touch) are documented here as the host's open limitation: (1) a script that
indexes far into its memory array (block > 0) for the first time from `@sample` without having
touched it in `@init`; (2) first use of a given named `gmem()` pool from `@sample` (there is no
public ysfx API to pre-touch a specific named `gmem` pool from the host — only the EEL script
itself names it). In both cases the very first touch does one `calloc(512 KiB)`; every subsequent
sample at any index in that block is allocation-free. This matches real REAPER/ysfx's own
documented behavior — it's an EEL2 design property, not something introduced by this vendoring.

## EEL2 compiler is not safe to call concurrently
`nseel-compiler.c`'s `optimizeOpcodes` caches some function lookups (e.g. the `x^const`/
`const^x` rewrite for `pow`) in function-local `static functionType *` variables, lazily
initialized from `nseel_getFunctionByName(NULL, ...)` — a lookup against a single process-wide
function table, with no locking of its own. Compiling two scripts concurrently from different
threads hit this directly during testing (a `WDL_ASSERT` abort in `optimizeOpcodes`, reproduced
by loading two fixtures that both use `^` from parallel `swift test` runs). `JSFXNode.load`
serializes `ysfx_compile`/`ysfx_init` process-wide behind a single `NSLock`
(`JSFXNode.compileLock`) as the fix. This only affects loading several JSFX effects at once
(already off the IO thread) — `process()` and parameter changes are unaffected and need no lock.

## `@gfx` (main thread) runs concurrently with `@sample` (IO thread)
`ysfx_gfx_run` and `ysfx_process_float` both execute against the *same* EEL VM instance and the
same registered variables (sliders, `gmem`, the implicit memory array, `spl0`/`spl1`), each
tagging the calling thread via `ysfx_set_thread_id` (`ysfx_thread_id_gfx` /
`ysfx_thread_id_dsp`) purely for internal bookkeeping — there is **no mutex guarding concurrent
VM execution** between the two paths. `ysfx.hpp`/`ysfx.cpp` only lock three narrow, specific
subsystems shared across threads: `string_mutex` (the string table), `image_mutex` (gfx image
cache), and the file list/file mutexes (`ysfx_api_file.cpp`'s `file_*` opcodes) — never a
general "VM state" lock. This is upstream's own design: the real ysfx plugin
(`plugin/components/graphics_view.cpp`) runs `@gfx` on JUCE's message thread while audio runs on
the audio thread, with the same absence of a VM-wide lock, so this host matches upstream's
concurrency model exactly rather than introducing a gap.

Practical consequence: reading a slider or scalar var from `@gfx` while `@sample` writes it
(our own `loopbacker_meter_gfx.jsfx` fixture's `peak` var is exactly this) can read a torn or
stale `EEL_F` (8-byte double) under a true data race, which is a correctness risk (a flickering
meter), not a safety one, on arm64/x86-64 where aligned 8-byte loads/stores are not split by the
hardware. The one place this becomes a *memory*-safety risk is EEL2's lazy RAM/`gmem`
first-touch `calloc` (`WDL/eel2/nseel-ram.c`, see above) — `pblocks[whichblock] = calloc(...)`
has no lock, so a block first touched by `@gfx` and `@sample` at the same time races on a plain
pointer write, confirmed by reading `nseel-ram.c` (not reproduced in testing: none of this
host's fixtures or the ReaTeam scripts smoke-tested below hit it, since well-behaved JSFX
pre-touches its buffers in `@init`, run single-threaded before either `@gfx` or `@sample` ever
starts). This is an inherent, unfixed-upstream EEL2 property (not introduced by this host) that
only surfaces for a script that both (a) indexes into a RAM block neither `@init` nor
`options:prealloc` has pre-touched, and (b) does so from both `@gfx` and `@sample` before either
side's first touch completes — documented here as an open limitation rather than silently
papered over, since fixing it upstream-correctly would mean adding a lock EEL2's design doesn't
have anywhere, including inside `@sample`, which the IO-thread no-locks contract forbids.

`JSFXEditorViewController`'s gfx tick (`JSFXNode.ysfxHandle` calls: `ysfx_gfx_setup`,
`ysfx_gfx_set_window_state`, `ysfx_gfx_run`, plus the mouse/keyboard forwarders) takes no lock of
its own, and neither does `JSFXNode.process`; the only lock in this slice,
`JSFXNode.compileLock`, is taken exclusively inside `load()`, never from `process()` or from the
editor's `tick()` — so there is no deadlock risk between the IO thread and the gfx/main thread.

## Measured: allocation, binary size, real-world smoke test
All measurements below used a throwaway interposed-malloc harness (the `scripts/bench/count.c`
pattern) linking directly against the built `CYSFX.o`, deleted after use; none of its code is
committed.

- **Allocation in `process()` steady state**: zero heap allocations (`malloc`/`calloc`/
  `realloc`/`free`/`posix_memalign`/`malloc_zone_malloc`, all interposed) across 10 s of signal
  at a 512-frame block size, after a 4-block warmup, for all three committed fixtures
  (`loopbacker_gain_pan.jsfx`, `loopbacker_fixed_delay.jsfx`, `loopbacker_meter_gfx.jsfx`) *and*
  for the 9 real-world ReaTeam/JSFX scripts that loaded successfully (below). Confirms
  `JSFXNode.process`'s design (fixed in/out pointer arrays reused across calls, no Array/
  Dictionary/String mutation, `ysfx_process_float`'s own hot path only ever indexing
  already-allocated EEL_F storage once warmed) holds in practice, not just by code reading.
- **Binary size**: stripped (`strip -x`) `swift build -c release` output, same worktree, CYSFX
  target added/removed via a temporary `Package.swift`/`Sources/Hosted` swap (restored
  afterwards; `git status` clean before and after): **7,332,664 bytes without CYSFX →
  8,260,328 bytes with CYSFX, +927,664 bytes (≈0.88 MB, ≈12.6%)**. The bulk is EEL2's compiler/
  JIT, LICE's software rasterizer + glyph cache, and SWELL's macOS GDI/window-system shim —
  none of it optional for JSFX hosting with `@gfx` support.
- **Real-world smoke test** (`ReaTeam/JSFX` at the commit cloned for this check; not committed),
  10 scripts across dynamics, EQ, saturation/distortion, delay, reverb, one explicitly chosen
  for `@gfx`, and others using `import`, 5 s of band-limited noise with a slow envelope at
  512-frame blocks:

  | Script | Category | Loaded | NaN-free | Latency | CPU / 512-block |
  |---|---|---|---|---|---|
  | `Dynamic/ersh_Transient Controller 2.jsfx` | dynamics, gfx | yes | yes | 0 ms | 0.030 ms |
  | `Dynamic/mrelwood_BandbAss.jsfx` | dynamics/compressor, gfx | yes | yes | 0 ms | 0.091 ms |
  | `Filter/bellesondes_eq1979.jsfx` | EQ, gfx | yes | yes | 0 ms | 0.075 ms |
  | `Filter/tilr_QuickFilter.jsfx` | EQ, import, gfx | yes | yes | 0 ms | 0.029 ms |
  | `Distortion/rcjach_RCInflator.jsfx` | saturation | yes | yes | 0 ms | 0.035 ms |
  | `Distortion/Loudener.jsfx` | saturation, gfx | yes | yes | 0 ms | 0.035 ms |
  | `Utility/CoreyScogin_TimeDelayByDistance.jsfx` | delay | yes | yes | 0 ms | 0.020 ms |
  | `Reverb/TiaR_HadamVerb.jsfx` | reverb, import | yes | yes | 0 ms | 0.102 ms |
  | `Filter/tilr_SKFilter.jsfx` | EQ, gfx | **no** | — | — | — |
  | `Modulation/snjuk2_LFO.jsfx` | modulation, import, gfx | yes | yes | 0 ms | 0.019 ms |

  9/10 compiled and ran cleanly (`mrelwood_BandbAss.jsfx`/`tilr_QuickFilter.jsfx` logged a
  non-fatal `[ysfx] warning: sliderN: the enumeration has an invalid range` to stderr, no crash,
  no NaN). `tilr_SKFilter.jsfx` failed to load: its import line reads
  `skf.Saike_Yutani_upsamplers.jsfx-inc`, but the checked-out repo has the sibling file
  (128 KB, present) named `skf.Saike_Yutani_upsamplers` with **no** `.jsfx-inc` extension — a
  naming mismatch in that script's own repository, not a bug in `ysfx_resolve_import_path` or
  this host (`ysfx_set_import_root` was correctly pointed at the script's own directory; the
  exact sibling file ysfx asked for is simply absent under that name). None of the 10 reported
  any latency (`pdc_delay`) — expected, since none of them are delay-compensating effects; the
  committed `loopbacker_fixed_delay.jsfx` fixture (10 ms / 480 samples at 48 kHz) is the latency
  coverage.

## Differences from upstream behavior
- `NSEEL_ATOF`/`WDL_LINEPARSE_ATOF` are not overridden to the locale-independent
  `ysfx_wdl_atof` upstream's CMake wires up; plain `atof()` is used. Only matters for
  scripts with numeric literals parsed under a decimal-comma locale, which Loopbacker (an
  English-UI macOS app) does not set.
- `ysfx_register_builtin_audio_formats` is a no-op (see "Omitted on purpose" above).

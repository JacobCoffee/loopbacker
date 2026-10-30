#!/usr/bin/env python3
"""Regenerates CWebRTCAEC/webrtc and CWebRTCAEC/abseil-cpp from meson+ninja builds of
webrtc-audio-processing, using ninja's introspection (not hand-maintained file lists) to find
the exact dependency closure -- for both architectures this target has to compile under
(`swift build`, arm64, what ships, and `swift build --arch x86_64`, what GitHub's CodeQL Swift
analysis uses; see "x86_64 support" below and ../AGENTS.md).

Usage (from scratch):
    brew install meson ninja           # arm64 Homebrew, i.e. /opt/homebrew/bin
    git clone --branch v2.1 https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git /tmp/wap
    cd /tmp/wap
    meson setup build-arm --default-library=static --buildtype=release
    ninja -C build-arm
    cat > /tmp/x86_64-cross.ini <<'EOF'
    [binaries]
    c = ['clang', '-arch', 'x86_64']
    cpp = ['clang++', '-arch', 'x86_64']
    ar = 'ar'
    strip = 'strip'
    pkgconfig = 'pkg-config'
    [host_machine]
    system = 'darwin'
    cpu_family = 'x86_64'
    cpu = 'x86_64'
    endian = 'little'
    EOF
    meson setup build-x86 --cross-file /tmp/x86_64-cross.ini --default-library=static --buildtype=release
    ninja -C build-x86
    python3 /path/to/CWebRTCAEC/generate.py /tmp/wap/build-arm /path/to/CWebRTCAEC --x86-64-build-dir /tmp/wap/build-x86

What this does and why:
  1. `ninja -t compdb` gives the exact compiler invocation (defines, include paths, and per-file
     `-m` flags such as `-mavx2 -mfma`) for every object file meson decided to compile -- this is
     the ground truth for what the build actually needs, instead of guessing from
     BUILD.gn/meson.build dependency graphs by hand.
  2. `ninja -t query <target>` on the final linked library/executable recursively lists every
     object file (including ones statically folded in from rtc_base/, api/, common_audio/,
     system_wrappers/, third_party/*, and the abseil-cpp subproject) that ends up in the
     binary -- this is the real link-time closure, not just what AEC3's own .cc files include.
  3. `ninja -t deps` dumps clang's `-M`-style header dependency database that ninja already
     collected during the build, which gives the exact set of project headers (as opposed to
     system/SDK headers) each of those object files actually included -- again ground truth,
     not a hand-rolled include scan.
  4. Every file from (2) and (3) is copied into `webrtc/` or `abseil-cpp/` here, preserving its
     path relative to the webrtc-audio-processing checkout (for `webrtc/...`) or relative to
     `subprojects/abseil-cpp-<version>/` (for `abseil-cpp/...`, so the directory name doesn't
     carry the pinned version number).

Re-run this after bumping the pinned tag to refresh the vendored tree; diff the output against
the current CWebRTCAEC/ to see what changed. The compiler defines and include paths this
discovers should also be checked against Package.swift's CWebRTCAEC target settings --
this script only prints them, it does not edit Package.swift.

## x86_64 support

`rtc_base/system/arch.h` picks `WEBRTC_ARCH_X86_FAMILY`/`WEBRTC_ARCH_ARM_FAMILY` itself from
compiler macros (`__x86_64__`/`__aarch64__`), so Package.swift does not (and must not) hard-code
an arch define: the arm64 meson build's object closure simply never includes the x86-only SIMD
translation units (`*_sse*.cc`, `*_avx2.cc`), because meson's own build graph is arch-conditional
and only the arm64 closure gets vendored from a single arm64 build. The `--x86-64-build-dir`
flag unions in the extra translation units an x86_64 meson build adds (SSE2/AVX2 `FIRFilter`,
`SincResampler`, Ooura FFT, and several AEC3 kernels) that the arm64 closure lacks, so
`swift build --arch x86_64` has everything `fir_filter_factory.cc` et al. `#include` on that
arch.

Those extra `.cc` translation units are wrapped in `#if defined(__x86_64__)` here before being
written out: SwiftPM compiles one source list per target regardless of `--arch` (there is no
per-file or per-arch source list), so an x86-only `.cc` that unconditionally
`#include`s `<xmmintrin.h>`/`<immintrin.h>` would fail to even parse when the same target is
compiled for arm64 (those headers themselves `#error` outside `__i386__`/`__x86_64__`). Files
whose original meson compile command included `-mavx2`/`-mfma` (ground truth from `compdb`, not
guessed from the filename) additionally get a
`#pragma clang attribute push(__attribute__((target("avx2,fma"))), apply_to = function)` /
`pop` pair around their body: SwiftPM has no way to pass `-mavx2 -mfma` to only those files
either, and the target attribute lets clang accept the AVX2/FMA intrinsics in just those
functions without raising the baseline ISA for the whole CWebRTCAEC target (which would make the
output binary require a CPU newer than SSE2 baseline, and would also break compiling for arm64
in the same target). Headers are copied unpatched -- none of the ones this discovers so far
declare types or members that need arch-specific intrinsics; they only forward-declare classes
and functions behind `#if defined(WEBRTC_ARCH_X86_FAMILY)` (itself derived from `arch.h`,
already safe) or hold plain scalar members. If a future upstream bump adds a header that does
use raw intrinsics, this script will still copy it (just unpatched) and `swift build --arch
x86_64` will fail loudly at that header -- patch it by hand the same way the `.cc` files below
are patched, and extend `_NEEDS_PATCH_EXTS` accordingly.

No equivalent union is needed for CYSFX or CAirwindows: CYSFX's EEL2 JIT already selects its
glue header (`glue_aarch64.h` vs `glue_x86_64_sse.h`) via `__aarch64__`/`__x86_64__` in
`nseel-compiler.c`, and the vendored x86-64 JIT trampoline
(`ysfx-sources/eel2-gas/asm-nseel-x64-sse.S`) is already wrapped in `#if defined(__x86_64__)`
upstream; CAirwindows has no architecture-specific code at all. Both compile under
`swift build --arch x86_64` unmodified.
"""
import json
import os
import shutil
import subprocess
import sys

# Translation units whose vendored copy needs the `#if defined(__x86_64__)` wrap (and, when the
# original compile command used AVX2/FMA, the `#pragma clang attribute` wrap) because they are
# only ever compiled by an x86_64 meson build and unconditionally include x86 intrinsic headers.
_PATCHABLE_EXTS = (".cc", ".c")

_WRAP_HEADER = """\
// Vendoring patch (CWebRTCAEC, fx3/x86): this is an x86-only translation unit;
// SwiftPM compiles one source list per target regardless of --arch, so wrap the
// whole file instead of excluding it per arch. See CWebRTCAEC/README.md.
"""

_WRAP_HEADER_AVX2 = """\
// Vendoring patch (CWebRTCAEC, fx3/x86): this is an x86-only translation unit;
// SwiftPM compiles one source list per target regardless of --arch, so wrap the
// whole file instead of excluding it per arch. The AVX2/FMA intrinsics below need
// a target attribute since SwiftPM has no per-file compiler flags (upstream meson
// builds this translation unit with -mavx2 -mfma). See CWebRTCAEC/README.md.
"""


def _find_license_end(lines):
    assert lines[0].startswith("/*"), "expected a /* ... */ license header first"
    for i, line in enumerate(lines):
        if line.strip() == "*/":
            return i + 1
    raise RuntimeError("no license header end ('*/') found")


def _wrap_x86_64(text, needs_avx2_fma):
    """Wraps a .cc/.c file's body (everything after its license header) in
    `#if defined(__x86_64__)` / `#endif`, and in a target("avx2,fma") pragma pair too if the
    file needs AVX2/FMA intrinsics. Idempotent: a file already wrapped is returned unchanged."""
    if "#if defined(__x86_64__)" in text:
        return text  # already patched (re-running against an already-patched source tree)

    lines = text.splitlines(keepends=True)
    lic_end = _find_license_end(lines)
    out = lines[:lic_end]
    out.append("\n")
    out.append("#if defined(__x86_64__)\n")
    out.append(_WRAP_HEADER_AVX2 if needs_avx2_fma else _WRAP_HEADER)

    rest = lines[lic_end:]
    if rest and rest[0].strip() == "":
        rest = rest[1:]

    if needs_avx2_fma:
        # Insert the target-attribute pragma after the last leading #include (before any
        # declaration), so it covers every function defined below, including ones only
        # forward-declared with no sse/avx class member state.
        include_end = None
        for i, line in enumerate(rest):
            if line.startswith("#include"):
                include_end = i
            elif line.strip() == "" or line.startswith("//"):
                continue
            elif include_end is not None:
                break
            else:
                break
        assert include_end is not None, "no #include found to anchor the pragma after"
        out.extend(rest[:include_end + 1])
        out.append("\n")
        out.append('#pragma clang attribute push(__attribute__((target("avx2,fma"))), '
                   "apply_to = function)\n")
        out.extend(rest[include_end + 1:])
        if not out[-1].endswith("\n"):
            out[-1] += "\n"
        out.append("\n")
        out.append("#pragma clang attribute pop\n")
    else:
        out.extend(rest)
        if not out[-1].endswith("\n"):
            out[-1] += "\n"

    out.append("#endif  // defined(__x86_64__)\n")
    return "".join(out)


def _closure(build_dir):
    """Returns (objs, by_output compdb map, root_dir, {dest-relative path: source abspath}) for
    the ninja build in `build_dir`, exactly as the original single-arch script computed it."""
    root_dir = os.path.realpath(os.path.join(build_dir, ".."))
    target = "webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a"

    query = subprocess.run(["ninja", "-C", build_dir, "-t", "query", target],
                           capture_output=True, text=True, check=True).stdout
    objs = sorted({line.strip() for line in query.splitlines()
                  if line.strip().endswith((".cc.o", ".c.o"))})

    compdb = json.loads(subprocess.run(["ninja", "-C", build_dir, "-t", "compdb"],
                                       capture_output=True, text=True, check=True).stdout)
    by_output = {e["output"]: e for e in compdb}

    defines, includes = set(), set()
    sources = []
    for o in objs:
        e = by_output[o]
        sources.append(os.path.realpath(os.path.join(e["directory"], e["file"])))
        for a in e["command"].split():
            if a.startswith("-D"):
                defines.add(a[2:])
            elif a.startswith("-I"):
                includes.add(a[2:])
    print(f"  {len(objs)} object files; defines: {sorted(defines)}")
    print(f"  include dirs (relative to build dir): {sorted(includes)}")

    deps_text = subprocess.run(["ninja", "-C", build_dir, "-t", "deps"],
                               capture_output=True, text=True, check=True).stdout
    obj_set = set(objs)
    headers = set()
    current_keep = False
    for line in deps_text.splitlines():
        if line and not line.startswith(" "):
            current_keep = line.split(":")[0] in obj_set
            continue
        if current_keep and line.startswith("    "):
            p = line.strip()
            if p.startswith(("/Applications/", "/opt/homebrew/include", "/usr/")):
                continue
            headers.add(p)
    print(f"  {len(headers)} project headers")

    all_files = set(sources)
    for h in headers:
        all_files.add(os.path.realpath(os.path.join(build_dir, h)))

    dest_map = {}
    for abspath in sorted(all_files):
        if not abspath.startswith(root_dir + os.sep):
            print("  SKIP (outside root):", abspath)
            continue
        rel = os.path.relpath(abspath, root_dir)
        if rel.startswith("subprojects/") and "abseil-cpp" in rel:
            tail = rel.split("/", 2)[2]
            destrel = "abseil-cpp/" + tail
        elif rel.startswith("webrtc/"):
            destrel = rel
        else:
            print("  SKIP (unexpected location):", abspath)
            continue
        dest_map[destrel] = abspath

    return by_output, dest_map


def main():
    args = sys.argv[1:]
    x86_build_dir = None
    if "--x86-64-build-dir" in args:
        i = args.index("--x86-64-build-dir")
        x86_build_dir = os.path.realpath(args[i + 1])
        del args[i:i + 2]
    if len(args) != 2:
        print(__doc__)
        sys.exit(1)
    build_dir = os.path.realpath(args[0])
    dest_dir = os.path.realpath(args[1])

    print(f"primary closure ({build_dir}):")
    primary_by_output, primary_map = _closure(build_dir)

    copied = 0
    for destrel, abspath in primary_map.items():
        dest = os.path.join(dest_dir, destrel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy2(abspath, dest)
        copied += 1
    print(f"copied {copied} files into {dest_dir}")

    if x86_build_dir:
        print(f"x86_64 closure ({x86_build_dir}):")
        x86_by_output, x86_map = _closure(x86_build_dir)

        x86_only = {rel: ap for rel, ap in x86_map.items() if rel not in primary_map}
        # Find each x86-only object's original compile command, to know whether it needs the
        # AVX2/FMA target attribute (ground truth: did meson pass -mavx2/-mfma for it).
        src_to_flags = {}
        for e in x86_by_output.values():
            src = os.path.realpath(os.path.join(e["directory"], e["file"]))
            src_to_flags[src] = e["command"]

        x86_copied = 0
        for destrel, abspath in sorted(x86_only.items()):
            dest = os.path.join(dest_dir, destrel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            if destrel.endswith(_PATCHABLE_EXTS) and abspath in src_to_flags:
                flags = src_to_flags[abspath]
                needs_avx2_fma = "-mavx2" in flags or "-mfma" in flags
                with open(abspath) as f:
                    text = f.read()
                with open(dest, "w") as f:
                    f.write(_wrap_x86_64(text, needs_avx2_fma))
            else:
                shutil.copy2(abspath, dest)
            x86_copied += 1
        print(f"copied {x86_copied} x86_64-only files into {dest_dir} "
              f"(wrapped in '#if defined(__x86_64__)')")


if __name__ == "__main__":
    main()

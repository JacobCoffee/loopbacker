#!/usr/bin/env python3
"""Regenerates CWebRTCAEC/webrtc and CWebRTCAEC/abseil-cpp from a meson+ninja build of
webrtc-audio-processing, using ninja's introspection (not hand-maintained file lists) to find
the exact dependency closure.

Usage (from scratch):
    brew install meson ninja           # arm64 Homebrew, i.e. /opt/homebrew/bin
    git clone --branch v2.1 https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git /tmp/wap
    cd /tmp/wap
    meson setup build --default-library=static --buildtype=release
    ninja -C build
    python3 /path/to/CWebRTCAEC/generate.py /tmp/wap/build /path/to/CWebRTCAEC

What this does and why:
  1. `ninja -t compdb` gives the exact compiler invocation (defines, include paths) for every
     object file meson decided to compile -- this is the ground truth for what the build
     actually needs, instead of guessing from BUILD.gn/meson.build dependency graphs by hand.
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
"""
import json
import os
import shutil
import subprocess
import sys


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    build_dir = os.path.realpath(sys.argv[1])
    dest_dir = os.path.realpath(sys.argv[2])
    root_dir = os.path.realpath(os.path.join(build_dir, ".."))

    # The final linked target to walk for the full static-link closure. For
    # webrtc-audio-processing 2.x this is the apm static library itself (it statically folds
    # in rtc_base/api/system_wrappers/common_audio/third_party/abseil -- see README.md).
    target = "webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a"

    query = subprocess.run(["ninja", "-C", build_dir, "-t", "query", target],
                           capture_output=True, text=True, check=True).stdout
    objs = sorted({line.strip() for line in query.splitlines()
                  if line.strip().endswith((".cc.o", ".c.o"))})
    print(f"{len(objs)} object files in the closure")

    compdb = json.loads(subprocess.run(["ninja", "-C", build_dir, "-t", "compdb"],
                                       capture_output=True, text=True, check=True).stdout)
    by_output = {e["output"]: e for e in compdb}

    defines, includes = set(), set()
    sources = []
    for o in objs:
        e = by_output[o]
        sources.append(os.path.realpath(os.path.join(e["directory"], e["file"])))
        args = e["command"].split()
        for i, a in enumerate(args):
            if a.startswith("-D"):
                defines.add(a[2:])
            elif a.startswith("-I"):
                includes.add(a[2:])
    print("defines:", sorted(defines))
    print("include dirs (relative to build dir):", sorted(includes))

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
    print(f"{len(headers)} project headers")

    all_files = set(sources)
    for h in headers:
        all_files.add(os.path.realpath(os.path.join(build_dir, h)))

    copied = 0
    for abspath in sorted(all_files):
        if not abspath.startswith(root_dir + os.sep):
            print("SKIP (outside root):", abspath)
            continue
        rel = os.path.relpath(abspath, root_dir)
        if rel.startswith("subprojects/") and "abseil-cpp" in rel:
            # strip "subprojects/abseil-cpp-<version>/" -> "abseil-cpp/"
            tail = rel.split("/", 2)[2]
            destrel = "abseil-cpp/" + tail
        elif rel.startswith("webrtc/"):
            destrel = rel
        else:
            print("SKIP (unexpected location):", abspath)
            continue
        dest = os.path.join(dest_dir, destrel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy2(abspath, dest)
        copied += 1
    print(f"copied {copied} files into {dest_dir}")


if __name__ == "__main__":
    main()

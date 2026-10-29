#!/usr/bin/env python3
"""perthread.py -- summarize a macOS `sample` report per thread.

Parses the "Call graph:" section of a report produced by the `sample` command
(e.g. `sample <pid|name> <seconds> -file report.txt`) and, for each thread,
prints the active (non-idle) percentage of a CPU core it used plus its top
leaf frames (the innermost sampled function for each captured stack).

`sample` captures every live thread of the process at each tick, so an idle
thread shows up every tick too, just with a leaf frame parked in a wait
primitive. Those leaf frames are excluded from "active" so idle threads don't
look busy.

Usage:
    perthread.py <report> <seconds> [top N]

    <report>   path to a `sample` text report
    <seconds>  total wall-clock duration the sample covered (the duration you
               passed to `sample`, in seconds)
    [top N]    leaf frames to show per thread (default: 5)
"""
from __future__ import annotations

import re
import sys
from collections import defaultdict

IDLE_LEAF_FRAMES = {
    "__workq_kernreturn",
    "semaphore_wait_trap",
    "semaphore_wait",
    "mach_msg2_trap",
    "mach_msg_trap",
    "kevent",
    "kevent_qos",
    "__psynch_cvwait",
    "__semwait_signal",
    "start_wqthread",
    "__ulock_wait",
}

# A call-graph line: branch-tree prefix (spaces/+/!/:/|), a sample count, then the frame text.
FRAME_RE = re.compile(r"^(?P<prefix>[ +!:|]*)(?P<count>\d+)\s+(?P<rest>.+?)\s*$")
THREAD_HEADER_RE = re.compile(r"^Thread_(?P<tid>\d+)\b(?P<tail>.*)$")
# "<func>  (in <module>) + <offset>  [addr]" -> captures <func>; falls back to the whole rest.
FUNC_RE = re.compile(r"^(?P<func>.*?)\s+\(in\s")
INTERVAL_RE = re.compile(r"every\s+([\d.]+)\s*millisecond")


def parse_thread_name(tail: str) -> str:
    """Extract the friendly thread name from the text after "Thread_<id>"."""
    tail = tail.strip()
    # "   DispatchQueue_119465: TNodeOperationTask::Run  (serial)" -> "TNodeOperationTask::Run"
    # ": com.apple.NSEventThread" -> "com.apple.NSEventThread"
    tail = re.sub(r"^DispatchQueue_\d+:\s*", "", tail)
    tail = tail.lstrip(":").strip()
    tail = re.sub(r"\s*\((serial|concurrent)\)\s*$", "", tail)
    return tail


def leaf_function(rest: str) -> str:
    m = FUNC_RE.match(rest)
    if m:
        return m.group("func").strip()
    # No "(in <module>)" annotation (rare); strip a trailing "[0x...]" if present.
    return re.sub(r"\s*\[0x[0-9a-fA-F]+\]\s*$", "", rest).strip()


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 1
    report_path = sys.argv[1]
    seconds = float(sys.argv[2])
    top_n = int(sys.argv[3]) if len(sys.argv) > 3 else 5

    with open(report_path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()

    interval_ms = 1.0
    for line in lines[:20]:
        m = INTERVAL_RE.search(line)
        if m:
            interval_ms = float(m.group(1))
            break

    start = next((i for i, l in enumerate(lines) if l.strip() == "Call graph:"), None)
    if start is None:
        print(f"perthread.py: no \"Call graph:\" section in {report_path}", file=sys.stderr)
        return 1
    end = next(
        (i for i in range(start + 1, len(lines))
         if lines[i].startswith("Total number in stack")
         or lines[i].startswith("Sort by top of stack")
         or lines[i].startswith("Binary Images:")),
        len(lines),
    )

    # Pre-parse every call-graph line once so we can look ahead for "has a child" (= not a leaf).
    parsed = []  # (prefix_len, count, rest, is_thread_header, tid, name)
    for line in lines[start + 1:end]:
        m = FRAME_RE.match(line)
        if not m:
            continue
        prefix, count, rest = m.group("prefix"), int(m.group("count")), m.group("rest")
        is_header = set(prefix) <= {" "} and THREAD_HEADER_RE.match(rest)
        if is_header:
            hm = THREAD_HEADER_RE.match(rest)
            tid, name = hm.group("tid"), parse_thread_name(hm.group("tail"))
            parsed.append((len(prefix), count, rest, True, tid, name))
        else:
            parsed.append((len(prefix), count, rest, False, None, None))

    thread_total = defaultdict(int)
    thread_name = {}
    thread_leaf_counts = defaultdict(lambda: defaultdict(int))
    thread_order = []

    current_tid = None
    for i, (depth, count, rest, is_header, tid, name) in enumerate(parsed):
        if is_header:
            current_tid = tid
            if tid not in thread_name:
                thread_order.append(tid)
                thread_name[tid] = name
            elif name and not thread_name[tid]:
                thread_name[tid] = name
            thread_total[tid] += count
            continue
        if current_tid is None:
            continue
        next_depth = parsed[i + 1][0] if i + 1 < len(parsed) else -1
        next_is_header = parsed[i + 1][3] if i + 1 < len(parsed) else True
        is_leaf = next_is_header or next_depth <= depth
        if is_leaf:
            func = leaf_function(rest)
            thread_leaf_counts[current_tid][func] += count

    if not thread_order:
        print(f"perthread.py: no threads parsed from {report_path}", file=sys.stderr)
        return 1

    total_ticks = max(seconds * 1000.0 / interval_ms, 1.0)

    print(f"{report_path}: {seconds:.1f}s @ {interval_ms:g} ms/tick, "
          f"~{total_ticks:.0f} ticks, {len(thread_order)} threads")
    print()

    rows = []
    for tid in thread_order:
        leaves = thread_leaf_counts[tid]
        active_count = sum(c for fn, c in leaves.items() if fn not in IDLE_LEAF_FRAMES)
        active_pct = active_count / total_ticks * 100.0
        total_pct = thread_total[tid] / total_ticks * 100.0
        rows.append((active_pct, total_pct, tid, thread_name.get(tid, ""), leaves))

    rows.sort(key=lambda r: r[0], reverse=True)

    for active_pct, total_pct, tid, name, leaves in rows:
        label = f"Thread_{tid}" + (f" ({name})" if name else "")
        print(f"{label}: {active_pct:5.1f}% active of a core ({total_pct:5.1f}% sampled)")
        top = sorted(
            ((fn, c) for fn, c in leaves.items() if fn not in IDLE_LEAF_FRAMES),
            key=lambda kv: kv[1], reverse=True,
        )[:top_n]
        for fn, c in top:
            print(f"    {c / total_ticks * 100.0:5.1f}%  {fn}")
        if not top:
            print("    (idle)")

    return 0


if __name__ == "__main__":
    sys.exit(main())

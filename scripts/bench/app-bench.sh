#!/bin/bash
# app-bench.sh -- measures Loopbacker.app CPU cost per UI state: process total CPU
# (ps cumulative cputime delta / wall) and per-thread CPU (via `sample` + perthread.py),
# picking out the main thread, any thread literally named "noise", and -- since the
# BNNS Graph rewrite runs noise suppression inline on the HAL IO threads -- the summed
# CPU of threads whose name contains "HALB", "IOThread", or "com.apple.audio".
#
# Usage:
#   app-bench.sh <app path> <label> [seconds] [--visible]
#
#   <app path>  path to a Loopbacker.app bundle to benchmark (a disposable build,
#               e.g. App/Loopbacker/.build/out/Products/Release -- see Package.swift).
#   <label>     free-form label written into the results TSV (e.g. a git ref or commit).
#   [seconds]   sample duration per state (default 8).
#   --visible   also measure with the Routing and Effects pages visible. THIS ACTIVATES
#               THE APP, STEALS FOCUS, AND SENDS ⌘1/⌘2 VIA osascript. It relaunches the
#               app for every state, interrupting any routes it had running. Never pass
#               this against an app instance carrying real audio.
#
# Appends one TSV row per state to ./app-bench-results.tsv:
#   label  state  total_pct  main_pct  noise_pct  hal_io_pct  frontmost
#
# `frontmost` is the frontmost app's name at the end of each --visible state; the row is
# invalid for that state unless it reads "Loopbacker".
set -euo pipefail

VISIBLE=false
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --visible) VISIBLE=true ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done
set -- "${POSITIONAL[@]:-}"

if [ "$#" -lt 2 ]; then
    echo "usage: app-bench.sh <app path> <label> [seconds] [--visible]" >&2
    exit 1
fi

APP_PATH="$1"
LABEL="$2"
DURATION="${3:-8}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PERTHREAD="$SCRIPT_DIR/perthread.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

RESULTS_TSV="app-bench-results.tsv"
if [ ! -f "$RESULTS_TSV" ]; then
    printf 'label\tstate\ttotal_pct\tmain_pct\tnoise_pct\thal_io_pct\tfrontmost\n' > "$RESULTS_TSV"
fi

INFO_PLIST="$APP_PATH/Contents/Info"
EXEC_NAME="$(defaults read "$INFO_PLIST" CFBundleExecutable)"
BIN_PATH="$APP_PATH/Contents/MacOS/$EXEC_NAME"
if [ ! -x "$BIN_PATH" ]; then
    echo "app-bench.sh: no executable at $BIN_PATH" >&2
    exit 1
fi

if [ "$VISIBLE" = true ]; then
    cat >&2 <<'WARN'
WARNING: --visible activates this app instance (stealing focus from whatever you're
doing), relaunches it between states, and sends Cmd+1 / Cmd+2 via osascript. Any routes
the instance had running are interrupted on each relaunch. Only point this at a
disposable build, never at an app instance carrying real audio.
WARN
fi

ps_cpu_seconds() {
    # Cumulative CPU time (ps TIME field, "[[DD-]HH:]MM:SS[.ss]") for a PID, in seconds.
    local t
    t="$(ps -o time= -p "$1" 2>/dev/null | tr -d ' ')"
    if [ -z "$t" ]; then
        echo 0
        return
    fi
    awk -F: -v t="$t" 'BEGIN {
        n = split(t, f, ":")
        s = 0
        for (i = 1; i <= n; i++) s = s * 60 + f[i]
        print s
    }'
}

relaunch() {
    pkill -f "$BIN_PATH" 2>/dev/null || true
    sleep 1
    "$BIN_PATH" &
    APP_PID=$!
    sleep 3 # let launch settle before measuring
}

activate_and_select_tab() {
    # $1: 1 for Routing, 2 for Effects (⌘1 / ⌘2 in the sidebar, per the app's shortcuts).
    osascript -e "tell application \"System Events\"
        set frontmost of (first process whose unix id is $APP_PID) to true
        delay 0.5
        keystroke \"$1\" using command down
    end tell" >/dev/null 2>&1
    sleep 1
}

frontmost_app_name() {
    osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || echo "unknown"
}

extract_pct() {
    # extract_pct <perthread output> <case-insensitive grep pattern>
    # Thread header lines look like "Thread_123 (name):   N.N% active of a core (...)".
    printf '%s\n' "$1" | grep -i "$2" | head -1 | sed -E 's/.*:[[:space:]]*([0-9.]+)% active.*/\1/'
}

sum_pct() {
    printf '%s\n' "$1" | grep -i -E "$2" | sed -E 's/.*:[[:space:]]*([0-9.]+)% active.*/\1/' \
        | awk '{s += $1} END {printf "%.1f", s + 0}'
}

measure_state() {
    local state="$1"
    local report="$WORK/${state//[^A-Za-z0-9]/_}.sample"
    local cpu0 cpu1 wall0 wall1

    cpu0="$(ps_cpu_seconds "$APP_PID")"
    wall0="$(date +%s.%N)"
    sample "$APP_PID" "$DURATION" -file "$report" >/dev/null 2>&1
    wall1="$(date +%s.%N)"
    cpu1="$(ps_cpu_seconds "$APP_PID")"

    local total_pct
    total_pct="$(awk -v c0="$cpu0" -v c1="$cpu1" -v w0="$wall0" -v w1="$wall1" \
        'BEGIN { w = w1 - w0; if (w <= 0) w = 1; printf "%.1f", (c1 - c0) / w * 100 }')"

    local pt_out
    pt_out="$(python3 "$PERTHREAD" "$report" "$DURATION" 1)"

    local main_pct noise_pct hal_pct
    main_pct="$(extract_pct "$pt_out" "com\.apple\.main-thread")"
    noise_pct="$(extract_pct "$pt_out" "noise")"
    hal_pct="$(sum_pct "$pt_out" "halb|iothread|com\.apple\.audio")"
    : "${main_pct:=0}" "${noise_pct:=0}" "${hal_pct:=0}"

    local frontmost="n/a"
    if [ "$VISIBLE" = true ]; then
        frontmost="$(frontmost_app_name)"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$LABEL" "$state" "$total_pct" "$main_pct" "$noise_pct" "$hal_pct" "$frontmost" >> "$RESULTS_TSV"
    echo "$state: total=${total_pct}% main=${main_pct}% noise=${noise_pct}% hal/io=${hal_pct}% frontmost=$frontmost"
}

relaunch
measure_state "background"

if [ "$VISIBLE" = true ]; then
    relaunch
    activate_and_select_tab 1
    measure_state "routing-visible"

    relaunch
    activate_and_select_tab 2
    measure_state "effects-visible"
fi

pkill -f "$BIN_PATH" 2>/dev/null || true
echo "app-bench.sh: results appended to $RESULTS_TSV"

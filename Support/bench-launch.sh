#!/bin/bash
# How long Parallex adds before an app starts: times a do-nothing app run
# directly, as an own-identity copy (through the launcher, with the Library
# redirect loaded) and as a launch-only wrapper. Budget: under 50 ms.
#
#   make bench        (builds first; uses the freshly built launcher)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/debug"
WORK="$(mktemp -d -t parallex-bench)"
export PARALLEX_HOME="$WORK/support"
export PARALLEX_LAUNCHER="$BIN/parallex-launcher"
export PARALLEX_HOME_LIBRARY="$BIN/libparallexhome.dylib"
export PARALLEX_GROUPS_LIBRARY="$BIN/libparallexgroups.dylib"
export PARALLEX_TRASH="$WORK/trash"

LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup() {
    for name in "Bench Copy" "Bench Wrapper"; do
        "$BIN/parallex" remove "$name" >/dev/null 2>&1 || true
    done
    # Running the bundles' binaries directly registers them too.
    local real
    real="$(cd "$WORK" && pwd -P)"
    for app in "$APP" "$WORK/apps/Bench Copy.app" "$WORK/apps/Bench Wrapper.app"; do
        "$LSR" -u "$real${app#"$WORK"}" >/dev/null 2>&1 || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

APP="$WORK/Bench.app"
mkdir -p "$APP/Contents/MacOS" "$WORK/apps"
printf 'int main(void) { return 0; }\n' > "$WORK/bench.c"
clang -O2 "$WORK/bench.c" -o "$APP/Contents/MacOS/Bench"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Bench</string>
<key>CFBundleIdentifier</key><string>dev.parallex.bench</string>
<key>CFBundleName</key><string>Bench</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PLIST

"$BIN/parallex" create "$APP" --name "Bench Copy" --clone --out "$WORK/apps" >/dev/null
"$BIN/parallex" create "$APP" --name "Bench Wrapper" --mode launch-only --out "$WORK/apps" >/dev/null

/usr/bin/python3 - "$APP" "$WORK/apps" <<'PY'
import statistics, subprocess, sys, time

app, apps = sys.argv[1], sys.argv[2]
def median_ms(command, runs=40, warmup=3):
    samples = []
    for i in range(runs + warmup):
        start = time.perf_counter()
        subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        if i >= warmup:
            samples.append((time.perf_counter() - start) * 1000)
    return statistics.median(samples)

direct = median_ms([f"{app}/Contents/MacOS/Bench"])
rows = [
    ("Own-identity copy", median_ms([f"{apps}/Bench Copy.app/Contents/MacOS/parallex-launcher"])),
    ("Launch-only wrapper", median_ms([f"{apps}/Bench Wrapper.app/Contents/MacOS/launcher"])),
]
print(f"App on its own       {direct:5.1f} ms")
worst = 0.0
for label, value in rows:
    worst = max(worst, value - direct)
    print(f"{label:20s} {value:5.1f} ms  (+{value - direct:.1f} ms)")
budget = 50
print(f"\nLauncher overhead is {'within' if worst < budget else 'OVER'} the {budget} ms budget.")
sys.exit(0 if worst < budget else 1)
PY

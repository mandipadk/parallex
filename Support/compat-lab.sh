#!/bin/zsh
# Compatibility lab: make a fresh instance of each app the way New Instance
# makes one by default (an own-identity copy with its own Library, keychain,
# Guard and recorder, or for browsers a wrapper that opens the original with
# a profile folder of its own), open it in the background, and see whether
# it runs, crashes, or reaches the original's data. When the default isn't a
# copy, an own-identity copy is tried too. Everything it makes goes in a
# folder of its own, in a Parallex library of its own, and is removed
# afterwards.
#
#   Support/compat-lab.sh [--install] [--wait SECONDS] [--out FILE] [--diagnose DIR] App[=cask] ...
#
#   App      the app's name in /Applications ("Visual Studio Code")
#   =cask    its Homebrew cask, installed first with --install (CI)
#
# Writes one JSON object per app to FILE (default: compat-lab.json): the
# default instance's result, its "mode" ("copy" or "wrapper"), and for a
# wrapper an "ownIdentity" object with the copy's. "toolCrashes" counts
# programs from elsewhere it started (macOS's sw_vers, say) that crashed;
# they don't make the app's result. A table goes to stdout (and to
# $GITHUB_STEP_SUMMARY in GitHub Actions). With --diagnose, an instance that
# quits, crashes or leaks, or whose programs crash, leaves DIR/<App>.txt (or
# "<App> (own identity).txt"): the system log around its launch, what it
# reached of the original's, its crash reports, and the original's and the
# instance's entitlements.
set -u

here=${0:A:h}
root=${here:h}
install=0
wait_seconds=25
out=compat-lab.json
diagnose=""
apps=()
while (( $# )); do
  case $1 in
    --install) install=1 ;;
    --wait) shift; wait_seconds=$1 ;;
    --out) shift; out=$1 ;;
    --diagnose) shift; diagnose=$1 ;;
    *) apps+=("$1") ;;
  esac
  shift
done
(( ${#apps} )) || { echo "usage: $0 [--install] [--wait SECONDS] [--out FILE] App[=cask] ..." >&2; exit 2 }

parallex=$root/.build/debug/parallex
[[ -x $parallex ]] || { echo "build first: swift build" >&2; exit 2 }
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Real paths only: a process's path is the resolved one, so a pattern with
# /tmp in it would miss one that runs from /private/tmp.
lab=$(mktemp -d "$HOME/.parallex-compat-lab.XXXXXX")
lab=${lab:A}
export PARALLEX_HOME=$lab/support PARALLEX_TRASH=$lab/trash PARALLEX_LAUNCHER_NO_UI=1
mkdir -p "$lab/apps"
: > "$out"

# An instance's processes: the one its pid file names, any started from its
# app or with its folder in their arguments (a wrapper runs the original app
# with a profile flag pointing there), and everything those started.
#   members MARKER ... [pidfile:PATH ...]
members() {
  ps -axww -o pid=,ppid=,command= 2>/dev/null | python3 -c '
import os, sys
markers = [a for a in sys.argv[1:] if not a.startswith("pidfile:")]
pidfiles = [a[len("pidfile:"):] for a in sys.argv[1:] if a.startswith("pidfile:")]
me = os.getpid()
procs = {}
for line in sys.stdin:
    parts = line.split(None, 2)
    if len(parts) < 2 or not parts[0].isdigit() or int(parts[0]) == me:
        continue
    procs[int(parts[0])] = (int(parts[1]), parts[2] if len(parts) > 2 else "")
found = {pid for pid, (_, command) in procs.items() if any(m in command for m in markers)}
for pidfile in pidfiles:
    try:
        lines = open(pidfile).read().splitlines()
        pid = int(lines[0])
    except Exception:
        continue
    # (Only while it is still the program the launcher became.)
    if pid in procs and (len(lines) < 2 or procs[pid][1].startswith(lines[1].strip())):
        found.add(pid)
grew = True
while grew:
    grew = False
    for pid, (parent, _) in procs.items():
        if pid not in found and parent in found:
            found.add(pid)
            grew = True
print("\n".join(str(p) for p in sorted(found)))
' "$@"
}

# Stop processes: politely, then not.
stop() {
  local pids=($(members "$@"))
  (( ${#pids} )) || return
  kill $pids 2>/dev/null; sleep 2
  pids=($(members "$@"))
  (( ${#pids} )) && kill -9 $pids 2>/dev/null
  sleep 1
}

# Crash reports written since STAMP by an instance: ones naming its app, or
# from one of its processes or their children (a wrapper's carry the
# original app's name, so only their process IDs tell them apart). KIND
# "app" is the app's own (run from the instance or the original app);
# "tools" is the programs it started from elsewhere (macOS's sw_vers, say).
#   crash_reports STAMP LABEL KIND PID ...
crash_reports() {
  local stamp=$1 label=$2 kind=$3
  shift 3
  find "$HOME/Library/Logs/DiagnosticReports" -newer "$stamp" -type f 2>/dev/null | python3 -c '
import json, re, sys
label, kind, original = sys.argv[1], sys.argv[2], sys.argv[3]
pids = {int(p) for p in sys.argv[4:] if p.isdigit()}
for path in sys.stdin.read().splitlines():
    try:
        text = open(path, errors="replace").read()
    except Exception:
        continue
    _, _, body = text.partition("\n")
    try:
        report = json.loads(body)
        ids = {report.get("pid"), report.get("parentPid")}
        program = report.get("procPath", "")
    except Exception:
        ids = {int(m) for m in re.findall(r"^(?:Process|Parent Process):.*\[(\d+)\]", text, re.M)}
        found = re.search(r"^Path:\s+(.*)$", text, re.M)
        program = found.group(1).strip() if found else ""
    if label + ".app" not in text and not ids & pids:
        continue
    own = not program or label + ".app/" in program or program.startswith(original + "/")
    if own == (kind == "app"):
        print(path)
' "$label" "$kind" "$original" "$@"
}

# Launch Services records a copy (and each helper app it starts) made:
# unregistered by path. One whose bundle is gone needs a stand-in there.
forget_records() {
  $lsregister -dump 2>/dev/null | python3 -c '
import re, sys
for record in sys.stdin.read().split("\n--------------------------------"):
    path = re.search(r"^path:\s+(.*?\.app)\s*(\(0x[0-9a-f]+\))?\s*$", record, re.M)
    ident = re.search(r"^identifier:\s+(\S+)", record, re.M)
    if path and ident and sys.argv[1] in path.group(1):
        print(path.group(1) + "\t" + ident.group(1))
' "$lab/" | while IFS=$'\t' read -r record_path ident; do
    # (Not "path": in zsh that's PATH.)
    if [[ ! -d $record_path ]]; then
      mkdir -p "$record_path/Contents/MacOS"
      printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleExecutable</key><string>x</string></dict></plist>' "$ident" > "$record_path/Contents/Info.plist"
      : > "$record_path/Contents/MacOS/x"
      chmod +x "$record_path/Contents/MacOS/x"
    fi
    $lsregister -u "$record_path" 2>/dev/null
  done
}

cleanup() {
  local found=("$lab/") pidfile
  for pidfile in "$lab"/support/instances/*/instance.pid(N); do found+=("pidfile:$pidfile"); done
  stop $found
  for copy in "$lab"/apps/*.app(N); do
    $lsregister -u "$copy" 2>/dev/null
    local id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$copy/Contents/Info.plist" 2>/dev/null)
    if [[ $id == com.parallex.instance.* ]]; then
      defaults delete "$id" >/dev/null 2>&1
      # (Deleting leaves an empty file behind.)
      rm -f "$HOME/Library/Preferences/$id.plist"
    fi
    rm -rf "$copy"
  done
  forget_records
  rm -rf "${lab:?}"
}
trap cleanup EXIT INT TERM

# One JSON object per app, written by Python so any name or version is
# quoted right: emit key=value ... (numbers for processes, leaks, …), with
# ownIdentity.key=value for the own-identity copy's.
emit() {
  python3 - "$@" >> "$out" <<'PY'
import json, sys
entry = {}
for pair in sys.argv[1:]:
    key, _, value = pair.partition("=")
    group, _, field = key.rpartition(".")
    value = int(value) if field in ("processes", "leaks", "blocked", "crashes", "toolCrashes") else value
    (entry.setdefault(group, {}) if group else entry)[field] = value
print(json.dumps(entry))
PY
}

# Write what's known about an instance that quit, crashed or leaked (or
# started a program that crashed) to $1.
diagnose_instance() {
  local file=$1 label=$2 app=$3 launched=$4 stamp=$5
  shift 5
  local executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$original/Contents/Info.plist" 2>/dev/null)
  mkdir -p "$diagnose"
  {
    print "# $name $version, as a $mode: $result"
    print "\n## The original's entitlements"
    codesign -d --entitlements - --xml "$original" 2>/dev/null | plutil -p - 2>&1
    print "\n## Update settings in the original's Info.plist"
    plutil -p "$original/Contents/Info.plist" 2>/dev/null | grep -iE '"SU|sparkle|squirrel'
    print "\n## The instance's signature and entitlements"
    codesign -dvv "$app" 2>&1
    codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p - 2>&1
    print "\n## The instance's app, as the launcher starts it"
    ls -la "$app/Contents/MacOS" 2>&1
    print "\n## System log from the launch"
    /usr/bin/log show --start "$launched" --style compact --predicate \
      "eventMessage CONTAINS[c] \"$label\" OR eventMessage CONTAINS[c] \"${executable:-$name}\" OR process == \"amfid\" OR subsystem == \"com.apple.MobileFileIntegrity\" OR (process == \"kernel\" AND (eventMessage CONTAINS[c] \"AMFI\" OR eventMessage CONTAINS[c] \"sandbox\" OR eventMessage CONTAINS[c] \"code signature\")) OR process == \"taskgated\" OR process == \"syspolicyd\"" \
      2>&1 | tail -400
    print "\n## What reached the original's data"
    print -r -- "$check" | python3 -c '
import json, sys
try:
    report = json.load(sys.stdin)
except Exception:
    sys.exit()
for finding in report.get("findings", []):
    if finding.get("category") == "leak":
        print(" ", finding.get("path"), "-", finding.get("reason"))
'
    print "\n## Crash reports"
    # macOS writes a report some seconds after the crash.
    for _ in {1..30}; do
      [[ -n $(crash_reports "$stamp" "$label" app "$@") ]] && break
      [[ $result == quit ]] || break
      sleep 2
    done
    { crash_reports "$stamp" "$label" app "$@"; crash_reports "$stamp" "$label" tools "$@" } | while read -r report; do
      print "### $report"
      # What the app said as it stopped, and the stack that stopped it.
      python3 - "$report" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
header, _, body = text.partition("\n")
try:
    report = json.loads(body)
except Exception:
    print(text[:6000]); sys.exit()
print("exception:", report.get("exception"), "termination:", report.get("termination"))
for key in ("asi", "crashInfo", "lastExceptionBacktrace", "ktriageinfo"):
    if key in report:
        print(key + ":", json.dumps(report[key])[:3000])
images = report.get("usedImages", [])
thread = report.get("threads", [])[report.get("faultingThread", 0)] if report.get("threads") else {}
for frame in thread.get("frames", [])[:30]:
    image = images[frame.get("imageIndex", 0)] if frame.get("imageIndex", -1) < len(images) else {}
    print(" ", image.get("name", "?"), hex(frame.get("imageOffset", 0)), frame.get("symbol", ""), frame.get("sourceFile", ""), frame.get("sourceLine", ""))
PY
    done
  } > "$file" 2>&1
}

# Make an instance of $original named LABEL with create's FLAG (--recommended
# or --clone), open it in the background, and see how it does. Sets mode,
# result, processes, leaks, blocked, crashes, tools (crashes of programs it
# started from elsewhere, which don't make the app's result) and detail.
#   try_instance LABEL FLAG DIAGNOSIS_FILE
try_instance() {
  local label=$1 flag=$2 diagnosis=$3
  local app="$lab/apps/$label.app"
  mode="" result="" processes=0 leaks=0 blocked=0 crashes=0 tools=0 detail=""
  local created=$($parallex create "$original" $flag --name "$label" --out "$lab/apps" 2>&1)
  if [[ ! -d $app ]]; then
    result="not copied"
    detail=$(print -r -- "$created" | tail -1 | tr -d '|')
    return
  fi
  local made=$($parallex list --json 2>/dev/null | python3 -c '
import json, sys
for entry in json.load(sys.stdin):
    manifest = entry["manifest"]
    if manifest["name"] == sys.argv[1]:
        print(("copy" if manifest.get("clone") else "wrapper") + "\t" + manifest["slug"])
' "$label")
  mode=${made%%$'\t'*}
  local folder="$PARALLEX_HOME/instances/${made#*$'\t'}"
  local found=("$app/" "$folder/" "pidfile:$folder/instance.pid")
  local stamp="$lab/started-${made#*$'\t'}"
  touch "$stamp"
  local launched=$(date '+%Y-%m-%d %H:%M:%S')
  open -g "$app"
  sleep "$wait_seconds"
  local pids=($(members $found))
  processes=${#pids}
  local check=$($parallex check "$label" --json 2>/dev/null)
  local summary=$(print -r -- "$check" | python3 -c '
import json, sys
try:
    report = json.load(sys.stdin)
except Exception:
    print("unknown\t0\t0"); sys.exit()
leaks = [f for f in report.get("findings", []) if f.get("category") == "leak"]
print(("clean" if report.get("clean") else "leak") + "\t" + str(len(leaks)) + "\t" + str(len(report.get("blocked", []))))
')
  local leak_state=${summary%%$'\t'*}
  local rest=${summary#*$'\t'}
  leaks=${rest%%$'\t'*}
  blocked=${rest#*$'\t'}
  # Its processes now, and the first one, which may have gone already.
  local seen=($pids $(head -1 "$folder/instance.pid" 2>/dev/null))
  crashes=$(crash_reports "$stamp" "$label" app $seen | wc -l | tr -d ' ')
  tools=$(crash_reports "$stamp" "$label" tools $seen | wc -l | tr -d ' ')
  if (( crashes > 0 )); then result="crashed"
  elif (( processes == 0 )); then result="quit"
  elif [[ $leak_state == leak ]]; then result="leaked"
  elif [[ $leak_state == clean ]]; then result="ran"
  else result="not checked"
  fi
  if [[ -n $diagnose && ( $result == quit || $result == crashed || $result == leaked || $tools != 0 ) ]]; then
    diagnose_instance "$diagnosis" "$label" "$app" "$launched" "$stamp" $seen
  fi
  # A copy is asked to quit by its own bundle ID. A wrapper's app runs as
  # the original, so it only gets signals (asking by ID would reach the
  # original).
  if [[ $mode == copy ]]; then
    local bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1
    sleep 3
  fi
  stop $found
}

# A name no real instance has (its preferences domain is named after it).
tag=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)

# The runner's Homebrew can be days old, and a cask's old download may be
# gone from its server.
(( install )) && brew update --quiet >/dev/null 2>&1

rows=()
for spec in "${apps[@]}"; do
  name=${spec%%=*}
  cask=""
  [[ $spec == *=* ]] && cask=${spec#*=}
  original="/Applications/$name.app"
  if (( install )) && [[ -n $cask && ! -d $original ]]; then
    # Once more after a failure: a download can stall.
    if ! brew install --cask "$cask" > "$lab/brew.log" 2>&1 && ! brew install --cask "$cask" > "$lab/brew.log" 2>&1; then
      echo "brew install --cask $cask failed:" >&2
      tail -8 "$lab/brew.log" >&2
    fi
    # Downloaded apps are quarantined; their copies would be stopped.
    [[ -d $original ]] && xattr -dr com.apple.quarantine "$original" 2>/dev/null
  fi
  if [[ ! -d $original ]]; then
    emit "app=$name" "result=not installed"
    rows+=("| $name | not installed | | | | | |")
    continue
  fi
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$original/Contents/Info.plist" 2>/dev/null)

  try_instance "$name Lab $tag" --recommended "$diagnose/$name.txt"
  if [[ $result == "not copied" ]]; then
    emit "app=$name" "version=$version" "result=$result" "detail=$detail"
    rows+=("| $name | $version | | not copied | | | $detail |")
    continue
  fi
  fields=("app=$name" "version=$version" "mode=$mode" "result=$result" "processes=$processes" "leaks=$leaks" "blocked=$blocked" "crashes=$crashes" "toolCrashes=$tools")
  row="| $name | $version | $mode | $result | $processes | ${leaks} leaks, ${blocked} kept out by Guard$( (( tools )) && print -n ", $tools programs it started crashed") |"
  # Own identity is the other choice New Instance offers for it.
  if [[ $mode == wrapper ]]; then
    try_instance "$name Lab $tag Own" --clone "$diagnose/$name (own identity).txt"
    fields+=("ownIdentity.result=$result")
    if [[ $result == "not copied" ]]; then
      fields+=("ownIdentity.detail=$detail")
      row+=" not copied |"
    else
      fields+=("ownIdentity.processes=$processes" "ownIdentity.leaks=$leaks" "ownIdentity.blocked=$blocked" "ownIdentity.crashes=$crashes" "ownIdentity.toolCrashes=$tools")
      row+=" $result ($processes processes, $leaks leaks$( (( tools )) && print -n ", $tools programs it started crashed")) |"
    fi
  else
    row+=" |"
  fi
  emit "${fields[@]}"
  rows+=("$row")
done

table="| App | Version | Mode | Result | Processes | Isolation | Own identity |
|---|---|---|---|---|---|---|
${(F)rows}"
print -r -- "$table"
[[ -n ${GITHUB_STEP_SUMMARY:-} ]] && print -r -- "## Compatibility lab

$table" >> "$GITHUB_STEP_SUMMARY"
exit 0

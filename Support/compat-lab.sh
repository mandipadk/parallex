#!/bin/zsh
# Compatibility lab: make a fresh own-identity copy of each app (its own
# Library, keychain, Guard and recorder, as a new copy gets), open it in the
# background, and see whether it runs, crashes, or reaches the original's
# data. Everything it makes goes in a folder of its own, in a Parallex
# library of its own, and is removed afterwards.
#
#   Support/compat-lab.sh [--install] [--wait SECONDS] [--out FILE] App[=cask] ...
#
#   App      the app's name in /Applications ("Visual Studio Code")
#   =cask    its Homebrew cask, installed first with --install (CI)
#
# Writes one JSON object per app to FILE (default: compat-lab.json), and a
# table to stdout (and to $GITHUB_STEP_SUMMARY in GitHub Actions).
set -u

here=${0:A:h}
root=${here:h}
install=0
wait_seconds=25
out=compat-lab.json
apps=()
while (( $# )); do
  case $1 in
    --install) install=1 ;;
    --wait) shift; wait_seconds=$1 ;;
    --out) shift; out=$1 ;;
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
started=$lab/started
touch "$started"

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
  pkill -f "$lab/apps/" 2>/dev/null; sleep 2; pkill -9 -f "$lab/apps/" 2>/dev/null; sleep 1
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
# quoted right: emit key=value ... (numbers for processes, leaks, …).
emit() {
  python3 - "$@" >> "$out" <<'PY'
import json, sys
entry = {}
for pair in sys.argv[1:]:
    key, _, value = pair.partition("=")
    entry[key] = int(value) if key in ("processes", "leaks", "blocked", "crashes") else value
print(json.dumps(entry))
PY
}

# A name no real instance has (its preferences domain is named after it).
tag=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)

rows=()
for spec in "${apps[@]}"; do
  name=${spec%%=*}
  cask=""
  [[ $spec == *=* ]] && cask=${spec#*=}
  original="/Applications/$name.app"
  if (( install )) && [[ -n $cask && ! -d $original ]]; then
    brew install --cask "$cask" >/dev/null 2>&1 || echo "brew install --cask $cask failed" >&2
    # Downloaded apps are quarantined; their copies would be stopped.
    [[ -d $original ]] && xattr -dr com.apple.quarantine "$original" 2>/dev/null
  fi
  if [[ ! -d $original ]]; then
    emit "app=$name" "result=not installed"
    rows+=("| $name | not installed | | | |")
    continue
  fi
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$original/Contents/Info.plist" 2>/dev/null)
  label="$name Lab $tag"
  copy="$lab/apps/$label.app"
  created=$($parallex create "$original" --clone --name "$label" --out "$lab/apps" 2>&1)
  if [[ ! -d $copy ]]; then
    reason=$(print -r -- "$created" | tail -1 | tr -d '|')
    emit "app=$name" "version=$version" "result=not copied" "detail=$reason"
    rows+=("| $name | $version | not copied | | $reason |")
    continue
  fi
  open -g "$copy"
  sleep "$wait_seconds"
  processes=$(pgrep -f "$copy/" | wc -l | tr -d ' ')
  slug=$(print -r -- "$label" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/-$//')
  check=$($parallex check "$label" --json 2>/dev/null)
  summary=$(print -r -- "$check" | python3 -c '
import json, sys
try:
    report = json.load(sys.stdin)
except Exception:
    print("unknown\t0\t0"); sys.exit()
leaks = [f for f in report.get("findings", []) if f.get("category") == "leak"]
print(("clean" if report.get("clean") else "leak") + "\t" + str(len(leaks)) + "\t" + str(len(report.get("blocked", []))))
')
  leak_state=${summary%%$'\t'*}
  rest=${summary#*$'\t'}
  leaks=${rest%%$'\t'*}
  blocked=${rest#*$'\t'}
  crashes=$(find "$HOME/Library/Logs/DiagnosticReports" -newer "$started" -type f 2>/dev/null \
    | xargs grep -l "$lab/apps/$label.app" 2>/dev/null | wc -l | tr -d ' ')
  if (( crashes > 0 )); then result="crashed"
  elif (( processes == 0 )); then result="quit"
  elif [[ $leak_state == leak ]]; then result="leaked"
  elif [[ $leak_state == clean ]]; then result="ran"
  else result="not checked"
  fi
  emit "app=$name" "version=$version" "result=$result" "processes=$processes" "leaks=$leaks" "blocked=$blocked" "crashes=$crashes"
  rows+=("| $name | $version | $result | $processes | ${leaks} leaks, ${blocked} kept out by Guard |")
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$copy/Contents/Info.plist" 2>/dev/null)
  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1
  sleep 3
  pkill -f "$copy/" 2>/dev/null; sleep 1; pkill -9 -f "$copy/" 2>/dev/null
done

table="| App | Version | Result | Processes | Isolation |
|---|---|---|---|---|
${(F)rows}"
print -r -- "$table"
[[ -n ${GITHUB_STEP_SUMMARY:-} ]] && print -r -- "## Compatibility lab

$table" >> "$GITHUB_STEP_SUMMARY"
exit 0

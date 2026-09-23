# Parallex

Run multiple isolated instances of a macOS app side by side — each with its own
data, sign-in, and settings. A free, open, developer-friendly alternative to
[parall.app](https://parall.app/).

Comes as **Parallex.app** (a manager window plus a menu-bar quick launcher) and
a **`parallex` CLI** — both over the same core, so instances created in one
show up in the other.

```
$ parallex create Claude --name "Claude Work" --badge W
✓ Created “Claude Work”
  Wrapper  /Applications/Claude Work.app
  Target   /Applications/Claude.app  (Electron app)
  Mode     data-dir — app-aware isolation (data-dir flags)
  Data     ~/Library/Application Support/Parallex/instances/claude-work/data
```

Now "Claude Work" lives in Spotlight and the Dock like any other app, and runs
alongside the original with its own data.

## How it works

`parallex create` emits a tiny wrapper `.app` (a few hundred KB — no copy of
the target):

```
Claude Work.app/
└── Contents/
    ├── Info.plist          # own CFBundleIdentifier + Parallex launch config
    ├── MacOS/launcher      # generic launcher binary
    └── Resources/app.icns  # target's icon, optionally badged
```

The launcher reads its configuration from the wrapper's own `Info.plist`, sets
up the isolated environment, writes a pid file, and `execv()`s the target
binary. Once running, the app checks in with macOS under its **own** identity —
macOS derives a process's bundle ID from its executable, and hardened-runtime
apps (nearly all of them) ignore the environment overrides that could change
that. So the Dock, ⌘-Tab, and notifications show a running instance as the
original app. Parallex compensates:

- **Window outlines** — every window of a running instance gets a thin border
  and a name tag in the instance's color. The original stays unmarked.
- **Menu bar** — shows the name of the instance in front.
- **Switcher** — <kbd>⌃⌥Space</kbd> lists every instance and running original
  by name; type to filter, Return to switch.

Launching a wrapper whose instance is already running brings that instance to
the front instead of starting a second copy.

Data isolation is tiered, auto-detected per app (`parallex doctor` shows the
verdict):

| Tier | Apps | Method |
|------|------|--------|
| app recipe | Claude, Codex | the app's own data-location switches (`CLAUDE_USER_DATA_DIR`, `CODEX_HOME`, …), with optional extras |
| data-dir | Electron, Chromium browsers, VS Code family, Firefox | framework flags (`--user-data-dir=…`, `--no-remote --profile …`, …) |
| home | other non-sandboxed apps | `HOME` points at a per-instance folder; Desktop/Documents/Downloads/… are symlinked back. Covers dotfiles and command-line state; see caveats for `~/Library` |
| launch-only | sandboxed (App Store) apps | a separate launcher only — macOS pins sandboxed app data to its container |

`parallex check <name>` verifies a running instance: it lists the files the
instance's processes have open and flags any that belong to the original app's
data, so isolation is something you can see rather than assume.

## Install

```sh
make app-install        # builds and installs /Applications/Parallex.app (GUI)
make install            # universal CLI binaries → Homebrew prefix if writable,
                        # else /usr/local (needs sudo)
# or: make install PREFIX=~/.local
```

Requires Xcode command line tools. For development: `swift build`, `swift test`.
A Homebrew formula scaffold lives in [Formula/parallex.rb](Formula/parallex.rb)
(`brew install --HEAD --build-from-source ./Formula/parallex.rb`).

## The app

Open **Parallex** and click **New Instance**: choose an app, and Parallex shows
what it found (framework, sandbox verdict, recommended isolation, recipe
options) before you commit. Name the instance, optionally give its icon a badge,
optionally move in an existing profile folder to keep its sign-in, create, done.

Each row shows running status, disk usage, and problems (missing or moved
original app, wrapper built by an older version) with a one-click **Repair**.
**Edit…** renames an instance or changes its badge, icon, isolation options,
environment, or arguments — the instance keeps its data and permissions.
**Check Isolation…** runs the leak check. Caches and leftover folders can be
moved to the Trash from the row menu. Removal always goes through the Trash.

Settings turn the window outlines, the switcher hotkey, and opening at login on
or off.

## CLI usage

```sh
parallex create <app> [options] [-- extra args for the target]
parallex list [--json]
parallex open <name> [--original | --reveal]
parallex edit <name> [options] [-- replacement extra args]
parallex repair <name> | --all [--app <path>]
parallex check <name> [--verbose] [--json]
parallex storage [<name>] [--clean-caches] [--remove-unused]
parallex remove <name> [--keep-data]
parallex doctor <app> [--json]
```

`<app>` can be a path (`/Applications/Claude.app`), a name (`Claude`), or a
bundle identifier (`com.anthropic.claudefordesktop`).

Useful `create` options:

| Option | |
|--------|--|
| `--name` | display name (default `<App> 2`, `<App> 3`, …) |
| `--badge W` / `--badge-color "#FF375F"` | letter badge on the icon to tell instances apart |
| `--mode auto\|data-dir\|home\|launch-only` | override isolation mode |
| `--out DIR` | where the wrapper goes (default `/Applications`) |
| `--env KEY=VALUE` | extra environment for the instance (repeatable) |
| `--share PATH` | extra home item to share in home mode, e.g. `.config/gh` (repeatable) |
| `--no-shared-defaults` | don't share Desktop/Documents/Downloads/… in home mode |
| `--icon FILE` | custom icon instead of the target's |
| `--option ID` / `--no-option ID` | turn a recipe option on or off (see `doctor`) |
| `--adopt-data DIR` | move an existing profile folder in as the instance's data |
| `--force` | rebuild an existing instance (keeps its data) |
| `--open` | launch right after creating |

Examples:

```sh
parallex create Claude --name "Claude Work" --badge W
parallex create "Google Chrome" --name "Chrome Dev" -- --remote-debugging-port=9222
parallex create Cursor --name "Cursor OSS" --badge O
parallex doctor Slack                    # what would Parallex do with Slack?
parallex edit "Claude Work" --option separate-claude-code
parallex check "Claude Work"             # any leaks into the original's data?
parallex repair --all                    # rebuild outdated or broken wrappers
parallex remove "Chrome Dev"             # wrapper + data → Trash
```

Instance data lives under `~/Library/Application Support/Parallex/instances/`
(override with `PARALLEX_HOME`). Removal always goes through the Trash, and
Parallex refuses to replace or delete any `.app` it didn't create.

## Per-app recipes

Some apps pin their data directory in code and ignore `--user-data-dir`, or keep
state outside it, but honor their own environment variables. Parallex carries
recipes for these and applies them automatically:

- **Claude** — `CLAUDE_USER_DATA_DIR` (also moves its logs into the instance).
  Option `separate-claude-code` gives the instance its own Claude Code settings,
  memory, and history (`CLAUDE_CONFIG_DIR`); off by default, so `~/.claude`
  stays shared.
- **Codex** — `CODEX_ELECTRON_USER_DATA_PATH` and `CODEX_HOME`.

For Electron apps without a recipe, `parallex doctor` lists environment
variables in the app's code that look like data-location switches, as leads to
try with `--env`. Recipes live in `Presets.recipes`.

## Caveats (inherited from the technique — Parall has these too)

- **Sandboxed (App Store) apps** get a separate identity but not separate data.
- **A running instance carries the original's identity** (see How it works):
  the Dock shows it under the original's icon, notifications come from the
  original's name, and data macOS keys by bundle ID (URL caches, native cookie
  storage) is shared. Parallex's outlines, menu bar, and switcher tell them apart.
- **Launching the original while an instance runs** needs "new instance"
  semantics — a plain `open` or Dock click focuses the instance. Use "Launch
  Original" in Parallex.app, the switcher, or `parallex open <name> --original`.
- **HOME isolation is partial on recent macOS**: system frameworks resolve
  `~/Library` from the user account rather than `$HOME`, so home mode reliably
  isolates dotfiles and CLI state but not necessarily a native app's
  `~/Library` data.
- **Privacy permissions** (camera, microphone, screen recording, …) are tied to
  the running app's identity, so an instance may share them with the original.
- **Re-opening a running instance** from Spotlight, Raycast, or the Dock
  briefly bounces the wrapper's icon while the launcher hands off to the
  running instance.
- **Notifications** may focus the wrong instance when several run at once.
- **Sign-in callbacks** (`app://` links, localhost OAuth) can land in the wrong
  instance when several of the same app run — quit the others before signing in.
- **Self-updating apps** update the shared original bundle; all instances pick
  it up on restart. An in-app "restart to update" may relaunch the app as the
  original rather than the instance — reopen the instance from Parallex.

## Status

v0.5 — see [PLAN.md](PLAN.md) for the design. The original proof of concept is
in [poc/](poc/).

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

### Own identity (clone mode)

For a real identity of its own, create the instance with `--clone` (or turn on
**Own identity** in the app). Parallex then makes the instance a copy of the
app — an APFS clone, so it costs almost no disk space — with its own bundle ID,
re-signed ad hoc, and with the Parallex launcher as its main executable. The
copy runs as itself: its own Dock icon and name, ⌘-Tab entry, notifications,
and privacy permissions. Every way of opening it (Dock, notifications, login)
still goes through the launcher, so its isolation always applies.

- **App Store / sandboxed apps** get their own sandbox container this way — the
  one way to give them separate data. Apps that keep data in shared app-group
  containers (e.g. WhatsApp) may still see the original's data there;
  `parallex doctor <app>` says what to expect.
- The copy doesn't update itself. When the original updates, the instance
  shows "repair to refresh the copy"; repairing re-copies it (quit it first).
- Features tied to the developer's signature (iCloud, push, keychain sharing)
  don't work in the copy, and it may ask for access to keychain items the
  original created. Apple's own apps can't be copied.

Data isolation is tiered, auto-detected per app (`parallex doctor` shows the
verdict):

| Tier | Apps | Method |
|------|------|--------|
| app recipe | Claude, Codex | the app's own data-location switches (`CLAUDE_USER_DATA_DIR`, `CODEX_HOME`, …), with optional extras |
| data-dir | Electron, Chromium browsers, VS Code family, Firefox | framework flags (`--user-data-dir=…`, `--no-remote --profile …`, …) |
| home | other non-sandboxed apps | `HOME` points at a per-instance folder; Desktop/Documents/Downloads/… are symlinked back. Covers dotfiles and command-line state; see caveats for `~/Library` |
| launch-only | sandboxed (App Store) apps | a separate launcher only — macOS pins sandboxed app data to its container |

### Sign-in links

Apps finish sign-in by opening a link in their own scheme (`claude://…`,
`cursor://…`). With several copies of an app running, macOS hands that link to
an arbitrary one. `parallex links enable` (or **Settings › Sign-in links**)
makes a small background app, *Parallex Links*, the handler for your
instances' schemes; it passes each link to the copy you used most recently, or
asks. Apps reclaim their scheme when they start, so keep Parallex.app running
(Settings › Open Parallex at login) — it takes the schemes back.

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

**First run** walks through what an instance is, suggests an app from your Mac
that duplicates especially well, and sets up the integrations that make
Parallex work well — opening at login, sign-in link routing, window outlines,
and the ⌃⌥Space switcher — each explained, each easy to change later.

**The window** lists instances grouped by the app they duplicate. Selecting one
shows everything about it, editable in place:

- **Isolation** — a plain-language summary, the own-identity switch, the app's
  recipe options, and **Verify Isolation**, which shows what the running
  instance actually has open.
- **Appearance** — name, color, badge, and icon, with a live preview.
- **Launch** — open the instance whenever Parallex starts.
- **Storage** — disk usage, clearing caches, removing leftovers.
- **Advanced** — isolation mode, extra environment and arguments, paths.

Changes that rebuild the instance collect in an apply bar; the rest save as you
make them. Problems (a moved or missing original, an outdated wrapper, a copy
older than its app) show at the top with a one-click fix. **New Instance**
(⌘N) offers your installed apps sorted by how well they duplicate, then a live
preview of the instance's icon as you name and color it.

**The menu bar** holds every instance one click away and shows which one is in
front. Parallex runs from there: it has a Dock icon only while its window is
open, and starts without a window at login.

## CLI usage

```sh
parallex apps [--all] [--json]
parallex create <app> [options] [-- extra args for the target]
parallex list [--json]
parallex open <name> [--original | --reveal]
parallex edit <name> [options] [-- replacement extra args]
parallex repair <name> | --all [--app <path>]
parallex check <name> [--verbose] [--json]
parallex storage [<name>] [--clean-caches] [--remove-unused]
parallex links [status | enable [--ask] | disable]
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
| `--clone` | own identity: make the instance a re-signed copy of the app (see above) |
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
parallex create WhatsApp --name "WhatsApp Work" --clone
parallex links enable                    # sign-in links go to the right copy
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

- **Claude** — `CLAUDE_USER_DATA_DIR`. Claude's log files stay in
  `~/Library/Logs/Claude` (it opens them before reading any setting).
  Option `separate-claude-code` gives the instance its own Claude Code settings,
  memory, and history (`CLAUDE_CONFIG_DIR`); off by default, so `~/.claude`
  stays shared.
- **Codex** — `CODEX_ELECTRON_USER_DATA_PATH` and `CODEX_HOME`.

For Electron apps without a recipe, `parallex doctor` lists environment
variables in the app's code that look like data-location switches, as leads to
try with `--env`. Recipes live in `Presets.recipes`.

## Caveats (inherited from the technique — Parall has these too)

- **Sandboxed (App Store) apps** get separate data only in clone mode (their
  own container), and only for data outside shared app-group containers.
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
- **Sign-in callbacks**: `app://` links are routed with `parallex links`;
  localhost OAuth callbacks go to whichever copy listens on the port — quit the
  others before signing in if they clash.
- **Self-updating apps** update the shared original bundle; all instances pick
  it up on restart. An in-app "restart to update" may relaunch the app as the
  original rather than the instance — reopen the instance from Parallex.

## Status

v0.7 — see [PLAN.md](PLAN.md) for the design. The original proof of concept is
in [poc/](poc/).

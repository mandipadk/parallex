# Parallex

Run multiple fully isolated instances of any macOS app — each with its own Dock
icon, its own data, and its own settings. A free, open, developer-friendly
alternative to [parall.app](https://parall.app/).

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
completely independently of the original.

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
up the isolated environment, and `execv()`s the target binary. Because the PID
Launch Services registered for the wrapper survives the exec, macOS attributes
the running app to the wrapper — that's what gives each instance its own Dock
identity and defeats single-instance checks at the Launch Services layer.

Data isolation is tiered, auto-detected per app (`parallex doctor` shows the
verdict):

| Tier | Apps | Method |
|------|------|--------|
| data-dir | Electron, Chromium browsers, VS Code family, Firefox | framework flags (`--user-data-dir=…`, `--no-remote --profile …`, …) |
| home | any non-sandboxed app | `HOME` points at a per-instance folder; Desktop/Documents/Downloads/… are symlinked back so user files stay shared |
| launch-only | sandboxed (App Store) apps | separate identity only — macOS pins sandboxed app data to its container |

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
what it found (framework, sandbox verdict, recommended isolation) before you
commit. Name the instance, optionally give its icon a one-letter badge, create,
done. The list shows live running status; the menu-bar icon launches any
instance in one click. Removal always goes through the Trash.

## CLI usage

```sh
parallex create <app> [options] [-- extra args for the target]
parallex list [--json]
parallex open <name> [--reveal]
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
| `--force` | rebuild an existing instance (keeps its data) |
| `--open` | launch right after creating |

Examples:

```sh
parallex create Claude --name "Claude Work" --badge W
parallex create "Google Chrome" --name "Chrome Dev" -- --remote-debugging-port=9222
parallex create Cursor --name "Cursor OSS" --badge O
parallex doctor Slack                    # what would Parallex do with Slack?
parallex remove "Chrome Dev"             # wrapper + data → Trash
```

Instance data lives under `~/Library/Application Support/Parallex/instances/`
(override with `PARALLEX_HOME`). Removal always goes through the Trash, and
Parallex refuses to replace or delete any `.app` it didn't create.

## Per-app recipes

Some apps pin their data directory in code and ignore `--user-data-dir`
entirely — Codex, for instance, but it honors its own environment overrides
(`CODEX_ELECTRON_USER_DATA_PATH`, `CODEX_HOME`). Parallex carries a table of
such recipes and applies them automatically in auto mode; `parallex doctor`
shows what will be used. Found another app like this? The table is one entry
in `Presets.appOverrides`.

## Caveats (inherited from the technique — Parall has these too)

- **Sandboxed (App Store) apps** get a separate identity but not separate data.
- **Launching the original while an instance runs** needs "new instance"
  semantics: a running instance re-registers under the original's identity
  after exec, so a plain `open`/Dock click focuses the instance instead. Use
  the instance's "Launch Original" menu item in Parallex.app, or
  `parallex open <name> --original` (or `open -n`).
- **HOME isolation is partial on recent macOS**: system frameworks resolve
  `~/Library` from the user account rather than `$HOME`, so home mode reliably
  isolates dotfiles and CLI state but not necessarily a native app's
  `~/Library` data.
- **Permissions prompt again** per instance (notifications, camera, screen
  recording, …) — TCC tracks them by bundle ID.
- **Phantom Dock icon** if a wrapper is re-opened via Spotlight/Raycast while
  that instance is already running.
- **Notifications** may focus the wrong instance when several run at once.
- **OAuth flows** with localhost callbacks can land in the wrong instance —
  quit the others before authorizing.
- **Self-updating apps** update the shared original bundle; all instances pick
  it up on restart. The updater may need App Management permission.

## Status

v0.2 — see [PLAN.md](PLAN.md) for the design and roadmap. Validated PoC in
[poc/](poc/).

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

- **Its own Library.** macOS finds an app's `~/Library` (Application Support,
  caches, cookies, web storage…) from the user account rather than `$HOME`,
  so for native apps a separate `HOME` alone leaves most of their data
  shared. A copy of an app that isn't sandboxed therefore also carries a small
  library, `libparallexhome.dylib`, that the launcher loads into it. The
  library answers the account lookups (`getpwuid` and friends) with the
  instance's home, so everything the app keeps under `~` lands in the
  instance. Documents, Desktop, Downloads and your dotfiles stay shared
  through links. The library is only active in processes whose executable
  lives inside the copy, so tools the app starts (shells, `git`, …) behave
  normally. It's on by default: turn off **Separate Library** in the
  instance, or use `parallex edit <name> --no-separate-library`. Copies made
  before 0.9 keep using the real `~/Library` until you turn it on.
- **Shared containers of App Store apps.** Many sandboxed apps keep their
  sign-in and data in app-group containers shared by the developer's apps
  (WhatsApp, for one). These are keyed by group, not by app. A copy's group
  entitlements are therefore renamed to groups of its own, and its nested
  services get identifiers of their own. A small library shipped inside the
  copy, `libparallexgroups.dylib`, which Launch Services loads into it,
  translates the app's requests for its original groups and services to the
  copy's. Tested live: a WhatsApp copy starts signed out, with its database
  in its own containers, and the original's are never opened. This is on by
  default for new copies ("Separate shared data").
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
| home | other non-sandboxed apps | `HOME` points at a per-instance folder; Desktop/Documents/Downloads/… are symlinked back. As an own-identity copy (the default for these apps) its whole `~/Library` is separate too; as a plain wrapper, only dotfiles and command-line state are |
| launch-only | sandboxed (App Store) apps | a separate launcher only — macOS pins sandboxed app data to its container |

### Sign-in links

Apps finish sign-in by opening a link in their own scheme (`claude://…`,
`cursor://…`). With several copies of an app running, macOS hands that link to
an arbitrary one. `parallex links enable` (or **Settings › Links**)
makes a small background app, *Parallex Links*, the handler for your
instances' schemes; it passes each link to the copy you used most recently, or
asks. Apps reclaim their scheme when they start, so keep Parallex.app running
(Settings › Open Parallex at login) — it takes the schemes back.

### Web links

Links you click in an instance can open in that instance's browser: work
links in your work browser, client links in the client's. With
`parallex links web on` (or **Settings › Links**), Parallex Links becomes your
default browser (macOS asks you to confirm). A link opened by an instance goes
to the browser its workspace uses (`parallex workspace browser Work "Chrome/Work"`
— a browser, a Chrome/Brave/Edge profile, or a browser instance), a site with a
rule goes where the rule says (`parallex links rule add northwind.com "Brave Browser"`),
and everything else opens in the browser you had before, as if Parallex weren't
there. `parallex links web off` gives links back to that browser.

### Websites as apps

Some services are only a website on the Mac, or their app can't be copied:
Teams, Outlook, a second WhatsApp or Gmail account. `parallex create --web
teams.microsoft.com` (or **New Instance › A website**) makes the site an app
of its own, with its own Dock icon (the site's icon, or a letter tile when it has
none), its own sign-in and cookies, and its own notifications. An unread count in
the page's title, like "(3) Inbox", becomes its Dock badge. Sign-in pop-ups stay
in the app, and links to other sites open in your browser. Under the hood it is
an own-identity copy of *Parallex Web*, a small WebKit app that ships with
Parallex, so it is separate from Safari and from every other instance.

`parallex check <name>` verifies a running instance: it lists the files the
instance's processes have open and flags any that belong to the original app's
data, so isolation is something you can see rather than assume.

## Install

**[Download Parallex for Mac](https://github.com/mandipadk/parallex/releases/latest/download/Parallex.dmg)**
(macOS 14 or later, Apple silicon and Intel), open the disk image, and drag
Parallex to Applications. Releases aren't notarized yet, so the first time you
open it macOS asks you to confirm: open **System Settings › Privacy & Security**
and choose **Open Anyway**.

After that, Parallex keeps itself up to date. It checks GitHub Releases once a
day (Settings › About), shows what's new, and installs an update in one click.
It installs only archives signed with the Parallex release key, which is built
into the app. The `parallex` command ships inside the app: **Settings › About ›
Install** links it onto your PATH, so it updates along with the app.

### From source

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
- **Launch** — open the instance whenever Parallex starts, and give it a
  global keyboard shortcut. Pressing the shortcut opens the instance, brings it
  forward, or hides it when it's already in front.
- **Storage** — disk usage, clearing caches, removing leftovers.
- **Advanced** — isolation mode, extra environment and arguments, paths.

Changes that rebuild the instance collect in an apply bar; the rest save as you
make them. Problems (a moved or missing original, an outdated wrapper, a copy
older than its app) show at the top with a one-click fix. **New Instance**
(⌘N) offers your installed apps sorted by how well they duplicate, then a live
preview of the instance's icon as you name and color it.

**Workspaces** group the instances you use together, like Work and Personal.
One click (or one shortcut) opens them all, optionally hiding the other
instances. They show at the top of the sidebar, in the menu bar and in the
switcher. **Duplicate** makes another instance with the same settings,
starting fresh or with a near-free APFS copy of its data.

**Starting from the original.** A copy with its own Library starts
empty. **Start from <App>'s data** (or `parallex copy-data <name>`) copies
the original app's Application Support, cookies and web storage, config
folder and preferences into the copy. These are APFS clones, so the copy
is instant. From then on the two go their own ways. Sign-ins the app keeps
in the keychain may need signing in again.

**Export and import.** `parallex export <name>` (or **Export…** in the
instance's menu) saves an instance's settings and data as one `.parallex`
file. Double-clicking the file (or `parallex import <file>`) recreates the
instance on any Mac that has the app, under a name that's free there.
The file is treated as untrusted:
- The app is found on the importing Mac by bundle ID, never by a path in the file.
- The file's extra launch arguments and environment are left out unless you
  pass `--keep-extras`.
- Even with `--keep-extras`, variables that load code (`DYLD_*`,
  `NODE_OPTIONS`, …) are never imported.
- Links pointing outside the instance are dropped.

**Links** open things from anywhere: Shortcuts, launchers, scripts, a
bookmark. Any web page can ask to open a link, so links only ever open or
show things.

```
parallex://open/Claude%20Work     open (or bring forward) an instance
parallex://workspace/Work         open a workspace
parallex://show/Claude%20Work     show the instance in Parallex
parallex://new?app=Obsidian       start a new instance of an app
```

**Notifications** are kept to the few that need you:
- a running own-identity copy whose app has updated (with **Restart Now**)
- an instance whose app is gone
- an automatic repair that failed
- a Parallex update

Each arrives once per change.

**The menu bar** holds every instance one click away and shows which one is in
front. Parallex runs from there: it has a Dock icon only while its window is
open, and starts without a window at login.

## CLI usage

```sh
parallex apps [--all] [--json]
parallex create <app> [options] [-- extra args for the target]
parallex create --web <site> [--name <name>] [--badge-color <hex>]
parallex list [--json]
parallex open <name> [--original | --reveal]
parallex edit <name> [options] [-- replacement extra args]
parallex repair <name> | --all [--app <path>]
parallex check <name> [--verbose] [--json]
parallex storage [<name>] [--clean-caches] [--remove-unused]
parallex links [status | enable [--ask] | disable]
parallex links web [on | off | status]
parallex links rule [add <site> <target> | remove <site> | list]
parallex workspace [list | create | add | remove | open | quit | rename | shortcut | browser | delete]
parallex duplicate <name> [--name <new name>] [--with-data]
parallex copy-data <name> [--dry-run]
parallex export <name> [-o <file.parallex>]
parallex import <file.parallex> [--name <name>] [--out <dir>]
parallex remove <name> [--keep-data]
parallex doctor <app> [--json]
parallex report <name> [--print]
```

`<app>` can be a path (`/Applications/Claude.app`), a name (`Claude`), or a
bundle identifier (`com.anthropic.claudefordesktop`).

Give an instance a global shortcut (the Parallex app must be running to
register it): `parallex edit "Claude Work" --shortcut ctrl+opt+1`.

Useful `create` options:

| Option | |
|--------|--|
| `--name` | display name (default `<App> 2`, `<App> 3`, …); any language works |
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
| `--throwaway` | once it has run and quit, the Parallex app moves it and its data to the Trash (also `edit --throwaway`) |
| `--hide-from-dock` | (`edit`) no Dock icon or ⌘-Tab entry for an own-identity copy; open it from its menu bar icon or shortcut |
| `--web SITE` | a website as an app of its own, instead of an app's instance (see above); `edit --web` changes its address |
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
parallex create --web teams.microsoft.com --name "Teams Client"   # a website as an app
parallex links enable                    # sign-in links go to the right copy
parallex workspace browser Work "Chrome/Work"  # Work's links open in Chrome's Work profile
parallex links web on                    # …once Parallex Links routes web links
parallex repair --all                    # rebuild outdated or broken wrappers
parallex report "Slack Work"             # tell others how Slack works (opens a prefilled GitHub report)
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

## Support

Parallex is free and made by a student. If it's useful to you, you can
[sponsor it on GitHub](https://github.com/sponsors/mandipadk) or
[buy it a coffee on Ko-fi](https://ko-fi.com/mandipadk). The first goal is the
$99 a year for Apple's Developer ID, so Parallex opens without the
"Open Anyway" step.

## Status

v0.16 — see [PLAN.md](PLAN.md) for the design. Tell others how an app works with `parallex report` or the [compatibility form](https://github.com/mandipadk/parallex/issues/new?template=compatibility.yml). The original proof of concept is
in [poc/](poc/).

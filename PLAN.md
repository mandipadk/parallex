# Parallex — Multi-Instance App Launcher for macOS

A free, open, developer-friendly alternative to [parall.app](https://parall.app/): run multiple
fully isolated instances of any macOS app, each with its own Dock identity, data, and settings.

## 1. How Parall actually works (research findings)

Parall does **not** clone or modify the target app, and does not use code injection. Per its
[FAQ](https://parall.app/faq/) and [GitHub README](https://github.com/JulyIghor/Parall):

- Each "shortcut" is a **tiny standalone `.app` bundle** whose executable directly launches the
  target app's binary (standard process launching — the configured environment and arguments are
  inherited by the target process).
- The wrapper bundle has its **own bundle identifier**, so it launches as its own app. (On current
  macOS the identity doesn't survive the exec for most apps — see §3, "Identity after exec".)
- Data isolation is tiered:
  - **App-aware mode** for known frameworks (Chromium, Electron, Firefox, ToDesktop, Eclipse):
    pass the framework's profile/data-dir flag (e.g. `--user-data-dir`).
  - **HOME override** as the generic fallback for non-sandboxed apps: the wrapper sets `HOME` to a
    fresh folder, with selective symlinks back to the real home for things you want shared
    (e.g. shell/Docker configs).
  - **Sandboxed (Mac App Store) apps cannot be isolated this way** — macOS forces their data into
    `~/Library/Containers/<bundle-id>/Data` regardless of `HOME`.
- Wrappers are ad-hoc signed (unsigned on old macOS) and need the quarantine attribute cleared.

## 2. Proof of concept — validated on this machine (macOS 26.3.1)

`poc/` contains a working PoC built and tested 2026-06-10:

- `launcher.c` → 33 KB arm64 Mach-O that `execv()`s
  `/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=…/Claude-ParallexPoC`
- Wrapped in `Claude PoC.app` with its own `CFBundleIdentifier` (`com.parallex.poc.claude`),
  Claude's `electron.icns` copied in, ad-hoc signed with `codesign --force --sign -`.

**Result:** launched via `open`, a fully independent Claude instance started alongside any
existing one, created its own data directory, and all helper processes (GPU, network, renderer)
inherited the isolated `--user-data-dir`. The mechanism is confirmed end-to-end.

`Claude.app` is Electron and **not sandboxed** (no `com.apple.security.app-sandbox`
entitlement), so both app-aware and HOME-override modes work.

## 3. Architecture

```
parallex/
├── PLAN.md
├── poc/                        # validated proof of concept (keep for reference)
├── launcher/
│   └── main.swift              # generic launcher: reads config from its own bundle, execs target
├── Sources/parallex/           # Swift CLI (swift-argument-parser)
│   ├── CreateCommand.swift     # parallex create
│   ├── ListCommand.swift       # parallex list
│   ├── RemoveCommand.swift     # parallex remove
│   ├── DoctorCommand.swift     # parallex doctor <app>  — detect framework/sandbox, suggest mode
│   ├── AppInspector.swift      # entitlement + framework detection
│   ├── BundleBuilder.swift     # assembles wrapper .app, signs, clears quarantine
│   └── Presets.swift           # per-framework isolation recipes
└── Package.swift
```

### The generic launcher (key design decision)

Instead of compiling a launcher per wrapper (PoC approach), build **one universal
(arm64 + x86_64) launcher binary at release time** and copy it into every wrapper. It reads its
configuration from its own bundle's `Info.plist` under a custom dict:

```xml
<key>Parallex</key>
<dict>
    <key>TargetBinary</key>   <string>/Applications/Claude.app/Contents/MacOS/Claude</string>
    <key>Arguments</key>      <array><string>--user-data-dir=…</string></array>
    <key>Environment</key>    <dict>…optional…</dict>
    <key>HomeOverride</key>   <string>…optional path…</string>
</dict>
```

Launcher logic (Swift using `Bundle.main`): read config → resolve the target (recorded bundle
path, re-reading its `CFBundleExecutable`; falling back to a Launch Services lookup by bundle ID
if the app moved) → if the pid file names a live instance, activate it and exit → create data
directories (failure is fatal: a missing data dir silently costs isolation) → set env vars →
optionally set `HOME` (with symlink scaffolding) → write `<pid>\n<executable>` to the pid file →
`execv` the target. `execv` keeps the PID, so the pid file identifies the instance's process for
its whole lifetime.

### Identity after exec

Measured on macOS 26: after `execv`, the target checks in with Launch Services under **its own**
bundle ID, name, and path — identity is derived from the executable. `CFProcessPath` (which makes
CoreFoundation treat another bundle as the main bundle) does keep the wrapper's identity, but only
for targets without the hardened runtime; hardened targets ignore it, and virtually every
distributed app is hardened. Copying or relocating the executable breaks code signing or, for
Electron, triggers a relaunch from the original bundle. So a running instance shares the
original's Dock tile, ⌘-Tab entry, notifications, and bundle-ID-keyed storage (URL cache, native
cookie store).

**Clone mode** gets a real identity by changing the executable instead: the instance is an APFS
clone of the whole app with its own bundle ID, re-signed ad hoc inside out (nested code keeps its
entitlements minus provisioning-only ones; hardened runtime dropped), with the Parallex launcher as
`CFBundleExecutable` and the app's binary beside it. Launch Services then registers the running
process under the copy's identity. `CFBundleName` stays (Electron locates `<Name> Helper.app` by
it); the display name changes. Sandboxed apps keep their own executable (the launcher can't do its
work inside the sandbox) and get their own container. Copies are marked stale when the original's
version changes.

Without clone mode, Parallex identifies instances by PID (pid file + executable check) and provides
the identity cues itself: colored window outlines with a name tag (window list bounds and owner PIDs
need no permission; overlays are ordered directly above each window), the front instance's name in
the menu bar, and a ⌃⌥Space switcher listing instances and running originals.

### Instance records

`instance.json` (schema 2) stores the user's choices (`settings`: requested mode, badge, custom
icon, extra env/args/shared items, recipe options) separately from the resolved launch config.
Edits and repairs re-derive the launch config from the settings, so recipe improvements reach
existing instances and nothing the user chose is lost. Schema-1 records are migrated on read;
their existing wrapper icon is preserved on the first rebuild.

### Wrapper bundle layout (what `parallex create` emits)

```
Claude Work.app/
└── Contents/
    ├── Info.plist          # unique CFBundleIdentifier (com.parallex.<slug>), name, icon, Parallex config
    ├── MacOS/launcher      # the universal generic launcher
    └── Resources/app.icns  # icon extracted from target (optionally badged)
```

Post-create steps the CLI performs automatically:
1. `codesign --force --sign - <wrapper>.app` (ad-hoc)
2. `xattr -dr com.apple.quarantine <wrapper>.app`
3. `lsregister -f <wrapper>.app` (or just rely on first `open`) to register with Launch Services

## 4. Isolation strategy (tiered, auto-detected by `doctor`)

| Tier | Detection | Method |
|------|-----------|--------|
| 1. App-aware | `Contents/Frameworks/Electron Framework.framework`, Chromium/Firefox markers | Framework-specific flags (below) |
| 2. HOME override | Non-sandboxed (no `com.apple.security.app-sandbox` in entitlements) | `HOME=<instance dir>` + symlink scaffolding |
| 3. Sandboxed | `app-sandbox` entitlement present | Warn: launch-only (no data isolation). Optional future "clone mode" (copy bundle, rewrite bundle ID, re-sign) — works but breaks on app updates and Apple-signed receipts; explicitly out of scope for v1. |

Framework presets for tier 1:
- **Electron / Chromium**: `--user-data-dir=<dir>` (also defeats the SingletonLock single-instance check)
- **Firefox-based**: `-no-remote -P <profile>` or `--profile <dir>`
- **VS Code / forks (Cursor, Windsurf, Zed-like)**: `--user-data-dir=<dir> --extensions-dir=<dir>`
  (note: marketplace URL must be set in the new profile for extension search — known Parall quirk)
- Preset table is data (`Presets.swift` / future JSON), easy to extend per app.

HOME override scaffolding (tier 2): create `~/Library/Application Support/Parallex/<instance>/home/`,
pre-create `Library/Preferences`, `Library/Application Support`, `Library/Caches`, and symlink
`Downloads` (and optionally `.gitconfig`, `.ssh`, shell rc files) back to the real home.

## 5. CLI UX

```bash
parallex create /Applications/Claude.app --name "Claude Work" \
    [--mode auto|data-dir|home|launch-only] [--icon-badge "W"] [--out /Applications]
parallex list                    # instances + their data dirs + target apps
parallex remove "Claude Work"    [--keep-data]
parallex doctor /Applications/SomeApp.app   # sandbox? framework? recommended mode
```

Defaults: `--mode auto` (doctor logic), wrapper written to `/Applications`, data under
`~/Library/Application Support/Parallex/<slug>/`.

## 6. Known caveats (inherited from the technique — Parall has these too)

- **Shared identity while running** (see §3, "Identity after exec"): Dock tile, ⌘-Tab, and
  notifications show the original; bundle-ID-keyed storage is shared.
- **Re-opening a running instance** from Spotlight/Raycast/Dock briefly bounces the wrapper's icon
  while the launcher hands off to the running instance.
- **Notifications** may focus the wrong instance when several run at once; notification
  registration is per bundle-ID of the *target* in some apps.
- **OAuth flows** (Cursor/Codex-style localhost callbacks) can fail if another instance of the
  same app is running — quit others before authorizing.
- **Self-updating apps** update the shared original bundle — all instances pick the update up on
  restart (a feature), but the updater may need App Management permission.
- **TCC permissions** (camera, mic, screen recording) follow the running app's identity, so an
  instance may share them with the original.
- **Sandboxed apps**: launch-only; no data isolation without clone mode.

## 7. Milestones

1. ~~**MVP**~~ ✅ superseded — went straight to v0.2.
2. ~~**v0.2**~~ ✅ **shipped 2026-06-10** — generic launcher + Info.plist config, HOME-override
   mode, `doctor`, `list`/`remove`, universal binary, preset table (Electron, Chromium browsers,
   VS Code family, Firefox). Plus, pulled forward from v0.3: icon badging (`--badge`/`--badge-color`),
   `--env` and `--` args passthrough, `--share`/`--no-shared-defaults` symlink config.
   40 tests incl. end-to-end launcher integration tests; smoke-tested against Claude.app.
3. ~~**v0.3**~~ ✅ **shipped 2026-06-10** — `parallex open <name>`, Homebrew formula scaffold
   (`Formula/parallex.rb`; tap publishing waits on a public repo), and the big one pulled forward
   from "later": **Parallex.app**, a SwiftUI GUI (manager window + menu-bar quick launcher) over
   the same core. Core logic extracted into a `ParallexCore` library shared by CLI and GUI;
   `make app-install` assembles and installs /Applications/Parallex.app. 49 tests.
4. **v0.5** — instance records v2 (settings stored separately; `edit` and `repair` rebuild
   faithfully, including renames that keep data and bundle ID); per-app recipes with options
   (Claude: `CLAUDE_USER_DATA_DIR`, optional separate Claude Code config; Codex); launcher that
   activates an already-running instance, follows a moved or renamed target, and fails loudly
   when it can't create data directories; `check` (open-file isolation verification), `storage`
   (usage, cache and leftover cleanup), `--adopt-data`; data-location switch discovery in
   `doctor`; app: status and repair per row, edit sheet, isolation check, window outlines, menu
   bar front-instance indicator, ⌃⌥Space switcher, open at login.
5. **v0.6** — clone mode (`--clone`: own identity via a re-signed APFS copy; own container for
   sandboxed apps; stale-copy detection and refresh); sign-in link routing (`parallex links`:
   generated "Parallex Links" handler for instances' schemes, delivery to a specific process by
   Apple Event, most-recently-used choice or ask, schemes reclaimed after apps re-register);
   launched apps no longer inherit another instance's isolation variables.
6. **v0.7** — redesigned app: first-run onboarding (app suggestions from an installed-app
   catalog, recommended integrations), list/detail window with in-place editing and an apply bar
   for rebuild changes, New Instance gallery with live icon preview, menu-bar panel, Settings
   tabs, new app icon; Liquid Glass surfaces on macOS 26 with material fallbacks (macOS 14+).
   Instance icons are built from the icon macOS shows for the app (asset catalogs), so they
   aren't placed on a backing plate on macOS 26. Recipes can declare unavoidably shared folders
   (Claude's logs). `parallex apps`; per-instance "open when Parallex starts".
7. **v0.8** — per-instance global shortcuts (open / bring forward / hide; `edit --shortcut`),
   ⌘1–9 in the switcher; notifications for a running copy behind its app (Restart Now), a
   missing app, a failed repair, and Parallex updates; What's New after upgrading; built-in
   updates from GitHub Releases (daily check, Ed25519-signed archives verified against a key
   compiled into the app, atomic swap and relaunch); the `parallex` command bundled in the app
   and linkable from Settings; `make dist` / `make publish` (signed zip for the updater, DMG for
   downloads). Creation takes a registry lock (safe concurrent creates); names without Latin
   letters get a transliterated or hashed slug; names that reduce to the same slug get distinct
   slugs. Stress tests cover churn, awkward names, concurrency, corrupt manifests, and targets
   that move or disappear.
8. **v0.9** — separate Library for own-identity copies of apps that aren't sandboxed: the copy
   carries `libparallexhome.dylib` (interposes the account lookups so the app's home — and so its
   `~/Library` — is the instance's), loaded by the launcher and written into nested XPC services'
   and helper apps' environments; scoped to processes inside the copy. On by default for new
   copies (native apps default to a copy), migrated off for older ones. The isolation check
   treats anything such a copy keeps in the real `~/Library` as a leak. Removing a copy takes its
   preferences and saved state along to the Trash. Validated on Spotify, Zed, IINA, VLC,
   Obsidian and Ghostty: zero writes to the originals' data.
9. **Later/optional** — badge style options; published Homebrew tap.

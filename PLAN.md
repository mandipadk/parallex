# Parallex — Multi-Instance App Launcher for macOS

A free, open, developer-friendly alternative to [parall.app](https://parall.app/): run multiple
fully isolated instances of any macOS app, each with its own Dock identity, data, and settings.

## 1. How Parall actually works (research findings)

Parall does **not** clone or modify the target app, and does not use code injection. Per its
[FAQ](https://parall.app/faq/) and [GitHub README](https://github.com/JulyIghor/Parall):

- Each "shortcut" is a **tiny standalone `.app` bundle** whose executable directly launches the
  target app's binary (standard process launching — the configured environment and arguments are
  inherited by the target process).
- The wrapper bundle has its **own bundle identifier**, so macOS gives it its own Dock icon, name,
  and app identity. Launch Services never sees the target's bundle ID, which also sidesteps
  "app is already running" single-instance behavior at the LS layer.
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

Notes specific to this machine: `Claude.app` is Electron and **not sandboxed** (no
`com.apple.security.app-sandbox` entitlement), so both app-aware and HOME-override modes work.
The existing `Claude Secondary.app` / `Claude Work.app` AppleScript applets are superseded by
this approach (they have no real bundle identity of their own and only isolate the user-data dir).

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

Launcher logic (~50 lines of Swift using `Bundle.main`): read config → set env vars → optionally
set `HOME` (creating the directory + symlink scaffolding on first run) → `execv` the target.
`execv` (not spawn-and-exit) keeps the same PID that Launch Services registered for the wrapper,
which is what gives the instance the wrapper's Dock icon and identity.

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

- **Phantom Dock icons** if a wrapper is re-opened via Spotlight/Raycast while already running.
- **Dock icon can be overwritten at runtime** by apps that draw their own Dock tile.
- **Notifications** may focus the wrong instance when several run at once; notification
  registration is per bundle-ID of the *target* in some apps.
- **OAuth flows** (Cursor/Codex-style localhost callbacks) can fail if another instance of the
  same app is running — quit others before authorizing.
- **Self-updating apps** update the shared original bundle — all instances pick the update up on
  restart (a feature), but the updater may need App Management permission.
- **TCC permissions** (camera, mic, screen recording) are granted per bundle ID — each wrapper
  prompts fresh on first use.
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
4. **Later/optional** — clone mode for sandboxed apps (explicitly deferred: breaks on app
   updates and Apple-signed receipts); badge style options; published Homebrew tap.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Wormhole is a native macOS menu bar application with a floating portal window. The built-in portal wraps [Magic Wormhole](https://magic-wormhole.readthedocs.io/en/latest/) for secure file transfers (drag to send, click to enter a receive code). Other portals are user-defined "command portals" that run a shell command on the dropped file. Portals are data in `portals.json`, editable in-app, by hand, or with the bundled `portal` CLI. It is open source (MIT); keep personal paths, domains and identifiers out of code, tests and docs.

## Build Commands

```bash
# Build the app
xcodebuild -project wormhole.xcodeproj -scheme wormhole -configuration Debug build

# Run unit tests (UI tests need a display; skip them)
xcodebuild -project wormhole.xcodeproj -scheme wormhole -destination 'platform=macOS' -only-testing:wormholeTests test

# Clean build
xcodebuild -project wormhole.xcodeproj -scheme wormhole clean
```

For development, open `wormhole.xcodeproj` in Xcode and use Cmd+R to build and run.

## Architecture

Targets: `wormhole` (the app), `portal` (CLI tool, embedded at `Contents/MacOS/portal`), `wormholeTests`, `wormholeUITests`. Folders are Xcode synchronized groups, so new files in a folder join its target automatically.

- `wormhole/wormholeApp.swift` — GUI code (app, AppDelegate, views, sounds).
- `wormhole/PortalHUD.swift` — `PortalHUDController`, the MacHUD contract (HUDKit socket server, panel verbs, parking, actions, settings).
- `wormhole/ModifierSetTracker.swift` — follows shift/option/control to swap portal sets.
- `wormhole/machud.json` — MacHUD manifest, copied to `Contents/Resources`.
- `PortalCore/` — `PortalStore.swift` (portal model, `portals.json` codec, load/save/migrate/watch), `PortalSets.swift` (`PortalLibrary`: sets, normalization, set operations) and `PortalCLI.swift` (CLI logic). Compiled into both the app and the CLI.
- HUDKit is a local Swift package at `../hudkit` (linked into the app target only).
- `portal/main.swift` — CLI entry point.
- `scripts/release-local.sh` — release build; configuration in `.env` (see `.env.example`, `docs/RELEASING.md`).
- `docs/` — design records (`portal-cli-design.md`, `user-definable-portals-design.md`) and release notes.

### Key Components

| Component | Where | Purpose |
|-----------|-------|---------|
| `SoundManager` | `wormholeApp.swift` | Singleton for audio effects |
| `AppDelegate` | `wormholeApp.swift` | Core logic, process management, window handling |
| `SetupWizardView` | `wormholeApp.swift` | First-launch onboarding UI (Homebrew + magic-wormhole only) |
| `PortalView` | `wormholeApp.swift` | Main portal interface |
| `PortalStore` | `PortalCore/PortalStore.swift` | `portals.json` load/save/migrate, add/set/rm |
| `PortalLibrary` | `PortalCore/PortalSets.swift` | Portals plus sets; always normalized |
| `PortalHUDController` | `wormhole/PortalHUD.swift` | MacHUD socket (`wormhole.sock`), parking, `state` events |
| `portal` CLI | `portal/main.swift` + `PortalCore/PortalCLI.swift` | Agent-facing `portal add/list/set/rm/show` and `sets`/`set-*` |

On launch the GUI loads `~/Library/Application Support/Wormhole/portals.json` (version 2; version 1 loads as a single `default` set). If it is missing, it migrates `portalDefinitions_v1` from UserDefaults once, or else seeds `PortalDefinition.firstRunPortals` (wormhole, Copy Path, Reveal in Finder). If the file cannot be read (e.g. a newer version) the app never saves over it. It watches the file for external edits, silently symlinks `~/.local/bin/portal` if that name is free, and starts the MacHUD socket. UserDefaults: `activeSetID` (base set), `selectedPortalBySet` (selection per set; `selectedPortalID` mirrors the default set's for older builds), `hotkey` (only once changed). When hosting unit tests, `applicationDidFinishLaunching` returns early and does none of this.

### Sets

`AppDelegate.library` is the whole file; every in-app change saves it (`didSet`), reloads from disk do not. `activeSet` is the modifier set while one is held (`modifierSetID`, driven by `ModifierSetTracker`) else the base set (`baseSetID`). The portal window shows `activePortals`. `selectedPortalID` is per active set.

### MacHUD contract

`PortalHUDController` runs `HUDSocketServer` at `HUDSocket.path(for: "wormhole")` with `HUDControlRouter`. Panel id `portal`. `panelMode` lives on `AppDelegate` (`PortalView` renders `compact`). Only the full-mode, non-animating frame is autosaved (`savePortalFrameIfResting`). Actions: `select-set`, `send`; settings: `activeSet`, `hotkey`. Drive it with `echo '{"command":"state"}' | nc -U ~/Library/Application\ Support/MacHUD/sockets/wormhole.sock`. A debug build shares the app's UserDefaults and `portals.json` with an installed Wormhole, and re-points `~/.local/bin/portal`.

### Command portals

`runCommandPortal` substitutes `{path}`, `{filename}`, `{dir}` (escaped for a double-quoted context) into the template and runs it with `/bin/zsh -c` (`-l` if `runInLoginShell`), optionally in `workingDirectory`. Exit 0 shows `successLabel`.

### State Enums

- **`TransferState`**: `idle` → `pending` → `transferring` → `success`/`failed`
- **`ProcessState`**: Tracks wormhole CLI process lifecycle
- **`DependencyState`**: Tracks Homebrew/Magic Wormhole installation status

### Process Execution

Wormhole commands run via `/bin/zsh -c`:
- **Send**: `{wormholePath} send "{escapedFilePath}"`
- **Receive**: `cd ~/Downloads && {wormholePath} receive {code}`

Output is parsed via regex to extract codes, progress percentages, and completion messages.

### Wormhole Code Validation

Codes must match pattern `^\d+-[a-z]+-[a-z]+$` (e.g., `7-guitarist-revenge`). This prevents shell injection.

## Dependencies

- **Sparkle** (SPM): auto-update; feed is `SUFeedURL` in `wormhole/Info.plist` (`https://viawormhole.xyz/appcast.xml`), appcast source is `releases/appcast.xml`. Release zips go to GitHub Releases, not git.
- **Magic Wormhole**: CLI tool (installed via Homebrew at runtime)

## Development Notes

- Portal window is a singleton borderless floating NSWindow. It's freely
  positionable (`isMovable`/`isMovableByWindowBackground`) and persists across
  show/hide toggles: `showPortalWindow()`/`closePortalWindow()` order it
  in/out rather than recreating it, so it keeps whatever position and size
  the user left it at. Its frame is saved to `UserDefaults` under the
  `"PortalWindow"` autosave name and restored on next launch; the top-right
  anchor position is only applied when no saved frame exists yet. Frame
  saving is done explicitly from `AppDelegate`'s `NSWindowDelegate`
  (`windowDidMove`/`windowDidResize`) rather than relying solely on
  `NSWindow`'s automatic autosave-on-move, which was observed not to persist
  reliably for this window.
- Launching with the `--show-portal` argument opens the portal window
  shortly after launch, independent of the global hotkey — used by
  `scripts/ax-move-test.sh` for automation.
- Global hotkey (default Option+Control+P, via `HUDHotKeyCenter`) toggles the portal; `settings set hotkey=` changes it.
- The portal window is `.resizable` so AX can set its size; its hosting view sits in a plain container with `sizingOptions = []` so SwiftUI never resizes it. Frames smaller than 320×240 show the portal centered and clipped.
- Sound effects are `.wav` files in the bundle; every one must be CC0 or CC BY and credited in README "Attributions" (no non-commercial licenses).
- The app is not sandboxed and its entitlements file is intentionally empty; add entitlements only with a concrete need.
- Deployment target is macOS 14.6 for every target.
- Debug logging uses emoji prefixes (🔄 state changes, ❌ errors, ✅ success)

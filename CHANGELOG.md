# Changelog

All notable changes to Wormhole are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The current version is
in [VERSION](VERSION), which mirrors `MARKETING_VERSION` in the Xcode project.
Released builds are listed in [releases/appcast.xml](releases/appcast.xml).
This file was reconstructed from `git log` on 2026-09-26.

## [Unreleased]

### Added
- Portal sets (`portals.json` version 2): ordered selections of portals, each
  with an optional Shift/Option/Control modifier that swaps the set in while held.
  Set editing in **Configure Portals…** and `portal sets` / `set-create` /
  `set-add` / `set-rm` / `set-order` / `set-edit` / `set-delete` in the CLI.
- MacHUD contract through HUDKit: `machud.json`, the `wormhole` control socket,
  panel `portal` with `show` / `hide` / `toggle` / `frame` / `mode`
  (`parked`, `compact`, `full`), `state` and `subscribe`, `settings`
  (`activeSet`, `hotkey`), actions `select-set` and `send`.
- Parking honours the edge and peek MacHUD asks for.
- The portal window can be moved and resized freely and keeps its frame.
- The selected portal is remembered per set across launches.
- New installs get Copy Path and Reveal in Finder command portals.
- MIT license; `docs/RELEASING.md`; release script configured from `.env`.

### Changed
- HUDKit is linked as a local Swift package (`../hudkit`).
- Sparkle feed moved to `https://viawormhole.xyz/appcast.xml`; release zips live
  on GitHub Releases instead of in git.
- Deployment target is macOS 14.6 for every target.
- README rewritten for the scriptable release; CLAUDE.md refreshed.

### Fixed
- Command portals no longer hang on large output.
- The `portals.json` watcher no longer drops external writes after a local save.
- The unit-test host no longer has launch side effects (hotkey, `~/.local/bin/portal`).

### Removed
- Monster Trash portal.
- Entitlements the unsandboxed app does not use.
- The non-commercial Robinhood76 sound effect.
- Personal strings from CLI help, tests and docs; per-user Xcode state.

## [1.2.0] - 2026-08-28

### Added
- The agent-facing `portal` CLI (`list`, `show`, `add`, `set`, `rm`), embedded in
  the app bundle and linked to `~/.local/bin/portal` when that name is free.
- `portals.json` in `~/Library/Application Support/Wormhole` as the portal store,
  watched for external edits.

### Changed
- Orbiting portal icons are opaque over a whitish fog.

## [1.1.0] - 2026-07-07

### Added
- User-configurable command portals that run a shell command on the dropped file.
- Monster Trash portal and a redesigned portal UI.
- Local release script (`scripts/release-local.sh`).
- README.

### Changed
- Transparent app icons.

## [1.0.1] - 2025-03-01

### Fixed
- The success screen is no longer skipped when installation completes.
- Open and close sounds no longer play on first open.
- File names are escaped properly.
- An erroneous error display.

## [1.0] - 2025-02-23

Version reset: the pre-1.0 builds below were numbered 1.2 to 1.5.

### Added
- Onboarding opens automatically on first launch.

### Changed
- The keyboard shortcut and menu item toggle the portal window; no double windows.
- New entitlements and project settings.

## Pre-reset builds (2025-02)

### [1.5] - 2025-02-12
- Colors fade instead of hover text; custom purple portal.
- Idle animation lifecycle and portal resetting fixed; spacing on the pending-send view.

### [1.4] - 2025-02-12
- Sound effects; purple portal.

### [1.3] - 2025-02-10
- Onboarding with dependency checking and installation of magic-wormhole.
- Global hotkey; portal opens in the top right; cancel while waiting for a peer.
- Send and receive combined in one portal; `LSUIElement` menu bar app.

### [1.2] - 2025-02-10
- First release: send and receive files with magic-wormhole from a menu bar app.

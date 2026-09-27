# User-Definable Portals — Design

> Historical design note. Superseded in part by [portal-cli-design.md](./portal-cli-design.md)
> (the store moved from UserDefaults to `portals.json`) and by the removal of Monster Trash.

Plan for refactoring the hardcoded three-portal system into a data-driven one where the
shipped app has only the Wormhole portal and users define their own portals in-app.

## Decisions (locked)

1. **Public build ships Wormhole only.** Default portal set = just the magic-wormhole portal.
2. **Custom portals are "command portals," defined as data** — name + SF Symbol + colors +
   a shell command template with `{path}` substituted. No code per portal.
3. **Edited via an in-app settings UI**, persisted (UserDefaults JSON). No hand-edited file.
4. **Monster Trash: kept but dormant.** Code and `MonsterTrashKit` stay in the repo; the
   portal is *not* wired into the new system for now. Nothing deleted. Revisit later.
5. **No personal portals are special-cased in Swift.** Any site-specific workflow (for
   example, a publish script) becomes a command portal the user creates in the editor on
   their own machine. No personal script paths ship in the binary.

## Current state being replaced

Hardcoded in three coupled spots in `wormhole/wormholeApp.swift`:
- `PortalMode` enum (`:173`) — `wormhole` / a hardcoded script portal / `monster`
- Three parallel SwiftUI overlays in `PortalView` (`:1818-1893`)
- Switch dispatch for drop (`:1738`), pending message (`:1903`), success message (`:1992`)
- `sendToScript` (`:731`), `sendToMonsterTrash` (`:791`)
- No persistence; `portalMode` resets to `.wormhole` each launch.

## Target architecture

> Per project CLAUDE.md, all code stays in `wormhole/wormholeApp.swift`.

### Data model

```swift
struct PortalDefinition: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String          // display label
    var symbolName: String    // SF Symbol
    var tintHex: String       // base color (#RRGGBB)
    var glowHex: String       // glow color
    var kind: PortalKind
}

enum PortalKind: Codable, Equatable {
    case wormhole                       // built-in, bespoke (CLI send/receive)
    case monster                        // built-in, dormant (not in default list)
    case command(CommandPortalConfig)   // user-defined
}

struct CommandPortalConfig: Codable, Equatable {
    var commandTemplate: String   // e.g. ~/scripts/publish.sh --push "{path}"
    var runInLoginShell: Bool     // zsh -l
    var workingDirectory: String? // optional cwd
    var pendingVerb: String       // "syncing"   -> "syncing..."
    var successLabel: String      // "added {filename}"
}
```

Template tokens substituted at run time: `{path}` (escaped full path), `{filename}`,
`{dir}`. Wormhole/monster ignore the command config.

### Store

```swift
final class PortalStore: ObservableObject {
    @Published var portals: [PortalDefinition]   // persisted JSON in UserDefaults
    // default when empty: [ .wormholeBuiltin ]
    // wormhole entry is non-deletable; command entries fully editable
}
```

`AppDelegate.portalMode: PortalMode` → replaced by a selected-portal id/index into the store.
The Monster definition exists as a constructible built-in but is **not** added to the default
list.

### Behavior dispatch

`handleDrop` switches on the active portal's `kind`:
- `.wormhole` → existing `send(with:)`
- `.command(cfg)` → new generic `runCommandPortal(cfg, path:)` (parameterized clone of the
  old hardcoded script sender: substitute tokens, run via `/bin/zsh` (`-l` optional), set
  `transferState`, surface `pendingVerb` / `successLabel`, success on exit code 0)
- `.monster` → existing `sendToMonsterTrash` (kept, but unreachable while dormant)

Generic per-portal UI state replaces the per-mode message properties with one
`@Published var portalMessage: String?`.

### UI refactor

`PortalView` stops hardcoding three overlays and **iterates `store.portals`**: active portal
rendered large + centered, inactive ones rendered small in flanks. The flank-offset logic
(currently 2 fixed left/right slots) must generalize to N inactive portals. With the default
single-portal build this is trivial; needs to fan out gracefully as the user adds portals.

### Settings editor (new SwiftUI window)

- Lists portals; add / edit / delete command portals.
- Fields: name, SF Symbol (text field + optional picker), tint color, glow color, command
  template, login-shell toggle, working directory, pending verb, success label.
- Wormhole row is non-deletable and minimally editable (rename/recolor at most).
- Opened from the menu bar menu and/or app Settings.

### Persistence & migration

- Store encodes `[PortalDefinition]` to JSON under a UserDefaults key.
- No real migration needed (no custom portals had shipped yet). Anyone who relied on the old
  hardcoded script portal recreates it via the editor.

## Security note

Command portals execute arbitrary shell with a dropped file path. Acceptable because the user
authors them locally. If portal definitions ever become importable/shareable, treat an
imported command template as untrusted and require explicit review before first run.

## Status: implemented (build succeeds)

All steps below are done in `wormhole/wormholeApp.swift`:
- `PortalDefinition` / `PortalKind` / `CommandPortalConfig` + `Color(hex:)`/`hexString`.
- `AppDelegate` holds `portals` + `selectedPortalID` + `portalMessage`; loads/saves JSON
  under UserDefaults key `portalDefinitions_v1`; default = `[.wormhole]`.
- `runCommandPortal(_:path:)` with `{path}`/`{filename}`/`{dir}` token substitution
  (escaped for double-quote context), optional login shell + working directory.
- `PortalView` iterates `appDelegate.portals` (active centered/large, inactive fan out in a
  centered top row). Drop dispatches on `selectedPortal.kind`.
- `PortalSettingsView` + `PortalEditor` (NavigationSplitView) opened from the menu bar
  "Configure Portals…" item via `showPortalSettings()`. Wormhole row non-deletable.
- Hardcoded script case + its sender + script path removed. Monster Trash
  (`sendToMonsterTrash`, `MonsterTrashKit` import, `monsterMessage`) left intact but dormant.

Note: SourceKit flags the pre-existing regex literals (`/.*%.*/`) and the `MonsterTrashKit`
import as errors in-editor; these are indexer false positives — `xcodebuild` compiles clean.

## Implementation order

1. Data model + `PortalStore` (+ UserDefaults persistence, wormhole default).
2. Generic `runCommandPortal` + unified `portalMessage` state.
3. Refactor `PortalView` to iterate the store (N-portal flank layout).
4. Settings editor window.
5. Remove the hardcoded script case + its sender + path; leave monster code dormant.
6. Build, test, verify wormhole still works and a hand-made command portal runs.

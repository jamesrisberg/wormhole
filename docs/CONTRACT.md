# Wormhole's MacHUD contract

Wormhole implements the MacHUD contract through HUDKit (see HUDKit's README).
MacHUD reads `wormhole.app/Contents/Resources/machud.json` without launching the
app and talks to the running app over a Unix socket. The implementation is
`PortalHUDController` in [`wormhole/PortalHUD.swift`](../wormhole/PortalHUD.swift).

- Manifest: [`wormhole/machud.json`](../wormhole/machud.json): app `JER.wormhole`,
  socket `wormhole`, one panel `portal` (title "Portal", symbol `circle.dotted`,
  default 220x220, compact 72x72, capability `acceptsFileDrop`, verbs `show`,
  `hide`, `toggle`, `frame`, `mode`, `select-set`). No settings schema
  (`settings.json`), so `settings schema` answers unsupported.
- Kind: **windowed**. The portal is an ordinary movable, resizable window that
  keeps its frame between launches; it is not a hover panel and does not slide out
  of the dock (`panel show` ignores `from=`/`anchor=`). The manifest has no `kind`
  field; MacHUD's default applies.
- Modes: `full` is the portal window. `parked` slides it off the nearest screen
  edge (or the `edge=` MacHUD asks for) leaving a 12 pt sliver (or `peek=`).
  `compact` shrinks it to a 72 pt button showing the selected portal, which still
  accepts file drops. `show` on a parked portal restores `full`; `hide` always
  returns to `full` first, so the next show is normal. Only the resting full-mode
  frame is saved.
- Socket: `~/Library/Application Support/MacHUD/sockets/wormhole.sock` (0600), one
  JSON object per line: `{"command": "...", "args": {...}}` in, `{"ok": true, ...}`
  or `{"ok": false, "error": "..."}` out.
- CLI: Wormhole has no socket CLI; drive the socket with `nc -U`. Its `portal`
  CLI edits `portals.json` (portals and sets), not the running app; see the
  README and [portal-cli-design.md](portal-cli-design.md).

```sh
S=~/Library/Application\ Support/MacHUD/sockets/wormhole.sock
echo '{"command":"hello"}' | nc -U "$S"
echo '{"command":"panel","args":{"action":"mode","id":"portal","mode":"parked","edge":"right"}}' | nc -U "$S"
echo '{"command":"action","args":{"name":"send","path":"~/report.pdf"}}' | nc -U "$S"
```

## Verbs

| Command | Args | Result |
|---|---|---|
| `hello` | | `{app, name, hudkit, version, panels, verbs}`: `hudkit` is the contract version, `version` the app's (`MARKETING_VERSION`) |
| `state` | | `{panels: [{id: "portal", visible, mode, badge, status}]}`: `badge` is `"1"` while a transfer is pending or running; `status` is e.g. `idle, set default`, `waiting for peer`, `sending 42%`, `done`, `failed: …` |
| `subscribe` | | acknowledged, then `{"event": "state", ...}` whenever the panel state changes |
| `panel show` / `hide` / `toggle` | `id=portal` | show or hide the portal window; `{visible, mode}` |
| `panel frame` | `id=portal x= y= w= h=` | set the window frame (AppKit screen coordinates, positive size); while parked it becomes the frame to return to |
| `panel mode` | `id=portal mode=full\|compact\|parked`, `edge=` and `peek=` (optional, for `parked`) | see Modes; `{visible, mode}` |
| `settings get` | `key=` (optional) | `{settings: {activeSet, sets, hotkey}}`; `sets` is read-only |
| `settings set` | `activeSet=<set> hotkey=<mods+key>` | validates the hotkey and registers it, then switches the base set; unknown keys are rejected |
| `action select-set` | `set=<name or id>` (or `action select-set name=<set>`) | switch the base set; `{activeSet}` |
| `action send` | `path=<file>` (`~` expanded) | shows the portal and starts a Wormhole send; replies `{code}` once the code is known, `{code: null, status: "pending"}` after 30 s, or an error (`busy`, no such file, send failed) |
| `quit` | | replies, then quits |

## Settings

| Key | Type | Default | Stored as |
|---|---|---|---|
| `activeSet` | set name or id | `default` | UserDefaults `activeSetID` (the set id) |
| `hotkey` | `mods+key`, e.g. `option+control+p` | `option+control+p` | UserDefaults `hotkey`, only once changed |

UserDefaults are the app's (`JER.wormhole`). Portals and sets themselves live in
`~/Library/Application Support/Wormhole/portals.json`, which is the contract for
portal data (format in the README).

## Environment

None. Wormhole reads no `WORMHOLE_*` variables yet: a debug build shares
UserDefaults, `portals.json`, the `wormhole` socket and `~/.local/bin/portal`
with an installed Wormhole. When it is the unit-test host
(`XCTestConfigurationFilePath` set) it skips every launch side effect.

## Launch flags

| Flag | Effect |
|---|---|
| `--show-portal` | open the portal window 0.5 s after launch (used by `scripts/ax-move-test.sh`) |

There is no `--snapshot`.

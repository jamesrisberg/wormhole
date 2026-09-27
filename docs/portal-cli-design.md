# Portal CLI — Design

Plan for an agent-facing `portal` command that creates and manages Wormhole command
portals. The glowing drop target remains the product. After Wormhole is installed
and launched once, an agent can add portals. Civilians never hear about a CLI.

Status: implemented (`PortalCore/`, `portal/`). Kept as the design record.

Related: [user-definable-portals-design.md](./user-definable-portals-design.md)
(command portals as data, in-app editor, UserDefaults store).

## Goal

Download Wormhole, open it once, and an agent (Claude Code, Codex, a human in
Terminal) can add command portals without clicking through Configure Portals.

```bash
portal add --name publish --cmd '~/scripts/publish.sh --push "{path}"'
```

The open portal window picks the change up. If it isn’t open, the new portal is
there next show.

## Locked decisions

1. **No MCP.** The agent API is the file, plus a small `portal` command. MCP can
   wrap that later if a shell-less client ever needs it; it is not v1.
2. **Binary name is `portal`.** Commands are flat: `portal add`, not
   `portal portal add`.
3. **Do not clobber magic-wormhole** (PATH name `wormhole`) **or SpatiumPortae’s
   Homebrew `portal`.** Never install into `/opt/homebrew/bin` or `/usr/local/bin`.
4. **Do not put CLI install in first-launch onboarding.** `SetupWizardView` stays
   Homebrew + magic-wormhole. No wizard copy about the CLI.
5. **Do not edit `.zprofile` / `.zshrc`.**
6. **Do not symlink the GUI executable.** `Contents/MacOS/wormhole` is a SwiftUI +
   Sparkle + AppKit process. `portal list` must not boot it.
7. **`portal select` is not v1.** Selection stays in the window. Do not leak GUI
   focus into a unix command.
8. **The JSON file is the contract.** `portal add` is sugar. An agent writing the
   file with `jq` is a supported way to add a portal.

## Objects

Two programs, one file.

```text
~/Library/Application Support/Wormhole/portals.json     ← contract
Contents/MacOS/wormhole                                 ← GUI, watches the file
Contents/MacOS/portal                                   ← tiny CLI, reads/writes the file
~/.local/bin/portal  →  …/Contents/MacOS/portal         ← silent symlink, if safe
```

The GUI never starts for `portal list`. The CLI never presents a menu bar.

`PortalStore` is the shared type: load, save (atomic temp + rename), migrate,
add/set/rm, ensure builtin. GUI and CLI both use it. Store path is injectable so
tests can use a temp dir.

## File

Path: `~/Library/Application Support/Wormhole/portals.json`

Flat schema — not Swift enum Codable (`kind.command._0`). Agents should be able
to read and write this without knowing the in-memory model.

```json
{
  "version": 1,
  "portals": [
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "name": "wormhole",
      "symbol": "line.3.crossed.swirl.circle.fill",
      "tint": "#763483",
      "glow": "#A850B9"
    },
    {
      "id": "F75709B4-CC5E-4304-A5EF-FFEB0E68FD02",
      "name": "publish",
      "symbol": "photo.circle.fill",
      "tint": "#4682B4",
      "glow": "#64A0D2",
      "command": "~/scripts/publish.sh --push \"{path}\"",
      "loginShell": true,
      "workingDirectory": null,
      "pendingVerb": "syncing",
      "successLabel": "added {filename}"
    }
  ]
}
```

Rules:

- No `command` key ⇒ builtin wormhole portal.
- Builtin is always present. Nothing may delete it or give it a command.
  Appearance (name / symbol / colors) may change.
- Names unique, case-insensitive. Name is the human key; UUID stays internal.
- `version` was `1` here. Version `2` (portal sets) adds `sets: [{id, name, modifier, portals}]`; version 1 files load as one `default` set. See the README. Unknown future versions: CLI errors; GUI does not clobber.
- Atomic write: temp file in the same directory + `rename`. Last writer wins.

### Migration

On GUI launch, if the file is missing, read UserDefaults key
`portalDefinitions_v1` (current in-app store), write the file, then stop using
UserDefaults for portals. If both are missing, default is `[wormhole]`.

The Swift Codable encoding of `PortalKind` stays an implementation detail of
the migrate path. It is not the on-disk format going forward.

## GUI

- Load `PortalStore` in `applicationDidFinishLaunching` (replace
  `loadPortalDefinitions()` / `savePortals()`).
- Settings editor (`PortalSettingsView`) writes the file on change, same as
  today it writes UserDefaults.
- Watch the file (DispatchSource or FSEvents, debounce ~100ms). Reload
  `@Published portals` so flank icons update live when an agent writes.
- If the selected portal id disappears after a reload, fall back to wormhole.
- The selected portal id is remembered across launches in the app's
  UserDefaults (`selectedPortalID`), not in the file. Do not add a `selected`
  field to the file until something needs it.

Onboarding (`SetupWizardView`) is unchanged.

## CLI

Tiny target, installed at `Wormhole.app/Contents/MacOS/portal`. Links the same
`PortalStore` code. Hand-rolled parser — no ArgumentParser package.

```text
portal list [--json]
portal show  <name> [--json]
portal add   --name <name> --cmd <template> [options]
portal set   <name> [options]
portal rm    <name>
portal --help
```

Options for add/set: `--symbol`, `--tint`, `--glow`, `--cmd`,
`--login-shell` / `--no-login-shell`, `--cwd`, `--pending`, `--success`.

Add defaults match `CommandPortalConfig.template` / `newCommandPortal()`:
`circle.fill`, steel-blue tint/glow, login shell on, pending `working`,
success `done`.

I/O:

- stdout = data, stderr = warnings/errors.
- Exit `0` ok, `1` error, `2` usage.
- `--json` on list/show so agents don’t scrape.
- `--cmd` should contain `{path}`; **warn on stderr**, don’t hard-fail.
- Cannot `rm` the builtin. `add` fails if the name exists; `set` / `rm` /
  `show` fail if it doesn’t. No interactive prompts.

Human `list`:

```text
  wormhole
  publish   ~/scripts/publish.sh --push "{path}"
```

`--help` is the agent doc. It must include:

- tokens `{path}`, `{filename}`, `{dir}` and the “put them in double quotes” rule
- a script example (e.g. publish a file with a local script)
- a “copy dropped file into this repo” example
- the fallback full path: `/Applications/wormhole.app/Contents/MacOS/portal`

## Silent PATH install

On GUI launch, after the store is ready:

1. `mkdir -p ~/.local/bin`
2. If `~/.local/bin/portal` is missing, or already a symlink to our CLI, recreate
   it pointing at `Bundle.main`’s `portal` helper (Sparkle updates then just
   work).
3. If `portal` exists there and is **not** us, leave it and log. Do not overwrite
   SpatiumPortae (or anything else).
4. Never install into Homebrew’s prefixes.
5. Never mention this in `SetupWizardView`. Never edit shell rc files.

After that, an agent can:

```bash
portal add --name publish --cmd '~/scripts/publish.sh --push "{path}"'
```

If that session doesn’t have `~/.local/bin` on `PATH`:

```bash
/Applications/wormhole.app/Contents/MacOS/portal add --name publish --cmd '...'
```

or write `portals.json` directly. Same file, same watch.

## Security

Command portals execute arbitrary shell with a dropped file path. Acceptable
because the author is local (the user, or an agent the user is running). CLI and
file writes are local-only.

Do not add import-from-URL or shareable portal packages without an explicit
review step. No approval dialog in v1.

## SpatiumPortae collision

Homebrew formula [`portal`](https://formulae.brew.sh/formula/portal)
(SpatiumPortae/portal) is a magic-wormhole-inspired Go file-transfer CLI
(`portal send` / `portal receive`). ~50 installs/month. Different protocol,
incompatible with magic-wormhole.

Policy: our symlink lives only in `~/.local/bin`. If that path is already some
other `portal`, skip. We do not ship a Homebrew formula named `portal`.

## Out of scope

- MCP
- URL schemes (`wormhole://…`)
- `portal select`
- Editing shell rc
- A Homebrew formula named `portal`
- Per-repo portal files (`--cwd` is enough)
- First-launch CLI copy / “install command line tool” wizard step
- Approval toast for agent-created portals

## Code layout

`CLAUDE.md` currently says all code lives in `wormhole/wormholeApp.swift`. Keep
that for GUI work.

The CLI is a separate program, so it is the justified exception:

| Piece | Where |
|---|---|
| `PortalStore` + file schema | shared — start in `wormholeApp.swift`, extract when the CLI target needs it |
| GUI load / watch / settings save | `wormholeApp.swift` |
| `portal` executable | new target, `Contents/MacOS/portal` |
| Tests | `wormholeTests` (empty today), against an injected temp-dir store |

Tests to have before calling the store done: migrate from a UserDefaults-shaped
fixture, add/list/rm, unique names, cannot rm builtin, JSON round-trip, CLI
usage → exit 2.

## Implementation order

1. **`PortalStore` + schema + UserDefaults migrate + atomic write + tests.**
   Load-bearing. GUI can keep working with no CLI on PATH.
2. **Point the GUI at the store** — load, settings save, file watch, live icon
   update. Onboarding untouched.
3. **Tiny `portal` target** — `--help`, list/add/set/rm/show, `--json`.
4. **Silent symlink** on GUI launch, with the “already someone else’s `portal`”
   guard.

## Rejected alternatives

- **MCP-in-the-app / local HTTP daemon.** App isn’t always running; creating a
  portal is rare CRUD; every agent already has a shell.
- **CLI as argv on the GUI binary.** `portal list` would boot AppKit. Separate
  helper instead.
- **Keep UserDefaults as the store.** Another process writing the plist does not
  reliably update a running app. A file is watchable and agent-readable.
- **Install `portal` during SetupWizardView.** First launch is already brew +
  magic-wormhole. A third step is a developer feature on a civilian path.
  Silent symlink on launch is enough for “out of the box” agent use.
- **`portal` as a Homebrew bin name.** Would fight SpatiumPortae and, if we had
  used `wormhole`, magic-wormhole itself.

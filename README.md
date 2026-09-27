# Wormhole

A native macOS menu bar app with a glowing drop target. Drop a file on the
portal to send it with [Magic Wormhole](https://magic-wormhole.readthedocs.io/en/latest/),
or switch to a **command portal** that runs any shell command on the file.
Portals are plain JSON, and a small `portal` CLI lets you (or an AI agent)
add new ones.

## What it is

Wormhole is a menu bar app (no Dock icon) whose one panel, the portal, is a
**windowed** panel: an ordinary window you move and resize, which remembers its
frame. The large portal in the middle is the active one; the others in the
current set orbit it. On its own it opens from the menu bar or a hotkey; inside
MacHUD it is a dock button that accepts file drops, and MacHUD can park it at a
screen edge or shrink it to a compact button. Part of the MacHUD family; it keeps
its own Xcode project, bundle id (`JER.wormhole`) and Sparkle updates.

## Install

1. Download the latest Wormhole from [viawormhole.xyz](https://viawormhole.xyz)
   (or from this repository's GitHub Releases).
2. Move Wormhole.app to your Applications folder.
3. Launch Wormhole.

On first launch, the setup wizard installs [Homebrew](https://brew.sh) if it is
missing, then uses it to install the `magic-wormhole` CLI. Updates arrive
through Sparkle ("Check for Updates..." in the menu bar menu).

## Use

| Key | Does |
|---|---|
| `⌥⌃P` (Option + Control + P) | open or close the portal window |
| Shift / Option / Control (held) | swap in the set with that modifier (see [Sets](#sets)) |

1. Click the Wormhole icon in the menu bar and choose **Portal**, or press
   `⌥⌃P` (Option + Control + P), to open the portal.
2. The large portal in the middle is the active one. The small portals orbiting
   it are the others in the current set; click one to make it active. Wormhole
   remembers your choice in each set across launches.
3. Drag a file onto the portal. The Wormhole portal shows a code to give to the
   receiver; click it with nothing dropped to enter a code and receive a file
   into `~/Downloads`.

The window can be moved and resized (by dragging, or by window managers
through Accessibility); it keeps its position between launches. Choose
**Configure Portals…** in the menu bar menu to add, edit, or delete portals and
sets in the app. The hotkey can be changed over the control socket
(`settings set hotkey=option+control+p`, see [MacHUD contract](#machud-contract)).
In the MacHUD dock the portal button accepts file drops (`acceptsFileDrop`),
including in its compact form.

## Sets

Portals live in one library. A **set** is an ordered selection of them, and a
portal can be in any number of sets. The portal window shows one set at a
time; the built-in Wormhole portal is in every set (first, unless you move it).

Every library has a `default` set, which starts as all your portals. Give any
other set a **modifier** (Shift, Option or Control): while the portal window
is focused, while you still hold the hotkey that opened it, or while you drag
a file over the portal, holding that modifier swaps the set in. Let go and
the portal returns to the base set. So you might keep day-to-day portals in
`default` and hold Shift for a `publish` set.

In **Configure Portals…**, pick a set at the top of the sidebar. Drag rows to
reorder the set, use the **+** next to a portal under "not in this set" to add
it, and right-click (or use the stack button) to remove it from the set; the
portal stays in the library. The **…** menu creates, renames and deletes sets,
assigns the modifier, and makes a set the base set (**Show This Set**). New
portals join `default` and the set you are editing. Wormhole remembers the
selected portal separately for each set.

## Command portals

A command portal runs a shell command with the dropped file substituted in.
New installs come with two:

| Portal | Command |
|---|---|
| Copy Path | `printf "%s" "{path}" \| pbcopy` |
| Reveal in Finder | `open -R "{path}"` |

Tokens:

| Token | Replaced with |
|---|---|
| `{path}` | full path of the dropped file |
| `{filename}` | last path component (`report.pdf`) |
| `{dir}` | enclosing directory |

Put tokens inside double quotes (`"{path}"`) so paths with spaces work; the
substituted values are escaped for a double-quoted context. Commands run with
`/bin/zsh -c` (`-l` for a login shell when `loginShell` is true, so your
`PATH` from `.zprofile` applies). Exit status 0 shows the success label;
anything else shows an error.

Command portals run arbitrary shell commands as you. Only add commands you
trust.

## portals.json

Portals live in `~/Library/Application Support/Wormhole/portals.json`. The file
is the contract: editing it by hand or with a script is supported, and the open
portal window picks up changes immediately.

```json
{
  "version": 2,
  "portals": [
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "name": "wormhole",
      "symbol": "line.3.crossed.swirl.circle.fill",
      "tint": "#763483",
      "glow": "#A850B9"
    },
    {
      "id": "6E1C1E0A-8A3C-4C43-9D9B-3A0B7E1F2C11",
      "name": "inbox",
      "symbol": "tray.circle.fill",
      "tint": "#4682B4",
      "glow": "#6BA0D0",
      "command": "cp \"{path}\" ~/Inbox/",
      "loginShell": true,
      "workingDirectory": null,
      "pendingVerb": "copying",
      "successLabel": "copied {filename}"
    }
  ],
  "sets": [
    {
      "id": "default",
      "name": "default",
      "modifier": null,
      "portals": [
        "00000000-0000-0000-0000-000000000001",
        "6E1C1E0A-8A3C-4C43-9D9B-3A0B7E1F2C11"
      ]
    },
    {
      "id": "publish",
      "name": "publish",
      "modifier": "shift",
      "portals": ["6E1C1E0A-8A3C-4C43-9D9B-3A0B7E1F2C11"]
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `id` | UUID. The built-in portal is always `00000000-0000-0000-0000-000000000001`. |
| `name` | Unique, case-insensitive. The CLI refers to portals by name. |
| `symbol` | An [SF Symbol](https://developer.apple.com/sf-symbols/) name. |
| `tint`, `glow` | Colors as `#RRGGBB`. |
| `command` | Command template. A record without `command` is the built-in Wormhole portal. |
| `loginShell` | Run with `zsh -l` (default `true`). |
| `workingDirectory` | Optional directory to run in (`~` is expanded). |
| `pendingVerb` | Shown as "\<verb\>..." while the command runs (default `working`). |
| `successLabel` | Shown on success; may contain `{filename}` (default `done`). |

Set fields:

| Field | Meaning |
|---|---|
| `id` | Stable id (`default` for the default set). Kept when a set is renamed. |
| `name` | Unique, case-insensitive. The CLI accepts a set's name or id. |
| `modifier` | `null`, `"shift"`, `"option"` or `"control"`. Each modifier belongs to one set; `default` has none. |
| `portals` | Portal ids in display order. The built-in portal is implied first unless listed. |

The built-in Wormhole portal is always present. You can rename or recolor it,
but not delete it, give it a command, or take it out of a set. Wormhole reads
versions `1` and `2`; a version 1 file (no `sets`) loads as a `default` set in
file order and is written as version 2 the next time anything changes. Wormhole
will not overwrite a file with a newer version it does not understand, or any
file it could not read. Versions of Wormhole before sets cannot read a
version 2 file.

## The `portal` CLI

The app bundles a small CLI at `Wormhole.app/Contents/MacOS/portal`. On launch,
Wormhole links it to `~/.local/bin/portal` if that name is free (it never
overwrites another `portal`, never touches Homebrew's prefixes, and never
edits your shell files). If `~/.local/bin` is not on your `PATH`, use the full
path `/Applications/wormhole.app/Contents/MacOS/portal`.

```text
portal list [--set <set>] [--json]
portal show  <name> [--json]
portal add   --name <name> --cmd <template> [--set <set>] [options]
portal set   <name> [options]
portal rm    <name>

portal sets                                   [--json]
portal set-create <set> [--modifier <mod>]    [--json]
portal set-add    <set> <portal>...           [--json]
portal set-rm     <set> <portal>...           [--json]
portal set-order  <set> <portal>...           [--json]
portal set-edit   <set> [--name <new>] [--modifier <mod>|none] [--json]
portal set-delete <set>
portal --help
```

Options for `add` and `set`: `--symbol <sf-symbol>`, `--tint <#RRGGBB>`,
`--glow <#RRGGBB>`, `--cmd <template>`, `--login-shell` / `--no-login-shell`,
`--cwd <path>` (`--cwd ""` clears it), `--pending <verb>`, `--success <label>`.

Portals and sets are named by name (case-insensitive) or id. `add` puts the
new portal in `default`, and also in `--set` if given. `set-rm` takes a portal
out of a set but keeps it in the library (`rm` deletes it everywhere).
`set-order` replaces the set's members with exactly the portals given, in that
order. `--modifier` is `shift`, `option`, `control` or `none`.

`--json` prints the same records as `portals.json`: `list` the whole file,
`list --set` `{"set": …, "portals": [ … ]}`, `sets` `{"sets": [ … ]}`, and the
set commands the set they changed. Output goes to stdout, warnings and errors
to stderr. Exit codes: `0` success, `1` error, `2` usage.

```bash
portal add --name inbox --cmd 'cp "{path}" ~/Inbox/' --symbol tray.circle.fill \
  --pending copying --success 'copied {filename}'
portal set inbox --tint '#8E44AD'
portal list
portal rm inbox

portal set-create publish --modifier shift
portal set-add publish inbox "Copy Path"
portal set-order publish "Copy Path" inbox wormhole
portal list --set publish
```

## Letting an AI agent add a portal

Any agent with a shell (Claude Code, Codex, and so on) can add portals, since
there is nothing to click through. Tell it what the portal should do, and to
use `portal --help` as the reference. For example: "Add a Wormhole portal named
*upload* that runs `~/scripts/upload.sh "{path}"`." The agent runs:

```bash
portal add --name upload --cmd '~/scripts/upload.sh "{path}"'
```

or edits `portals.json` directly. The new portal appears in the open window
right away. `portal --help` documents the tokens, the quoting rule, and the
file location, so it is enough context for an agent on its own.

## MacHUD contract

Wormhole implements the [MacHUD](https://github.com/jamesrisberg/hudkit) app contract
through HUDKit. Panel `portal`, kind windowed, socket `wormhole`.
`Wormhole.app/Contents/Resources/machud.json` describes it without launching the
app, and while it runs it listens on
`~/Library/Application Support/MacHUD/sockets/wormhole.sock` (mode 0600), one
JSON object per line. Wormhole has no socket CLI (the `portal` CLI edits
`portals.json`), so use `nc -U`:

```bash
S=~/Library/Application\ Support/MacHUD/sockets/wormhole.sock
echo '{"command":"state"}' | nc -U "$S"
echo '{"command":"panel","args":{"action":"mode","id":"portal","mode":"parked"}}' | nc -U "$S"
echo '{"command":"action","args":{"name":"select-set","set":"publish"}}' | nc -U "$S"
```

| Command | Effect |
|---|---|
| `hello` | App id, name, HUDKit version, the `portal` panel |
| `panel show/hide/toggle id=portal` | Show or hide the portal window |
| `panel frame id=portal x= y= w= h=` | Set the window frame (AppKit screen coordinates); Wormhole keeps it |
| `panel mode id=portal parked/compact/full` | `parked` slides the portal off the nearest screen edge (or `edge=`), leaving a sliver; `compact` shrinks it to a 72 pt button showing the selected portal (drop files on it); `full` restores it |
| `state` | `{panels: [{id, visible, mode, badge, status}]}`; `badge` is `"1"` while a transfer is in flight |
| `subscribe` | Keeps the connection open and pushes a `state` event on every change |
| `settings get` / `settings set activeSet=<set> hotkey=<mods+key>` | Base set and global hotkey |
| `action name=select-set set=<set>` | Switch the base set (`action select-set name=<set>` also works) |
| `action name=send path=<file>` | Start a Wormhole send; replies with the code once known |
| `quit` | Quit Wormhole |

Full reference: [docs/CONTRACT.md](docs/CONTRACT.md).

## Settings

| Key | Type | Default | |
|---|---|---|---|
| `activeSet` | set name or id | `default` | the base set the portal window shows |
| `hotkey` | `mods+key` | `option+control+p` | global hotkey that opens the portal |

Set them with `settings set` over the socket (the set also from **Configure
Portals…** > **Show This Set**). They are stored in Wormhole's UserDefaults
(`activeSetID`, `hotkey`); portals and sets are in `portals.json` (above).

## Build from source

Requirements: Xcode 16 or later, macOS 14.6 or later, and HUDKit cloned next to
this repository (`../hudkit`; the project references it as a local package).

```bash
git clone https://github.com/jamesrisberg/hudkit.git
git clone https://github.com/jamesrisberg/wormhole.git
cd wormhole
xcodebuild -project wormhole.xcodeproj -scheme wormhole -configuration Debug -destination 'platform=macOS' build
xcodebuild -project wormhole.xcodeproj -scheme wormhole -destination 'platform=macOS' -only-testing:wormholeTests test
```

Or open `wormhole.xcodeproj` and run the `wormhole` scheme. Swift Package
Manager fetches [Sparkle](https://sparkle-project.org) automatically. There is
no `--snapshot`; `--show-portal` opens the portal at launch for UI checks. The
version is `MARKETING_VERSION`, mirrored in [VERSION](VERSION); changes are in
[CHANGELOG.md](CHANGELOG.md). Releases (signed, notarized, Sparkle appcast):
[docs/RELEASING.md](docs/RELEASING.md).

Layout:

| Path | What |
|---|---|
| `wormhole/` | The app (SwiftUI + AppKit), sounds, assets |
| `PortalCore/` | `PortalStore` and `PortalLibrary` (`portals.json`, sets) and the CLI implementation, shared by the app and CLI |
| `portal/` | The `portal` executable's entry point |
| `wormholeTests/` | Unit tests for the store, sets and CLI |
| `scripts/release-local.sh` | Signed, notarized release build; see [docs/RELEASING.md](docs/RELEASING.md) |

### Contributing

Issues and pull requests are welcome. The project file sets
`DEVELOPMENT_TEAM` to the maintainer's Apple team ID. To build signed on your
machine, pick your own team under Signing & Capabilities (or pass
`DEVELOPMENT_TEAM=<your team id>` to `xcodebuild`), and please leave that
change out of your pull request. Run the unit tests before opening one.

## Isolation env vars for testing

None yet. A debug build shares UserDefaults, `portals.json`, the `wormhole`
socket and the `~/.local/bin/portal` link with an installed Wormhole, so quit
the installed copy (or accept the overlap) when testing a build. Unit tests are
the exception: as a test host the app skips every launch side effect.

## License

MIT; see [LICENSE](LICENSE). The bundled sound effects keep their own
licenses, listed below.

### Attributions

Sound effects from [freesound.org](https://freesound.org):

- BlasterOutgoing6abox.wav by zimbot -- https://freesound.org/s/177023/ -- License: Attribution 4.0
- EerieAmbience03.wav by zimbot -- https://freesound.org/s/122969/ -- License: Attribution 4.0
- Fast Warp In by GammaGool -- https://freesound.org/s/735062/ -- License: Creative Commons 0
- CD_CONTACT_004FX_Space_wind_radiations.wav by kevp888 -- https://freesound.org/s/706811/ -- License: Attribution 4.0
- Retro, Portal Opens Up or Closes.wav by MATRIXXX_ -- https://freesound.org/s/659369/ -- License: Creative Commons 0

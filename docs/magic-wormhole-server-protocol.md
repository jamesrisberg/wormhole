# Magic Wormhole: Handshake Server Protocol & Self-Hosting

Research notes on how the `magic-wormhole` CLI (the tool this app wraps) talks to its
servers, written up so we can decide on standing up our own infrastructure to harden the
app. Based on the actually-installed source: **magic-wormhole 0.23.0** (Homebrew, at
`/opt/homebrew/Cellar/magic-wormhole/0.23.0_2/`).

## TL;DR

- There are **two separate servers**, not one. The "handshake" server (mailbox/rendezvous)
  brokers the short code exchange; a separate "transit relay" carries file bytes as a
  fallback.
- **Neither server can read your files, and neither ever sees the encryption key.** The key
  is derived client-side via SPAKE2 (a PAKE) from the human-readable code. The servers only
  ever see opaque blobs and ciphertext.
- We currently use the **public defaults for both** — run by one person (Brian Warner) on a
  personal server, plaintext `ws://`. That's the dependency we'd be hardening away.
- Self-hosting is two pip-installable Twisted servers + pointing the CLI at them with flags
  we've already stubbed out in code.

## The two servers

| Server | Public default | Role | Sees file? | Sees key? |
|--------|----------------|------|-----------|-----------|
| **Mailbox / Rendezvous** | `ws://relay.magic-wormhole.io:4000/v1` | The "handshake" — brokers the code exchange over WebSocket | No | **No** |
| **Transit relay** | `tcp:transit.magic-wormhole.io:4001` | Fallback bytes-pipe when peers can't connect directly | Yes (ciphertext only) | No |

Both default URLs live in `wormhole/cli/public_relay.py`:

```python
# This is a relay I run on a personal server. If it gets too expensive to
# run, I'll shut it down.
MAILBOX_RELAY = RENDEZVOUS_RELAY = "ws://relay.magic-wormhole.io:4000/v1"
TRANSIT_RELAY = "tcp:transit.magic-wormhole.io:4001"
```

That comment is the core reliability argument for self-hosting: our app's uptime currently
depends on one person's hobby server which they reserve the right to shut down.

## The handshake server (mailbox / rendezvous)

A **WebSocket server** speaking a small JSON protocol. It's a dumb message broker built
around two concepts:

- **Nameplate** — the short number at the front of the code (the `7` in
  `7-guitarist-revenge`). A short, reusable pointer to a mailbox.
- **Mailbox** — a channel where the two sides drop messages for each other.

### Wire protocol (from `wormhole/_rendezvous.py`)

Every message is JSON over WebSocket. Client→server verbs:

1. **`bind`** — on connect, client announces `appid`
   (`lothar.com/wormhole/text-or-file-xfer`) and a random `side` id. The `appid` namespaces
   traffic so unrelated apps don't collide on the same server.
2. **`allocate`** → server replies **`allocated`** with a fresh nameplate (sender gets `7`).
3. **`claim`** (nameplate) → server replies **`claimed`** with the mailbox id. Both sides
   claim the same nameplate — that's the rendezvous.
4. **`open`** (mailbox) — start listening on the channel.
5. **`add`** (phase, body) — drop a message into the mailbox. Server **broadcasts** it to the
   other side and echoes a **`message`** to everyone on the channel.
6. **`release`** / **`close`** — tear down nameplate and mailbox. `close` carries a `mood`
   (happy / scary / errory) used only for the server's own logging/metrics.

Server→client also includes:
- **`welcome`** on connect — can carry an MOTD, a version-nag, or an `error` to refuse service.
- **`error`** — e.g. `CrowdedError` if a third party tries to join a 2-person channel.

### Why the server learns nothing — SPAKE2

The file-transfer key is **never** derived on the server. `wormhole/_key.py` uses
`SPAKE2_Symmetric`, a Password-Authenticated Key Exchange:

- The shared secret is the **full code** (`7-guitarist-revenge`), carried out-of-band by the
  human (you read it to your friend).
- Each side runs SPAKE2 with that code as the password and posts its PAKE message into the
  mailbox (`add` with phase `pake`).
- The server just **relays those two blobs**. From them, each side independently computes the
  same strong session key. The server can't compute it without the password; the nameplate
  (`7`) alone is useless.
- All later phases (`version`, `0`, `1`, ...) are encrypted with NaCl `SecretBox` under that
  key.

So the mailbox server sees only: an appid, two random side-ids, opaque PAKE blobs, and opaque
ciphertext. It **cannot read messages, cannot MITM without knowing the code, and never
touches the file.** A malicious mailbox server's worst case is DoS or a single brute-force
*attempt* against the low-entropy code — which is why the protocol allows only one guess (a
wrong PAKE abandons the channel).

## The transit relay (the other server)

After keys are established, peers exchange IP "hints" and try a **direct TCP connection**. If
NAT/firewalls block that, they fall back to the transit relay — a blind TCP pipe that glues
two connections together by matching a `please relay <token>` handshake
(`wormhole/transit.py`, `build_sided_relay_handshake`). It sees only end-to-end-encrypted
ciphertext, never the key. This is the bandwidth-heavy server.

## Self-hosting

Two separate server packages (both pip-installable, both Twisted-based, same author):

- **`magic-wormhole-mailbox-server`** → the handshake/rendezvous WebSocket server. Very
  lightweight (only brokers tiny messages).
- **`magic-wormhole-transit-relay`** → the transit relay. Bandwidth-heavy.

Point the CLI at them with global options (they go *before* `send`/`receive`):

```bash
wormhole --relay-url=wss://your.host/v1 \
         --transit-helper=tcp:your.host:4001 \
         send "..."
```

Env-var equivalents also exist: `WORMHOLE_RELAY_URL`, `WORMHOLE_TRANSIT_HELPER`.

### Hardening recommendations

1. **Run both servers** on infra we control. The mailbox server is cheap; a small VM is
   plenty. The transit relay needs bandwidth.
2. **Use `wss://` (TLS)** for the mailbox — the public default is plaintext `ws://`. Payloads
   are already encrypted, but TLS protects metadata (appid, timing, IP hints).
3. **Set a custom `appid`** to namespace our traffic separately from the public network.
4. **Wire the flags into the app** (`--relay-url` / `--transit-helper` / `--appid`),
   ideally from settings so we can fall back to the public servers if ours is down.

### Critical caveat: interoperability

Both peers must use the **same** mailbox server to find each other. If our app talks to our
private mailbox, the receiver must *also* run our app (or the CLI pointed at our server). We
cannot interoperate with vanilla `magic-wormhole` users unless we also keep the public
default available. Self-hosting fits when both ends are *our* app; it breaks sending to
arbitrary upstream users.

## Current state in this app

- `wormhole/wormholeApp.swift:534` invokes plain `wormhole send "..."` — no server flags, so
  we use public defaults for both servers today.
- Lines ~541-542 already have a comment noting `--relay-url` and `--transit-helper` exist but
  are unused. Wiring them is the implementation hook.

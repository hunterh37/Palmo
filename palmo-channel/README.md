# Palmo channel

Lets the Palmo app send a chosen reply **into a running Claude Code session** —
no terminal window focusing, no synthetic keystrokes.

```
Palmo  ──HTTP POST──▶  palmo-channel (MCP)  ──channel notification──▶  Claude session
```

## How routing works

Each session launched through the `palmo-claude` wrapper gets a **unique
localhost port** (`PALMO_PORT`):

- the channel server (`index.mjs`) binds that port,
- the Palmo Claude-orb **hook** reads `PALMO_PORT` from its environment and
  writes it into the session's JSON, and
- Palmo reads that port from the session JSON and POSTs the reply to it.

So the reply always lands in the correct session, and sessions **not** launched
through the wrapper simply have no port (Palmo shows "can't send" for those).

## Setup

1. Install deps (the wrapper also does this on first run):
   ```bash
   cd palmo-channel && npm install
   ```
2. Launch Claude through the wrapper instead of `claude`:
   ```bash
   ./palmo-channel/palmo-claude          # or add it to your PATH
   ```
   Optionally alias it:
   ```bash
   alias claude-palmo="$HOME/Dev/HandOrbMenu/palmo-channel/palmo-claude"
   ```

That's it. The wrapper picks a free port, registers the `palmo` channel server
in `~/.claude.json`, and starts Claude with the channel loaded.

## Manual test (no app needed)

With a session running under `palmo-claude`, find its port (printed at launch,
or in `~/Library/Application Support/HandOrbMenu/claude-sessions/<id>.json`) and:

```bash
curl -X POST http://127.0.0.1:<PORT> \
  -H "X-Sender: palmo_app" \
  -H "X-Session: <session-id>" \
  -d "run the auth tests"
```

The text appears in the session as a `<channel>` prompt.

## Research-preview caveats

Channels are a Claude Code **research preview**, so:

- launch uses `--dangerously-load-development-channels server:palmo`;
- the capability key (`claude/channel`) and notification method
  (`notifications/claude/channel`) in `index.mjs` follow the current channels
  reference — if Claude Code reports an unknown method/capability, verify those
  two constants against the docs and update them.

Security: the server binds `127.0.0.1` only and rejects any request without an
allow-listed `X-Sender` header.

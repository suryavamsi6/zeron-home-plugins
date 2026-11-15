# Pi tokens per second

A chip in the composer's toolbar, beside the context ring: how fast pi's model writes in this chat.

`84.2 tok/s` — the rate of the last reply pi finished, from pi's own numbers for it: the output tokens it wrote over the milliseconds it took. Switch to another chat and it shows that chat's last reply.

It isn't a live count. pi records a reply's tokens and duration when the reply is done, so the number changes as each reply lands, not mid-sentence.

## How it reads them

Zeron gives plugins no token events, so the chip reads what pi writes:

| File | What it gives |
| --- | --- |
| `~/.zeron/orgs/*/user_*/journals/<chat>.jsonl` | the session this chat runs in, and its harness |
| `~/.pi/agent/sessions/**/<day>_<session>.jsonl` | each finished reply: `usage.output` and `durationMs` |

The journal's `sessionStarted` names the session; for a pi chat that id finds the second file, and the last reply in it is the number shown. A chat run by another harness has no pi session file, so the chip stays empty there.

It reads again when a turn finishes, and every couple of seconds for a chat switched to. Only the file's end is read: a long chat's session file is megabytes.

## Permissions

- `ui.add` — the chip in the composer's toolbar.
- `sessions.read` — which chat is on screen.
- `commands` — `find`, `tail`, `jq`, to locate and read those two files.

It reads; it never writes.

## Build

`init.luau` is the plugin, `zeron.luau` Zeron's helpers, `zeron-plugin.json` its manifest. Save any file and Zeron re-signs and reloads it. Where plugins can place nodes: `/home/surya/.zeron/docs/plugins.md`.

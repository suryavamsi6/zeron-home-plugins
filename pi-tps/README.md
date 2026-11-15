# Pi tokens per second

A chip in the composer's toolbar, beside the context ring: how fast pi's model is writing in this chat.

It counts up live while pi writes — `~62 tok/s` — and when the reply lands it settles on pi's own figure for it: `58.3 tok/s`, the output tokens pi reported over the milliseconds the reply took. Switch to another chat and it shows that chat's last reply.

## Where the numbers come from

| File | What it gives |
| --- | --- |
| `~/.zeron/orgs/*/user_*/journals/<chat>.jsonl` | every fragment as pi writes it, and the session this chat runs in |
| `~/.pi/agent/sessions/**/<day>_<session>.jsonl` | each finished reply: `usage.output` and `durationMs` |

**Live.** Zeron fills the chat's journal as pi streams: each reasoning and text fragment is one line. The chip reads what the journal gained since the turn began and divides it by the time it took.

Characters are not tokens, so it needs a ratio — and it measures its own rather than assuming one. Every reply ends with a `usage` line carrying the output tokens pi counted for it; the characters read since the last such line, over those tokens, is what the model really writes per token. That ratio carries into the next reply, so it stays right across models.

**Exact.** When the reply finishes, pi's session file has the reply's `usage.output` and `durationMs`. The journal's `sessionStarted` names the session and the harness running it; for a pi chat that id finds the session file, and its last reply is the number the chip settles on. A chat run by another harness has no pi session, so the chip stays empty there.

## Details worth knowing

- Only a fragment's `text` is counted, never the JSON around it. A fragment is ~13 characters of reply inside ~86 bytes of line — counting the line would overstate the rate about five times.
- Only whole lines count. The last line of a read may still be arriving, so it waits for the next one.
- The live figure covers a 3-second window, and only appears once there's 0.7 s of stream to divide by.
- No new text for 1.5 s means the model has stopped writing, so the live figure is withdrawn rather than frozen. It's cleared 6 s after a reply ends if pi's own figure hasn't replaced it.
- `durationMs` runs from the request to the end of the response, so the exact figure includes time to first token. That's why it reads a little under the live one.

## Permissions

- `ui.add` — the chip in the composer's toolbar.
- `sessions.read` — which chat is on screen.
- `commands` — `find`, `tail`, `jq`, to locate and read those two files.

It reads; it never writes.

## Build

`init.luau` is the plugin, `zeron.luau` Zeron's helpers, `zeron-plugin.json` its manifest. Save any file and Zeron re-signs and reloads it. Where plugins can place nodes: `/home/surya/.zeron/docs/plugins.md`.

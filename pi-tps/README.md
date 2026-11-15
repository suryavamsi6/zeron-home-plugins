# Pi tokens per second

A chip in the composer's toolbar, beside the context ring: how fast pi's model is writing in this chat.

It counts up live while pi writes — `~62 tok/s` — and when the reply lands it settles on pi's own figure for it: `58.3 tok/s`, the output tokens pi reported over the milliseconds the reply took. Switch to another chat and it shows that chat's last reply.

## Where the numbers come from

| File | What it gives |
| --- | --- |
| `~/.zeron/orgs/*/user_*/journals/<chat>.jsonl` | every fragment as pi writes it, and the session this chat runs in |
| `~/.pi/agent/sessions/**/<day>_<session>.jsonl` | each finished reply: `usage.output` and `durationMs` |

**Live.** Zeron fills the chat's journal as pi streams: each reasoning and text fragment is one line. The chip reads what the journal gained since it last looked, and divides it by the time it took. The journal only grows while the model writes, so an idle read finds nothing and costs nothing — no turn events to miss, nothing to poll while it's quiet.

Characters are not tokens, so it needs a ratio. It starts at the four pi's own terminal assumes, then measures this chat's own: every reply ends with a `usage` line carrying the tokens pi counted for it, and the characters written since the last such line, over those tokens, is what this chat really writes per token. It takes the median of the last eight — and only once three replies agree, since one reply's ratio is no median.

That measurement matters because pi's output tokens include thinking the journal never records — a reply that reasons hard writes far fewer visible characters than its token count suggests. Left at four, the live figure read up to 50% low on this chat; measured, it settles around 2.2.

**Exact.** When the reply finishes, pi's session file has the reply's `usage.output` and `durationMs`. The journal's `sessionStarted` names the session and the harness running it; for a pi chat that id finds the session file, and its last reply is the number the chip settles on. A chat run by another harness has no pi session, so the chip stays empty there.

## Details worth knowing

- Only a fragment's `text` is counted, never the JSON around it. A fragment is ~13 characters of reply inside ~86 bytes of line — counting the line would overstate the rate about five times.
- Only whole lines count. The last line of a read may still be arriving, so it waits for the next one.
- The live figure covers a 3-second window, and only appears once there's 0.7 s of stream to divide by. A window older than that is a pause, not a slow model, so no figure is shown.
- Reading the journal costs a process, so a chat that has been quiet is read less and less often (at most one tick in sixteen). A turn starting, or text arriving, puts it back to every tick.
- A live figure is marked `~` (an estimate, as a terminal marks one) and withdrawn after 1.5 s without new text rather than frozen at a stale number.
- `durationMs` runs from the request to the end of the response, so the exact figure includes time to first token. That's why it reads a little under the live one.

## Permissions

- `ui.add` — the chip in the composer's toolbar.
- `sessions.read` — which chat is on screen.
- `commands` — `find` and `tail`, to locate and read those two files.

It reads; it never writes.

## Build

`init.luau` is the plugin, `zeron.luau` Zeron's helpers, `zeron-plugin.json` its manifest. Save any file and Zeron re-signs and reloads it. Where plugins can place nodes: `/home/surya/.zeron/docs/plugins.md`.

# Pi tokens per second

A chip in the composer's toolbar, beside the context ring: how fast pi's model is writing in this chat.

While Pi writes, the chip shows an estimate such as `~62 tok/s`. After each assistant response, it shows the reported output tokens divided by the response duration, such as `58.3 tok/s`. Switch chats to see that chat's last completed response.

## Where the numbers come from

| File | What it gives |
| --- | --- |
| `~/.zeron/orgs/*/user_*/journals/<chat>.jsonl` | every fragment as pi writes it, and the session this chat runs in |
| `~/.pi/agent/sessions/**/<day>_<session>.jsonl` | each finished reply: `usage.output` and `durationMs` |

**Live estimate.** The plugin decodes `textDelta` and `reasoningDelta` journal events and counts Unicode characters, not JSON escapes or UTF-8 bytes. Character growth over the sampling window is divided by the estimated characters per output token.

The ratio starts at 4. Each complete response contributes its characters divided by its reported output tokens, provided it contains more than 200 characters and 60 output tokens. After three qualifying responses, the plugin uses the median of the last eight ratios, bounded to 1.5–8. Responses only partly observed after attaching or skipping an oversized read do not calibrate the ratio. Multiple response boundaries in one read are handled separately.

This remains approximate. Hidden reasoning and tool arguments may contribute output tokens without visible characters. Their proportions, the language, and the model can change between responses. The `~` is never removed from a live estimate.

**Completed response.** The last assistant message in Pi's session file provides `usage.output` and `durationMs`. The calculation is `usage.output / (durationMs / 1000)`. Reasoning tokens are already included in `output`, so they are not added again. This is per assistant response, not an average across a tool-using turn.

The journal's `sessionStarted` event identifies the harness and Pi session file. Chats using another harness have no Pi rate.

## Details worth knowing

- Only decoded text and reasoning fragments count. Tool results, user messages, and JSON metadata do not.
- Only complete JSONL records are consumed. An unfinished last record is retried on the next read.
- The live window covers up to 3 seconds and needs at least 0.7 seconds between samples. Each usage event clears the previous response's samples.
- Journal reads run every 300 ms while active, backing off to one read every 17 ticks when quiet. Starting a turn wakes the sampler. Completed-rate reads run every 2 seconds.
- Live estimates expire after 1.5 seconds without new text. Polling an older completed response does not overwrite a live estimate.
- `durationMs` includes time to first token. The completed rate is therefore an end-to-end response rate, not decode-only throughput.
- Async reads from a chat switched away from cannot update the new chat's state.

## Permissions

- `ui.add` — the chip in the composer's toolbar.
- `sessions.read` — which chat is on screen.
- `commands` — `find`, `jq`, and `tail`, to locate and read those two files.

It reads; it never writes.

## Build

`init.luau` is the plugin, `zeron.luau` Zeron's helpers, `zeron-plugin.json` its manifest. Save files in the installed plugin folder and Zeron re-signs and reloads them. Plugin authoring documentation is at `/home/surya/.zeron/docs/plugins.md`.

## Tests

Run the production rate logic with mocked Zeron I/O in the official Luau CLI. Python 3 supplies decoded JSON fixtures; the plugin has no new runtime dependencies.

```sh
python3 pi-tps/tests/test_rates.py /path/to/luau
```

The regressions cover calibration, escaped and Unicode text, response boundaries, partial reads, stale callbacks, completed-rate arithmetic, and live estimate expiry.

#!/usr/bin/env python3
"""Run production rate logic in Luau with mocked Zeron I/O.

Usage: python3 pi-tps/tests/test_rates.py /path/to/luau
No runtime dependency is added to the plugin. JSON fixtures are decoded by
Python, then supplied at the ui.json.decode boundary used by the host.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def lua(value):
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "{" + ",".join(map(lua, value)) + "}"
    return "{" + ",".join(f"[{lua(k)}]={lua(v)}" for k, v in value.items()) + "}"


fixtures = {}


def record(value):
    line = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    fixtures[line] = value
    return line + "\n"


def delta(text, kind="textDelta"):
    return record({"seq": 1, "event": {"type": kind, "text": text}})


def usage(tokens):
    return record({"event": {"type": "usage", "outputTokens": tokens}})


escaped = delta('a\n"\\é🙂', "reasoningDelta")
unrelated = record({"event": {"type": "toolResult", "text": "ignored", "outputTokens": 999}})
response = record({"type": "message", "id": "r1", "message": {
    "role": "assistant", "usage": {"output": 120, "reasoning": 80}, "durationMs": 2000}})
user = record({"type": "message", "message": {
    "role": "user", "usage": {"output": 999}, "durationMs": 1}})
invalid_duration = record({"type": "message", "message": {
    "role": "assistant", "usage": {"output": 120}, "durationMs": 0}})
start = usage(0)
a = delta("a" * 400)
b = delta("b" * 600)
c = delta("c" * 800)
trail = delta("tail")
complete = usage(200)
lookup = "pi session-id\n"

prelude = """
local now = 0
local pending = {}
local fixtures = FIXTURES
local ui = {
    now = function() return now end,
    json = { decode = function(line)
        local value = fixtures[line]
        if value == nil then error("invalid fixture JSON") end
        return value
    end },
}
local mock = {
    place = function(_) end,
    run = function(command, args)
        return { after = function(_, success, failure)
            table.insert(pending, { command = command, args = args, success = success, failure = failure })
        end }
    end,
}
local function settle(body, status)
    local p = table.remove(pending, 1)
    assert(p ~= nil, "no command pending")
    p.success({ status = status or 0, stdout = body })
    return p
end
local function fail()
    local p = table.remove(pending, 1)
    assert(p ~= nil)
    p.failure()
end
""".replace("FIXTURES", lua(fixtures))

checks = r'''
local total = 0
local function test(name, fn)
    pending = {}
    reset("test")
    now = 0
    fn()
    assert(#pending == 0, "unsettled commands in " .. name)
    total += 1
    print("PASS " .. name)
end
local function journal(body, at)
    now = at or now
    W.journal, W.off = "journal", W.off or 1
    W.idle = 0
    sample_live()
    settle(body)
end

test("learned calibration is used", function()
    W.ratio = 2
    W.samples = {{ t = 0, u = 0 }, { t = 1000, u = 400 }}
    assert(live_rate(1000) == 200, `calibrated rate: expected 200 tok/s, got {tostring(live_rate(1000))}`)
end)

test("decoded Unicode, escaping, unrelated and partial records", function()
    local input = ESCAPED .. UNRELATED .. "not-json\n" .. "partial"
    local events, used = count(input)
    assert(#events == 1 and events[1].units == 6)
    assert(used == #input - #"partial")
    local empty, zero = count("partial")
    assert(#empty == 0 and zero == 0)
end)

test("ordered usage boundaries calibrate separate replies", function()
    journal(START .. A .. COMPLETE .. B .. COMPLETE .. C .. COMPLETE .. TRAIL)
    assert(#W.ratios == 3)
    assert(W.ratios[1] == 2 and W.ratios[2] == 3 and W.ratios[3] == 4)
    assert(W.ratio == 3 and W.round == 4 and W.units == 4)
end)

test("partial first response never calibrates", function()
    journal(A .. COMPLETE)
    assert(#W.ratios == 0 and W.complete and W.round == 0)
    journal(A .. COMPLETE)
    assert(#W.ratios == 1 and W.ratios[1] == 2)
end)

test("zero output closes and clears the response", function()
    W.complete = true
    journal(A .. START .. B)
    assert(#W.ratios == 0 and W.round == 600 and W.units == 600)
end)

test("old exact poll preserves live and reasoning is not added twice", function()
    W.file, W.live, W.liveAt = "session", 200, 10
    read_rate()
    settle(RESPONSE .. USER .. INVALID_DURATION)
    assert(W.rate == 60 and W.live == 200)
    read_rate()
    settle(RESPONSE)
    assert(W.live == 200)
end)

test("live sample, completion, and next reply stay separate", function()
    W.complete = true
    journal(A, 0)
    journal(A, 1000)
    assert(W.live == 100)
    journal(COMPLETE .. TRAIL, 1100)
    assert(W.live == nil and W.round == 4 and #W.samples == 1)
    journal(A, 2100)
    assert(W.live == 100)
end)

test("stale estimate expires", function()
    W.live, W.liveAt = 100, 0
    now = 1501
    sample_live()
    assert(W.live == nil)
end)

test("late exact and live callbacks cannot alter next chat", function()
    W.file, W.journal, W.off = "A", "A", 1
    read_rate()
    sample_live()
    reset("B")
    W.file, W.journal, W.off = "B", "B", 42
    read_rate()
    sample_live()
    settle(RESPONSE)
    settle(A .. COMPLETE)
    assert(W.rate == nil and W.round == 0 and W.off == 42)
    assert(W.busy.rate and W.busy.live)
    fail()
    fail()
    assert(not W.busy.rate and not W.busy.live)
end)

test("discovery publishes journal only after offset, rejects old callbacks", function()
    find_session("A")
    settle("A-journal\n")
    assert(pending[1].command == "jq")
    assert(pending[1].args[2] == [[select(.event.type == "sessionStarted") | "\(.event.harness) \(.event.sessionId)"]])
    settle(LOOKUP)
    settle("A-session\n")
    assert(W.journal == nil)
    reset("B")
    find_session("B")
    settle("123")
    assert(W.journal == nil and W.busy.journal)
    settle("B-journal\n")
    settle(LOOKUP)
    settle("B-session\n")
    assert(W.journal == nil)
    settle("456")
    assert(W.journal == "B-journal" and W.off == 457)
    settle(RESPONSE)
    assert(W.rate == 60)
end)

test("late nested discovery and failure release only original locks", function()
    find_session("A")
    settle("A-journal\n")
    reset("B")
    find_session("B")
    settle(LOOKUP)
    assert(#pending == 1 and W.busy.journal)
    fail()
    assert(not W.busy.journal)
end)

test("oversized reads invalidate incomplete calibration", function()
    W.complete, W.round, W.live = true, 400, 100
    journal(string.rep("x", MAX_READ + 1))
    assert(not W.complete and W.round == 0 and W.live == nil)
    journal(A .. COMPLETE)
    assert(#W.ratios == 0)
    journal(A .. COMPLETE)
    assert(#W.ratios == 1)
end)

test("ratio uses bounded rolling median", function()
    W.complete = true
    for i = 1, 12 do
        W.round = 1000
        finish_response(100)
    end
    assert(#W.ratios == RATIO_SPAN and W.ratio == MAX_RATIO)
    W.ratios = {}
    for i = 1, 3 do
        W.round = 300
        finish_response(1000)
    end
    assert(W.ratio == MIN_RATIO)
end)

print(`{total} regression tests passed`)
'''
for key, value in {"ESCAPED": escaped, "UNRELATED": unrelated, "RESPONSE": response,
                   "USER": user, "INVALID_DURATION": invalid_duration, "START": start,
                   "COMPLETE": complete, "TRAIL": trail, "LOOKUP": lookup,
                   "A": a, "B": b, "C": c}.items():
    prelude += f"\nlocal {key} = {lua(value)}\n"

source = (Path(__file__).resolve().parents[1] / "init.luau").read_text()
source = source.replace('local zeron = require("./zeron")("pi-tps")', 'local zeron = mock', 1)
with tempfile.TemporaryDirectory(prefix="pi-tps-tests-") as directory:
    script = Path(directory) / "rates.luau"
    script.write_text(prelude + source + "\n" + checks)
    result = subprocess.run([sys.argv[1] if len(sys.argv) > 1 else "luau", str(script)])
    sys.exit(result.returncode)

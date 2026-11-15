-- Pi tokens per second: how fast pi's model is writing, in this chat.
--
-- One chip in the composer's toolbar, beside the context ring. While pi
-- writes it counts up live ("~62 tok/s"); once the reply is done it shows
-- pi's own figure for it ("58.3 tok/s"): the output tokens pi reported over
-- the milliseconds it took.
--
-- Live, from the chat's journal
--   ~/.zeron/orgs/*/user_*/journals/<chat>.jsonl
-- which Zeron fills as pi streams — every reasoning and text fragment is a
-- line there. The chip reads only what was added since the turn began and
-- turns those characters into tokens with a ratio it measures from the
-- journal itself (characters written per token pi reported), so the estimate
-- keeps pace with whichever model is in use.
--
-- Exact, from pi's session file for this chat
--   ~/.pi/agent/sessions/**/<day>_<session>.jsonl
-- where each finished reply is one line with `usage.output` and
-- `durationMs`. The journal's sessionStarted names that session, and the
-- harness running it: another harness has no pi session, so the chip stays
-- empty there.

local zeron = require("./zeron")("pi-tps")

local LIVE_MS = 300 -- how often the journal is looked at while pi writes
local POLL_MS = 2000 -- how often the exact figure is re-read when idle
local WINDOW_MS = 3000 -- the live figure covers this much of the stream
local MIN_SPAN_MS = 700 -- less stream than this and there is no figure yet
local STALE_MS = 1500 -- no new text for this long: the model isn't writing
local CLEAR_MS = 6000 -- a live figure kept this long after its reply ends
local DEFAULT_RATIO = 3.5 -- characters per token, until one is measured

-- What's been learned about the chat on screen, kept outside the build so a
-- rebuild doesn't lose it.
local W = {
	chat = nil :: string?,
	journal = nil :: string?,
	file = nil :: string?,
	rate = nil :: number?, -- pi's own figure for the last finished reply
	live = nil :: number?, -- the estimate while it writes
	liveAt = 0,
	ratio = DEFAULT_RATIO,
	units = 0, -- characters of this turn's reply read so far
	round = 0, -- of those, the ones since the last usage line
	off = nil :: number?, -- the journal's next byte to read
	samples = {} :: { { t: number, u: number } },
	streaming = false,
	gen = 0,
	busy = { journal = false, rate = false, live = false },
	-- Told when the figure changes, so the chip shows it at once. Set by the
	-- place's build.
	bump = nil :: (() -> ())?,
}

local function show()
	if W.bump ~= nil then
		W.bump()
	end
end

local function reset(chat: string?)
	W.chat = chat
	W.journal = nil
	W.file = nil
	W.rate = nil
	W.live = nil
	W.streaming = false
	W.off = nil
	W.units = 0
	W.round = 0
	W.samples = {}
	show()
end

local function trim(s: string): string?
	local t = string.gsub(string.gsub(s, "^%s+", ""), "%s+$", "")
	return if t == "" then nil else t
end

-- The rate of pi's last finished reply. Reads only the file's end: a long
-- chat's session file is megabytes.
local function read_rate()
	if W.busy.rate or W.file == nil then
		return
	end
	W.busy.rate = true
	local filter = '[inputs | fromjson? | select(.type == "message" and .message.role == "assistant") | {o: (.message.usage.output // 0), d: (.message.durationMs // 0)} | select(.o > 0 and .d > 0)] | last'
	zeron.run("tail", { "-n", "40", W.file }):after(function(t: any)
		zeron.run("jq", { "-R", "-n", filter }, { stdin = tostring(t.stdout) }):after(function(j: any)
			W.busy.rate = false
			if j.status ~= 0 then
				return
			end
			local ok, v = pcall(ui.json.decode, tostring(j.stdout))
			if not ok or type(v) ~= "table" or type(v.o) ~= "number" or type(v.d) ~= "number" then
				return
			end
			W.rate = v.o / (v.d / 1000)
			-- pi's own figure for this reply replaces the estimate.
			W.live = nil
			show()
		end, function()
			W.busy.rate = false
		end)
	end, function()
		W.busy.rate = false
	end)
end

-- Declared here so the session lookup below can start a watch that was
-- waiting on it.
local begin_live: () -> ()

-- This chat's journal, then the pi session it names (and whether it's pi's
local function find_session(chat: string)
	if W.busy.journal then
		return
	end
	W.busy.journal = true
	zeron.run("find", { ".zeron/orgs", "-name", `{chat}.jsonl`, "-print", "-quit" }):after(function(r: any)
		local path = if r.status == 0 then trim(tostring(r.stdout)) else nil
		if path == nil then
			W.busy.journal = false
			return
		end
		zeron.run("jq", { "-r", 'select(.event.type == "sessionStarted") | "\\(.event.harness) \\(.event.sessionId)"', path }):after(function(h: any)
			local harness, sid = nil, nil
			for line in string.gmatch(tostring(h.stdout), "[^\n]+") do
				harness, sid = string.match(line, "^(%S+) (%S+)$")
			end
			if harness ~= "pi" or sid == nil then
				W.busy.journal = false
				return
			end
			zeron.run("find", { ".pi/agent/sessions", "-name", `*{sid}.jsonl`, "-print", "-quit" }):after(function(f: any)
				W.busy.journal = false
				W.journal = path
				W.file = if f.status == 0 then trim(tostring(f.stdout)) else nil
				-- A turn may have begun while this was being looked up; the
				-- watch can start now.
				if W.streaming and W.off == nil then
					begin_live()
				end
			end, function()
				W.busy.journal = false
			end)
		end, function()
			W.busy.journal = false
		end)
	end, function()
		W.busy.journal = false
	end)
end

-- How much new reply a chunk of the journal holds, in characters of the
-- reply itself, and a fresh reading of characters per token when the
-- chunk carries a reply's usage.
--
-- Only a fragment's `text` counts, never its JSON: a fragment is ~13
-- characters of reply inside ~86 bytes of line, and counting the line
-- would overstate the rate about five times over.
-- Only whole lines count: the last one may still be arriving.
local function count(chunk: string): (number, number?, number)
	local units = 0
	local sample = nil
	local start = 1
	while true do
		local nl = string.find(chunk, "\n", start, true)
		if nl == nil then
			break
		end
		local line = string.sub(chunk, start, nl - 1)
		start = nl + 1
		-- A reasoning or text fragment, as written.
		if string.find(line, 'Delta"', 1, true) ~= nil then
			local text = string.match(line, '^.*"text":"(.*)"}}$')
			if text ~= nil then
				units += string.len(text)
			end
		else
			local out = tonumber(string.match(line, '"outputTokens":%s*(%d+)'))
			if out ~= nil then
				-- Measured against what pi reported for the same reply.
				if W.round > 200 and out > 60 then
					sample = W.round / out
				end
				W.round = 0
			end
		end
	end
	return units, sample, start - 1
end

-- The live figure: characters read over the last few seconds, as tokens.
local function live_rate(now: number): number?
	local first = W.samples[1]
	local last = W.samples[#W.samples]
	if first == nil or last == nil or first == last then
		return nil
	end
	local span = last.t - first.t
	if span < MIN_SPAN_MS then
		return nil
	end
	local grew = last.u - first.u
	if grew <= 0 then
		return nil
	end
	local rate = (grew / (span / 1000)) / W.ratio
	if rate <= 0 or rate > 2000 then
		return nil
	end
	return rate
end

-- A turn began: watch the journal from where it stands now.
function begin_live()
	W.gen += 1
	W.streaming = true
	W.units = 0
	W.round = 0
	W.samples = {}
	W.off = nil
	if W.journal == nil then
		return
	end
	-- `find` reports the file's size; the watch starts past what's there.
	zeron.run("find", { W.journal, "-printf", "%s" }):after(function(r: any)
		local size = tonumber(string.match(tostring(r.stdout), "^%s*(%d+)"))
		if size ~= nil and W.streaming then
			W.off = size + 1
		end
	end)
end

-- Reads what the journal gained since last time.
local function sample_live()
	if W.busy.live or W.journal == nil or W.off == nil then
		return
	end
	W.busy.live = true
	zeron.run("tail", { "-c", `+{W.off}`, W.journal }):after(function(t: any)
		W.busy.live = false
		if t.status ~= 0 then
			return
		end
		local units, sample, used = count(tostring(t.stdout))
		W.off += used
		W.units += units
		W.round += units
		if sample ~= nil then
			W.ratio = math.clamp(sample, 2, 8)
		end
		if units == 0 then
			return
		end
		local now = ui.now()
		table.insert(W.samples, { t = now, u = W.units })
		while #W.samples > 2 and W.samples[2].t <= now - WINDOW_MS do
			table.remove(W.samples, 1)
		end
		local rate = live_rate(now)
		if rate ~= nil then
			W.live = rate
			W.liveAt = now
			show()
		end
	end, function()
		W.busy.live = false
	end)
end

-- It ended. The estimate stays a moment, until pi's own figure for the
-- reply lands.
local function end_live()
	W.streaming = false
	W.off = nil
	local gen = W.gen
	ui.after(CLEAR_MS, function()
		if W.gen == gen and not W.streaming and W.live ~= nil then
			W.live = nil
			show()
		end
	end)
end

zeron.place {
	at = "hook:chat.composer.toolbar.end",
	before = function(): Node
		local route = zeron.live("route")
		local tick = ui.use_state(0 :: number)
		local chat = ui.computed(function(): string?
			local r = route()
			if r == nil or r.name ~= "session" then
				return nil
			end
			return r.session
		end)

		local function refresh()
			local id = chat:get()
			if id == nil then
				if W.chat ~= nil then
					reset(nil)
				end
				return
			end
			if W.chat ~= id then
				reset(id)
			end
			if W.file == nil then
				find_session(id)
				return
			end
			read_rate()
		end

		W.bump = function()
			tick:set(tick:peek() + 1)
		end

		-- A turn beginning is the moment there's something to watch, and its
		-- end the moment pi's own figure can be read.
		zeron.on("turn.started", function()
			refresh()
			begin_live()
		end)
		zeron.on("turn.finished", function()
			end_live()
			refresh()
		end)
		zeron.on("turn.errored", function()
			end_live()
			refresh()
		end)

		-- While a turn runs: the journal, often. Otherwise: the exact figure
		-- now and then, for a chat switched to or a reply already on disk.
		ui.every(LIVE_MS, function()
			if not W.streaming then
				return
			end
			if W.live ~= nil and ui.now() - W.liveAt > STALE_MS then
				W.live = nil
				show()
			end
			sample_live()
		end)
		ui.every(POLL_MS, refresh)

		local label = ui.computed(function(): string
			tick:get()
			if W.live ~= nil then
				return `~{math.floor(W.live + 0.5)} tok/s`
			end
			if W.rate == nil then
				return ""
			end
			return `{string.format("%.1f", W.rate)} tok/s`
		end)

		return ui.text {
			label,
			-- Its space is kept with no answer yet, so the toolbar doesn't
			-- shift as the first reply lands.
			hidden = function(): boolean
				return label:get() == ""
			end,
			text_size = "$font.size.xs",
			color = "$text.tertiary",
		}
	end,
}

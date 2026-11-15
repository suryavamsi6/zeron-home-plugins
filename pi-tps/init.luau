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
-- line there. The chip reads only what was added since it last looked and
-- turns those characters into tokens the way pi's own terminal does (four
-- characters to a token), so the two figures agree while it writes.
--
-- Exact, from pi's session file for this chat
--   ~/.pi/agent/sessions/**/<day>_<session>.jsonl
-- where each finished reply is one line with `usage.output` and
-- `durationMs`. The journal's sessionStarted names that session, and the
-- harness running it: another harness has no pi session, so the chip stays
-- empty there.

local zeron = require("./zeron")("pi-tps")

local LIVE_MS = 300 -- how often the journal is read
local POLL_MS = 2000 -- how often the exact figure is re-read
local WINDOW_MS = 3000 -- the live figure covers this much of the stream
local MIN_SPAN_MS = 700 -- less stream than this and there is no figure yet
local STALE_MS = 1500 -- no new text for this long: the model isn't writing
local CHARS_PER_TOKEN = 4 -- characters per token, until this chat shows better
local RATIO_SPAN = 8 -- replies to measure it over
local MIN_RATIO = 1.5 -- a reply this thin says nothing about the next one
local MAX_RATIO = 8
local MIN_SAMPLES = 3 -- replies to see before the default is set aside
local MAX_READ = 200000 -- a bigger jump than this is a new turn, not a burst
local MAX_IDLE = 16 -- a quiet chat is read 1 tick in this many, at most

-- What's been learned about the chat on screen, kept outside the build so a
-- rebuild doesn't lose it.
local W = {
	chat = nil :: string?,
	journal = nil :: string?,
	file = nil :: string?,
	rate = nil :: number?, -- pi's own figure for the last finished reply
	live = nil :: number?, -- the estimate while it writes
	liveAt = 0,
	units = 0, -- characters of the reply read so far this turn
	off = nil :: number?, -- the journal's next byte to read
	samples = {} :: { { t: number, u: number } },
	ticks = 0, -- ticks seen, to read a quiet journal less often
	idle = 0, -- how many reads in a row found nothing
	-- Characters written per token pi reported, one per finished reply, and
	-- their median: what this chat's own replies actually run at.
	ratios = {} :: { number },
	ratio = CHARS_PER_TOKEN,
	-- Characters written since the last usage line, for the next reading.
	round = 0,
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

local function trim(s: string): string?
	local t = string.gsub(string.gsub(s, "^%s+", ""), "%s+$", "")
	return if t == "" then nil else t
end

local function reset(chat: string?)
	W.chat = chat
	W.journal = nil
	W.file = nil
	W.rate = nil
	W.live = nil
	W.off = nil
	W.units = 0
	W.samples = {}
	W.idle = 0
	W.ratios = {}
	W.ratio = CHARS_PER_TOKEN
	W.round = 0
	show()
end

-- The rate of pi's last finished reply. Reads only the file's end: a long
-- session's file is read from its tail, never whole. The lines are parsed
-- here rather than piped through jq: a few hundred KB down a pipe is a lot
-- to hand a promise, and one that stalls would keep the figure stale for
-- good.
local function read_rate()
	if W.busy.rate or W.file == nil then
		return
	end
	W.busy.rate = true
	-- The last reply can sit well back from the end once tool results have
	-- been written after it, so read a generous tail: it is still small.
	zeron.run("tail", { "-n", "400", W.file }):after(function(t: any)
		W.busy.rate = false
		if t.status ~= 0 then
			return
		end
		-- The last reply pi reported both numbers for.
		local found = nil
		for line in string.gmatch(tostring(t.stdout), "[^\n]+") do
			local out = string.match(line, '"usage":{[^}]-"output":%s*(%d+)')
			local dur = string.match(line, '"durationMs":%s*(%d+)')
			if out ~= nil and dur ~= nil then
				local o, d = tonumber(out), tonumber(dur)
				if o ~= nil and d ~= nil and o > 0 and d > 0 then
					found = o / (d / 1000)
				end
			end
		end
		if found == nil then
			return
		end
		W.rate = found
		-- pi's own figure for this reply replaces the estimate.
		W.live = nil
		show()
	end, function()
		W.busy.rate = false
	end)
end

-- This chat's journal, then the pi session it names (and whether it's pi's).
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
				-- Start reading from where the journal stands: what's there
				-- already is finished business.
				zeron.run("find", { path, "-printf", "%s" }):after(function(s: any)
					local size = tonumber(string.match(tostring(s.stdout), "^%s*(%d+)"))
					if size ~= nil then
						W.off = size + 1
					end
				end)
				read_rate()
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
-- reply itself.
--
-- Only a fragment's `text` counts, never its JSON: a fragment is ~13
-- characters of reply inside ~86 bytes of line, and counting the line would
-- overstate the rate about five times over.
-- Only whole lines count: the last one may still be arriving.
local function count(chunk: string): (number, number, number?)
	local units = 0
	local tokens = nil
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
			-- A reply's own usage: the tokens pi counted for what was just
			-- written, against the characters seen since the last one.
			local out = tonumber(string.match(line, '"outputTokens":%s*(%d+)'))
			if out ~= nil and out > 0 then
				tokens = out
			end
		end
	end
	return units, start - 1, tokens
end

-- The live figure: characters read over the last few seconds, as tokens.
local function live_rate(now: number): number?
	local first = W.samples[1]
	local last = W.samples[#W.samples]
	if first == nil or last == nil or first == last then
		return nil
	end
	local span = last.t - first.t
	-- Samples older than the window are a pause, not a slow model.
	if span < MIN_SPAN_MS or span > WINDOW_MS * 1.5 then
		return nil
	end
	local grew = last.u - first.u
	if grew <= 0 then
		return nil
	end
	local rate = (grew / (span / 1000)) / CHARS_PER_TOKEN
	if rate <= 0 or rate > 2000 then
		return nil
	end
	return rate
end

-- Reads what the journal gained since last time. The journal only grows
-- while the model writes, so an idle read finds nothing — and reading
-- costs a process, so a quiet chat is read less and less often until a
-- turn starts, which is the only thing that can make it worth reading
-- again.
local function sample_live()
	-- A figure that has stopped being fed is withdrawn, whether or not this
	-- tick reads anything.
	if W.live ~= nil and ui.now() - W.liveAt > STALE_MS then
		W.live = nil
		show()
	end
	W.ticks += 1
	if W.ticks % (1 + W.idle) ~= 0 then
		return
	end
	if W.busy.live or W.journal == nil or W.off == nil then
		return
	end
	W.busy.live = true
	zeron.run("tail", { "-c", `+{W.off}`, W.journal }):after(function(t: any)
		W.busy.live = false
		if t.status ~= 0 then
			return
		end
		local body = tostring(t.stdout)
		if #body > MAX_READ then
			-- A new turn's worth, not a burst: start counting from here.
			W.off += #body
			W.units = 0
			W.samples = {}
			return
		end
		local units, used, tokens = count(body)
		W.off += used
		W.round += units
		if tokens ~= nil then
			-- What this reply wrote per token pi counted for it. Thinking the
			-- journal never sees counts toward pi's tokens, so a chat that
			-- thinks hard runs below four; measure rather than assume.
			if W.round > 200 and tokens > 60 then
				-- One reply is one reply: its own ratio is no median. Until a
				-- few agree, four characters a token stands.
				table.insert(W.ratios, W.round / tokens)
				while #W.ratios > RATIO_SPAN do
					table.remove(W.ratios, 1)
				end
				local sorted = {}
				for i, v in ipairs(W.ratios) do
					sorted[i] = v
				end
				table.sort(sorted)
				local mid = math.floor((#sorted + 1) / 2)
				if #sorted >= MIN_SAMPLES then
					local median = if #sorted % 2 == 1 then sorted[mid] else (sorted[mid] + sorted[mid + 1]) / 2
					W.ratio = math.clamp(median, MIN_RATIO, MAX_RATIO)
				end
			end
			W.round = 0
		end
		if units == 0 then
			W.idle = math.min(W.idle + 1, MAX_IDLE)
			return
		end
		W.idle = 0
		W.units += units
		local now = ui.now()
		table.insert(W.samples, { t = now, u = W.units })
		while #W.samples > 1 and W.samples[1].t <= now - WINDOW_MS do
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
			if W.journal == nil then
				find_session(id)
				return
			end
			if W.file == nil then
				return
			end
			read_rate()
		end

		W.bump = function()
			tick:set(tick:peek() + 1)
		end

		-- A reply landing is the moment pi's own figure can be read.
		zeron.on("turn.finished", refresh)
		zeron.on("turn.errored", refresh)
		-- A turn starting is the only thing that can make a quiet journal
		-- worth reading again, so it wakes the sampler up.
		zeron.on("turn.started", function()
			W.idle = 0
		end)

		-- The journal, often while it's growing: this is the live figure and
		-- nothing else.
		ui.every(LIVE_MS, sample_live)
		-- The exact figure now and then, for a chat switched to or a reply
		-- already on disk.
		ui.every(POLL_MS, refresh)

		local label = ui.computed(function(): string
			tick:get()
			-- An estimate is marked as one: `~`, as a terminal does.
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

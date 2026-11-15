-- Pi tokens per second for the chat on screen.
-- Live is an estimate from decoded text and reasoning characters over a
-- rolling window, calibrated against completed responses when possible.
-- It cannot see every generated token, including hidden reasoning and tool
-- arguments. A finished response uses usage.output / (durationMs / 1000),
-- including startup latency. Reasoning tokens are already part of output.

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
local MAX_READ = 200000 -- skip oversized reads without calibrating a partial response
local MAX_IDLE = 16 -- back off to one read every 17 ticks

-- What's been learned about the chat on screen, kept outside the build so a
-- rebuild doesn't lose it.
local W = {
	generation = 0,
	chat = nil :: string?,
	journal = nil :: string?,
	file = nil :: string?,
	rate = nil :: number?, -- pi's own figure for the last finished reply
	live = nil :: number?, -- the estimate while it writes
	liveAt = 0,
	units = 0, -- decoded characters in the current response
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
	complete = false, -- false when we attached or skipped bytes mid-response
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
	W.generation += 1
	W.busy = { journal = false, rate = false, live = false }
	W.chat = chat
	W.journal = nil
	W.file = nil
	W.rate = nil
	W.live = nil
	W.off = nil
	W.liveAt = 0
	W.ticks = 0
	W.units = 0
	W.samples = {}
	W.idle = 0
	W.ratios = {}
	W.ratio = CHARS_PER_TOKEN
	W.round = 0
	W.complete = false
	show()
end

-- Read the last completed assistant response, not user text or tool output.
-- Updating this fallback must not hide a newer response's live estimate.
local function read_rate()
	if W.busy.rate or W.file == nil then
		return
	end
	local generation, busy = W.generation, W.busy
	busy.rate = true
	zeron.run("tail", { "-n", "400", W.file }):after(function(t: any)
		busy.rate = false
		if generation ~= W.generation or t.status ~= 0 then
			return
		end
		local found = nil
		for line in string.gmatch(tostring(t.stdout), "[^\n]+") do
			local ok, entry = pcall(ui.json.decode, line)
			if ok and type(entry) == "table" and entry.type == "message" then
				local message = entry.message
				if type(message) == "table" and message.role == "assistant" and type(message.usage) == "table" then
					local out, duration = message.usage.output, message.durationMs
					if type(out) == "number" and type(duration) == "number" and out > 0 and duration > 0 then
						found = out / (duration / 1000)
					end
				end
			end
		end
		if found ~= nil then
			W.rate = found
			show()
		end
	end, function()
		busy.rate = false
	end)
end

-- Publish the journal only after its starting offset is known. Every async
-- callback belongs to the chat generation that started the lookup.
local function find_session(chat: string)
	if W.busy.journal then
		return
	end
	local generation, busy = W.generation, W.busy
	busy.journal = true
	local function failed()
		busy.journal = false
	end
	zeron.run("find", { ".zeron/orgs", "-name", `{chat}.jsonl`, "-print", "-quit" }):after(function(r: any)
		if generation ~= W.generation then return end
		local path = if r.status == 0 then trim(tostring(r.stdout)) else nil
		if path == nil then failed(); return end
		zeron.run("jq", { "-r", 'select(.event.type == "sessionStarted") | "\\(.event.harness) \\(.event.sessionId)"', path }):after(function(h: any)
			if generation ~= W.generation then return end
			local harness, sid = nil, nil
			for line in string.gmatch(tostring(h.stdout), "[^\n]+") do
				harness, sid = string.match(line, "^(%S+) (%S+)$")
			end
			if h.status ~= 0 or harness ~= "pi" or sid == nil then failed(); return end
			zeron.run("find", { ".pi/agent/sessions", "-name", `*{sid}.jsonl`, "-print", "-quit" }):after(function(f: any)
				if generation ~= W.generation then return end
				local file = if f.status == 0 then trim(tostring(f.stdout)) else nil
				zeron.run("find", { path, "-printf", "%s" }):after(function(s: any)
					failed()
					if generation ~= W.generation or s.status ~= 0 then return end
					local size = tonumber(string.match(tostring(s.stdout), "^%s*(%d+)"))
					if size == nil then return end
					W.journal, W.file, W.off = path, file, size + 1
					W.complete = false
					read_rate()
				end, failed)
			end, failed)
		end, failed)
	end, failed)
end

-- Keep usage boundaries in order, including zero-token completions. Only
-- complete JSONL records are consumed; a partial last record is read again.
local function count(chunk: string): ({ { units: number?, tokens: number? } }, number)
	local events = {}
	local start = 1
	while true do
		local nl = string.find(chunk, "\n", start, true)
		if nl == nil then break end
		local line = string.sub(chunk, start, nl - 1)
		start = nl + 1
		local ok, record = pcall(ui.json.decode, line)
		local event = if ok and type(record) == "table" then record.event else nil
		if type(event) == "table" then
			if (event.type == "textDelta" or event.type == "reasoningDelta") and type(event.text) == "string" then
				table.insert(events, { units = utf8.len(event.text) or #event.text })
			elseif event.type == "usage" and type(event.outputTokens) == "number" and event.outputTokens >= 0 then
				table.insert(events, { tokens = event.outputTokens })
			end
		end
	end
	return events, start - 1
end

local function clear_stream()
	W.round, W.units = 0, 0
	W.samples = {}
	W.live = nil
end

local function finish_response(tokens: number)
	if W.complete and W.round > 200 and tokens > 60 then
		table.insert(W.ratios, W.round / tokens)
		while #W.ratios > RATIO_SPAN do table.remove(W.ratios, 1) end
		if #W.ratios >= MIN_SAMPLES then
			local sorted = table.clone(W.ratios)
			table.sort(sorted)
			local mid = math.floor((#sorted + 1) / 2)
			local median = if #sorted % 2 == 1 then sorted[mid] else (sorted[mid] + sorted[mid + 1]) / 2
			W.ratio = math.clamp(median, MIN_RATIO, MAX_RATIO)
		end
	end
	clear_stream()
	W.complete = true
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
	local rate = (grew / (span / 1000)) / W.ratio
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
	local generation, busy = W.generation, W.busy
	busy.live = true
	zeron.run("tail", { "-c", `+{W.off}`, W.journal }):after(function(t: any)
		busy.live = false
		if generation ~= W.generation or t.status ~= 0 then return end
		local body = tostring(t.stdout)
		if #body > MAX_READ then
			W.off += #body
			clear_stream()
			W.complete = false
			show()
			return
		end
		local events, used = count(body)
		W.off += used
		local units = 0
		for _, event in ipairs(events) do
			if event.tokens ~= nil then
				finish_response(event.tokens)
				units = 0
			elseif event.units ~= nil then
				W.round += event.units
				W.units += event.units
				units += event.units
			end
		end
		if units == 0 then
			W.idle = math.min(W.idle + 1, MAX_IDLE)
			if #events > 0 then show() end
			return
		end
		W.idle = 0
		local now = ui.now()
		table.insert(W.samples, { t = now, u = W.units })
		while #W.samples > 1 and W.samples[1].t <= now - WINDOW_MS do
			table.remove(W.samples, 1)
		end
		W.live = live_rate(now)
		W.liveAt = now
		show()
	end, function()
		busy.live = false
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
			-- A character-based estimate is always marked with `~`.
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

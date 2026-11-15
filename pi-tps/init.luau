-- Pi tokens per second: how fast pi's model writes in this chat.
--
-- One chip in the composer's toolbar, beside the context ring: the rate of
-- the reply pi finished last, e.g. "84.2 tok/s" — its own numbers for that
-- reply, the output tokens it wrote over the milliseconds it took.
--
-- Where it comes from: pi's session file for this chat
--   ~/.pi/agent/sessions/**/<day>_<session>.jsonl
-- Every reply pi finishes is one line there, with `usage.output` and
-- `durationMs`. The chat's journal (~/.zeron/orgs/*/user_*/journals/<chat>.jsonl)
-- names the session it runs in (sessionStarted), which is how that file is
-- found, and the harness that runs it: another harness has no pi session,
-- so the chip stays empty.
--
-- (There is no per-token stream to watch: pi writes a reply's line when the
-- reply is done, so the chip changes with each reply, not mid-sentence.)

local zeron = require("./zeron")("pi-tps")

local POLL_MS = 2000

-- What's been learned about the chat on screen, kept outside the build so a
-- rebuild doesn't lose it.
local W = {
	chat = nil :: string?,
	file = nil :: string?,
	rate = nil :: number?,
	busy = { journal = false, rate = false },
	-- Told when the rate changes, so the chip shows it at once. Set by the
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
	W.file = nil
	W.rate = nil
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
			show()
		end, function()
			W.busy.rate = false
		end)
	end, function()
		W.busy.rate = false
	end)
end

-- This chat's journal, then the pi session it names (and whether it's pi's
-- at all).
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
				W.file = if f.status == 0 then trim(tostring(f.stdout)) else nil
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

		-- A reply landing is the moment there's something new to read; the
		-- slow poll catches a chat switched to, and a rate already on disk.
		zeron.on("turn.finished", refresh)
		zeron.on("turn.errored", refresh)
		ui.every(POLL_MS, refresh)

		local label = ui.computed(function(): string
			tick:get()
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

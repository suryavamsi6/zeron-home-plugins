-- Home greeting: a hello on a new chat, like Claude Code desktop's —
-- "Good evening, Surya" in big type under the composer's place, with
-- the time of day as it changes, in the slot Zeron keeps for it on a
-- new chat's screen (screens/chat/home's "chat.home" slot).

local zeron = require("./zeron")("home-greeting")

local function greet(hour: number): string
	if hour < 5 then
		return "Working late"
	elseif hour < 12 then
		return "Good morning"
	elseif hour < 17 then
		return "Good afternoon"
	else
		return "Good evening"
	end
end

local function first_name(profile: any): string?
	if type(profile) ~= "table" then
		return nil
	end
	local name = profile.name or profile.username
	if type(name) ~= "string" or name == "" then
		return nil
	end
	return (string.match(name, "^%S+"))
end

local function Greeting(): Node
	local profile = zeron.context("profile")
	-- Refresh the line as the hour turns while a new chat sits open.
	local now = ui.use_state(os.time() :: number)
	ui.every(30000, function()
		now:set(os.time())
	end)
	local line = ui.computed(function(): string
		local h = (os.date("*t", now:get()) :: any).hour
		local name = first_name(profile)
		return if name then `{greet(h)}, {name}` else greet(h)
	end)
	return ui.column {
		id = "home-greeting",
		items = "center",
		gap = "$space.1",
		ui.text {
			function(): string
				return line:get()
			end,
			text_size = "$font.size.xxl",
			weight = "$font.weight.semibold",
			color = "$text.primary",
		},
		ui.text {
			"What are we building today?",
			text_size = "$font.size.md",
			color = "$text.tertiary",
		},
	}
end

-- Over the page, a third of the way down — right above where the
-- composer floats on a new chat (the dock's row would lay a sibling
-- beside the box instead). Sessions hide it: the route reads "home"
-- only while the chat hasn't started.
zeron.place {
	at = "#chat-composer-dock",
	before = function(): Node
		local route = zeron.live("route")
		return ui.div {
			absolute = true,
			left = 0,
			right = 0,
			top = "33%",
			items = "center",
			ui.show(function(): boolean
				local r = route()
				return r ~= nil and r.name == "home"
			end, Greeting()),
		}
	end,
}

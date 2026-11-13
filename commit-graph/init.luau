--!strict
-- Commit graph: a year of the working project's commits as a calendar
-- of squares on a new chat (GitHub's own: a week a column, a day a
-- square, its depth the day's count), newest days at the right. The
-- service (service.luau) counts the days on the device the project's
-- folder is on; this only draws what it answers.
--
-- It shows on a new chat only (the `chat.home` slot lives there), in
-- the project the composer has chosen, and is gone once the chat is.
-- Where there's no project to read it hides, and it loads again as the
-- choice changes and half a minute apart. A square under the pointer
-- says the day's count and date.

local zeron = require("./zeron")("commit-graph")
local Tooltip = require("@ds/tooltip")
local ink = require("@ds/visual_ink")

-- A day square, the gap between squares, the weekday gutter's and
-- month row's widths and heights, and the head's.
local SQ, GAP, GUTTER, MONTH_H, HEAD_H = 9, 3, 30, 13, 18
local PITCH = SQ + GAP

-- A day's depth as a colour: nothing faint ink, then the accent at
-- rising depth. (GitHub's ramp on the theme's accent.)
local function level_color(level: number): any
	if level <= 0 then
		return { token = "text.primary", alpha = 0.08 }
	end
	return { token = "accent", alpha = 0.30 + 0.175 * level }
end

-- A count's square: empty, else its quarter of the year's busiest day.
local function level_of(n: number, max: number): number
	if n <= 0 or max <= 0 then
		return 0
	end
	return math.clamp(math.ceil(n / max * 4), 1, 4)
end

-- 10281 -> "10,281"
local function commas(n: number): string
	local s = tostring(n)
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

-- Today at noon (comparing day cells against it).
local function today(): number
	local t = os.date("*t")
	return os.time { year = t.year, month = t.month, day = t.day, hour = 12 } :: number
end

local function strip(): Node
	local show = zeron.setting("show")
	local all = zeron.setting("all_branches")
	local route = zeron.live("route")
	-- What a new chat's composer has picked ({ id, name }, live; the
	-- route's own `project` is only the choice remembered, not a pick
	-- just made).
	local pick = ui.shared("zeron.project", nil :: any)
	local data = ui.use_state({ total = 0, days = {} } :: any)
	local grid_w = ui.use_state(0 :: number)
	local hovered = ui.use_state(nil :: string?)

	-- The project the new chat would work in ("none", none), its folder
	-- the checkout to count.
	local function project(): any
		local p = pick:peek()
		return if p and p.id then zeron.context_of("project", p.id) else nil
	end
	local function load()
		local r = route()
		if r and r.name ~= "home" then
			data:set({ total = 0, days = {} })
			return
		end
		local p = project()
		local cwd = p and (p.path or p.folder)
		if type(cwd) ~= "string" or cwd == "" then
			data:set({ total = 0, days = {} })
			return
		end
		zeron.service(p.device):call(
			"days",
			{ cwd = cwd, all = all:peek() == true },
			{ timeout = 60 }
		):after(function(res: any)
			data:set(if res and res.days then res else { total = 0, days = {} })
		end, function()
			-- No checkout here, the service off or unallowed, the device
			-- away: nothing to show.
			data:set({ total = 0, days = {} })
		end)
	end
	load()
	ui.every(30000, load)
	-- Another project picked in the composer, or the page changed under
	-- it (a chat just sent: its year, not the last's — and the strip
	-- hides).
	local was: any = nil
	ui.effect(function()
		local r = route()
		local p = pick:get()
		local key = `{r and r.name}|{p and p.id}`
		if key ~= was then
			was = key
			load()
		end
	end)
	zeron.on_setting(function(id: string)
		if id == "all_branches" then
			load()
		end
	end)

	-- The weeks that fit, ending in this one's: each its Sunday noon.
	local laid = ui.computed(function()
		local d = data:get()
		local weeks = math.min(53, math.floor(math.max(0, grid_w:get() - GUTTER) / PITCH))
		local max = 0
		for _, n in d.days do
			max = math.max(max, n)
		end
		local t = today()
		local now = os.date("*t", t)
		local sun = t - ((now.wday - 1) * 86400)
		return {
			total = d.total or 0,
			days = d.days,
			max = max,
			weeks = math.max(0, weeks),
			today = t,
			first = sun - math.max(0, weeks - 1) * 7 * 86400,
		}
	end)
	-- A hit square per shown day, for its tooltip.
	local cells = ui.computed(function(): { any }
		local l = laid:get()
		local out = {}
		for c = 0, l.weeks - 1 do
			for r = 0, 6 do
				local t = l.first + (c * 7 + r) * 86400
				if t <= l.today then
					local d = os.date("%Y-%m-%d", t) :: string
					table.insert(out, {
						key = d,
						x = GUTTER + c * PITCH,
						y = MONTH_H + r * PITCH,
						t = t,
						n = l.days[d] or 0,
					})
				end
			end
		end
		return out
	end)

	-- The legend's squares, levels 0 to 4.
	local legend = {}
	for i = 0, 4 do
		table.insert(legend, ui.div { w = SQ, h = SQ, rounded = 2, bg = ink.paint(level_color(i)) })
	end

	return ui.show(function(): boolean
		local r = route()
		return show:get() ~= false and (not r or r.name == "home") and laid:get().total > 0
	end, ui.div {
		id = "commit-graph",
		-- Hung under the composer, not in its column: the footer's glass
		-- tray keeps to the column's foot (a child in it would grow it,
		-- and the tray would sit under this instead).
		absolute = true,
		left = 0,
		right = 0,
		top = "100%",
		h = 8 + HEAD_H + MONTH_H + 7 * PITCH - GAP,
		px = "$space.2",
		pt = "$space.1",
		ui.row {
			w_full = true,
			h = HEAD_H,
			items = "center",
			ui.text {
				function(): string
					return commas(laid:get().total)
				end,
				text_size = "$font.size.sm",
				weight = "$font.weight.semibold",
				color = "$text.primary",
			},
			ui.text {
				" commits in the last year",
				text_size = "$font.size.sm",
				color = "$text.secondary",
			},
			ui.div { grow = 1 },
			ui.text { "Less", text_size = "$font.size.xs", color = "$text.tertiary" },
			ui.row { items = "center", gap = 3, mx = 1, table.unpack(legend) },
			ui.text { "More", text_size = "$font.size.xs", color = "$text.tertiary" },
		},
		ui.div {
			w_full = true,
			h = MONTH_H + 7 * PITCH - GAP,
			relative = true,
			on_resize = function(size: { w: number, h: number })
				if math.abs(grid_w:peek() - size.w) > 0.5 then
					grid_w:set(size.w)
				end
			end,
			ui.canvas {
				w_full = true,
				h_full = true,
				aria_hidden = true,
				draw = function(c: any, w: number, _h: number)
					local l = laid:get()
					if l.weeks < 1 then
						return
					end
					local faint = "$text.tertiary"
					-- The months, over the week each starts in.
					local was_m = nil
					for ci = 0, l.weeks - 1 do
						local m = os.date("%b", l.first + ci * 7 * 86400)
						if m ~= was_m then
							c:text(m, GUTTER + ci * PITCH, 0, { size = 9, color = faint, baseline = "top" })
							was_m = m
						end
					end
					-- Monday, Wednesday, Friday down the gutter.
					for r, name in { [1] = "Mon", [3] = "Wed", [5] = "Fri" } do
						c:text(name, GUTTER - 6, MONTH_H + r * PITCH + SQ / 2, {
							size = 9,
							color = faint,
							align = "end",
							baseline = "middle",
						})
					end
					local hov = hovered:get()
					for ci = 0, l.weeks - 1 do
						local x = GUTTER + ci * PITCH
						for r = 0, 6 do
							local t = l.first + (ci * 7 + r) * 86400
							if t <= l.today then
								local d = os.date("%Y-%m-%d", t)
								local lv = level_of(l.days[d] or 0, l.max)
								local y = MONTH_H + r * PITCH
								if d == hov then
									c:rect(x - 1, y - 1, SQ + 2, SQ + 2, ink.hex({ token = "text.primary", alpha = 0.35 }), 3)
								end
								c:rect(x, y, SQ, SQ, ink.canvas(level_color(lv)), 2)
							end
						end
					end
				end,
			},
			ui.each(cells, function(cell: any): Node
				return ui.div {
					absolute = true,
					left = cell.x,
					top = cell.y,
					w = SQ,
					h = SQ,
					on_hover = function(inside: boolean)
						hovered:set(if inside then cell.key else nil)
					end,
					tooltip = Tooltip { function(): string
						local when = `{os.date("%a, %b", cell.t)} {tonumber(os.date("%d", cell.t))}, {os.date("%Y", cell.t)}`
						return if cell.n > 0 then `{cell.n} commits on {when}` else `No commits on {when}`
					end },
				}
			end, {
				key = function(cell: any): string
					return cell.key
				end,
			}),
		},
	})
end

-- Under the message box, on a new chat only: a sibling of the
-- composer's toolbar (the same composer floats over a new chat's page
-- and a session's; the strip shows itself only where the route says
-- the chat hasn't started).
zeron.place {
	at = "#composer-toolbar",
	after = strip,
}

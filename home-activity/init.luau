-- Recent activity from the signed-in GitHub account and Zeron's chats.
-- The two feeds are independent: a GitHub failure never hides the chats.
local zeron = require("./zeron")("home-activity")
local Icon = require("@ds/icon")
local Button = require("@ds/button")
local locale = require("@ds/locale")

local REFRESH_SECONDS = 300
local LIMIT = 4

-- GitHub's event timestamps are UTC. Luau's os.time reads a table as UTC.
local function event_time(value: any): number?
	if type(value) ~= "string" then return nil end
	local y, mo, d, h, mi, s = string.match(value, "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
	if not y then return nil end
	local ok, t = pcall(os.time, { year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
	return if ok and type(t) == "number" then t else nil
end

local function text_or(value: any, fallback: string): string
	return if type(value) == "string" and value ~= "" then value else fallback
end

local function event_row(e: any): any?
	if type(e) ~= "table" or type(e.repo) ~= "table" then return nil end
	local repo = text_or(e.repo.name, "")
	if not string.match(repo, "^[%w_.%-]+/[%w_.%-]+$") then return nil end
	local payload = if type(e.payload) == "table" then e.payload else {}
	local kind = e.type
	local action = payload.action
	local detail, icon = "GitHub activity", "global"
	if kind == "PushEvent" then
		detail, icon = "Pushed commits", "git-branch"
	elseif kind == "PullRequestEvent" then
		local pr = if type(payload.pull_request) == "table" then payload.pull_request else {}
		local verb = if pr.merged == true then "Merged" elseif action == "opened" then "Opened" elseif action == "closed" then "Closed" elseif action == "reopened" then "Reopened" else "Updated"
		detail, icon = `{verb} pull request`, "pull-request"
	elseif kind == "PullRequestReviewEvent" then
		detail, icon = "Reviewed a pull request", "pull-request"
	elseif kind == "PullRequestReviewCommentEvent" then
		detail, icon = "Commented on a pull request", "pull-request"
	elseif kind == "IssuesEvent" then
		local verb = if action == "opened" then "Opened" elseif action == "closed" then "Closed" elseif action == "reopened" then "Reopened" else "Updated"
		detail, icon = `{verb} an issue`, "list"
	elseif kind == "IssueCommentEvent" then
		detail, icon = "Commented on an issue or pull request", "chat-round-line"
	elseif kind == "ReleaseEvent" then
		detail, icon = "Published a release", "tag"
	elseif kind == "CreateEvent" then
		detail, icon = if payload.ref_type == "repository" then "Created a repository" elseif payload.ref_type == "tag" then "Created a tag" else "Created a branch", "git-branch"
	elseif kind == "DeleteEvent" then
		detail, icon = if payload.ref_type == "tag" then "Deleted a tag" else "Deleted a branch", "git-branch"
	elseif kind == "WatchEvent" then
		detail, icon = "Starred a repository", "star"
	elseif kind == "ForkEvent" then
		detail, icon = "Forked a repository", "git-branch"
	elseif kind == "MemberEvent" then
		detail, icon = "Updated repository access", "access-supervised"
	end
	local item = payload.pull_request or payload.issue or payload.release or payload.comment
	local url = if type(item) == "table" then item.html_url else nil
	if type(url) ~= "string" or not string.match(url, "^https://github%.com/[^%s]+$") then
		url = `https://github.com/{repo}`
	end
	return { id = tostring(e.id or `{kind}:{repo}:{e.created_at}`), title = detail, sub = repo, icon = icon, at = event_time(e.created_at), url = url }
end

local function chat_rows(): { any }
	local projects = zeron.projects()
	local rows = {}
	for id, s in zeron.sessions() do
		if type(s) ~= "table" or s.archived == true then continue end
		local at = s.updated or s.created
		if type(at) ~= "number" then at = 0 end
		local project = if type(s.project) == "string" then projects[s.project] else s.project
		local name = if type(project) == "table" then text_or(project.name, "Zeron") else "Zeron"
		local status = s.status
		local label = if status == "working" or status == "connecting" then "Working" elseif status == "input" or status == "approval" or status == "awaitingInput" then "Needs input" elseif status == "failed" or status == "errored" then "Failed" elseif status == "done" or status == "completed" then "Completed" else "Recent chat"
		table.insert(rows, { id = id, title = text_or(s.title, "Untitled chat"), sub = `{name} · {label}`, icon = "chat-round-line", at = at, session = id })
	end
	table.sort(rows, function(a, b)
		if a.at == b.at then return a.id < b.id end
		return a.at > b.at
	end)
	while #rows > LIMIT do table.remove(rows) end
	return rows
end

local function row(item: any, now: any): Node
	return ui.button {
		w_full = true, min_w = 0, h = 42, px = "$space.2", rounded = "$radius.md",
		items = "center", gap = "$space.2", cursor = "pointer",
		bg = "#00000000", hover = { bg = "$zeron.secondary.bg" },
		on_click = function()
			if item.session then zeron.open({ session = item.session })
			elseif item.url then zeron.open_url(item.url) end
		end,
		ui.div { color = "$text.tertiary", shrink = 0, Icon { name = item.icon, size = 15 } },
		ui.column {
			grow = 1, min_w = 0, gap = 1,
			ui.text { item.title, literal = true, w_full = true, truncate = true, text_size = "$font.size.sm", weight = "$font.weight.medium", color = "$text.primary" },
			ui.text { item.sub, literal = true, w_full = true, truncate = true, text_size = "$font.size.xs", color = "$text.tertiary" },
		},
		ui.text {
			function(): string
				return if type(item.at) == "number" and item.at > 0 then locale.ago_short(math.max(0, now:get() - item.at)) else ""
			end,
			shrink = 0, text_size = "$font.size.xs", color = "$text.tertiary",
		},
	}
end

local function Activity(): Node
	local route = zeron.live("route")
	local github = ui.use_state({} :: { any })
	local state = ui.use_state("loading")
	local now = ui.use_state(os.time())
	local busy, last_attempt = false, 0

	local function fail()
		busy = false
		state:set("error")
	end
	local function load(force: boolean?)
		local r = route()
		if not force and (not r or r.name ~= "home" or not zeron.window(true).shown) then return end
		if busy or (not force and os.time() - last_attempt < REFRESH_SECONDS) then return end
		busy, last_attempt = true, os.time()
		state:set("loading")
		zeron.run("gh", { "api", "user", "--jq", ".login" }, { timeout = 20, env = { GH_PROMPT_DISABLED = "1" } }):after(function(result: any)
			local login = if type(result) == "table" and result.status == 0 and type(result.stdout) == "string" then string.match(result.stdout, "^%s*([%w%-]+)%s*$") else nil
			if not login then fail(); return end
			zeron.run("gh", { "api", `users/{login}/events?per_page=30` }, { timeout = 20, env = { GH_PROMPT_DISABLED = "1" } }):after(function(answer: any)
				if type(answer) ~= "table" or answer.status ~= 0 or type(answer.stdout) ~= "string" then fail(); return end
				local ok, events = pcall(ui.json.decode, answer.stdout)
				if not ok or type(events) ~= "table" then fail(); return end
				local rows = {}
				for _, event in events do
					local entry = event_row(event)
					if entry then table.insert(rows, entry) end
					if #rows >= LIMIT then break end
				end
				github:set(rows)
				busy = false
				state:set("ready")
			end, fail)
		end, fail)
	end

	ui.effect(function()
		local r = route()
		local window = zeron.window()
		if r and r.name == "home" and window.shown then load() end
	end)
	ui.every(60000, function()
		now:set(os.time())
		load()
	end)

	local chats = ui.computed(chat_rows)
	local function empty(text: () -> string): Node
		return ui.text { text, w_full = true, px = "$space.2", py = "$space.2", wrap = true, text_size = "$font.size.xs", color = "$text.tertiary" }
	end
	return ui.show(function(): boolean
		local r = route()
		return r ~= nil and r.name == "home"
	end, ui.div {
		id = "home-activity",
		absolute = true, left = 32, right = 32, top = "50%", mt = 174, bottom = 8,
		items = "center", pointer_events = "none",
		ui.scroll {
			w_full = true, h_full = true, max_w = 680, pointer_events = "auto",
			ui.column {
				w_full = true, gap = "$space.1",
				ui.row {
					w_full = true, h = 24, items = "center", px = "$space.2",
					ui.text { "Recent activity", text_size = "$font.size.sm", weight = "$font.weight.semibold", color = "$text.primary" },
					ui.div { grow = 1 },
					Button { "Refresh", size = "xs", tone = "ghost", on_click = function() load(true) end },
				},
				ui.row {
					w_full = true, items = "start", gap = "$space.3",
					ui.column {
						grow = 1, basis = 0, min_w = 0,
						ui.text { "ZERON", px = "$space.2", py = "$space.1", text_size = "$font.size.xs", weight = "$font.weight.semibold", color = "$text.tertiary" },
						ui.each(chats, function(item: any): Node return row(item, now) end, { key = function(item: any): string return item.id end, w_full = true }),
						ui.show(function(): boolean return #chats:get() == 0 end, empty(function(): string return "No recent chats yet." end)),
					},
					ui.column {
						grow = 1, basis = 0, min_w = 0,
						ui.text { "GITHUB", px = "$space.2", py = "$space.1", text_size = "$font.size.xs", weight = "$font.weight.semibold", color = "$text.tertiary" },
						ui.each(github, function(item: any): Node return row(item, now) end, { key = function(item: any): string return item.id end, w_full = true }),
						ui.show(function(): boolean return state:get() ~= "ready" or #github:get() == 0 end, empty(function(): string
							local s = state:get()
							if s == "loading" then return "Loading GitHub activity…" end
							if s == "error" then return "GitHub unavailable. Check gh sign-in and refresh." end
							return "No recent GitHub activity."
						end)),
					},
				},
			},
		},
	})
end

zeron.place { at = "#chat-composer-dock", before = Activity }

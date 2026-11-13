--!strict
-- Commit graph's service: run by Zeron's engine on each device that has
-- the plugin, with no window open. It is where a session's checkout is
-- (this Mac, or a devbox), and it reads that checkout's commits with the
-- device's own `git` ("commands": ["git"]), for the plugin's windows on
-- this device or another of yours. Reading only; nothing here changes
-- the checkout.
--
-- A failure is `error("<code>: <words>", 0)`: the window just draws
-- nothing where there's no checkout to read.

local zeron = require("./zeron")("commit-graph")

-- Every run: git's words untranslated (they are read), no prompt for a
-- password, and no lock an agent's git could trip over.
local ENV = { LC_ALL = "C", GIT_TERMINAL_PROMPT = "0", GIT_OPTIONAL_LOCKS = "0" }
-- What git prints and the plugin reads: never its colours or a pager,
-- and no filesystem monitor a repository's config names.
local BASE = {
	"-c", "core.quotepath=off", "-c", "color.ui=false", "-c", "core.pager=cat",
	"-c", "core.fsmonitor=false",
}

type Ran = { status: number, stdout: string, stderr: string }

-- `git -C cwd …`, as it ended.
local function run(cwd: string, args: { string }, opts: { stdin: string?, timeout: number? }?): Ran
	local all = table.clone(BASE)
	table.insert(all, 1, cwd)
	table.insert(all, 1, "-C")
	for _, a in args do
		table.insert(all, a)
	end
	local o = opts or {}
	return zeron.run("git", all, { stdin = o.stdin, timeout = o.timeout or 30, env = ENV }):await()
end

local function trim(s: string): string
	return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end

-- git's own words for a failure, on one line.
local function said(r: Ran): string
	local text = if r.stderr ~= "" then r.stderr else r.stdout
	return trim(text) ~= "" and trim(text) or `git stopped ({r.status})`
end

-- git's words as a person reads them: its first line that says something
-- (past "hint:" lines), without "fatal:"/"error:".
local function first_line(words: string): string
	for line in string.gmatch(words .. "\n", "([^\n]*)\n") do
		local l = trim(line)
		if l ~= "" and not string.match(l, "^hint:") then
			l = string.gsub(l, "^fatal:%s*", "")
			l = string.gsub(l, "^error:%s*", "")
			l = string.gsub(l, "^warning:%s*", "")
			return (string.gsub(l, "^%l", string.upper))
		end
	end
	return words
end

-- A failure of git's with the code the window may want: a folder it
-- won't work in, a lock left behind; else `git:` and its own first line.
local function classified(words: string): string
	if string.find(words, "not a git repository", 1, true) then
		return "not_a_repo: " .. first_line(words)
	end
	if string.find(words, "dubious ownership", 1, true) then
		return "unsafe_dir: " .. first_line(words)
	end
	if string.find(words, "index.lock", 1, true) then
		return "locked: " .. first_line(words)
	end
	return "git: " .. first_line(words)
end

-- `git -C cwd …`'s output, or a failure with a code.
local function git(cwd: string, args: { string }, opts: any?): string
	local r = run(cwd, args, opts)
	if r.status == -1 then
		error("timeout: git took too long", 0)
	end
	if r.status ~= 0 then
		error(classified(said(r)), 0)
	end
	return r.stdout
end

-- The folders git may work in: this device's chats' and projects'
-- (`zeron.folders`), asked again when one isn't among those last heard.
local folders: { string } = {}
local function among(cwd: string): boolean
	for _, f in folders do
		local root = if string.sub(f, -1) == "/" then string.sub(f, 1, -2) else f
		if cwd == root or string.sub(cwd, 1, #root + 1) == root .. "/" then
			return true
		end
	end
	return false
end

-- A checkout of this device's: a whole path, plainly written, in a
-- chat's folder or a project's. Never anywhere a caller names.
local function check_cwd(cwd: any): string
	if type(cwd) ~= "string" or cwd == "" or string.sub(cwd, 1, 1) ~= "/" then
		error("no_checkout: This chat has no folder to look in", 0)
	end
	for part in string.gmatch(cwd, "[^/]+") do
		if part == "." or part == ".." then
			error("no_checkout: This chat has no folder to look in", 0)
		end
	end
	cwd = if #cwd > 1 and string.sub(cwd, -1) == "/" then string.sub(cwd, 1, -2) else cwd
	if not among(cwd) then
		folders = zeron.folders():await() or {}
	end
	if not among(cwd) then
		error("not_a_checkout: That folder isn't one of this device's chats or projects", 0)
	end
	return cwd
end

-- -- days ------------------------------------------------------------------

-- A year of days: each local day's commit count (GitHub's calendar
-- squares), over this branch's history — or (`all`) every branch,
-- remote and tag. Days are the checkout's own clock (`format-local`).
local function days(args: any): any
	local cwd = check_cwd(args.cwd)
	local head = run(cwd, { "rev-parse", "-q", "--verify", "HEAD" })
	if head.status ~= 0 then
		return { total = 0, days = {} }
	end
	local cmd = {
		"log",
		`--since={os.date("%Y-%m-%d", os.time() - 372 * 86400)}`,
		"--date=format-local:%Y-%m-%d",
		"--format=%ad",
	}
	if args.all then
		table.insert(cmd, "--all")
	end
	table.insert(cmd, "--")
	local out = git(cwd, cmd, { timeout = 60 })
	local by_day: { [string]: number } = {}
	local total = 0
	for line in string.gmatch(out, "[^\n]+") do
		local d = trim(line)
		if d ~= "" then
			by_day[d] = (by_day[d] or 0) + 1
			total += 1
		end
	end
	return { total = total, days = by_day }
end

-- Reading only, safe to run again.
zeron.serve("days", days, { safe = true })

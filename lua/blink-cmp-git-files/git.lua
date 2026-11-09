--- Asynchronous listing of git-tracked files, cached per working directory.
---
--- The set of tracked files can only change when the git index does, so the
--- cache is validated with a single `fs_stat` on the index and git is spawned
--- only when its mtime has moved.

local M = {}

local NOT_A_REPO_RETRY_NS = 30 * 1e9

local LIST_TRACKED = { "git", "ls-files", "-z", "--cached", "--deduplicate" }
local LIST_DELETED = { "git", "ls-files", "-z", "--deleted" }
local FIND_INDEX = { "git", "rev-parse", "--path-format=absolute", "--git-path", "index" }

--- An immutable snapshot of the tracked files.
--- @class blink-cmp-git-files.Listing
--- @field files string[] Tracked paths relative to the working directory
--- @field lowered string[] Lowercased `files`, at the same indices
--- @field tracked table<string, true> `files` as a lookup table
--- @field raw_tracked string `ls-files --cached` output, used to skip reparsing
--- @field raw_deleted string `ls-files --deleted` output

--- @class blink-cmp-git-files.Entry
--- @field listing? blink-cmp-git-files.Listing
--- @field index_path? string Absolute path of the git index
--- @field mtime_sec? integer
--- @field mtime_nsec? integer
--- @field refreshing boolean
--- @field retry_at? integer `hrtime` before which git is not tried again
--- @field waiters fun(listing?: blink-cmp-git-files.Listing)[]

--- @type table<string, blink-cmp-git-files.Entry>
local entries = {}

--- @type fun()[]
local change_listeners = {}

local function notify_changed()
	for _, listener in ipairs(change_listeners) do
		listener()
	end
end

local function index_mtime(path)
	local stat = vim.uv.fs_stat(path)
	if stat then
		return stat.mtime.sec, stat.mtime.nsec
	end
end

local function is_stale(entry)
	local sec, nsec = index_mtime(entry.index_path)
	return sec ~= entry.mtime_sec or nsec ~= entry.mtime_nsec
end

--- Runs a command without blocking and calls back on the main loop.
local function run(cmd, cwd, on_done)
	local started = pcall(vim.system, cmd, { cwd = cwd, text = false }, function(result)
		vim.schedule(function()
			on_done(result.code == 0, result.stdout or "")
		end)
	end)
	-- vim.system throws if git is not executable or cwd no longer exists
	if not started then
		vim.schedule(function()
			on_done(false, "")
		end)
	end
end

--- @return blink-cmp-git-files.Listing
local function parse(raw_tracked, raw_deleted)
	local gone = {}
	for path in raw_deleted:gmatch("[^%z]+") do
		gone[path] = true
	end

	local files, lowered, tracked, count = {}, {}, {}, 0
	for path in raw_tracked:gmatch("[^%z]+") do
		if not gone[path] then
			count = count + 1
			files[count] = path
			lowered[count] = path:lower()
			tracked[path] = true
		end
	end

	return {
		files = files,
		lowered = lowered,
		tracked = tracked,
		raw_tracked = raw_tracked,
		raw_deleted = raw_deleted,
	}
end

local function finish(entry)
	entry.refreshing = false
	local waiters = entry.waiters
	entry.waiters = {}
	for _, waiter in ipairs(waiters) do
		waiter(entry.listing)
	end
end

local function fail(entry)
	local had_listing = entry.listing ~= nil
	entry.listing, entry.index_path = nil, nil
	entry.retry_at = vim.uv.hrtime() + NOT_A_REPO_RETRY_NS
	finish(entry)
	if had_listing then
		notify_changed()
	end
end

local function store(entry, raw_tracked, raw_deleted)
	-- Commands like `git status` touch the index without changing the file
	-- list. Identical output needs no reparse and no redraw.
	local previous = entry.listing
	local changed = not previous or previous.raw_tracked ~= raw_tracked or previous.raw_deleted ~= raw_deleted
	if changed then
		entry.listing = parse(raw_tracked, raw_deleted)
	end
	finish(entry)
	if changed then
		notify_changed()
	end
end

local function list_files(entry, cwd)
	-- Read the mtime first: an index written during the listing then counts as
	-- stale on the next fetch rather than being missed.
	local sec, nsec = index_mtime(entry.index_path)

	run(LIST_TRACKED, cwd, function(tracked_ok, raw_tracked)
		if not tracked_ok then
			return fail(entry)
		end
		run(LIST_DELETED, cwd, function(deleted_ok, raw_deleted)
			if not deleted_ok then
				return fail(entry)
			end
			entry.mtime_sec, entry.mtime_nsec = sec, nsec
			store(entry, raw_tracked, raw_deleted)
		end)
	end)
end

local function refresh(entry, cwd)
	if entry.refreshing then
		return
	end
	entry.refreshing = true

	if entry.index_path then
		return list_files(entry, cwd)
	end
	run(FIND_INDEX, cwd, function(ok, stdout)
		if not ok then
			return fail(entry)
		end
		entry.index_path = vim.trim(stdout)
		list_files(entry, cwd)
	end)
end

--- Calls back with the listing for `cwd`, or nil if it is not a git repository.
--- A cached listing is served immediately, even when a refresh has just started.
--- @param cwd string
--- @param callback fun(listing?: blink-cmp-git-files.Listing)
function M.get(cwd, callback)
	local entry = entries[cwd]
	if not entry then
		entry = { refreshing = false, waiters = {} }
		entries[cwd] = entry
	end

	if entry.retry_at then
		if vim.uv.hrtime() < entry.retry_at then
			return callback(nil)
		end
		entry.retry_at = nil
	end

	if entry.listing then
		if is_stale(entry) then
			refresh(entry, cwd)
		end
		return callback(entry.listing)
	end

	table.insert(entry.waiters, callback)
	refresh(entry, cwd)
end

--- Returns the cached listing for `cwd` without checking for changes.
--- @param cwd string
--- @return blink-cmp-git-files.Listing?
function M.peek(cwd)
	local entry = entries[cwd]
	return entry and entry.listing
end

--- Registers a function called on the main loop when a file list changes.
--- @param listener fun()
function M.on_change(listener)
	table.insert(change_listeners, listener)
end

return M

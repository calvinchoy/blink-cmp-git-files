--- Asynchronous listing of git-tracked files, cached per working directory.
---
--- The set of tracked files can only change when the git index does, so the
--- cache is validated with a single `fs_stat` on the index and git is spawned
--- only when its mtime has moved.

local M = {}

local NOT_A_REPO_RETRY_NS = 30 * 1e9

--- @class blink-cmp-git-files.Entry
--- @field files? string[] Tracked paths relative to the working directory
--- @field lowered? string[] Lowercased `files`, built on first use
--- @field file_set? table<string, true> `files` as a lookup table, built on first use
--- @field index_path? string Absolute path of the git index
--- @field mtime_sec? integer
--- @field mtime_nsec? integer
--- @field raw_tracked? string Last `ls-files` output, used to skip reparsing
--- @field raw_deleted? string
--- @field refreshing boolean
--- @field retry_at? integer `hrtime` before which git is not tried again
--- @field waiters fun(entry?: blink-cmp-git-files.Entry)[]

--- @type table<string, blink-cmp-git-files.Entry>
local entries = {}

--- @type fun(cwd: string)[]
local change_listeners = {}

local function notify_changed(cwd)
	for _, listener in ipairs(change_listeners) do
		listener(cwd)
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

local function parse(tracked, deleted)
	local gone
	if deleted ~= "" then
		gone = {}
		for path in deleted:gmatch("[^%z]+") do
			gone[path] = true
		end
	end

	local files, count = {}, 0
	for path in tracked:gmatch("[^%z]+") do
		if not (gone and gone[path]) then
			count = count + 1
			files[count] = path
		end
	end
	return files
end

local function finish(entry)
	entry.refreshing = false
	local waiters = entry.waiters
	entry.waiters = {}
	local result = entry.files and entry or nil
	for _, waiter in ipairs(waiters) do
		waiter(result)
	end
end

local function fail(entry, cwd)
	local had_files = entry.files ~= nil
	entry.files, entry.lowered, entry.file_set, entry.index_path = nil, nil, nil, nil
	entry.raw_tracked, entry.raw_deleted = nil, nil
	entry.retry_at = vim.uv.hrtime() + NOT_A_REPO_RETRY_NS
	finish(entry)
	if had_files then
		notify_changed(cwd)
	end
end

local function list_files(entry, cwd)
	-- Read the mtime first: an index written during the listing then counts as
	-- stale on the next fetch rather than being missed.
	local sec, nsec = index_mtime(entry.index_path)
	local tracked, deleted
	local pending, succeeded = 2, true

	local function on_listed()
		pending = pending - 1
		if pending > 0 then
			return
		end
		if not succeeded then
			return fail(entry, cwd)
		end

		entry.mtime_sec, entry.mtime_nsec = sec, nsec
		-- Commands like `git status` touch the index without changing the file
		-- list. Identical output needs no reparse and keeps derived tables valid.
		local changed = tracked ~= entry.raw_tracked or deleted ~= entry.raw_deleted
		if changed then
			entry.files = parse(tracked, deleted)
			entry.lowered, entry.file_set = nil, nil
			entry.raw_tracked, entry.raw_deleted = tracked, deleted
		end
		finish(entry)
		if changed then
			notify_changed(cwd)
		end
	end

	run({ "git", "ls-files", "-z", "--cached", "--deduplicate" }, cwd, function(ok, stdout)
		succeeded = succeeded and ok
		tracked = stdout
		on_listed()
	end)
	run({ "git", "ls-files", "-z", "--deleted" }, cwd, function(ok, stdout)
		succeeded = succeeded and ok
		deleted = stdout
		on_listed()
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
	run({ "git", "rev-parse", "--path-format=absolute", "--git-path", "index" }, cwd, function(ok, stdout)
		if not ok then
			return fail(entry, cwd)
		end
		entry.index_path = vim.trim(stdout)
		list_files(entry, cwd)
	end)
end

--- Calls back with the entry for `cwd`, or nil if it is not a git repository.
--- A cached list is served immediately, even when a refresh has just started.
--- @param cwd string
--- @param callback fun(entry?: blink-cmp-git-files.Entry)
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

	if entry.files then
		if is_stale(entry) then
			refresh(entry, cwd)
		end
		return callback(entry)
	end

	table.insert(entry.waiters, callback)
	refresh(entry, cwd)
end

--- Returns the cached entry for `cwd` without checking for changes.
--- @param cwd string
--- @return blink-cmp-git-files.Entry?
function M.peek(cwd)
	local entry = entries[cwd]
	return entry and entry.files and entry or nil
end

--- Registers a function called on the main loop when a file list changes.
--- @param listener fun(cwd: string)
function M.on_change(listener)
	table.insert(change_listeners, listener)
end

--- Tracked paths as a lookup table.
--- @param entry blink-cmp-git-files.Entry
--- @return table<string, true>
function M.tracked_set(entry)
	if not entry.file_set then
		local file_set = {}
		for _, path in ipairs(entry.files) do
			file_set[path] = true
		end
		entry.file_set = file_set
	end
	return entry.file_set
end

--- Lowercased paths for case-insensitive filtering.
--- @param entry blink-cmp-git-files.Entry
--- @return string[]
function M.lowered(entry)
	if not entry.lowered then
		local lowered = {}
		for i, path in ipairs(entry.files) do
			lowered[i] = path:lower()
		end
		entry.lowered = lowered
	end
	return entry.lowered
end

return M

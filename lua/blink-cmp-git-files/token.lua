--- The definition of an `@path` token, shared by completion and highlighting.

local M = {}

local MAX_TOKEN_BYTES = 512

local AT_BYTE = string.byte("@")
local DOT_BYTE = string.byte(".")

local function byte_set(chars)
	local set = {}
	for i = 1, #chars do
		set[chars:byte(i)] = true
	end
	return set
end

local PATH_BYTES =
	byte_set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./+~$")
local BYTES_BEFORE_AT = byte_set(" \t([{\"'`")

local function starts_token(line, at)
	return at == 1 or BYTES_BEFORE_AT[line:byte(at - 1)]
end

--- Returns the index of the last path byte in the run following `at`.
local function scan_path(line, at)
	local last = at
	local limit = at + MAX_TOKEN_BYTES
	while last < limit and PATH_BYTES[line:byte(last + 1)] do
		last = last + 1
	end
	return last
end

--- Returns where the tracked path in `line[first..last]` ends, or nil if there
--- is none. Trailing dots are dropped if needed, so a sentence can end after a
--- path.
local function tracked_end(line, first, last, tracked)
	while last >= first do
		if tracked[line:sub(first, last)] then
			return last
		end
		if line:byte(last) ~= DOT_BYTE then
			return nil
		end
		last = last - 1
	end
	return nil
end

--- Finds the `@` of the file token ending at the cursor.
--- @param line string
--- @param col integer Number of bytes before the cursor
--- @return integer? at 1-based byte index of the `@`
function M.find_start(line, col)
	for i = col, math.max(col - MAX_TOKEN_BYTES, 1), -1 do
		local current = line:byte(i)
		if current == AT_BYTE then
			return starts_token(line, i) and i or nil
		end
		if not PATH_BYTES[current] then
			return nil
		end
	end
	return nil
end

--- Returns the range of each `@path` on a line whose path is in `tracked`.
--- @param line string
--- @param tracked table<string, true>
--- @return { [1]: integer, [2]: integer }[] ranges 0-based, end-exclusive byte columns
function M.file_ranges(line, tracked)
	local ranges = {}
	local at = line:find("@", 1, true)
	while at do
		local last = scan_path(line, at)
		local path_end = starts_token(line, at) and tracked_end(line, at + 1, last, tracked)
		if path_end then
			ranges[#ranges + 1] = { at - 1, path_end }
		end
		at = line:find("@", last + 1, true)
	end
	return ranges
end

return M

--- The definition of an `@path` token, shared by completion and highlighting.

local M = {}

local MAX_TOKEN_BYTES = 512

local byte, find, sub = string.byte, string.find, string.sub
local AT_BYTE = byte("@")
local DOT_BYTE = byte(".")

local function byte_set(chars)
	local set = {}
	for i = 1, #chars do
		set[byte(chars, i)] = true
	end
	return set
end

local PATH_BYTES =
	byte_set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./")
local BYTES_BEFORE_AT = byte_set(" \t([{\"'`")

local function starts_token(line, at)
	return at == 1 or BYTES_BEFORE_AT[byte(line, at - 1)] == true
end

--- Finds the `@` of the file token ending at the cursor.
--- @param line string
--- @param col integer Number of bytes before the cursor
--- @return integer? at 1-based byte index of the `@`
function M.in_token(line, col)
	for i = col, math.max(col - MAX_TOKEN_BYTES, 1), -1 do
		local current = byte(line, i)
		if current == AT_BYTE then
			if starts_token(line, i) then
				return i
			end
			return nil
		end
		if not PATH_BYTES[current] then
			return nil
		end
	end
	return nil
end

--- Returns the range of each `@path` on a line whose path is in `tracked`.
--- Trailing dots are ignored if needed, so a sentence can end after a path.
--- @param line string
--- @param tracked table<string, true>
--- @return { [1]: integer, [2]: integer }[]? ranges 0-based, end-exclusive byte columns
function M.file_ranges(line, tracked)
	local ranges
	local at = find(line, "@", 1, true)
	while at do
		local token_end = at
		local limit = at + MAX_TOKEN_BYTES
		while token_end < limit and PATH_BYTES[byte(line, token_end + 1)] do
			token_end = token_end + 1
		end

		if token_end > at and starts_token(line, at) then
			local path_end = token_end
			local path = sub(line, at + 1, path_end)
			while not tracked[path] and path_end > at + 1 and byte(line, path_end) == DOT_BYTE do
				path_end = path_end - 1
				path = sub(line, at + 1, path_end)
			end
			if tracked[path] then
				ranges = ranges or {}
				ranges[#ranges + 1] = { at - 1, path_end }
			end
		end

		at = find(line, "@", token_end + 1, true)
	end
	return ranges
end

return M

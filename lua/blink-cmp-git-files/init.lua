--- blink.cmp source that completes `@path` tokens from git-tracked files.

local git = require("blink-cmp-git-files.git")
local token = require("blink-cmp-git-files.token")

local PROVIDER_ID = "git_files"
local DEFAULT_FILETYPES = { "markdown" }
local DEFAULT_MAX_CANDIDATES = 5000

local byte = string.byte

--- @class blink-cmp-git-files.Source : blink.cmp.Source
--- @field max_candidates integer
--- @field file_kind integer
local source = {}

source.in_token = token.in_token

--- Adds this source to a provider list. Use it in `sources.default`.
--- While the cursor is in a `@` token, this source becomes the only provider.
--- @param base string[]
--- @param filetypes? string[] Defaults to `{ "markdown" }`
--- @return string[]
function source.with_sources(base, filetypes)
	if not vim.tbl_contains(filetypes or DEFAULT_FILETYPES, vim.bo.filetype) then
		return base
	end
	local col = vim.api.nvim_win_get_cursor(0)[2]
	if source.in_token(vim.api.nvim_get_current_line(), col) then
		return { PROVIDER_ID }
	end
	local providers = vim.list_extend({}, base)
	providers[#providers + 1] = PROVIDER_ID
	return providers
end

--- @param opts? { max_candidates?: integer }
function source.new(opts)
	opts = opts or {}
	local max_candidates = opts.max_candidates or DEFAULT_MAX_CANDIDATES
	assert(
		type(max_candidates) == "number" and max_candidates > 0,
		"blink-cmp-git-files: max_candidates must be a positive number"
	)

	local self = setmetatable({
		max_candidates = max_candidates,
		file_kind = require("blink.cmp.types").CompletionItemKind.File,
	}, { __index = source })

	-- Load the list now so the first `@` does not wait on git
	git.get(vim.fn.getcwd(), function() end)
	return self
end

function source:get_trigger_characters()
	return { "@", "/", "." }
end

--- True if the bytes of `needle` appear in order in `haystack` from `start`.
local function is_subsequence(needle, needle_length, haystack, start)
	local matched = 1
	local wanted = byte(needle, matched)
	for i = start, #haystack do
		if byte(haystack, i) == wanted then
			matched = matched + 1
			if matched > needle_length then
				return true
			end
			wanted = byte(needle, matched)
		end
	end
	return false
end

--- @param entry blink-cmp-git-files.Entry
--- @param query string Text between the `@` and the cursor
--- @param range lsp.Range
--- @return blink.cmp.CompletionResponse
function source:build_response(entry, query, range)
	local files = entry.files
	local max_candidates = self.max_candidates
	local file_kind = self.file_kind

	-- Blink only fuzzy-matches the text after the last `/` or `.`, so anything
	-- before it has to be matched here.
	local prefix = (query:match("^(.*[/.])") or ""):lower()
	local prefix_length = #prefix
	local keyword = query:sub(prefix_length + 1):lower()
	local keyword_length = #keyword

	-- Small lists go to blink whole and are filtered there without another
	-- fetch. Past the cap, the keyword has to narrow the list here instead.
	local is_large = #files > max_candidates
	local filter_keyword = is_large and keyword_length > 0
	local lowered = (prefix_length > 0 or filter_keyword) and git.lowered(entry) or nil

	local items, count, truncated = {}, 0, false
	for i, path in ipairs(files) do
		local remainder_start = 1
		local matches = true

		if prefix_length > 0 then
			local _, prefix_end = lowered[i]:find(prefix, 1, true)
			if prefix_end then
				remainder_start = prefix_end + 1
			else
				matches = false
			end
		end
		if matches and filter_keyword then
			matches = is_subsequence(keyword, keyword_length, lowered[i], remainder_start)
		end

		if matches then
			if count == max_candidates then
				truncated = true
				break
			end
			count = count + 1
			items[count] = {
				label = path,
				kind = file_kind,
				filterText = remainder_start > 1 and path:sub(remainder_start) or nil,
				-- Shared between items: blink copies an edit before changing it
				textEdit = { newText = path, range = range },
			}
		end
	end

	return {
		is_incomplete_forward = truncated,
		is_incomplete_backward = filter_keyword,
		items = items,
	}
end

function source:get_completions(context, callback)
	local col = context.cursor[2]
	local at = source.in_token(context.line, col)
	if not at then
		callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
		return
	end

	local query = context.line:sub(at + 1, col)
	local line_number = context.cursor[1] - 1
	local range = {
		start = { line = line_number, character = at },
		["end"] = { line = line_number, character = col },
	}

	git.get(vim.fn.getcwd(), function(entry)
		if not entry then
			callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
			return
		end
		callback(self:build_response(entry, query, range))
	end)
end

return source

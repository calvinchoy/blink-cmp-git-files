--- blink.cmp source that completes `@path` tokens from git-tracked files.

local git = require("blink-cmp-git-files.git")
local token = require("blink-cmp-git-files.token")

local PROVIDER_ID = "git_files"
local DEFAULT_FILETYPES = { "markdown" }
local DEFAULT_MAX_CANDIDATES = 5000

--- @class blink-cmp-git-files.Source : blink.cmp.Source
--- @field max_candidates integer
--- @field file_kind integer
local source = {}

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
	if token.find_start(vim.api.nvim_get_current_line(), col) then
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

local function empty_response()
	return { is_incomplete_forward = false, is_incomplete_backward = false, items = {} }
end

--- Returns the index following the first `prefix` in `path`, or nil if absent.
local function after_prefix(path, prefix)
	if prefix == "" then
		return 1
	end
	local _, prefix_end = path:find(prefix, 1, true)
	return prefix_end and prefix_end + 1
end

--- True if the bytes of `needle` appear in order in `haystack` from `start`.
local function is_subsequence(needle, haystack, start)
	local matched = 1
	for i = start, #haystack do
		if haystack:byte(i) == needle:byte(matched) then
			if matched == #needle then
				return true
			end
			matched = matched + 1
		end
	end
	return false
end

--- @param listing blink-cmp-git-files.Listing
--- @param query string Text between the `@` and the cursor
--- @param range lsp.Range
--- @return blink.cmp.CompletionResponse
function source:build_response(listing, query, range)
	-- Blink only fuzzy-matches the text after the last `/` or `.`, so anything
	-- before it has to be matched here.
	local prefix = (query:match("^(.*[/.])") or ""):lower()
	local keyword = query:sub(#prefix + 1):lower()

	-- Small lists go to blink whole and are filtered there without another
	-- fetch. Past the cap, the keyword has to narrow the list here instead.
	local filter_keyword = #listing.files > self.max_candidates and keyword ~= ""

	local items, truncated = {}, false
	for i, path in ipairs(listing.files) do
		local lowered = listing.lowered[i]
		local remainder = after_prefix(lowered, prefix)

		if remainder and (not filter_keyword or is_subsequence(keyword, lowered, remainder)) then
			if #items >= self.max_candidates then
				truncated = true
				break
			end
			items[#items + 1] = {
				label = path,
				kind = self.file_kind,
				filterText = remainder > 1 and path:sub(remainder) or nil,
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
	local at = token.find_start(context.line, col)
	if not at then
		return callback(empty_response())
	end

	local query = context.line:sub(at + 1, col)
	local line_number = context.cursor[1] - 1
	local range = {
		start = { line = line_number, character = at },
		["end"] = { line = line_number, character = col },
	}

	git.get(vim.fn.getcwd(), function(listing)
		callback(listing and self:build_response(listing, query, range) or empty_response())
	end)
end

return source

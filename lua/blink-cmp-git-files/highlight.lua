--- Colours `@path` tokens whose path is a git-tracked file.
---
--- Highlights are ephemeral and computed during redraw, so only visible lines
--- are processed and nothing is stored in the buffer.

local git = require("blink-cmp-git-files.git")
local token = require("blink-cmp-git-files.token")

local M = {}

local GROUP = "BlinkCmpGitFilesPath"
-- Above treesitter (100) and plugin extmarks with the default priority (4096)
local PRIORITY = 4200

local filetypes = {}
local active_listing
local installed = false

local function define_highlight()
	vim.api.nvim_set_hl(0, GROUP, { link = "Special", default = true })
end

--- Checks whether the tracked files changed. Costs one `fs_stat` once loaded.
local function check_for_changes()
	if filetypes[vim.bo.filetype] then
		git.get(vim.fn.getcwd(), function() end)
	end
end

local function redraw()
	vim.api.nvim__redraw({ valid = false, flush = true })
end

--- `getcwd(win)` ignores 'autochdir', so the current window has to use the
--- plain form to share its cache entry with `check_for_changes` and completion.
local function window_cwd(win)
	if win == vim.api.nvim_get_current_win() then
		return vim.fn.getcwd()
	end
	return vim.fn.getcwd(win)
end

local function install(namespace)
	define_highlight()

	local group = vim.api.nvim_create_augroup("BlinkCmpGitFilesHighlight", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_highlight })
	vim.api.nvim_create_autocmd({ "BufEnter", "FileType", "FocusGained", "DirChanged", "InsertLeave" }, {
		group = group,
		callback = check_for_changes,
	})

	git.on_change(redraw)

	vim.api.nvim_set_decoration_provider(namespace, {
		on_win = function(_, win, buf)
			if not filetypes[vim.bo[buf].filetype] then
				return false
			end
			active_listing = git.peek(window_cwd(win))
			return active_listing ~= nil
		end,
		on_line = function(_, _, buf, row)
			local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
			if not line then
				return
			end
			for _, range in ipairs(token.file_ranges(line, active_listing.tracked)) do
				vim.api.nvim_buf_set_extmark(buf, namespace, row, range[1], {
					end_col = range[2],
					hl_group = GROUP,
					priority = PRIORITY,
					ephemeral = true,
				})
			end
		end,
	})
end

--- Enables highlighting. Safe to call more than once.
--- @param opts? { filetypes?: string[] } Filetypes default to `{ "markdown" }`
function M.setup(opts)
	opts = opts or {}
	filetypes = {}
	for _, filetype in ipairs(opts.filetypes or { "markdown" }) do
		filetypes[filetype] = true
	end

	if not installed then
		installed = true
		install(vim.api.nvim_create_namespace("blink-cmp-git-files"))
	end
	check_for_changes()
end

return M

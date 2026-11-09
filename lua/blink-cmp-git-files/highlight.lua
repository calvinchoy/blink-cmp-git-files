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
local current_cwd
local active_entry
local installed = false

local function define_highlight()
	vim.api.nvim_set_hl(0, GROUP, { link = "Special", default = true })
end

--- Checks whether the tracked files changed. Costs one `fs_stat` once loaded.
local function check_for_changes()
	if filetypes[vim.bo.filetype] then
		current_cwd = vim.fn.getcwd()
		git.get(current_cwd, function() end)
	end
end

local function redraw()
	vim.api.nvim__redraw({ valid = false, flush = true })
end

local function install(namespace)
	define_highlight()

	local group = vim.api.nvim_create_augroup("BlinkCmpGitFilesHighlight", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_highlight })
	vim.api.nvim_create_autocmd({ "BufEnter", "FileType", "FocusGained", "DirChanged", "InsertLeave" }, {
		group = group,
		callback = check_for_changes,
	})

	git.on_change(function(cwd)
		if cwd == current_cwd then
			redraw()
		end
	end)

	vim.api.nvim_set_decoration_provider(namespace, {
		on_win = function(_, _, buf)
			if not filetypes[vim.bo[buf].filetype] or not current_cwd then
				return false
			end
			active_entry = git.peek(current_cwd)
			return active_entry ~= nil
		end,
		on_line = function(_, _, buf, row)
			local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
			if not line or not line:find("@", 1, true) then
				return
			end
			local ranges = token.file_ranges(line, git.tracked_set(active_entry))
			if not ranges then
				return
			end
			for _, range in ipairs(ranges) do
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

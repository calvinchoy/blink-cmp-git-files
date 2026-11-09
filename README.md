# blink-cmp-git-files

A [blink.cmp](https://github.com/Saghen/blink.cmp) source that completes `@path` tokens from git-tracked files.

It is built for editing agent prompts. When Claude Code, opencode, or a similar tool opens its prompt in Neovim, type `@` to pick a project file. Accepting a file inserts `@relative/path`, which the agent can resolve.

## Requirements

- Neovim 0.10 or newer
- blink.cmp v1
- git 2.31 or newer

## Installation

With `vim.pack` (Neovim 0.12 or newer):

```lua
vim.pack.add({ "https://github.com/calvinchoy/blink-cmp-git-files" })
```

With [lazy.nvim](https://github.com/folke/lazy.nvim), add it as a dependency of blink.cmp:

```lua
{
  "saghen/blink.cmp",
  dependencies = { "calvinchoy/blink-cmp-git-files" },
  -- opts: see Setup below
}
```

## Setup

Register the provider and add it to your source list:

```lua
require("blink.cmp").setup({
  sources = {
    default = function()
      return require("blink-cmp-git-files").with_sources({ "lsp", "path", "snippets", "buffer" })
    end,
    providers = {
      git_files = {
        name = "Git",
        module = "blink-cmp-git-files",
        score_offset = 100,
        -- opts = { max_candidates = 5000 },
      },
    },
  },
})
```

The provider ID must be `git_files`.

`with_sources(base, filetypes?)` enables the source for the given filetypes, which default to `{ "markdown" }`. While the cursor is in an `@` token, it returns only this source so other completions stay out of the list.

## Behaviour

- Files come from `git ls-files`, run in Neovim's working directory rather than the buffer's. Agent prompt files usually live in a temp directory, while Neovim inherits the agent's working directory.
- Paths are relative to the working directory. From a subdirectory, only files under it are listed.
- `@` starts a token at the start of a line or after whitespace or one of `( [ { " ' `` ` ``, so email addresses are ignored.
- Text before the last `/` or `.` must appear literally in the path. Text after it is fuzzy-matched.

## Highlighting

Colour `@path` references whose path is a tracked file:

```lua
require("blink-cmp-git-files.highlight").setup()
-- or: setup({ filetypes = { "markdown", "gitcommit" } })
```

Call this when the filetype loads rather than from blink's setup, because blink usually loads on `InsertEnter` and a file may already contain references.

Both the `@` and the path use `BlinkCmpGitFilesPath`, which links to `Special` by default. Override it like any other highlight group:

```lua
vim.api.nvim_set_hl(0, "BlinkCmpGitFilesPath", { fg = "#7fb4ca", bold = true })
```

Only visible lines are processed, and nothing is stored in the buffer. The colour follows git: a new file is coloured after `git add`.

## Options

| Option | Default | Description |
|---|---|---|
| `max_candidates` | `5000` | Most items sent to blink per response. Larger repositories are narrowed as you type. |

## Performance

- Git runs asynchronously and never blocks input.
- The file list is reused until the git index's mtime changes, so there is no polling.
- When the index has changed, the cached list is served while a refresh runs in the background.

## Limits

- Typing a path character outside letters, digits, `_`, `-`, `.`, `/`, `+`, `~`, and `$` closes the menu. Those files can still be found by matching other parts of the name.
- A file deleted in the working tree stays listed until the index next changes.
- Paths containing spaces are inserted as they are, and an agent may read them as ending at the space.
- `@path` inside code fences is highlighted too.

## License

[MIT](LICENSE)

# synopsis.nvim

![Browsing files in Telescope: a cached synopsis appears immediately, then a new file's synopsis is written after a one-second pause on it](docs/demo.gif)

In the recording, `softmax.py` already has a synopsis, so it appears immediately; `related.lua`
does not, so one is written after a one-second pause on the file.

When you browse a codebase in Telescope, synopsis shows a short summary of the previewed file in
a pane above the results list. A summary is one sentence on what the file does, plus up to three
notes: behaviour that is not obvious, gotchas, and the other files it works with. It is written
by a large language model (LLM) for a reader who knows what the project is for but not its
details. If you keep a background file, the wording is pitched at your level.

Summaries are written in ASD-STE100 Simplified Technical English (short sentences, one fact
each, common words), with a blank line between items, so they can be read in a few seconds.

A summary that already exists appears immediately. A file without one gets one once you have
stayed on it for a second; with the default model, the summary arrives about 1.3 s later.
Summaries are cached outside the repo and marked as outdated when the file changes.

`:SynopsisAsk` answers a question about the repo, such as "where is the request retried?" or
"how does a file get its cache key?". The model searches and reads the code itself, and cites
the lines it relies on; you can open them from the answer. See [Ask about the repo](#ask-about-the-repo).

**Status:** early. Works with Telescope's file and grep pickers and any OpenAI-compatible chat
endpoint. Tested on macOS with Neovim 0.12.4 and Telescope commit `9377230`; a GitHub Actions
workflow runs the automated tests on Linux. Not yet available: summaries in the results list, questions about a visual
selection, and a history of past questions.

## Requirements

- Neovim 0.12, [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim), `curl`
- An API key for the model you choose, or a local model server

## Install

With the built-in `vim.pack`:

```lua
vim.pack.add {
  'https://github.com/nvim-lua/plenary.nvim',
  'https://github.com/nvim-telescope/telescope.nvim',
  'https://github.com/aaholmes/synopsis.nvim',
}
require('synopsis').setup()
```

Then give the pickers you want a summary pane the `synopsis` layout. It is Telescope's
`horizontal` layout with the pane added above the results, and it accepts the same
`layout_config` options:

```lua
require('telescope').setup {
  pickers = {
    find_files = { layout_strategy = 'synopsis' },
    live_grep = { layout_strategy = 'synopsis' },
  },
}
```

The default model, GPT-6 Luna, needs an OpenAI API key in `OPENAI_API_KEY`.

## Before anything is sent

The first time you preview a file without a summary in a repo, the pane asks whether that
repo's files may be sent to the model provider. Ctrl-a allows it and Ctrl-o turns synopses off;
the answer is remembered for that repo. Cached summaries are always shown, and nothing is sent until
you answer. `:SynopsisAllow` and `:SynopsisDeny` change the answer for the current buffer's repo.

For a local model server, where nothing leaves your machine, `setup { consent = 'always' }`
turns the question off.

## Keys

In the picker's prompt, in Insert and Normal mode:

| Key | Action |
|---|---|
| Ctrl-e / Ctrl-y | Scroll the synopsis down / up half a page (the mouse wheel works too) |
| Ctrl-a / Ctrl-o | Allow this repo's files to be sent / turn synopses off for this repo |

Telescope's own keys scroll the preview (`<C-u>` / `<C-d>`) and the results (`<PageUp>` /
`<PageDown>`).

## Ask about the repo

`:SynopsisAsk where is the request retried?` (or `:SynopsisAsk` alone, to be prompted) opens a
window with the answer. Map it to a key in your config, for example:

```lua
vim.keymap.set('n', '<leader>sa', '<cmd>SynopsisAsk<cr>', { desc = 'Ask about this repo' })
```

While the model works, the window shows each step ("Searching `retry`", "Reading
`lua/synopsis/llm.lua` 40–90"). The answer cites locations as `path:line`. In the window:

| Key | Action |
|---|---|
| `<CR>` | Open the citation under the cursor |
| `gl` | List every cited location in Telescope, previewed |
| `a` | Ask a follow-up question in the same conversation |
| `q` / `<Esc>` | Close the window, and stop the request if one is running |

The model starts from a map of the repo with one line per file: the file's leading comment (or
docstring) and the names it defines, read with Tree-sitter, so building the map needs no model.
It then searches the code with ripgrep, reads line ranges, and lists a file's definitions, for up to 10
rounds of tool calls. It uses the same consent question, `exclude` patterns and `max_bytes` limit as
the summaries, so excluded files are never searched or read.

This design comes from an evaluation on 80 questions about 8 repos, with GPT-6 Luna
(`eval/wiki/RESULTS.md`). As `:SynopsisAsk` runs them, answers contained 0.74 of the facts a
correct answer needs [95% CI 0.69, 0.79], compared with 0.36 for answers from file summaries
alone; 15% of answers contained a false claim. In the same evaluation, the map did as well as
summaries written by a model, and better than no map.

## Tell it who you are

Summaries are pitched at the reader described in `~/.config/butwhy/background.md`, the same file
[butwhy.nvim](https://github.com/aaholmes/butwhy.nvim) uses; set `background` to use another
path. Specific topics work better than job titles:

```markdown
# Reader background

## Strong
- Python, NumPy, PyTorch

## New to me
- Lua, Neovim's plugin API
```

Without the file, summaries are written for a general programmer.

## Configuration

The defaults:

```lua
require('synopsis').setup {
  -- Any OpenAI-compatible chat endpoint. api_key_env = false sends no key (a local server).
  llm = {
    url = 'https://api.openai.com',
    chat_path = '/v1/chat/completions',
    model = 'gpt-6-luna',
    api_key_env = 'OPENAI_API_KEY',
    params = { reasoning_effort = 'none' }, -- added to the request body as given
    timeout_ms = 30000,
    -- Reuse of the prompt start that a repo's files share (README, file list): 'auto' marks it
    -- for OpenAI's cache when url is api.openai.com; 'openai' always; false never.
    cache = 'auto',
    prompt_cache_key = true, -- send a hash of the repo root as the cache key
  },
  background = '~/.config/butwhy/background.md',
  consent = 'ask',        -- or 'always': send without asking
  delay_ms = 1000,        -- how long a file must stay previewed before a summary is requested
  max_bytes = 100 * 1024, -- larger files are never sent
  exclude = { '.env', '.env.*', '*.pem', '*.key', '*secret*', '*.lock', '*-lock.json' },
  max_concurrent = 3,
  height = 0.6,           -- below 1: fraction of the left column; otherwise lines
  -- In the picker's prompt; false for none.
  keymaps = { scroll_up = '<C-y>', scroll_down = '<C-e>', allow = '<C-a>', deny = '<C-o>' },
  ask = {
    max_rounds = 10,         -- turns of tool calls before the model must answer
    max_map_chars = 150000,  -- past this, files are listed in the map by path only
    keymaps = { close = { 'q', '<Esc>' }, open = '<CR>', locations = 'gl', follow_up = 'a' },
  },
}
```

For example, a local [llama.cpp](https://github.com/ggml-org/llama.cpp) server:

```lua
require('synopsis').setup {
  llm = { url = 'http://127.0.0.1:8080', model = 'local', api_key_env = false, params = {} },
  consent = 'always',
}
```

The pane's colours come from these highlight groups:

| Group | Used for | Linked by default to |
|---|---|---|
| `SynopsisLabel` | Bold labels such as "Watch out:" | `@markup.strong` |
| `SynopsisCode` | File paths and identifiers | `@markup.raw` |
| `SynopsisBullet` | The dot before each note | `@markup.list` |
| `SynopsisMessage` | Status lines such as "Writing a synopsis…" | `Comment` |

`:SynopsisClear` deletes the cached summaries for the current buffer's repo.

## What is sent, and what it costs

For each summary, the request contains:
- your background file;
- the first 150 lines of the repo's README;
- the repo's file list (up to 400 paths);
- the file itself (cut at 40,000 characters).

Binary files, files over `max_bytes` and files matching `exclude` are never sent; the pane says
why.

I measured cost and speed with GPT-6 Luna on 30 files from two small Neovim plugins and a
Neovim config (2026-11-08). The README and file list, which every file of a repo shares, are
read from OpenAI's cache after the repo's first file. A summary then cost a median of $0.00014
(at $0.10 / $0.50 per million tokens in / out), about a third of the cost without the cache.
At the median, previewing every file of a 1,000-file repo would cost about $0.14. The model
replied in a median of 1.3 s after the one-second pause. `eval/` holds the scripts, so you can
repeat the measurement on your own files.

An answer to `:SynopsisAsk` sends the file map (paths, leading comments, definition names) and then
whatever the model searches for or reads, up to 200 lines per read. In the evaluation, an answer
took a median of 8 tool calls and 10.1 s, and cost a median of $0.0027; 1,000 questions would
cost about $2.70.

Summaries are stored as one JSON file per summarized file under Neovim's cache directory
(`~/.cache/nvim/synopsis` on Linux and macOS), never in the repo. A summary is marked as
outdated, and rewritten next time you stay on the file, when the file changes, or when the
prompt, background file or model does.

## Tests

```sh
tests/run.sh
```

The tests run headless and use a fake chat endpoint, so they need no network or API key.

## License

MIT

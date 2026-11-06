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
stayed on it for a second; with the default model, the summary arrives about 1.4 s later.
Summaries are cached outside the repo and marked as outdated when the file changes.

**Status:** early. Works with Telescope's file and grep pickers and any OpenAI-compatible chat
endpoint. Tested on macOS with Neovim 0.12.4 and Telescope commit `9377230`; a GitHub Actions
workflow runs the automated tests on Linux. Not yet available: summarizing a whole repo in one batch, summaries in the
results list, summaries of folders.

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
Neovim config (2026-11-06). A summary used a median of 2,900 tokens in and 61 out, which is $0.0003 at $0.10 /
$0.50 per million tokens. The largest file, about 1,000 lines, cost $0.0013. At the median,
previewing every file of a 1,000-file repo would cost about $0.30. The model replied in a median
of 1.4 s (range 1.1–2.3 s) after the one-second pause. `eval/` holds the scripts, so you can
repeat the measurement on your own files.

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

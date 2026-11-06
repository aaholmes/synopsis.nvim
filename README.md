# whatsthis.nvim

When you browse a codebase in Telescope, whatsthis shows a short summary of the previewed file in
a pane above the results list. A summary is one sentence on what the file does and why it exists,
plus up to four notes: non-obvious behaviour, gotchas, and the other files it works with. It is
written by a large language model (LLM) for a reader who knows what the project is for but not
its details. If you keep a background file, the wording is pitched at your level.

A summary that already exists appears immediately. A file without one gets one once you have
stayed on it for a second, usually a few seconds later. Summaries are cached outside the repo and
marked as outdated when the file changes.

**Status:** early. Works with Telescope's file and grep pickers and any OpenAI-compatible chat
endpoint. Not yet available: summarizing a whole repo in one batch, summaries in the results list,
summaries of folders.

## Requirements

- Neovim 0.12, [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim), `curl`
- An API key for the model you choose, or a local model server

## Install

With the built-in `vim.pack`:

```lua
vim.pack.add {
  'https://github.com/nvim-lua/plenary.nvim',
  'https://github.com/nvim-telescope/telescope.nvim',
  'https://github.com/aaholmes/whatsthis.nvim',
}
require('whatsthis').setup()
```

Then give the pickers you want a summary pane the `whatsthis` layout. It is Telescope's
`horizontal` layout with the pane added above the results, and it accepts the same
`layout_config` options:

```lua
require('telescope').setup {
  pickers = {
    find_files = { layout_strategy = 'whatsthis' },
    live_grep = { layout_strategy = 'whatsthis' },
  },
}
```

The default model, GPT-6 Luna, needs an OpenAI API key in `OPENAI_API_KEY`.

## Tell it who you are

Summaries are pitched at the reader described in `~/.config/butwhy/background.md`, the same file
[butwhy.nvim](https://github.com/aaholmes/butwhy.nvim) uses. Specific topics work better than job
titles:

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
require('whatsthis').setup {
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
  delay_ms = 1000,        -- how long a file must stay previewed before a summary is requested
  max_bytes = 100 * 1024, -- larger files are never sent
  exclude = { '.env', '.env.*', '*.pem', '*.key', '*secret*', '*.lock', '*-lock.json' },
  max_concurrent = 3,
  height = 8,             -- lines of text in the pane
}
```

For example, a local [llama.cpp](https://github.com/ggml-org/llama.cpp) server:

```lua
require('whatsthis').setup {
  llm = { url = 'http://127.0.0.1:8080', model = 'local', api_key_env = false, params = {} },
}
```

`:WhatsthisClear` deletes the cached summaries for the current buffer's repo.

## What is sent, and what it costs

For each summary, the request contains:
- your background file;
- the first 150 lines of the repo's README;
- the repo's file list (up to 400 paths);
- the file itself (cut at 40,000 characters).

Binary files, files over `max_bytes` and files matching `exclude` are never sent; the pane says
why. Nothing is sent until a file has been previewed for `delay_ms`.

With GPT-6 Luna ($0.10 per million input tokens, $0.50 per million output tokens), I estimate (not yet
measured) that a summary of a typical source file uses about 5,000 tokens in and 150 out. That
would be roughly $0.0006, or about $0.60 to preview every file in a 1,000-file repo.

Summaries are stored as one JSON file per summarized file under Neovim's cache directory
(`~/.cache/nvim/whatsthis` on Linux and macOS), never in the repo. A summary is marked as
outdated, and rewritten next time you stay on the file, when the file changes, or when the
prompt, background file or model does.

## Tests

```sh
tests/run.sh
```

The tests run headless and use a fake chat endpoint, so they need no network or API key.

## License

MIT

# synopsis.nvim

![Browsing files in Telescope: a cached synopsis appears immediately, then a new file's synopsis is written after a one-second pause on it](docs/demo.gif)

In the recording, `softmax.py` already has a synopsis, so it appears immediately; `related.lua`
does not, so one is written after a one-second pause on the file.

synopsis is a Neovim plugin for getting up to speed in an unfamiliar codebase. It does two
things:

- **Summaries while you browse.** When you preview a file in
  [Telescope](https://github.com/nvim-telescope/telescope.nvim), a fuzzy finder for Neovim, a pane
  above the results shows a short summary of it. The summary has one sentence on what the file
  does, plus up to three notes: behaviour that is not obvious, gotchas, and the files it works
  with. It is written by a large language model (LLM), pitched at your background if you
  describe it.
- **Answers about the repo.** Ctrl-Space on a file in Telescope, or `:SynopsisAsk`, opens a chat
  about the repo. The model finds each answer by searching and reading the code itself, and
  cites the lines it relied on as `path:line`. On a wide screen the chat opens beside
  Telescope, which stays open, and Telescope's preview shows the cited lines, highlighted.
  Markdown and LaTeX in answers are rendered when
  [markview.nvim](https://github.com/OXY2DEV/markview.nvim) and
  [snacks.nvim](https://github.com/folke/snacks.nvim) are installed.

## Goals

- **Answers you can check.** Every answer cites locations, and selecting a citation shows its
  lines beside the answer.
- **Fast enough not to interrupt browsing.** A cached summary appears immediately, and a new one
  about 1.3 s after a one-second pause on the file.
- **Cheap enough to leave on.** A summary costs a median of $0.00014 and an answer $0.0027, with
  GPT-6 Luna.
- **Nothing sent without permission.** Each repo is sent to the model provider only after you
  allow it, and secret-looking files are never sent.
- **Model and prompt choices backed by measurements.** Each was tested on real repos, with
  predictions written before each run.

## How it works

```
Telescope preview ──► core ──► store (cached summary?) ──► render ──► pane
                       │ no summary after a 1 s pause
                       └──► prompt ──► llm (curl) ──► OpenAI-compatible endpoint

Ctrl-Space in Telescope, or :SynopsisAsk
     └──► answer ──► map (one line per file, no model) ──┐
            ▲                                             ▼
            └──── ask (tool loop) ◄──► llm ◄──► tools (rg, read, outline)
```

| Module | Role |
|---|---|
| `telescope.lua` | Registers a Telescope layout, `synopsis`: the standard horizontal layout with a strip freed above the results for the pane, narrowed from the right when the chat is open beside it. No fork of Telescope. |
| `core.lua` | Decides what the pane shows for the previewed file, and when to request a summary: after a 1 s pause, at most 3 requests at a time. |
| `prompt.lua`, `prompts/` | Builds the summary request: your background file, the repo's README and file list, then the file. |
| `store.lua` | Caches one JSON file per summary outside the repo, with hashes of the file and the prompt, so a changed file's summary is marked outdated. |
| `render.lua` | Lays out the summary in the pane: wrapped text, bullets and highlighted labels. |
| `consent.lua`, `files.lua` | Records which repos may be sent, and which files may never be sent (exclude patterns, size limit, binary files). |
| `llm.lua` | One request to any OpenAI-compatible chat endpoint, made with curl. It handles tool calls, cancelling, and OpenAI's prompt cache. |
| `map.lua` | The repo map for questions: each file's leading comment (or docstring) and the names it defines, read with Tree-sitter, Neovim's built-in parser. It is built in small chunks and cached by file. |
| `tools.lua` | The tools the model may call: `rg` (search with ripgrep), `read` (a range of lines), `outline` (a file's definitions with line numbers). They obey the same exclude and size rules. |
| `ask.lua` | The question loop: up to 10 rounds of tool calls, then a final answer. It never blocks the editor. A conversation holds the messages across questions; cancelling a question restores them to how they were before it, so the conversation can go on. |
| `answer.lua` | The chat: one conversation per repo, kept while Neovim runs; an input panel that holds every key, and a link cursor that moves through the citations; a preview, which is Telescope's own when the chat is beside a picker; progress lines; a Telescope list of every cited location; and rendering with markview and snacks (LaTeX written as `\(…\)` or `\[…\]` is rewritten with dollar signs, which they recognise). |

**Tech stack:**
- The plugin is Lua on Neovim 0.12 (`vim.system`, `vim.uv` timers, floating windows,
  Tree-sitter), with Telescope and plenary.
- Requests go through curl, and searches through ripgrep.
- The tests are headless Neovim talking to a fake chat server, and run on GitHub Actions.
- The evaluations are written in Lua and Python, in `eval/`.

## Design choices

### Model and prompts, and the evidence for them

All measurements use GPT-6 Luna with reasoning off. Intervals are 95% bootstrap intervals,
paired over the same files or questions. Details are in `eval/*/RESULTS.md`.

- **Summaries are written in ASD-STE100 Simplified Technical English** (short sentences, one
  fact each, common words), so they can be read in a few seconds.
- **The shared start of each request is marked as a cache point.** Every file of a repo shares
  the README and file list. OpenAI's automatic caching only stores a prompt up to the end of its
  latest user message, so the shared part was never reused: 2 of 30 requests hit the cache.
  Marking the shared part explicitly gave 27 of 30 hits and cut the median cost per summary to
  0.32 [0.26, 0.40] of what it was.
- **A hosted model by default.** I tested local models on a 16 GB M2 MacBook, using llama.cpp:
  - The best, Qwen3.5 4B, took a median of 11–12 s per summary, compared with 1.4 s for GPT-6
    Luna.
  - Only 17 of 29 of its summaries were free of wrong claims, compared with 27 of 29 for Luna.
  - Reading the prompt is the bottleneck on that hardware.

  Local servers still work, as any OpenAI-compatible endpoint does.
- **Questions are answered by reading code, not from summaries.** On 80 questions about 8
  repos (Lua, Python and Rust, with 31 to 754 files), an LLM graded each answer for the facts a
  correct answer needs. Answers from file summaries alone contained 0.36 of them. With tools to
  search and read the code, they contained 0.79 [0.74, 0.83], and the share of answers with a
  false claim fell from 30% to 16%.
- **The repo map is built without a model.** A map built from comments and definition names
  did as well as summaries written by the model: −0.01 [−0.04, +0.02]. It also did better than no
  map: +0.04 [+0.00, +0.08], with fewer tool calls. It costs nothing to build and is never out
  of date, so `:SynopsisAsk` needs no summaries at all.
- **Things that did not help, and are left out:**
  - Folder summaries and a repo overview added to the file summaries: +0.00 [−0.03, +0.03].
  - Go-to-definition and find-references from a language server (LSP): offered, but the model
    used them once in 240 answers, preferring `rg` and `read`.
- **The released code is measured too.** The evaluation runs on the plugin's own modules. As
  `:SynopsisAsk` runs, answers contained 0.74 [0.69, 0.79] of the required facts, and 15% had a
  false claim. That is 0.03 [0.00, 0.06] below the evaluation's own arm with the same map. A
  likely cause, not yet tested, is that the path:line citations now count toward the 150-word
  limit on answers.

**Limits of this evidence:**
- One model wrote the summaries, answered the questions and graded the answers, so any bias it
  shares across those roles goes undetected. Hand checks of 7 random grades agreed with all 7.
- The questions were written by agents reading the code, so people's own questions may differ.
- The eight repos are well commented, which favours the map.

### The chat

- **It opens beside Telescope, not instead of it.** Searching for files and asking about them
  are two ways of finding your way round a repo, so both stay usable, and Ctrl-Space moves the
  focus between them. Telescope closes a picker when the focus leaves its prompt, using one
  autocmd. The `synopsis` layout removes that autocmd while the chat is open and restores it
  afterwards; closing the picker, or moving to an ordinary window, closes both. The other
  option, writing a separate fuzzy finder, would have meant rebuilding Telescope's sorting,
  grep results and previewers.
- **One typing cursor, and a separate link cursor.** Every key works in the input panel, so
  typing a question and moving through the answer never compete for the focus. Tab moves a
  highlighted link cursor through the conversation, which jumps to each new answer's first
  link. `<CR>` with nothing typed opens it, and Telescope's own keys and clicks for opening a
  file open it too. The conversation itself never keeps the focus; clicking a link selects it.
  Only one key, Ctrl-Space, switches between the picker and the chat. Other plugins remap keys
  in every buffer (llama.vim maps and unmaps `<Tab>` as you type; blink.cmp maps `<C-n>`), so
  synopsis maps its keys in the input again after them.
- **One previewed file, whichever side has the focus.** The chat shows citations in
  Telescope's preview, and selecting a link also selects its file in Telescope's results, so
  the results, the preview and the summary pane always agree. Switching sides never changes
  the file; moving the selection in the picker does. A cited file that is not among the
  results clears the prompt so that it can be selected, which means the results then list
  every file rather than the last search. Telescope previews a file whenever its selection
  changes, so synopsis moves the selection with that preview switched off.
- **One conversation per project, not per file.** Questions asked while browsing usually build
  on each other, so Ctrl-Space on a second file continues the chat, and the model is told the
  new file once. The chat is titled with the project's name. Beside a picker, Ctrl-Space on any
  file goes back to that picker's chat, even a file with another root, such as one in a nested
  repo. A cancelled question is removed from the messages, because the API rejects a
  conversation that ends in an unanswered tool call.

## Current state

Early. Both features work with Telescope's file and grep pickers and any OpenAI-compatible chat
endpoint. Tested on macOS with Neovim 0.12.4 and Telescope commit `9377230`. GitHub Actions runs
the 206 automated tests on Linux. The tests call the chat's mouse handler directly, since
headless Neovim receives no real clicks.

Known limitations:
- An inline equation drawn as an image by snacks can push the text after it onto a later row.
  Neovim decides where to wrap a line using the LaTeX source hidden behind the image, so a long
  equation leaves empty rows after it.
- A cited file is selected in the results only if Telescope lists it. With an empty prompt,
  Telescope keeps its first 250 results, and a grep picker lists nothing, so in a large repo or
  a grep picker the citation is previewed without being selected.

## Future directions

- Test whether excluding citations from the 150-word limit recovers the 0.03 lost in the
  released code.
- Break the chat's lines in synopsis itself, counting each equation as the width of its image,
  so inline maths stays on its line.
- On screens too narrow for three columns, show the chat in place of the summary and results,
  so the picker can stay open there too. Today the picker closes on such screens.
- Bring the chat back when Telescope's `resume` reopens a picker.
- Questions about a highlighted passage, and chats saved across Neovim sessions.
- Summaries in Telescope's results list, next to each file name.
- An evaluation set of real questions asked while using the tool, to replace the
  agent-written ones.

## Install

Requirements: Neovim 0.12, telescope.nvim, `curl` and `rg` (ripgrep), plus an API key for the
model you choose or a local model server. With the built-in `vim.pack`:

```lua
vim.pack.add {
  'https://github.com/nvim-lua/plenary.nvim',
  'https://github.com/nvim-telescope/telescope.nvim',
  'https://github.com/aaholmes/synopsis.nvim',
}
require('synopsis').setup()
```

Give the pickers that should show a summary pane the `synopsis` layout. It accepts the same
`layout_config` options as Telescope's `horizontal` layout:

```lua
require('telescope').setup {
  pickers = {
    find_files = { layout_strategy = 'synopsis' },
    live_grep = { layout_strategy = 'synopsis' },
  },
}
```

Map `:SynopsisAsk` to a key if you like:

```lua
vim.keymap.set('n', '<leader>sa', '<cmd>SynopsisAsk<cr>', { desc = 'Ask about this repo' })
```

The default model, GPT-6 Luna, needs an OpenAI API key in `OPENAI_API_KEY`.

## Before anything is sent

The first time a repo would be sent, synopsis asks whether that repo's files may be sent to the
model provider:
- in the pane, Ctrl-a allows it and Ctrl-o refuses;
- for `:SynopsisAsk`, a menu asks.

The answer is remembered per repo, and `:SynopsisAllow` and `:SynopsisDeny` change it.
Cached summaries are always shown. For a local model server, where nothing leaves your
machine, `setup { consent = 'always' }` turns the question off.

## Keys

In the picker's prompt, in Insert and Normal mode:

| Key | Action |
|---|---|
| Ctrl-e / Ctrl-y | Scroll the summary down / up half a page (the mouse wheel works too) |
| Ctrl-a / Ctrl-o | Allow this repo's files to be sent / turn synopses off for this repo |
| Ctrl-Space | Ask about the selected file in the repo's chat. At 180 columns or more, the chat opens beside the picker and Ctrl-Space moves between the two; on narrower screens the picker closes, and closing the chat reopens it where it was |

The `:SynopsisAsk` chat has:
- **a conversation.** Questions have a coloured bar. While the model works, its steps appear
  as muted lines ("Searching `retry`", "Reading `lua/synopsis/llm.lua` 40–90"), and each answer
  ends with a muted line giving its tool calls, time and tokens. One link is selected and
  highlighted; each new answer selects its own first link.
- **an input panel** below it, where the typing cursor stays. All the chat's keys work there.
- **a preview** of the selected link, with the cited lines highlighted, three lines below the
  top. Files that are never sent (see `exclude`) are never shown.

Opened from Telescope on a screen at least 180 columns wide, the chat takes a column to the
right of the picker and uses Telescope's preview and border colours. The selected link's file
is selected in the results too, and stays previewed when you go back to the prompt; `q` in the
chat closes only the chat. A cited file fires the same event as a previewed one
(`User TelescopePreviewerLoaded`), so border colours set by filetype follow it. Otherwise the
chat opens in windows of its own, with the preview in a pane on the right when the screen is
at least 120 columns wide.

Each repo keeps its conversation until you quit Neovim. Reopening the chat, or Ctrl-Space on
another file, continues it; a muted "Now viewing `b.lua`" line marks the change of file. Closing
the chat while an answer is coming stops the request and shows "Cancelled."; that question is
dropped from what the model sees.

In the input panel:

| Key | Action |
|---|---|
| `<CR>` | Send the question (ignored while an answer is still coming); with nothing typed, open the selected link |
| `<Tab>` / `<S-Tab>` | Select the next / previous link and preview it, wrapping around |
| `<C-x>` / `<C-v>` / `<C-t>` | Open the selected link in a split / a vertical split / a tab, as in Telescope |
| `<C-Space>` | Back to the picker's prompt, when the chat is beside one |
| `<C-n>` | Start a new chat for this repo |
| `<C-c>`, or `q` / `<Esc>` in Normal mode | Close the chat, and stop the request if one is running |
| `gl` (Normal mode) | List every cited location in Telescope, previewed |

With the mouse, clicking a link selects it, clicking the chat or the prompt moves the typing
cursor there, and the wheel scrolls the conversation. Beside the picker, clicking Telescope's
preview from the chat opens what it shows, as a click from the prompt does: the selected link,
or the picker's file when no link is selected. In the chat's own preview pane, `<CR>` opens the
file at the cursor's line.

## Tell it who you are

Summaries are pitched at the reader described in `~/.config/butwhy/background.md`, the file
[butwhy.nvim](https://github.com/aaholmes/butwhy.nvim) also uses; set `background` to use
another path. Specific topics work better than job titles:

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
  keymaps = { scroll_up = '<C-y>', scroll_down = '<C-e>', allow = '<C-a>', deny = '<C-o>', ask = '<C-Space>' },
  ask = {
    max_rounds = 10,         -- turns of tool calls before the model must answer
    max_map_chars = 150000,  -- past this, files are listed in the map by path only
    render = true,           -- render the chat with markview.nvim and snacks.nvim, if installed
    preview = true,          -- a pane of cited lines, when the chat has windows of its own
    preview_min_columns = 120, -- narrower screens get no preview
    side_min_columns = 180,  -- from this width, Ctrl-Space opens the chat beside the picker
    -- All in the input panel; close and locations in Normal mode
    keymaps = {
      close = { 'q', '<Esc>' }, open = '<CR>', locations = 'gl', new_chat = '<C-n>',
      next_citation = '<Tab>', prev_citation = '<S-Tab>', picker = '<C-Space>',
      open_split = '<C-x>', open_vsplit = '<C-v>', open_tab = '<C-t>',
    },
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

The colours come from these highlight groups, which follow your colour scheme by default:

| Group | Used for | Default |
|---|---|---|
| `SynopsisLabel` | Bold labels such as "Watch out:" in the pane | `@markup.strong` |
| `SynopsisCode` | File paths and identifiers in the pane | `@markup.raw` |
| `SynopsisBullet` | The dot before each note in the pane | `@markup.list` |
| `SynopsisMessage` | Status lines such as "Writing a synopsis…" | `Comment` |
| `SynopsisQuestion` | Questions in the chat | `Function`'s colour, bold |
| `SynopsisProgress`, `SynopsisMeta`, `SynopsisHint` | The chat's progress lines, footers and hint | `Comment` |
| `SynopsisCited` | The cited lines in the preview | `Visual` |
| `SynopsisLink` | The selected link in the chat | `IncSearch` |

After each change to the chat, synopsis fires `User SynopsisAnswerRendered` with `{ buf, win }`,
for other markdown renderers; set `ask.render = false` to turn off the built-in rendering.

`:SynopsisClear` deletes the cached summaries for the current buffer's repo.

## What is sent, and what it costs

A summary request contains:
- your background file;
- the first 150 lines of the repo's README;
- the repo's file list (up to 400 paths);
- the file itself (cut at 40,000 characters).

A question sends:
- the file map (paths, leading comments and definition names);
- then whatever the model searches for or reads, up to 200 lines per read.

Files over `max_bytes`, binary files and files matching `exclude` are never sent, searched or
read.

Measured with GPT-6 Luna (2026-11-08), at $0.10 / $0.50 per million tokens in / out:
- **A summary:** a median of $0.00014 and 1.3 s after the pause, on 30 files from three small
  repos. Previewing every file of a 1,000-file repo would cost about $0.14.
- **An answer:** a median of 8 tool calls, 10.1 s and $0.0027, on the 80 evaluation questions.
  1,000 questions would cost about $2.70.

`eval/` holds the scripts, so you can repeat these measurements on your own files.

Summaries are stored as one JSON file per file under Neovim's cache directory
(`~/.cache/nvim/synopsis` on Linux and macOS), never in the repo. A summary is marked as
outdated, and rewritten the next time you stay on the file, when the file, the prompt, the
background file or the model changes.

## Tests

```sh
tests/run.sh
```

The tests run headless and use a fake chat endpoint, so they need no network or API key.

## License

MIT

# synopsis.nvim: design

How the plugin is built, why, and the measurements behind its choices. For installing and using
it, see the [README](../README.md).

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
| `answer.lua` | The chat: one conversation per repo, kept while Neovim runs; an input panel that holds every key, and a link cursor that moves through the citations; a preview, which is Telescope's own when the chat is beside a picker, with each cited line widened to the code block that starts on it; progress lines; a Telescope list of every cited location; and rendering with markview and snacks (LaTeX written as `\(…\)` or `\[…\]` is rewritten with dollar signs, which they recognise). |

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
- **A cited line is widened to its code block, by the parser rather than the model.** The model
  cites single lines (`path:line`), as the evaluated prompt asks. The preview highlights the
  largest syntax node, found with Tree-sitter, that starts on that line and is at most 50 lines
  long: citing a `def` line highlights the function, and citing a `for` line the loop. A line
  inside a block stands for itself (a one-line `loss = …` inside a training loop highlights only
  that line). Ranges the model writes (`path:first-last`) are highlighted as written.
- **One conversation per repo, not per file.** Questions asked while browsing usually build on
  each other, so Ctrl-Space on a second file continues the chat, and the model is told the new
  file once. The chat is titled with the repo's name. Beside a picker, Ctrl-Space on any file
  goes back to that picker's chat, even a file with another root, such as one in a nested repo.
  A cancelled question is removed from the messages, because the API rejects a conversation
  that ends in an unanswered tool call.

## State

Early. Both features work with Telescope's file and grep pickers and any OpenAI-compatible chat
endpoint. Tested on macOS with Neovim 0.12.4 and Telescope commit `9377230`. GitHub Actions runs
the 213 automated tests on Linux. The tests call the chat's mouse handler directly, since
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

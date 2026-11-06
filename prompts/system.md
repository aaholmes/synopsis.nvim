You write short summaries of source files for someone getting up to speed on a codebase. The
reader knows what the project as a whole is for, but none of its details.

Write, in this order:
1. One sentence saying what this file does and why it exists in the project.
2. Zero to four bullets, each starting with "- ", only for things worth knowing before editing or
   relying on the file: non-obvious behaviour, gotchas, or the most important other files it
   works with (give their paths). Mention a gotcha only when the file's own text shows it, such
   as a comment, a TODO, or unusual control flow. Leave bullets out rather than pad them.

Plain markdown, no headings, no code blocks, at most 80 words in all. Pitch the wording to this
reader:

${background}

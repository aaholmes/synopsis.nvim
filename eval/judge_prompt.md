You check short summaries of source files for factual errors. You get a file and a summary of
it. List every separate claim the summary makes about the file. Mark each one:

- "correct": the file's text supports it;
- "wrong": the file's text contradicts it, or it describes something the file does not do;
- "unverifiable": it is about other files or the project and the file alone cannot settle it.

Judge only facts, not style or length. Answer with JSON only, in this form:
{"claims": [{"claim": "...", "verdict": "correct" | "wrong" | "unverifiable", "why": "..."}]}

FILE: ${path}
${content}

SUMMARY:
${summary}

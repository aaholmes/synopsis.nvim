# Records docs/chat.gif in butwhy.nvim, a small public repo checked out next to this one.
# Run from this repo's root with OPENAI_API_KEY set: vhs demo/chat.tape
# The model's wait is recorded as it happened: Wait holds until the answer's footer appears.
Output docs/chat.gif

Require nvim
Set Shell "bash"
Set FontFamily "Fira Code"
Set FontSize 15
Set Width 1600
Set Height 720
Set Padding 12
Set TypingSpeed 40ms

# Off camera: write the summary of the file the chat starts from.
Hide
Type "cd ../butwhy && nvim -u ../synopsis/demo/init.lua" Enter
Sleep 2s
Type " sf"
Sleep 1s
Type "butwhy/init"
Sleep 6s
Escape
Escape
Sleep 500ms
Show

Sleep 500ms
Type " sf"
Sleep 1s
Type "butwhy/init"
Sleep 2500ms
# Ask about the repo from the selected file; the chat opens beside the picker.
Ctrl+Space
Sleep 1500ms
Type "Which files build the prompt for a but why? follow-up?"
Sleep 800ms
Enter
Wait+Screen@60s /tool calls? ·/
# The answer's first link is selected, and Telescope previews its code block.
Sleep 3500ms
# Tab moves to the next link: the preview, the selected result and the summary follow.
Tab
Sleep 3s
Tab
Sleep 3s
# Back to Telescope: the same file stays previewed.
Ctrl+Space
Sleep 3s
Hide
Type ":qa!" Enter

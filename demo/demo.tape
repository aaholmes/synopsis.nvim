# Records docs/demo.gif in butwhy.nvim, a small public repo checked out next to this one.
# Run from this repo's root with OPENAI_API_KEY set: vhs demo/demo.tape
Output docs/demo.gif

Require nvim
Set Shell "bash"
Set FontFamily "Fira Code"
Set FontSize 15
Set Width 1400
Set Height 720
Set Padding 12
Set TypingSpeed 70ms

# Off camera: write one summary, so the recording can show a cached one appearing immediately.
Hide
Type "cd ../butwhy && nvim -u ../synopsis/demo/init.lua" Enter
Sleep 2s
Type " sf"
Sleep 1s
Type "softmax"
Sleep 6s
Escape
Escape
Sleep 500ms
Show

Sleep 500ms
Type " sf"
Sleep 1s
# Cached: shown as soon as the file is previewed.
Type "softmax"
Sleep 3s
Backspace 7
# Not cached: written after a one-second pause on the file.
Type "related.lua"
Sleep 6s
Escape
Escape
Sleep 300ms
Hide
Type ":qa!" Enter

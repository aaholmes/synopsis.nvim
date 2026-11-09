# Records docs/demo.gif in modded-nanogpt (github.com/KellerJordan/modded-nanogpt), checked out
# next to this repo.
# Run from this repo's root with OPENAI_API_KEY set: vhs demo/demo.tape
Output docs/demo.gif

Require nvim
Set Shell "bash"
Set FontFamily "Fira Code"
Set FontSize 15
Set Width 1400
Set Height 720
Set Padding 12
Set TypingSpeed 45ms

# Off camera: write one summary, so the recording can show a cached one appearing immediately.
Hide
Type "cd ../modded-nanogpt && nvim -u ../synopsis/demo/init.lua" Enter
Sleep 2s
Type " sf"
Sleep 1s
Type "polar_express"
Sleep 8s
Escape
Escape
Sleep 500ms
Show

Sleep 500ms
Type " sf"
Sleep 1s
# Cached: shown as soon as the file is previewed.
Type "polar_express"
Sleep 3s
Backspace 13
# Not cached: written after a one-second pause on the file.
Type "model/attention"
Sleep 7s
Escape
Escape
Sleep 300ms
Hide
Type ":qa!" Enter

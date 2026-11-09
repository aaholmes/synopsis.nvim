# Records docs/chat.gif in modded-nanogpt (github.com/KellerJordan/modded-nanogpt), checked out
# next to this repo.
# Run from this repo's root with OPENAI_API_KEY set: vhs demo/chat.tape
# Wait holds until the answer's footer appears. The README's GIF then has the wait sped up 4x, from
# the frame where the input's title becomes "waiting for the answer…" (start) to the answer (end):
#   ffmpeg -i raw.gif -filter_complex "[0:v]trim=0:START,setpts=PTS-STARTPTS[a];
#     [0:v]trim=START:END,setpts=(PTS-STARTPTS)/4[b];[0:v]trim=END,setpts=PTS-STARTPTS[c];
#     [a][b][c]concat=n=3:v=1,fps=25,split[x][y];[x]palettegen=stats_mode=diff[p];
#     [y][p]paletteuse=dither=none" docs/chat.gif
Output docs/chat.gif

Require nvim
Set Shell "bash"
Set FontFamily "Fira Code"
Set FontSize 15
Set Width 1600
Set Height 720
Set Padding 12
Set TypingSpeed 25ms

# Off camera: write the summary of the file the chat starts from.
Hide
Type "cd ../modded-nanogpt && nvim -u ../synopsis/demo/init.lua" Enter
Sleep 2s
Type " sf"
Sleep 1s
Type "ngram_table"
Sleep 8s
Escape
Escape
Sleep 500ms
Show

Sleep 500ms
Type " sf"
Sleep 1s
Type "ngram_table"
Sleep 2s
# Ask about the repo from the selected file; the chat opens beside the picker.
Ctrl+Space
Sleep 1s
Type "What does the n-gram table add to the model?"
Sleep 500ms
Enter
Wait+Screen@60s /tool calls? ·/
# The answer's first link is selected, and Telescope previews its code block.
Sleep 2500ms
# Tab moves to the next link: the preview, the selected result and the summary follow.
Tab
Sleep 2500ms
Tab
Sleep 2s
# Ctrl-D scrolls the preview without leaving the chat's input.
Ctrl+D
Sleep 1500ms
# Back to Telescope: the same file stays previewed.
Ctrl+Space
Sleep 2s
Hide
Type ":qa!" Enter

#!/bin/sh
# Measure one model: start llama-server on it, summarize the files in $FILES, stop the server.
#   eval/local/run_arm.sh NAME MODEL.gguf OUTDIR [extra llama-server flags]
# Context 16,384 tokens, all layers on the GPU, flash attention, one slot (so the shared start of
# the prompt is reused between files), thinking off, at most 400 tokens out. Writes OUTDIR/NAME.jsonl and NAME.log.
set -eu
name=$1 model=$2 out=$3; shift 3
port=${PORT:-8090}
cd "$(dirname "$0")/../.."
llama-server -m "$model" --port "$port" -c 16384 -ngl 99 -fa on -np 1 --cache-reuse 256 \
  --jinja --reasoning off "$@" > "$out/$name.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null' EXIT
until curl -sf "http://127.0.0.1:$port/health" > /dev/null; do
  kill -0 $pid 2>/dev/null || { echo "$name: server exited, see $out/$name.log"; exit 1; }
  sleep 1
done
# One short request first, so model loading is not counted in the first file's time.
curl -s "http://127.0.0.1:$port/v1/chat/completions" -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say ok."}],"max_tokens":4}' > /dev/null
rm -f "$out/$name.jsonl"
SYNOPSIS_PARAMS=${SYNOPSIS_PARAMS:-'{"max_tokens":400,"chat_template_kwargs":{"enable_thinking":false}}'} SYNOPSIS_URL="http://127.0.0.1:$port" SYNOPSIS_MODEL="$name" SYNOPSIS_OUT="$out/$name.jsonl" SYNOPSIS_FILES="$FILES" \
  nvim --headless -u NONE -c 'luafile eval/collect.lua' > /dev/null 2>&1
echo "$name: $(wc -l < "$out/$name.jsonl") files"

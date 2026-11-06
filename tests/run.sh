#!/bin/sh
# Run every spec headless; exit non-zero if any fails. A spec that errors before calling
# finish() exits with an error instead of leaving Neovim open.
cd "$(dirname "$0")/.." || exit 1
status=0
for spec in tests/*_spec.lua; do
  echo "== $spec"
  nvim --headless -u tests/minimal_init.lua \
    -c "lua local ok, err = pcall(dofile, '$spec') if not ok then io.write('ERROR ', tostring(err), '\n') vim.cmd 'cq!' end" \
    || status=1
done
exit $status

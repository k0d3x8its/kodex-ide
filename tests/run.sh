#!/usr/bin/env bash
# Headless test runner for kodex-ide. Each tests/*_spec.lua runs in its own
# `nvim --headless -u NONE` so a crash or cq in one spec can't poison another.
# A spec signals failure with `:cq` (exit 1); this script aggregates.
#   bash tests/run.sh   (or: make test)
set -u
cd "$(dirname "$0")/.."

fail=0
for spec in tests/*_spec.lua; do
  echo "──────── $spec ────────"
  if ! nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile $spec"; then
    fail=1
  fi
  echo
done

if [ "$fail" -eq 0 ]; then
  echo "✓ all specs passed"
else
  echo "✗ failures present"
fi
exit "$fail"

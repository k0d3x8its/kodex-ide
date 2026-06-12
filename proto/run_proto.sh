#!/usr/bin/env bash
# PROTOTYPE runner (throwaway) — findings Q6 diff-workflow validation.
#   bash proto/run_proto.sh        headless hard-case suite
#   bash proto/run_proto.sh -i     interactive manual drive
set -e
cd "$(dirname "$0")"

if [ "${1:-}" = "-i" ]; then
  nvim -u NONE -c "luafile diff_proto_interactive.lua"
else
  nvim --headless -u NONE -c "luafile diff_proto_test.lua"
fi

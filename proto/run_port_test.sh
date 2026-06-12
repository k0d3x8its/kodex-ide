#!/usr/bin/env bash
# Port-verification test runner — drives the real lua/utils/opencode_diff.lua
# against the same 9 hard cases as diff_proto_test.lua.
#   bash proto/run_port_test.sh
set -e
cd "$(dirname "$0")/.."
nvim --headless -u NONE \
  --cmd "set runtimepath+=." \
  -c "luafile proto/port_test.lua"

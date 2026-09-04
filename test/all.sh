#!/usr/bin/env bash
# 跑全部测试。用法: bash test/all.sh [modmain路径]
set -e
cd "$(dirname "$0")/.."
PY="${PY:-C:/Users/yunlongzhao/.workbuddy/binaries/python/envs/default/Scripts/python.exe}"
TARGET="${1:-modmain.lua}"
"$PY" test/runner.py harness.lua "$TARGET"
"$PY" test/runner.py client.lua  "$TARGET"
"$PY" test/runner.py bench.lua   "$TARGET"

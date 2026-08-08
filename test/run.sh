#!/bin/sh
# Run the assistant.koplugin test suite.
# Usage: ./test/run.sh          (run all tests)
#        ./test/run.sh exttools (run a single module)
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd /usr/lib/koreader
exec /usr/lib/koreader/luajit "$PROJECT_DIR/test/run_tests.lua" "$PROJECT_DIR" "$@"
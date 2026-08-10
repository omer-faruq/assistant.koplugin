#!/bin/sh
# Run assistant.koplugin UI widget tests via KOReader's wbuilder environment.
# Usage: ./test/runui.sh               (default: model_picker)
#        ./test/runui.sh model_picker  (run a specific test)
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

TEST_NAME="${1:-model_picker}"

# KO_MULTIUSER ensures DataStorage uses ~/.config/koreader/ for cache/settings
# instead of the current directory (which may be read-only /usr/lib/koreader).
export KO_MULTIUSER=1

cd /usr/lib/koreader
exec /usr/lib/koreader/luajit "$PROJECT_DIR/test/${TEST_NAME}.lua"

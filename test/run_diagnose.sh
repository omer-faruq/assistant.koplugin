#!/bin/sh
# Run an optional lua-language-server diagnostic scan over the assistant.koplugin
# source tree. The LSP is not part of KOReader's runtime, so this step is skipped
# gracefully when no server is installed.
#
# Usage: ./test/run_diagnose.sh         (defaults to Warning)
#        ./test/run_diagnose.sh Information

# Run the assistant.koplugin static diagnose step: try the Lua language
# server if it is installed, otherwise report that it was skipped.
# Optional, and kept separate from the LuaJIT test suite in run.sh.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LEVEL="${1:-Warning}"

# Locate a lua-language-server binary, without assuming a specific install path.
LUA_LS=""
for candidate in \
    "lua-language-server" \
    "/usr/bin/lua-language-server" \
    "/usr/local/bin/lua-language-server" \
    ; do
    if command -v "$candidate" >/dev/null 2>&1; then
        LUA_LS="$candidate"
        break
    elif [ -x "$candidate" ]; then
        LUA_LS="$candidate"
        break
    fi
done

# Search a few common per-user locations (Zed, VS Code, VS Code Server,
# opencode, etc.) if the server is not on PATH.
if [ -z "$LUA_LS" ]; then
    for name in \
        "$HOME/.cache/lua-language-server/lua-language-server" \
        "$HOME/.local/bin/lua-language-server" \
        ; do
        if [ -x "$name" ]; then
            LUA_LS="$name"
            break
        fi
    done
fi

if [ -z "$LUA_LS" ]; then
    # Fall back to a best-effort recursive search under per-user caches and
    # editor extensions. Keeps the list opt-in and bounded to common roots.
    found=$(find "$HOME/.cache" "$HOME/.local" -type f -name lua-language-server -perm -111 2>/dev/null | head -n 1)
    if [ -n "$found" ] && [ -x "$found" ]; then
        LUA_LS="$found"
    fi
fi

if [ -z "$LUA_LS" ]; then
    printf '%s\n' "lua-language-server not found; skipping diagnostic scan."
    exit 0
fi

CONFIG="$PROJECT_DIR/.luarc.json"
LOGDIR="${TMPDIR:-/tmp}/assistant_luaserver_log"
METADIR="${TMPDIR:-/tmp}/assistant_luaserver_meta"
mkdir -p "$LOGDIR" "$METADIR"

printf '%s\n' "Running lua-language-server diagnostic scan with $LUA_LS ..."
"$LUA_LS" \
    --check="$PROJECT_DIR" \
    --configpath="$CONFIG" \
    --check_format=pretty \
    --checklevel="$LEVEL" \
    --logpath="$LOGDIR" \
    --metapath="$METADIR"
STATUS=$?

if [ "$STATUS" -eq 0 ]; then
    printf '%s\n' "Diagnostic scan: no problems found."
else
    printf '%s\n' "Diagnostic scan: problems found (exit $STATUS)."
fi

exit "$STATUS"
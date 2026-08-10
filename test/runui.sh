#!/bin/sh
# Run assistant.koplugin UI widget tests via KOReader's wbuilder environment.
# Usage: ./test/runui.sh [OPTIONS] [test_name]
#        ./test/runui.sh model_picker                  (default)
#        ./test/runui.sh -w=1072 -h=1448 -d=300 model_picker
#        ./test/runui.sh -s=kobo-clara model_picker
#
# Options:
#   -w, --screen-width=X    Set width (default: 600)
#   -h, --screen-height=X   Set height (default: 800)
#   -d, --screen-dpi=X      Set DPI (default: unset, uses system default)
#   -s, --simulate=DEVICE   Simulate a known device:
#                           kobo-clara, kobo-forma, kobo-aura-one, kobo-h2o,
#                           kindle-paperwhite, kindle, hidpi
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Defaults (matching kodev run defaults)
SCREEN_WIDTH=600
SCREEN_HEIGHT=800
SCREEN_DPI=""

# Parse options
while [ $# -gt 0 ]; do
    case "$1" in
        -w=*|--screen-width=*) SCREEN_WIDTH="${1#*=}"; shift ;;
        -h=*|--screen-height=*) SCREEN_HEIGHT="${1#*=}"; shift ;;
        -d=*|--screen-dpi=*) SCREEN_DPI="${1#*=}"; shift ;;
        -s=*|--simulate=*)
            case "${1#*=}" in
                kobo-clara|kindle-paperwhite) SCREEN_WIDTH=1072; SCREEN_HEIGHT=1448; SCREEN_DPI=300 ;;
                kobo-forma) SCREEN_WIDTH=1440; SCREEN_HEIGHT=1920; SCREEN_DPI=300 ;;
                kobo-aura-one) SCREEN_WIDTH=1404; SCREEN_HEIGHT=1872; SCREEN_DPI=300 ;;
                kobo-h2o) SCREEN_WIDTH=1080; SCREEN_HEIGHT=1429; SCREEN_DPI=265 ;;
                kindle) SCREEN_WIDTH=600; SCREEN_HEIGHT=800; SCREEN_DPI=167 ;;
                hidpi) SCREEN_WIDTH=1500; SCREEN_HEIGHT=2000; SCREEN_DPI=600 ;;
                *) echo "Unknown device: ${1#*=}" >&2; exit 1 ;;
            esac
            shift ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) break ;;
    esac
done

TEST_NAME="${1:-model_picker}"

export KO_MULTIUSER=1
export EMULATE_READER_W="${SCREEN_WIDTH}"
export EMULATE_READER_H="${SCREEN_HEIGHT}"
if [ -n "${SCREEN_DPI}" ]; then
    export EMULATE_READER_DPI="${SCREEN_DPI}"
fi

cd /usr/lib/koreader
exec /usr/lib/koreader/luajit "$PROJECT_DIR/test/${TEST_NAME}.lua"

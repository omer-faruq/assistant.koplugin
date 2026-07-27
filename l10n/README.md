# Multi-language support

The plugin uses the same language translation logic as KOReader.

## How it Works

The localization process uses standard `gettext` tools (`.pot` template file and `.po` language files).

- `templates/koreader.pot`: The template file containing all translatable strings from the source code.
- `<LANG_CODE>/koreader.po`: The translation file for a specific language.

The `Makefile` in this directory automates the gettext part of the pipeline
(extract → merge → compile → check). AI translation is handled by the
`ai_translate.py` Python script.

`AI_TRANSLATE.sh` is the older bash implementation; it remains in the
repository for historical reference and is **not** invoked by the
`Makefile` anymore. New development targets `ai_translate.py`.

## Env and Tools

Install the system and Python dependencies (Debian/Ubuntu):

    sudo apt install gettext make python3 python3-dotenv python3-requests python3-polib

`curl` and `jq` are **no longer required** — the new script uses
`requests` and the Python standard library.

Create an `.env` file in this directory with the following variables
(required unless noted):

    API_ENDPOINT=https://api.openai.com/v1/chat/completions
    API_MODEL=gpt-4o-mini
    API_KEY=sk-...

Optional tuning variables (defaults shown):

    AI_CHUNK_SIZE=20        # msgids per API request (smaller = safer, slower)
    AI_MAX_TOKENS=4096      # max response tokens per chunk
    AI_REQUEST_TIMEOUT=120  # per-request HTTP timeout, in seconds
    AI_MAX_RETRIES=8        # retries on 429 / 5xx / network errors
    AI_MAX_CHUNK_TIME=900   # hard cap on total seconds spent per chunk

On any retry, the script logs a one-liner with the reason (e.g. `HTTP 429`,
`network:ReadTimeout`) and the backoff duration, so long runs remain
observable.

## How translation avoids output truncation

The previous bash version asked the LLM to emit a full `.po` file as
free-form text. When the model hit its output-token cap (the
`finish_reason=length` you used to see), the response was silently
truncated and the whole language batch failed.

`ai_translate.py` avoids that problem with three layered defenses:

1. **JSON-in / JSON-out contract.** The model is asked to return a
   `{"translations": [...]}` object — never an entire `.po` file.
   The script validates the structure strictly, so a malformed response
   fails fast instead of being written to disk.
2. **Chunking.** Each request covers at most `AI_CHUNK_SIZE` msgids
   (default 20). Output size is well under any provider's cap.
3. **Automatic bisection on truncation.** If a chunk still gets
   `finish_reason=length`, the script splits it in half and retries
   until every entry is translated. Progress is saved after every chunk
   to `<output>.partial`, so any crash / Ctrl-C / network failure is
   fully resumable — just re-run `make translate`.

## Usage

Verify the API works before kicking off a batch:

    make check-api        # or: ./ai_translate.py --check-api

Translate a single language:

    make ai-translate-fr  # or: ./ai_translate.py fr

Run the full pipeline (extract → translate → merge → check → clean):

    make translate

Detect drift between this project and KOReader's supported languages:

    make check-langs

Force a single-language run from the command line:

    L10N_LANG=de make ai-translate

## Updating Translations

When the source code changes, new strings might be added or modified. To update all language files:

    make

If the run is interrupted (Ctrl-C, network failure, etc.), just re-run
`make`; the Python script will resume from the most recent partial state
for any language that did not complete.

## Notes on KOReader language sync

The list of supported languages lives in two places and must stay in
sync:

- `Makefile`'s `LANGS` variable
- `ai_translate.py`'s `LANG_MAP` dictionary

Both should also match the directories under KOReader's `l10n/`
installation (`/usr/lib/koreader/l10n/`). Use `make check-langs` to
detect any drift, and override the reference path with
`KOREADER_L10N_DIR=/path/to/l10n make check-langs` if KOReader is
installed elsewhere.

# Multi-language support

The plugin uses the same language translation logic as KOReader.

## How it Works

The localization process uses standard `gettext` tools (`.pot` template file and `.po` language files).

- `templates/assistant.pot`: The template file containing all translatable strings from the source code.
- `<LANG_CODE>/assistant.po`: The translation file for a specific language.
- `<LANG_CODE>/assistant.mo`: The compiled catalogue, committed alongside the `.po` and shipped in the release.

The `Makefile` automates the gettext part of the pipeline (extract → merge → compile
→ check). AI translation is handled by `ai_translate.py`; `check_mix.py` audits
the results. See `Auditing the catalogues` below.

## Env and Tools

Install the system and Python dependencies (Debian/Ubuntu):

    sudo apt install gettext make python3 python3-dotenv python3-requests python3-polib

Create an `.env` file in this directory with the following variables
(required unless noted):

    API_ENDPOINT=https://api.openai.com/v1/chat/completions
    API_MODEL=gpt-4o-mini
    API_KEY=sk-...

Optional tuning variables (defaults shown):

    AI_CHUNK_SIZE=20        # msgids per API request (smaller = safer, slower)
    AI_MAX_TOKENS=8192      # max response tokens per chunk
    AI_REQUEST_TIMEOUT=120  # per-request HTTP timeout, in seconds
    AI_MAX_RETRIES=8        # retries on 429 / 5xx / network errors
    AI_MAX_CHUNK_TIME=900   # hard cap on total seconds spent per chunk
    RANDOM_SESSION_ID=      # stable id sent as x-opencode-session, only when
                             # API_ENDPOINT contains "opencode.ai". The Makefile
                             # generates one per run; direct script runs get a
                             # per-process fallback.

On any retry, the script logs a one-liner with the reason (e.g. `HTTP 429`,
`network:ReadTimeout`) and the backoff duration, so long runs remain
observable.

## The response contract

The model is asked for a JSON object per chunk, never a whole `.po` file, and
each answer is checked before it reaches the catalogue. Four layers:

1. **Strict JSON.** The response must be `{"translations": [...]}`. A malformed
   one fails fast instead of being written to disk.
2. **Id-keyed answers.** Each element is `{"id": N, "text": "..."}` and must
   carry the id of the request item it translates. Order carries no meaning, so
   the response cannot drift out of alignment; a missing, duplicated or invented
   id is a hard error the retry and bisect paths already handle.
3. **Chunking.** Each request covers at most `AI_CHUNK_SIZE` msgids (default
   20), keeping output well under any provider's token cap.
4. **Bisection on truncation.** A chunk that comes back `finish_reason=length`
   is split in half and retried until every entry is translated. Progress is
   saved after every chunk to `<output>.partial`, so any crash, Ctrl-C or
   network failure is fully resumable — just re-run `make translate`.

### Why id-keying, and what else is validated

A positional array has the right length even when the model has translated a
different item, so a shifted answer is indistinguishable from a good one by
length alone. Keying by id turns that into an error the retry path handles, and
bisection then re-asks for the offending entry on its own.

Every answer is also checked against the msgid it claims to translate:

- it must carry the same `<b>` tags — invariant 4 in the root `AGENTS.md` makes
  that non-negotiable, since `bold_format` parses them rather than rendering
  them as HTML
- it must not carry a `%N` that no source form of the msgid has

Both conditions are footprints of the same failure: when the model answers with
another msgid's translation, the tags and placeholders of the msgid it was
actually given are the ones that go missing. Together they reject 5 of the
25354 committed translations and nothing else.

Two things are deliberately **not** rejected, because rejecting them would retry
a chunk that can never satisfy the check:

- **a `%N` in a singular plural-form.** gettext picks the form from `n` at
  runtime, so every form may carry whatever any source form carries. A singular
  form mentioning `%1` is grammatical sloppiness, not a wrong-slot answer.
- **`%s` and `%d`.** The plugin mixes `string.format` with `T()` (see
  `assistant_hooks.lua`), so a msgid's own conversion style is a per-call-site
  choice that cannot be judged from the catalogue.

## Usage

Verify the API works before kicking off a batch:

    make check-api        # or: ./ai_translate.py --check-api

Translate a single language:

    L10N_LANG=fr make ai-translate      # or: make ai-translate-fr

Both forms depend on `extract-untranslated`, so a single-language run works on a
clean tree. `extract-untranslated` skips a language whose `untranslated.po` is
already newer than its catalogue, so naming one language repeatedly does not
re-translate what is already done.

Run the full pipeline (extract → translate → merge → check → clean → mo):

    make translate

Detect drift between this project and KOReader's supported languages, and
validate the `LANG_MAP` / `LANG_EN` / `PLURAL_FORMS` tables against the
catalogues on disk:

    make check-langs

Audit every catalogue for translations written in the wrong language or in the
wrong slot:

    make check-mix
    make check-mix CHECK_MIX_ARGS=--list

Retranslate one exact msgid everywhere (e.g. after a terminology fix — empties it
in all `.po` files, then runs it back through the pipeline):

    make retranslate-msgid MSGID="OpenAI-compatible Chat Completions API"
    L10N_LANG=ja make retranslate-msgid MSGID="OpenAI-compatible Chat Completions API"

## Per-language translator notes

`<LANG_CODE>/ai_note.txt` is optional. When present, its contents are appended to
the system prompt for that language and take precedence over the general guidance.
Use it for terminology, style rules, and — most importantly — warnings about a
language the model is likely to confuse with a neighbour.

The file is plain text with no required structure, so a native speaker can fix or
extend their own locale's note without touching `ai_translate.py`. That is the
point: diagnosing a wrong-language catalogue needs someone who reads the
language, and it should not require them to edit Python.

The prompt already names the language three ways (English name from `LANG_EN`,
endonym from `LANG_MAP`, locale code); a note is for what those three cannot
express. `sk/ai_note.txt` is the worked example — Slovak's endonym
`slovenčina` reads literally as "Slovene", so the note warns against Slovenian
and lists the distinguishing letters (`ľ ĺ ŕ ô ť ď ň`) and the
genitive-vs-dative tells. `sl`, `nb_NO` and `nn` carry mirrored notes.

`ai_note.txt` is excluded from the release archive in `.releaseignore`; it is
tooling input, not runtime data.

## Auditing the catalogues

`make translate` only fills **empty** msgstr, so a string that came back wrong —
in the wrong language, or the translation of a different msgid — counts as done
forever. Both failure modes are self-sealing, and nothing in the pipeline
distinguishes a hand-patched or wrong-language string from a good one.

**Never hand-edit a `.po` to correct a translation. Empty the msgstr** and let
the pipeline refill it.

`check_mix.py` (via `make check-mix`) is the guard. All three of its signals need
no knowledge of the target language:

- **A. Calibrated agreement** compares, for each pair of same-script locales, how
  often *our* two catalogues agree against how often KOReader's own reviewed
  `koreader.mo` catalogues agree. The upstream rate is the baseline two real
  languages are expected to hit, so it self-normalizes per pair — no dictionary,
  no hand-tuned threshold, no false positives from merely-related languages. Set
  `KOREADER_L10N_DIR` if KOReader lives elsewhere.
- **B. Sibling identical** is the raw count of msgstr shared byte-for-byte with
  another locale. It needs no upstream and covers every entry, including the
  ~90% of msgids that have no upstream counterpart.
- **C. Structural loss** flags a msgstr that dropped a `<b>` tag the msgid has, or
  that carries a `%N` no source form of the msgid has. This is the offline mirror
  of `ai_translate._check_markup`, and it is what surfaces a wrong-slot answer.

Findings are a **triage list, not a verdict**. A pair can score high while the
flagged wording is correct for that language — `es` and `gl` share 21 of 39
strings and every one of them is the same word in both, and KOReader's own
catalogues agree. Always read the `koreader <lang>` column before acting.

To clear the entries a locale got wrong, so the next run refills them:

    ./check_mix.py --empty sk --peer sl           # sk's Slovenian strings
    ./check_mix.py --empty de --structural       # dropped <b> tags
    make ai-translate && make mo

`--peer` is required, and an entry is only cleared when all three hold: our two
catalogues agree on it, KOReader's catalogue disagrees with it for the target
language, and KOReader's catalogue confirms it for the peer. That is what keeps
the innocent side of a pair from being emptied — run it the wrong way round and
you delete the correct translations.

Run `./check_mix.py --check-data` to validate the `LANG_MAP` / `LANG_EN` /
`PLURAL_FORMS` tables against the catalogues on disk; `make check-langs` runs it
as part of its language-drift check.

## Updating Translations

When the source code changes, new strings might be added or modified. To update
all language files:

    make

If the run is interrupted (Ctrl-C, network failure, etc.), just re-run `make`;
the Python script resumes from the most recent partial state for any language
that did not complete.

## Notes on KOReader language sync

The list of supported languages lives in `Makefile`'s `LANGS` and in
`ai_translate.py`'s `LANG_MAP`, and must stay in sync with each other and with
the directories under KOReader's `l10n/` installation (`/usr/lib/koreader/l10n/`).
`LANG_EN` (English names) and `PLURAL_FORMS` must cover the same set; the prompt
is built from all four. `make check-langs` detects any drift, and
`KOREADER_L10N_DIR=/path/to/l10n make check-langs` overrides the reference path.

`PLURAL_FORMS` for `sk`, `uk` and `lt_LT` is `nplurals=3`, which differs from
KOReader's own headers for those languages: upstream ships `nplurals=4` with a
no-op `n % 1 == 0` guard wrapped around the Czech three-form rule, leaving form 3
unreachable. All three are genuinely three-form languages. gettext reads
`Plural-Forms` from the header of the catalogue being loaded and `msgfmt` bakes
`nplurals` into the `.mo`, so a self-consistent header is all that matters here.

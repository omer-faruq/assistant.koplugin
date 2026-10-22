# Multi-language support

The plugin uses the same language translation logic as KOReader.

## How it Works

The localization process uses standard `gettext` tools (`.pot` template file and `.po` language files).

- `templates/assistant.pot`: The template file containing all translatable strings from the source code.
- `<LANG_CODE>/assistant.po`: The translation file for a specific language.
- `<LANG_CODE>/assistant.mo`: The compiled catalogue, committed alongside the `.po` and shipped in the release.

The `Makefile` automates the gettext part of the pipeline (extract → merge → compile
→ check). AI translation is handled by `helper/ai_translate.py`, which also
validates the static language tables offline; `helper/review_translations.py`
runs the optional LLM review for every locale that ships a `review_note.txt`.
See `Auditing the catalogues` below.

The Python tools live in `helper/`; the `Makefile` targets are the supported
entry point. Direct `helper/...` invocations below are for debugging.

## Env and Tools

Install the system packages (Debian/Ubuntu):

    sudo apt install gettext make python3 python3-dotenv python3-polib python3-openai

`helper/ai_translate.py` talks to the API through the official `openai` Python SDK.
The scripts use the system `python3` via their shebang.

Create an `.env` file in this directory with the following variables
(required unless noted):

    API_PROTOCOL=chat_completions   # chat_completions (default) or responses
    API_BASE=https://api.openai.com/v1
    API_MODEL=gpt-4o-mini
    API_KEY=sk-...

`API_PROTOCOL` selects the wire format the SDK adapter uses: `chat_completions`
(default) calls the Chat Completions API, `responses` calls the OpenAI Responses
API. It is explicit config, never inferred from the base URL. `API_BASE` is the
base URL of the OpenAI-compatible API and defaults to
`https://api.openai.com/v1`; the protocol appends its own path
(`/chat/completions` or `/responses`) to form the full endpoint. The base must
not already carry those path suffixes.

`.env` is gitignored (see `.gitignore`) and excluded from the release archive, so
real keys never get committed. Create the file locally and do not commit it.

### Per-locale overrides

A locale may override any of the global values with its own `.env` next to its
catalogue, `l10n/<lang>/.env` (for example `l10n/sk/.env`). It uses the same
variable names as the global file - `API_PROTOCOL`, `API_BASE`,
`API_MODEL`, `API_KEY` - not a `_<LANG>` suffix.

`helper/ai_translate.py` resolves each setting with this precedence, highest first:

1. the exported process environment,
2. `l10n/<lang>/.env` when one exists for the locale,
3. the global `l10n/.env`.

A blank value is ignored at every layer, so an empty entry in a locale file
leaves the global value in place rather than erasing it. Only the route an
invocation actually uses has to be complete.

For example, the Slovak route migrates to the Responses API against OpenCode
while every other locale keeps the globals. Put this in `l10n/sk/.env`:

    API_PROTOCOL=responses
    API_BASE=https://opencode.ai/inference/go/v1
    API_MODEL=grok-4.7
    # API_KEY unset: the global API_KEY is used

`./helper/ai_translate.py sk` reads `l10n/sk/.env` layered over `l10n/.env`; every
other locale reads the global file alone. The global `API_PROTOCOL=...` selects
the wire format for every locale that does not override it, and a locale's own
`API_PROTOCOL` overrides it for that locale only. Ping one locale's route with
`./helper/ai_translate.py --check-api-lang sk`, or the global default with
`./helper/ai_translate.py --check-api`.

Optional tuning variables (defaults shown). These may be exported, or placed in
the global `.env` or a locale's `.env`; the same precedence applies:

    AI_CHUNK_SIZE=20        # msgids per API request (smaller = safer, slower)
    AI_MAX_TOKENS=8192      # max response tokens per chunk
    AI_REQUEST_TIMEOUT=120  # per-request timeout handed to the SDK, in seconds
    AI_MAX_RETRIES=8        # retries the SDK performs on 429 / 5xx / network errors
    RANDOM_SESSION_ID=      # stable id sent as x-opencode-session, only when
                             # API_BASE contains "opencode.ai". The Makefile
                             # generates one per run; direct script runs get a
                             # per-process fallback.

There is no `AI_MAX_CHUNK_TIME`: `helper/ai_translate.py` hands the request timeout and
the retry count to the SDK, which owns backoff and the per-request deadline, so
the script no longer enforces a separate wall-clock cap per chunk. Set
`AI_LOG_LEVEL=DEBUG` (or `AI_DEBUG=1`) to surface the SDK's own retry logs.

The optional LLM reviewer is a second model reached through the same SDK layer as
`helper/ai_translate.py`, defaulting to the Responses protocol. Its route comes from the
dedicated `L10N_REVIEW_API_PROTOCOL` / `L10N_REVIEW_API_BASE` /
`L10N_REVIEW_API_MODEL` / `L10N_REVIEW_API_KEY` keys (process environment,
`l10n/<lang>/.env` or `l10n/.env`), while the JSON-schema mode and timeout/retry
policy are the shared `AI_JSON_SCHEMA` / `AI_REQUEST_TIMEOUT` / `AI_MAX_RETRIES`
knobs; see `LLM review of the AI output` below.

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
   saved after every chunk to `<LANG_CODE>/assistant.po.partial`, so any crash, Ctrl-C or
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

    make check-api                          # or: ./helper/ai_translate.py --check-api
    ./helper/ai_translate.py --check-api-lang sk   # a locale's own protocol/route
    make list-models                        # or: ./helper/ai_translate.py --list-models [lang]

Translate a single language:

    L10N_LANG=fr make ai-translate

`ai-translate` translates every locale whose catalogue has empty or fuzzy
entries; a locale with nothing pending is skipped. Run `make update` first (or
`make translate`) so the catalogue reflects the current source.

Run the full pipeline (template → update → translate → review → check → clean →
mo). `make` alone runs the same pipeline (`all` depends on `translate`):

    make translate
    make

Bare `make` also reviews the entries changed by the run in every locale that
ships a `review_note.txt`. The reviewer works on `<LANG_CODE>/assistant.po`,
empties exactly the entries it confidently marks `repair`, and sends only those
back through `helper/ai_translate.py`. A locale without a note is never reviewed
or touched. `make check` never runs the reviewer. See `LLM review of the AI
output` below.

Detect drift between this project and KOReader's supported languages, and
validate the `LANG_MAP` / `LANG_EN` / `PLURAL_FORMS` tables against the
catalogues on disk:

    make check-langs

Review a locale's LLM output for wrong-language or wrong-meaning entries with a
second model (the normal pipeline refills what it flags; only locales with a
`review_note.txt` are reviewed, see `LLM review of the AI output` below):

    ./helper/review_translations.py                 # review sk/assistant.po (default lang)
    ./helper/review_translations.py --lang sl       # review sl/assistant.po
    ./helper/review_translations.py --full          # read-only audit of sk/assistant.po
    make review-hooked                       # full read-only audit of every hooked locale

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
extend their own locale's note without touching `helper/ai_translate.py`. That is the
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

`make translate` only fills **empty or fuzzy** msgstr, so a string that came back wrong —
in the wrong language, or the translation of a different msgid — counts as done
forever. Both failure modes are self-sealing, and nothing in the pipeline
distinguishes a hand-patched or wrong-language string from a good one.

**Never hand-edit a `.po` to correct a translation. Empty the msgstr** and let
the pipeline refill it: clear the wrong msgstr (by hand, or let the LLM reviewer
do it — see below), then re-run `make ai-translate` and `make mo`.

Two deterministic checks guard what can be judged without knowing the target
language:

- **Wrong-slot answers** are caught at request time. `helper/ai_translate.py` validates
  every answer against the msgid it claims to translate (`_check_markup`): the
  translation must carry the msgid's `<b>` tags and must not carry a `%N` index
  that no source form of the msgid has. Both are the footprint of the model
  answering with a different msgid's translation. A bad answer fails the chunk
  and is retried, then bisected, so it never reaches the catalogue. Placeholder
  movement and `%s` / `%d` are left alone — the plugin mixes `string.format`
  with `T()`, so a msgid's own conversion style is a per-call-site choice.
- **The static language tables** are checked offline by
  `./helper/ai_translate.py --check-data`, which `make check-langs` runs. It confirms
  `LANG_MAP`, `LANG_EN` and `PLURAL_FORMS` all cover the same locales, that every
  `.po` header agrees with `PLURAL_FORMS` on `nplurals`, and that every plural
  entry declares exactly `nplurals` forms.

Neither catches a translation that is simply in the wrong language or says the
wrong thing; that is what the LLM review below is for.

### LLM review of the AI output (second model)

`make translate` runs `review-translations` as its fourth step, after
`ai-translate` and before `check`. `ai-translate` leaves a pre-run copy at
`<LANG_CODE>/assistant.po.pre-ai`, so for every locale that ships
`l10n/<LANG_CODE>/review_note.txt` (currently only `sk`) the reviewer sees only
the entries this run changed, not the whole catalogue. A locale without a note
is never discovered, looped or reviewed, and its catalogue ships unchanged. A
hooked locale with no changed entries this run is skipped.

Unlike the deterministic signals above, this is a model judgement. It answers one
question - is this msgstr correct for the target language? - and returns only a
per-entry verdict, never a rewritten translation:

- `pass` - correct in the target language and meaning what the msgid says.
- `repair` - a strong, explicit wrong-language or wrong-meaning finding. Reserved
  for that; a short or ambiguous string abstains instead.
- `abstain` - too short, a proper noun or a technical token, or otherwise not
  judgeable with confidence.

`helper/review_translations.py` reviews the catalogue in **chunks**
(`L10N_REVIEW_CHUNK_SIZE`, default 50 entries), one request per chunk, not one
call per msgid. The system message carries the judgement rubric and the output
contract; each user message carries the target language name from `LANG_EN`, the
locale's `review_note.txt` and its slice of the compact entry list, so every
chunk is self-contained. The answer is requested as structured output against a
strict verdict schema, so the reply is a bare JSON object; a missing, extra or
duplicate id, a malformed reply or a truncated chunk fails the whole pass closed.

An entry is only ever emptied, never hand-edited. The msgstr flagged `repair` is
cleared in the catalogue and `helper/ai_translate.py` refills it under its own
validation - only empty or fuzzy entries are filled, so good translations stay. A run is:

1. **no `repair` verdicts** - one chunked reviewer pass; check continues with
   the translated catalogue.
2. **`repair` verdicts** - clear exactly those msgstr, run `helper/ai_translate.py
   <LANG_CODE>` once, then make one final chunked reviewer pass. A `repair`
   verdict that survives the refill stops the run **before check** (exit 3) and
   preserves the catalogue. It never loops.
3. **a setup failure** - no `review_note.txt`, no `L10N_REVIEW_API_KEY`, an
   authentication error, a timeout or an invalid reply - warns and keeps the AI
   output. The review is best-effort: it hands the pipeline a better catalogue
   and never stops a translation run for its own problems.

A locale is reviewed only when it ships a `review_note.txt`, so `make check` never
invokes the reviewer; the deterministic checks in `helper/ai_translate.py` and
`make check-langs` keep working with no model, network or API account.

#### Per-locale review note

`l10n/<LANG_CODE>/review_note.txt` is the opt-in: a locale is reviewed only when
it ships one. The note carries the guidance the reviewer needs to tell the target
language apart from the languages it is confused with, and its format is free
text. `sk/review_note.txt` is the worked example - it warns that the endonym
`slovenčina` reads like "Slovene", lists the Slovak-only letters (`ľ ĺ ŕ ô ť ď
ň`) and the genitive-vs-dative ending, and gives the Slovenian-only words that
justify a `wrong_language` verdict (`Uporabi`, `Prevajanje`, `Prilagojeni
pozivi`) against their Slovak equivalents (`Použiť`, `Preklad`/`Preložiť`,
`Vlastné prompty`). A native speaker can add or fix their own locale's note
without touching Python. The translator note (`<LANG_CODE>/ai_note.txt`) is
separate; it feeds `helper/ai_translate.py`, not the reviewer.

The `Makefile` hook set, `REVIEW_HOOKED`, is every `LANGS` entry that has both
`review_note.txt` and `assistant.po`; the pipeline and the `review-*` targets
operate on exactly that set.

`review_note.txt` is excluded from the release archive in `.releaseignore`; it is
tooling input, not runtime data.

#### Reviewer route and model

The reviewer is a second model, reached through the same OpenAI-compatible SDK
layer as the translator (`llm_client.Config` + `request`) rather than a
CLI. It defaults to the **Responses** protocol and reads a dedicated route:

    L10N_REVIEW_API_PROTOCOL=responses   # chat_completions or responses
    L10N_REVIEW_API_BASE=<base URL>      # defaults to https://api.openai.com/v1
    L10N_REVIEW_API_MODEL=<model>        # the second model
    L10N_REVIEW_API_KEY=<key>

These resolve through the same loader as the translator (process environment,
then `l10n/<LANG_CODE>/.env`, then `l10n/.env`), so a locale can point its review
at a different provider or model than its translation. The shared
`AI_JSON_SCHEMA`, `AI_REQUEST_TIMEOUT` and `AI_MAX_RETRIES` knobs control the
structured-output mode, the per-request timeout and the retry policy, exactly as
for translation:

    L10N_REVIEW_CHUNK_SIZE=50            # entries per reviewer request
                                         # (default 50; a non-numeric or
                                         # non-positive value warns and falls
                                         # back to the default)
    L10N_REVIEW_CONCURRENCY=4            # review requests run in parallel
                                         # (default 4; a non-numeric or
                                         # non-positive value warns and falls
                                         # back to the default)
    L10N_REVIEW_MAX_RETRIES=2            # retries per failed review chunk
                                         # (default 2, i.e. up to 3 attempts;
                                         # a non-numeric or non-positive value
                                         # warns and falls back to the default)

Each request carries at most this many entries, so a large catalogue is reviewed
as several self-contained requests instead of one that can overflow the model's
output budget. The requests run concurrently up to `L10N_REVIEW_CONCURRENCY`
(default 4). A chunk that fails (transport error, truncation, refusal, empty or
invalid verdicts) is retried up to `L10N_REVIEW_MAX_RETRIES` times (default 2,
so up to 3 attempts) before it fails the whole pass; cancellation of requests
that have not yet started but leaving in-flight ones to finish stays as
described above. The script's `--model` and `--timeout` override the route's model
and the request timeout; the locale is selected with `--lang <code>` (default
`sk`).

The reviewer needs no OpenCode account: it uses the key you configure above. The
review sends the locale's public UI strings and the context around them to that
provider, so its data-retention and billing policy applies. Opt a locale in only
when that is acceptable.

#### Full-catalogue audit (read-only)

The normal pipeline reviews only the entries changed by this run, never the whole
committed catalogue. To audit the whole historical catalogue of every hooked locale once:

    make review-hooked                 # chunked reviewer pass per hooked locale, no writes
    ./helper/review_translations.py --lang sk --full

`--full` reviews `<LANG_CODE>/assistant.po` and prints the per-status report; it
clears nothing and runs no translator. The report is a triage list, not a
verdict: read the `repair` rows before acting. **No full retranslation has been
run against the result of this audit** - it is a historical check, and acting on
it is a separate, deliberate step.

#### Outages and failures

The review is optional and never blocks a normal `make`. If the reviewer route's
key is missing or rejected, the account is out of quota, the call times out, or
the reply is malformed, the step prints a warning and the pipeline imports the AI
output unchanged. The only non-zero outcome is a `repair` verdict that survives
the single refill, which stops the run before check so the flagged catalogue can
be inspected. There is no retry loop.

## Updating Translations

When the source code changes, new strings might be added or modified. To update
all language files:

    make

`make` (default goal `translate`) reviews the entries changed by the run in every
locale that ships a `review_note.txt` after `ai-translate`; a locale without a note, or a run
without a configured reviewer route, is skipped with a warning, and `make check`
never runs the reviewer.

If the run is interrupted (Ctrl-C, network failure, etc.), just re-run `make`;
the Python script resumes from the most recent partial state for any language
that did not complete.

## Notes on KOReader language sync

The list of supported languages lives in `Makefile`'s `LANGS` and in
`helper/lang_data.py`'s `LANG_MAP`, and must stay in sync with each other and with
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

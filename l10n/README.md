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

Run the full pipeline (template → update → extract → translate → jev-check →
import → check → clean → mo). `make` alone runs the same pipeline (`all` depends
on `translate`):

    make translate
    make

Bare `make` also Jev-checks the AI output of every locale that opts in with
`<LANG_CODE>/jev_note.txt`. It audits `updated_translated.po` right after
`ai-translate`, empties the entries the classifier confidently places in the
peer language, and sends only those back through `ai_translate.py`. It makes Jev
requests only for those hooked locales, and only when `API_JEV_ENDPOINT` and
`API_KEY` are set. `make check` and `make check-mix` never make a Jev request.
See `Jev check of the AI output (the pipeline step)` below.

Detect drift between this project and KOReader's supported languages, and
validate the `LANG_MAP` / `LANG_EN` / `PLURAL_FORMS` tables against the
catalogues on disk:

    make check-langs

Audit every catalogue for translations written in the wrong language or in the
wrong slot:

    make check-mix
    make check-mix CHECK_MIX_ARGS=--list

Audit one locale for translations written in a *different* language with the
optional Jev classifier (opt-in per locale, report-only unless `--retranslate-jev`
or `--jev-clear-only` is given; see `Language audit with Jev SystemOne` below):

    ./check_mix.py --jev sk
    ./check_mix.py --jev sk --retranslate-jev
    ./check_mix.py --jev sk --jev-clear-only

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

### Language audit with Jev SystemOne (optional)

`./check_mix.py --jev <lang>` is a third, opt-in audit that answers the one
question the signals above cannot: *is this msgstr actually written in the
target language?* It sends translated msgstrs (except strings identical to the
English msgid or containing only format placeholders) to the Jev SystemOne
decision model, each as its own typed `choice` question - target language / peer
language / unclear - and reports the entries the model confidently places in the
peer language.

To cut the request count, independent per-msgstr questions are packed into
batches of `JEV_BATCH_SIZE` (default 10, see below). Batching is a transport
optimisation only: every entry keeps its own question and its own answer, so one
entry's verdict never affects another's. It is **not** a screening gate - there
is no "is any entry in this batch wrong?" step that could pass a bad string
because its neighbours are clean. A batch reply is matched by question id; if
the answer map is missing an id, carries an extra one, or is otherwise
malformed, the whole batch fails closed and every entry in it is reported as an
error (never silently treated as clean), and no further requests are sent.

SystemOne is not a chat-completions API: a request carries a `state` and a map
of typed `questions`, and the answer is keyed by the question id. See
<https://jevapi.io/jev-api/> for the wire format. The configured endpoint and
key must be authorized for SystemOne; a Go or chat-completions subscription
credential is not accepted there.

`requests`, `python-dotenv` and the language tables are imported only when
`--jev` is used, so the deterministic A/B/C checks keep working without them.

#### Per-locale opt-in hook

A locale opts in by shipping `l10n/<LANG_CODE>/jev_note.txt`, the Jev analogue
of `ai_note.txt`. Without that file the locale is skipped: no request is sent
and nothing is written, in report, retranslate or clear-only mode. One locale
(and its hook-defined peer) is handled per invocation; there is no sweep across
locales.

The file is free text. One directive is recognized, `peer: <code>`, naming the
contaminating locale to test against; every other non-blank, non-`#` line is
distinguishing guidance embedded in the model's question. `sk/jev_note.txt` is
the worked example - it declares `peer: sl` and lists the Slovak/Slovenian
tells (the letters `ľ ĺ ŕ ô ť ď ň`, the genitive-vs-dative ending, and a short
Slovenian-only word list). A native speaker can extend their locale's hook
without touching Python. `--peer` overrides the hook's peer for an experiment.

A locale that ships a hook but names no peer (and is not given `--peer`) fails
before any request is sent: without a peer there is nothing to classify against.

`jev_note.txt` is excluded from the release archive in `.releaseignore`; it is
tooling input, not runtime data.

#### Setup

Prerequisites are the same as `ai_translate.py` (`python3-requests`,
`python3-polib`, `python3-dotenv`). Add the endpoint to `.env`; `API_KEY` is
reused from the block above as the Bearer credential:

    API_JEV_ENDPOINT=https://.../v1/systemone   # required for check_mix.py --jev
    API_KEY=sk-...                              # required, shared with ai_translate
    API_JEV_MODEL=jev-1.13-free                 # optional (default shown)

Optional tuning variables (defaults shown):

    JEV_REQUEST_TIMEOUT=60    # per-request HTTP timeout, in seconds (> 0, finite)
    JEV_MAX_RETRIES=5         # retries on 429 / 529 / 5xx / network errors (>= 1)
    JEV_BATCH_SIZE=10         # independent questions per request (1-100, default 10)
    JEV_MAX_RETRY_AFTER=60    # cap on a server Retry-After, in seconds (>= 0)
    JEV_MAX_PAID_REQUESTS=100 # paid-fallback HTTP attempt cap (>= 1)

A malformed `JEV_REQUEST_TIMEOUT`, `JEV_MAX_RETRIES`, `JEV_BATCH_SIZE`,
`JEV_MAX_RETRY_AFTER` or `JEV_MAX_PAID_REQUESTS` exits `2` with a diagnostic
naming the variable, before any request is sent. When `API_JEV_ENDPOINT` or
`API_KEY` is unset, the run prints a skip message and exits `0` without sending
a request. It never prints the key.

`JEV_MAX_RETRY_AFTER` bounds how long the audit will wait when a retryable
response (429 / 529 / 5xx) carries a `Retry-After`. A `Retry-After` longer than
this exits with a diagnostic instead of sleeping hours. A large `Retry-After`
is only ever an ordinary retryable response: it is never read as a quota signal
and never triggers a model switch.

#### Free model, paid fallback

The default `jev-1.13-free` is free only while its quota lasts. When an HTTP
`429` response's JSON body carries `error.type == "FreeUsageLimitError"` **and**
the active model is exactly `jev-1.13-free`, the run switches to the paid
`jev-1.13` model and restarts the **entire** audit from the first batch. Every
free-model judgment is discarded, so no mutation can mix the two models; each
classified row records the model that produced its verdict. The switch is
reported explicitly. It happens at most once per invocation: if the paid pass
also fails, the run ends as a normal failed batch (`--retranslate-jev` then
aborts before clearing anything).

Only that exact discriminator triggers the switch. A `429` whose `error.type`
is `RateLimitError` (a transient burst limit) retries the same model after
`Retry-After`/backoff; a non-JSON body, a differently shaped body, or any other
`error.type` is an ordinary retryable response and never falls back. The audit
never switches on HTTP status or `Retry-After` magnitude alone.

Paid fallback requests are capped by `JEV_MAX_PAID_REQUESTS` (default `100`),
counting real HTTP attempts (retries included) made by the paid fallback in one
invocation; free-model requests are never counted. The cap is a request guard,
not a dollar cap: paid input is billed at the provider's current pricing, so
the fallback stops before exceeding the cap rather than promising a spend
ceiling.

#### Report mode (read-only)

    ./check_mix.py --jev sk                          # report; peer from sk's hook
    ./check_mix.py --jev de --peer en                # override the hook's peer
    ./check_mix.py --jev sk --limit 50 --min-confidence 0.9
    ./check_mix.py --jev sk --list                   # print target/unclear rows too

Report mode never edits, empties or saves a catalogue and starts no translator.
`--limit N` audits at most `N` entries in msgid order (omitted audits all, and
an explicit `0` means the same) and is valid only in report mode; a negative
limit is rejected. `--min-confidence` and `--min-probability` (both default
`0.8`, and each must lie within `[0, 1]`) gate what counts as a confident peer
hit. A msgstr shorter than four characters - `Da` and `Ne` are the same word in
Slovak and Slovenian - is always reported as ambiguous and never flagged, and a
choice the model invents (anything other than target/peer/unclear) is treated
as unclear rather than a verdict.

#### Retranslate mode (opt-in, mutating)

    ./check_mix.py --jev sk --retranslate-jev

This is the single-command repair path. It classifies the whole catalogue
first, then, only if every request succeeded and at least one entry clears the
stricter mutation thresholds, empties exactly those entries and runs the
existing per-locale Make pipeline to refill them. It never writes a translation
itself: the msgstr is emptied (never hand-edited) and `ai_translate.py` refills
it under its own validation.

The mutation thresholds are higher than the report's, because clearing a good
translation costs a retranslation: by default the model's overall confidence
must be `>= 0.85` **and** the peer option's own probability `>= 0.90`
(`--retranslate-min-confidence` / `--retranslate-min-probability` override
them, and like the report thresholds each must lie within `[0, 1]`). Both
signals are required, so the known genuine Slovenian strings in
`sk` (confidence `.86`, `p(peer) .91`) qualify while a coin-flip between the
two languages does not. These are a starting point, not a law: if the peer
probability drifts (a model change, a different contaminant), re-check the
flagged rows by hand and recalibrate the two thresholds rather than trusting
the defaults blindly.

Only entries the model places in the peer language can be emptied; too-short,
identical, format-only, below-threshold, unclear and target rows are never
touched. When any plural form is flagged, every form of that entry is emptied,
because the pipeline only refills an entry once all of its forms are empty.

The run fails closed - clearing nothing and starting no translator - when:

- any Jev request failed (a partial verdict is not trusted). A failed batch
  records every entry in it as an error and stops all further requests, so a
  rate-limited endpoint is not hammered
- no entry cleared the mutation thresholds
- `git status` cannot be run or exits non-zero, so the target cannot be proven
  clean
- `git status` reports staged or unstaged changes to the target catalogue, or
  a previous run left pending intermediates such as `untranslated.po` or
  `updated_translated.po.partial` that clearing would overwrite.

#### Clear-only mode (the pipeline step)

    ./check_mix.py --jev sk --jev-clear-only
    ./check_mix.py --jev sk --jev-clear-only --intermediate

This is the clear step of retranslate mode **without** the nested pipeline. It
classifies the whole catalogue under exactly the same batch and paid-fallback
mechanics and the same stricter mutation thresholds (`>= 0.85` confidence and
`>= 0.90` peer probability), then empties only the confident peer-language
msgstr. It never starts Make: the ordinary pipeline it is already part of
refills the emptied entries under `ai_translate.py`'s own validation.

Clear-only is **best-effort**: it exists only to hand the outer pipeline a few
more entries to re-translate, so nothing it does may stop a translation run. A
failed or incomplete audit always clears nothing (the clear is all-or-nothing,
applied only after every request succeeds), and the outer pipeline continues.

`--jev-clear-only` requires `--jev <lang>` and cannot be combined with
`--retranslate-jev`, `--limit`, `--empty` or `--structural`. It runs the whole
catalogue, so no `--limit`. The manual `--retranslate-jev` command keeps its
strict fail-closed contract; only this pipeline step is lenient.

#### Jev check of the AI output (the pipeline step)

`make translate` runs `jev-check-translated` as its fifth step, after
`ai-translate` and before `import-translation`. It audits the LLM output
`<lang>/updated_translated.po`, not the live `assistant.po`, so the git-clean
gate does not apply: that catalogue is the pipeline's own intermediate. For each
hooked locale (`l10n/<LANG_CODE>/jev_note.txt`, currently only `sk`) it runs:

    ./check_mix.py --jev <lang> --jev-clear-only --intermediate

If that empties any msgstr, the whole `updated_translated.po` goes back through
`ai_translate.py` as its untranslated input. Only empty msgstr are filled, so
good translations stay and the flagged entries are retranslated. The refilled
file replaces `updated_translated.po`, and `import-translation` merges it.
Retranslation runs once; it is not audited again.

- **Jev setup, API, network or paid-fallback failure** - warns and keeps the AI
  output. A failed or incomplete audit never clears anything.
- **Missing hook, missing Jev credential, or no `updated_translated.po`** -
  skips; no request is sent.
- **No entry clears the thresholds** - no-op; the AI output is imported as is.
- **Failed refill** - stops the run like any other `ai-translate` failure.

`--intermediate` also works in report mode (`./check_mix.py --jev sk
--intermediate`), so the flagged rows can be read before import.

#### Full-catalogue audit and retranslate (`assistant.po`)

`./check_mix.py --jev <lang> --retranslate-jev` is the manual, whole-catalogue
entry. It audits the live `assistant.po`, empties the confident peer-language
entries, and runs `make retranslate-jev` to refill them. It fails closed: it
clears nothing if any request failed, no entry met the thresholds, git cannot
prove `assistant.po` clean, or intermediates are pending. `--intermediate` is
not accepted with it.

#### Pipeline scope and recovery

The pipeline is invoked as `make retranslate-jev L10N_LANG=<lang>`. It validates
the locale against `LANGS` and its catalogue before running anything, then
runs only the per-locale steps: `extract-untranslated-<lang>` ->
`ai-translate-<lang>` -> `import-translation-<lang>` -> `make check` ->
`<lang>/assistant.mo`. Extraction and import are scoped to the one locale, so
no other locale's intermediates, catalogue or `.mo` is touched, and the global
`make clean` is never run.

`make check` covers the whole tree and its failure is not swallowed: the target
still compiles `<lang>/assistant.mo`, then exits non-zero with a warning. The
locale's intermediates (`untranslated.po`, `_untranslated.po`, `_fuzzy.po`,
`updated_translated.po`, `updated.po`) are removed only after every step
succeeds. On any failure they are preserved and the exact resume command is
printed:

    make retranslate-jev L10N_LANG=sk

There is no automatic commit; review the diff first.

#### Data flow

Report, retranslate and clear-only send the target `msgid`, its current `msgstr`,
the locale metadata and the hook's guidance to the SystemOne endpoint
(`API_JEV_ENDPOINT`) with the `API_KEY` Bearer credential - nothing else. On
successful classification, retranslate mode hands the emptied entries to the
pipeline it starts itself, and clear-only mode leaves them for the `make`
pipeline that invoked it; both then send them to the configured `API_ENDPOINT` /
`API_MODEL`. The default `jev-1.13-free` model is free only while its quota
lasts; when the free quota is exhausted the audit falls back to the paid
`jev-1.13` model, so a bare `make` whose hooked locale has exhausted its free
quota can make **paid** Jev requests. Paid fallback requests are capped by
`JEV_MAX_PAID_REQUESTS` (default `100`, counting real HTTP attempts) - a request
guard, not a dollar cap - so check the provider's terms and current pricing
before relying on it.

## Updating Translations

When the source code changes, new strings might be added or modified. To update
all language files:

    make

`make` (default goal `translate`) Jev-checks the AI output for hooked locales
after `ai-translate`; locales without a hook, or without a Jev credential, are
skipped without a request, and `make check` / `make check-mix` never make a Jev
request.

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

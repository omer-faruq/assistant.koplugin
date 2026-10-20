#!/usr/bin/env python3
"""Review l10n catalogues with a second model and repair what it flags.

Why this exists: helper/ai_translate.py only fills empty or fuzzy msgstr, so a translation
that came back in the wrong language, or with the wrong meaning, counts as done
forever. Its output-time checks catch a wrong-slot answer (lost markup or a
ghost %N), but a msgid whose translation is simply in the wrong language, or
says the wrong thing, still ships wrong. This harness asks a reviewer model one
question - is this translation actually correct for the target language? - and,
when it confidently says no, empties exactly those msgstr so the normal pipeline
refills them. It never writes a translation itself.

The catalogue is reviewed in chunks (L10N_REVIEW_CHUNK_SIZE, default 50
entries), each chunk sent as its own request and answered with a compact
per-entry verdict (`pass`, `repair` or `abstain`), not one call per msgid. A
whole catalogue in one request can overflow the reviewer's output budget, so
chunking keeps each verdict set small; a truncated or malformed chunk fails the
whole pass. `repair` is reserved for a strong, explicit wrong-language or
wrong-meaning finding; a short or ambiguous string abstains instead. An entry
whose msgstr equals its msgid or is nothing but format placeholders is never
sent: it is not prose to judge.

Modes:
    helper/review_translations.py [--lang LANG]                 review LANG/assistant.po
    helper/review_translations.py [--lang LANG] --changed-from P
                                                                review only entries changed since P
    helper/review_translations.py [--lang LANG] --full          audit LANG/assistant.po, report-only

A locale opts into the review by shipping l10n/<LANG>/review_note.txt: the note
is its distinguishing guidance (which languages its catalogue is confused with,
and the tells that resolve them), and the prompt names the target language from
LANG_EN. No locale without a note is ever reviewed, so the harness carries no
per-language code.

Normal mode reviews the catalogue written by `make translate`. With
`--changed-from`, it reviews only entries whose translation changed since that
snapshot; the Makefile passes the pre-run copy so a full catalogue is not
re-reviewed every time. When it flags entries it empties their msgstr, refills
them once through helper/ai_translate.py, and reviews the result a second time;
a repair verdict that survives the refill stops the run before check (exit 3).
It never loops.

Every failure that is not a surviving repair verdict is best-effort: a missing
review note, a missing reviewer credential, an authentication error, a timeout
or an invalid reply warns and leaves the pipeline running (exit 0). The point is
to hand the outer pipeline a better catalogue, never to stop a translation run.

The reviewer is a second model reached through the same OpenAI-compatible SDK
layer as the translator (helper/ai_translate.py), defaulting to the Responses
protocol. Its route is read from L10N_REVIEW_API_PROTOCOL / L10N_REVIEW_API_BASE / L10N_REVIEW_API_MODEL
/ L10N_REVIEW_API_KEY, resolved through the shared loader (process environment,
then l10n/<LANG>/.env, then l10n/.env); the JSON-schema mode and timeout/retry
policy are the shared AI_JSON_SCHEMA / AI_REQUEST_TIMEOUT / AI_MAX_RETRIES knobs,
and L10N_REVIEW_CHUNK_SIZE sets how many entries each request carries;
L10N_REVIEW_CONCURRENCY (default 4) sets how many review requests run in
parallel; L10N_REVIEW_MAX_RETRIES (default 2) sets how many times a failed
chunk is retried before the pass fails.
See l10n/README.md.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import time

from lang_data import LANG_EN, L10N_DIR
from llm_client import Config, load_settings, request
from po_ops import clear_entry, load

DOMAIN = "assistant"
REVIEW_NOTE_FILE = "review_note.txt"
AI_TRANSLATE = os.path.join(L10N_DIR, "helper", "ai_translate.py")

# A locale is reviewed only when it ships its own review_note.txt; the default
# keeps a bare invocation convenient.
DEFAULT_LANG = "sk"

# The reviewer route: a dedicated L10N_REVIEW_* key set so a second model can
# sit behind its own base URL, model and credential, defaulting to the
# Responses protocol. Any L10N_REVIEW_* key left unset falls back to the
# translator's API_* key, so an unconfigured reviewer shares its route. The
# shared AI_* knobs (schema mode, timeout, retries) still apply through
# Config.
ROUTE_PREFIX = "L10N_REVIEW_"
DEFAULT_PROTOCOL = "responses"

# Entries per reviewer request. A whole catalogue in one request can overflow
# the model's output budget on large catalogues (finish_reason=length), so each
# request carries a slice small enough that the verdict JSON fits comfortably.
# Overridable with L10N_REVIEW_CHUNK_SIZE through the shared settings loader.
DEFAULT_CHUNK_SIZE = 50
CHUNK_SIZE_KEY = "L10N_REVIEW_CHUNK_SIZE"

# Reviewer requests run concurrently. Fixed default (not CPU-derived): the
# limit is about API/provider concurrency, not local cores.
DEFAULT_CONCURRENCY = 4
CONCURRENCY_KEY = "L10N_REVIEW_CONCURRENCY"

# Retries per failed chunk: run_review + empty-reply + parse_verdicts is retried
# this many times on top of the first attempt, so a default of 2 means up to 3
# attempts per chunk.
DEFAULT_MAX_RETRIES = 2
MAX_RETRIES_KEY = "L10N_REVIEW_MAX_RETRIES"

STATUS_PASS = "pass"
STATUS_REPAIR = "repair"
STATUS_ABSTAIN = "abstain"
STATUSES = (STATUS_PASS, STATUS_REPAIR, STATUS_ABSTAIN)

# A repair verdict's issue class. Free-form text stays out of this field so the
# report is aggregatable; the human sentence lives in `reason`.
ISSUE_CLASSES = frozenset({
    "wrong_language",
    "wrong_meaning",
    "markup_loss",
    "wrong_slot",
    "ambiguous",
    "other",
})

MAX_REASON = 200
MAX_LANGUAGE = 80

# A msgstr that is nothing but the msgid's placeholders, or identical to the
# msgid, is a technical token or an untranslated source form, not prose to judge.
TOKEN_MSGSTR = re.compile(r"%(?:\d+\$)?[sd]|%s|%d")

EXIT_OK = 0
# Repair verdicts survived the single refill. The caller stops before check and
# keeps the catalogue; the harness never loops.
EXIT_BLOCK = 3

# The reviewer's instructions: the judgement rubric and the output contract,
# sent as the model's system message. The target language and per-locale
# guidance arrive in the user message (build_prompt), so this text names no
# language. The JSON shape is enforced by VERDICT_SCHEMA; the prose states the
# semantics the schema cannot (reason is required on a repair, null elsewhere).
REVIEW_SYSTEM_PROMPT = """You are a localization reviewer for the user-facing strings of an open-source e-book reader's AI assistant plugin. A caller sends you one catalogue of translated strings and asks you to judge whether each translation is correct for the target language.

The caller names the target language and, when the locale ships one, provides authoritative locale guidance: which languages its catalogue is commonly confused with, and the words or letters that tell them apart. Treat that guidance as authoritative over your own priors, and never assume a language from the locale code alone.

Judge each entry against its source (msgid) and the target language:

- `pass` - the msgstr is a correct translation in the target language and says what the msgid says.
- `repair` - a strong, explicit defect: the msgstr is in a different language, means something the msgid does not, drops required markup, or belongs to another msgid's slot. Name the telling word or form in `reason`.
- `abstain` - too short, a proper noun, a technical token, or otherwise not judgeable with confidence.

Reserve `repair` for a defect you can point at; when the only signal is that a translation "reads oddly", or the string is short or ambiguous, answer `abstain`. Never write, suggest or rewrite a translation.

Output contract:

- One review element per id you were sent, each id exactly once, in any order.
- `status` is mandatory and is one of `pass`, `repair`, `abstain`.
- `language` is the detected language, set only when it is not the target.
- `issue` classifies a `repair`: one of `wrong_language`, `wrong_meaning`, `markup_loss`, `wrong_slot`, `ambiguous`, `other`.
- `reason` is one short factual sentence naming the telling word or form, with no hedging. A `repair` must carry a `reason`.
- Set `language`, `issue` and `reason` to null when they do not apply.
"""

# The JSON Schema for the {"reviews": [...]} answer, the structured-output
# contract. It pins the object/array/string types and the status/issue enums;
# like TRANSLATIONS_SCHEMA it uses no length or conditional keywords, because
# strict-mode providers reject them, so "one element per sent id" and
# "reason required on a repair" are enforced by parse_verdicts instead. Every
# property is required, with null for the ones that do not apply.
VERDICT_SCHEMA: dict = {
    "type": "object",
    "properties": {
        "reviews": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "status": {"type": "string", "enum": list(STATUSES)},
                    "language": {"anyOf": [{"type": "string"}, {"type": "null"}]},
                    "issue": {
                        "anyOf": [
                            {"type": "string", "enum": sorted(ISSUE_CLASSES)},
                            {"type": "null"},
                        ]
                    },
                    "reason": {"anyOf": [{"type": "string"}, {"type": "null"}]},
                },
                "required": ["id", "status", "language", "issue", "reason"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["reviews"],
    "additionalProperties": False,
}


class ReviewError(RuntimeError):
    """A review pass that could not produce a usable, complete verdict set."""


def _warn(message: str) -> None:
    print(f"[review] warning: {message}", file=sys.stderr)


def _log(message: str) -> None:
    print(f"[review] {message}", file=sys.stderr)


def load_review_note(lang: str) -> str | None:
    """Read l10n/<lang>/review_note.txt, or None when the locale ships none.

    The note is the locale's distinguishing guidance (which languages its
    catalogue is confused with, and the tells that resolve them). Without it
    the review is skipped.
    """
    path = os.path.join(L10N_DIR, lang, REVIEW_NOTE_FILE)
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as handle:
        return handle.read().strip()


def language_name(lang: str) -> str:
    """The English name of the target language, from lang_data.LANG_EN.

    The prompt names the language by name so the reviewer cannot infer it from
    the locale code alone. A locale missing from the table falls back to its
    code, keeping an unknown locale reviewable.
    """
    return LANG_EN.get(lang, lang)


def review_config(lang: str) -> Config:
    """The reviewer's Config: the L10N_REVIEW_* route, Responses by default.

    Built through the shared Config, so the reviewer reuses the
    same client construction, protocol handling, JSON-schema downgrade and
    timeout/retry policy as the translator, layering l10n/.env and
    l10n/<lang>/.env the same way. Raises ValueError on an unknown protocol.
    """
    return Config(
        lang, route_prefix=ROUTE_PREFIX, default_protocol=DEFAULT_PROTOCOL
    )


def resolve_chunk_size(lang: str) -> int:
    """Entries per reviewer request, from L10N_REVIEW_CHUNK_SIZE or the default.

    The key resolves through the shared loader (process environment, then
    l10n/<lang>/.env, then l10n/.env). A non-numeric or non-positive value warns
    and falls back to DEFAULT_CHUNK_SIZE rather than failing the review.
    """
    raw = load_settings(lang).get(CHUNK_SIZE_KEY, "")
    if raw == "":
        return DEFAULT_CHUNK_SIZE
    try:
        value = int(raw)
    except ValueError:
        _warn(
            f"{CHUNK_SIZE_KEY}={raw!r} is not an integer; "
            f"using {DEFAULT_CHUNK_SIZE}."
        )
        return DEFAULT_CHUNK_SIZE
    if value <= 0:
        _warn(
            f"{CHUNK_SIZE_KEY}={raw!r} must be > 0; using {DEFAULT_CHUNK_SIZE}."
        )
        return DEFAULT_CHUNK_SIZE
    return value


def resolve_concurrency(lang: str) -> int:
    """Worker count for the review pass, from L10N_REVIEW_CONCURRENCY or default.

    The key resolves through the shared loader (process environment, then
    l10n/<lang>/.env, then l10n/.env). A non-numeric or non-positive value
    warns and falls back to DEFAULT_CONCURRENCY rather than failing the review.
    """
    raw = load_settings(lang).get(CONCURRENCY_KEY, "")
    if raw == "":
        return DEFAULT_CONCURRENCY
    try:
        value = int(raw)
    except ValueError:
        _warn(
            f"{CONCURRENCY_KEY}={raw!r} is not an integer; "
            f"using {DEFAULT_CONCURRENCY}."
        )
        return DEFAULT_CONCURRENCY
    if value <= 0:
        _warn(
            f"{CONCURRENCY_KEY}={raw!r} must be > 0; "
            f"using {DEFAULT_CONCURRENCY}."
        )
        return DEFAULT_CONCURRENCY
    return value


def resolve_max_retries(lang: str) -> int:
    """Per-chunk retry count, from L10N_REVIEW_MAX_RETRIES or the default.

    The key resolves through the shared loader (process environment, then
    l10n/<lang>/.env, then l10n/.env). A non-numeric or non-positive value
    warns and falls back to DEFAULT_MAX_RETRIES rather than failing the review.
    """
    raw = load_settings(lang).get(MAX_RETRIES_KEY, "")
    if raw == "":
        return DEFAULT_MAX_RETRIES
    try:
        value = int(raw)
    except ValueError:
        _warn(
            f"{MAX_RETRIES_KEY}={raw!r} is not an integer; "
            f"using {DEFAULT_MAX_RETRIES}."
        )
        return DEFAULT_MAX_RETRIES
    if value <= 0:
        _warn(
            f"{MAX_RETRIES_KEY}={raw!r} must be > 0; "
            f"using {DEFAULT_MAX_RETRIES}."
        )
        return DEFAULT_MAX_RETRIES
    return value


def _is_token(msgid: str, msgstr: str) -> bool:
    if msgstr.strip() == msgid.strip():
        return True
    return TOKEN_MSGSTR.sub("", msgstr).strip() == ""


def collect_entries(path: str) -> list[dict]:
    """Every translated, non-token msgstr, in catalogue order, each with an id.

    Plural entries contribute one record per non-empty form, carrying the
    msgid_plural and the form index so the reviewer can judge the form against
    the source. The id is assigned in catalogue order and is reused to clear the
    exact msgstr after the pass.
    """
    po = load(path)
    out: list[dict] = []
    for entry in po:
        if entry.obsolete:
            continue
        forms = (
            [(str(i), v) for i, v in entry.msgstr_plural.items()]
            if entry.msgid_plural
            else [("", entry.msgstr)]
        )
        for form, msgstr in forms:
            if not (msgstr or "").strip() or _is_token(entry.msgid, msgstr):
                continue
            out.append({
                "id": f"e{len(out)}",
                "msgctxt": entry.msgctxt or "",
                "msgid": entry.msgid,
                "msgid_plural": entry.msgid_plural or "",
                "form": form,
                "msgstr": msgstr,
            })
    return out


def changed_keys(old_path: str, new_path: str) -> set[tuple[str, str]]:
    """Return (msgctxt, msgid) pairs whose translation changed between two files."""
    previous = {(e.msgctxt or "", e.msgid): e for e in load(old_path)}
    changed: set[tuple[str, str]] = set()
    for entry in load(new_path):
        if entry.obsolete:
            continue
        key = (entry.msgctxt or "", entry.msgid)
        before = previous.get(key)
        if (
            before is None
            or before.msgstr != entry.msgstr
            or before.msgstr_plural != entry.msgstr_plural
            or ("fuzzy" in before.flags) != ("fuzzy" in entry.flags)
        ):
            changed.add(key)
    return changed


def _compact(entry: dict) -> dict:
    """The reviewer-facing record: only the fields that carry information."""
    item = {"id": entry["id"], "msgid": entry["msgid"], "msgstr": entry["msgstr"]}
    if entry["msgctxt"]:
        item["msgctxt"] = entry["msgctxt"]
    if entry["msgid_plural"]:
        item["msgid_plural"] = entry["msgid_plural"]
        item["plural_form"] = entry["form"]
    return item


def build_prompt(entries: list[dict], note: str, lang: str, language: str) -> str:
    """The user message: locale metadata, the note, and the batch of entries.

    The verdict contract lives in the system message (REVIEW_SYSTEM_PROMPT);
    this message fixes the target language, the locale's guidance and the
    entries sent.
    """
    header = (
        f"Target language: {language} (locale {lang}).\n"
        f"Entries to review: {len(entries)}.\n"
    )
    if note:
        header += (
            "\nLocale guidance (authoritative - use it to tell the target "
            "language apart from the ones it is confused with):\n" + note + "\n"
        )
    header += (
        f"\nReview every entry below for {language}. Answer each id exactly "
        "once, following the output contract. Never write a translation.\n"
    )
    payload = json.dumps(
        [_compact(entry) for entry in entries],
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return header + "\nEntries (JSON array):\n" + payload + "\n"


def run_review(prompt: str, cfg: Config) -> str:
    """Run one review request over the config's route; return its reply text.

    The prompt goes as the user message, never in argv, so a chunk cannot
    exhaust the argument list. A missing credential, a transport error,
    a refusal or a truncation raises ReviewError; the caller treats any of them
    as an unrun review.
    """
    route = cfg.get_route()
    if not route.api_key:
        raise ReviewError(f"{ROUTE_PREFIX}API_KEY is not set")
    messages = [
        {"role": "system", "content": REVIEW_SYSTEM_PROMPT},
        {"role": "user", "content": prompt},
    ]
    try:
        result = request(
            cfg,
            messages,
            schema=VERDICT_SCHEMA,
            schema_name="review_verdicts",
        )
    except Exception as exc:
        raise ReviewError(f"review request failed: {exc}") from exc
    if result.get("finish_reason") == "length":
        raise ReviewError("the reviewer reply was truncated (finish_reason=length)")
    return result.get("content") or ""


def _extract_json(text: str) -> dict:
    """Parse the reviewer's JSON object.

    Structured output guarantees a bare JSON object - json_schema, or
    json_object on the automatic downgrade - so the reply must parse as one:
    prose around it or a truncated stream fails the pass instead of being
    partially trusted.
    """
    try:
        parsed = json.loads(text)
    except ValueError as exc:
        raise ReviewError("reply is not valid JSON") from exc
    if not isinstance(parsed, dict):
        raise ReviewError("reply is not a JSON object")
    return parsed


def parse_verdicts(text: str, expected_ids: list[str]) -> dict[str, dict]:
    """Validate the reviewer's reply against the ids that were sent.

    The reply must name every sent id exactly once, and each element must carry
    a known status. A missing, extra or duplicate id fails the whole pass: a
    verdict set that cannot be matched to the entries is not trustworthy.
    """
    payload = _extract_json(text)
    reviews = payload.get("reviews")
    if not isinstance(reviews, list):
        raise ReviewError("reply has no 'reviews' array")
    expected = set(expected_ids)
    out: dict[str, dict] = {}
    for element in reviews:
        if not isinstance(element, dict):
            raise ReviewError("a review element is not an object")
        rid = element.get("id")
        if not isinstance(rid, str):
            raise ReviewError("a review element has no string 'id'")
        if rid not in expected:
            raise ReviewError(f"reply names unknown id {rid!r}")
        if rid in out:
            raise ReviewError(f"reply repeats id {rid!r}")
        status = element.get("status")
        if status not in STATUSES:
            raise ReviewError(f"id {rid!r} has invalid status {status!r}")
        verdict = {
            "id": rid, "status": status,
            "language": "", "issue": "", "reason": "",
        }
        language = element.get("language")
        if language is not None:
            if not isinstance(language, str):
                raise ReviewError(f"id {rid!r} has a non-string 'language'")
            verdict["language"] = language.strip()[:MAX_LANGUAGE]
        issue = element.get("issue")
        if issue is not None:
            if not isinstance(issue, str):
                raise ReviewError(f"id {rid!r} has a non-string 'issue'")
            issue = issue.strip()
            if issue and issue not in ISSUE_CLASSES:
                raise ReviewError(f"id {rid!r} has unknown issue {issue!r}")
            verdict["issue"] = issue
        reason = element.get("reason")
        if reason is not None:
            if not isinstance(reason, str):
                raise ReviewError(f"id {rid!r} has a non-string 'reason'")
            verdict["reason"] = " ".join(reason.split())[:MAX_REASON]
        if status == STATUS_REPAIR and not verdict["reason"]:
            raise ReviewError(f"id {rid!r} is 'repair' without a reason")
        out[rid] = verdict
    missing = [rid for rid in expected_ids if rid not in out]
    if missing:
        raise ReviewError(
            f"reply is missing {len(missing)} of {len(expected_ids)} id(s): "
            f"{missing[:5]}"
        )
    return out


def _run_review_chunk(index: int, total: int, chunk: list[dict],
                      lang: str, cfg: Config,
                      note: str, language: str,
                      max_retries: int):
    """Send one review chunk with retries; return its validated verdicts.

    One attempt covers run_review (transport/SDK errors, truncation, refusal),
    the empty-reply check and parse_verdicts (malformed verdicts). Any of those
    failures retries the whole attempt; only after all attempts are exhausted
    does the chunk fail the pass.
    """
    attempts = max_retries + 1
    ids = [entry["id"] for entry in chunk]
    for attempt in range(1, attempts + 1):
        prompt = build_prompt(chunk, note, lang, language)
        started = time.monotonic()
        try:
            text = run_review(prompt, cfg)
            elapsed = time.monotonic() - started
            if not text.strip():
                raise ReviewError(
                    f"chunk {index}/{total}: the reviewer produced no text reply"
                )
            chunk_verdicts = parse_verdicts(text, ids)
            _log(
                f"{lang}: chunk {index}/{total}: reply after {elapsed:.0f}s, "
                f"{len(chunk_verdicts)} verdicts OK"
            )
            return chunk_verdicts
        except Exception as exc:
            reason = str(exc) or type(exc).__name__
            if attempt < attempts:
                _log(
                    f"{lang}: chunk {index}/{total}: attempt {attempt}/{attempts} "
                    f"failed ({reason}); retrying..."
                )
                time.sleep(2 * attempt)
            else:
                _log(
                    f"{lang}: chunk {index}/{total}: failed after {attempts} "
                    f"attempts ({reason})"
                )
                raise ReviewError(
                    f"chunk {index}/{total}: failed after {attempts} attempts "
                    f"({reason})"
                ) from exc


def review_pass(note: str, path: str, cfg: Config,
                lang: str, language: str,
                only: set[tuple[str, str]] | None = None,
                chunk_size: int | None = None,
                concurrency: int | None = None,
                max_retries: int | None = None):
    """One review pass over path, one request per chunk. Returns (entries, verdicts).

    The catalogue is split into chunks of L10N_REVIEW_CHUNK_SIZE entries so a
    large catalogue cannot overflow the reviewer's output budget; each chunk is
    sent as its own self-contained request (same locale header and note, its
    entry slice) and validated against its own ids. Requests run concurrently
    up to L10N_REVIEW_CONCURRENCY. Verdicts merge back into catalogue order.
    A truncated, refused or invalid chunk is retried up to
    L10N_REVIEW_MAX_RETRIES times; only after all attempts fail does the pass
    raise ReviewError: not-yet-started futures are cancelled and no further
    chunks are dispatched, but in-flight requests are left to finish.
    """
    entries = collect_entries(path)
    if only is not None:
        entries = [e for e in entries if (e["msgctxt"], e["msgid"]) in only]
        if not entries:
            _log(f"{lang}: no changed entries to review.")
            return [], {}
    if not entries:
        raise ReviewError("no translated entries to review")
    if chunk_size is None:
        chunk_size = resolve_chunk_size(lang)
    if concurrency is None:
        concurrency = resolve_concurrency(lang)
    if max_retries is None:
        max_retries = resolve_max_retries(lang)
    chunks = [
        entries[start:start + chunk_size]
        for start in range(0, len(entries), chunk_size)
    ]
    total = len(chunks)
    _log(
        f"{lang}: sending {len(entries)} entries in {total} chunk(s) of up "
        f"to {chunk_size}, concurrency {concurrency}; the reply can take a few "
        f"minutes, please wait..."
    )
    verdicts: dict[str, dict] = {}
    futures_map: dict = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        pending = iter(list(enumerate(chunks, 1)))

        def dispatch():
            while len(futures_map) < concurrency:
                try:
                    index, chunk = next(pending)
                except StopIteration:
                    return
                _log(
                    f"{lang}: chunk {index}/{total}: sending {len(chunk)} "
                    f"entries..."
                )
                future = executor.submit(
                    _run_review_chunk, index, total, chunk, lang, cfg, note, language,
                    max_retries,
                )
                futures_map[future] = (index, chunk)

        dispatch()
        try:
            while futures_map:
                done, _ = concurrent.futures.wait(
                    futures_map, return_when=concurrent.futures.FIRST_COMPLETED,
                )
                for future in done:
                    futures_map.pop(future)
                    verdicts.update(future.result())
                dispatch()
        except Exception:
            for future in list(futures_map):
                future.cancel()
            raise
    return entries, {entry["id"]: verdicts[entry["id"]] for entry in entries}


def clear_entries(path: str, entries: list[dict], repair_ids: set[str]) -> list[str]:
    """Empty the exact msgstr the reviewer flagged, in place.

    A flagged plural form empties every form the entry declares, because
    helper/ai_translate.py refills a plural entry only once all of its forms
    are empty. Returns one label per changed entry.
    """
    wanted: dict[tuple[str, str], set[str]] = {}
    for entry in entries:
        if entry["id"] in repair_ids:
            wanted.setdefault((entry["msgctxt"], entry["msgid"]), set()).add(
                entry["form"]
            )
    po = load(path)
    changed: list[str] = []
    for entry in po:
        forms = wanted.get((entry.msgctxt or "", entry.msgid))
        if not forms:
            continue
        if entry.msgid_plural:
            indices = [int(form) for form in forms if form != ""]
            if not indices:
                continue
            if any((entry.msgstr_plural.get(i) or "").strip() for i in indices):
                clear_entry(entry)
                changed.append(f"{entry.msgid[:60]!r} [plural]")
        elif entry.msgstr.strip():
            clear_entry(entry)
            changed.append(f"{entry.msgid[:60]!r}")
        if "fuzzy" in entry.flags:
            entry.flags.remove("fuzzy")
    if changed:
        po.save(path)
    return changed


def refill(lang: str) -> None:
    """Refill the cleared entries by running the translator once.

    The translator fills empty and fuzzy entries in <lang>/assistant.po in
    place. The caller owns the backup of the pre-review catalogue and restores
    it if this raises.
    """
    try:
        proc = subprocess.run(
            [sys.executable, AI_TRANSLATE, lang],
            cwd=L10N_DIR,
        )
    except OSError as exc:
        raise ReviewError(f"cannot run helper/ai_translate.py: {exc}") from exc
    if proc.returncode != 0:
        partial = os.path.join(L10N_DIR, lang, f"{DOMAIN}.po.partial")
        if os.path.isfile(partial):
            os.remove(partial)
        raise ReviewError(f"helper/ai_translate.py exited {proc.returncode}")


def _repaired_ids(entries: list[dict], verdicts: dict[str, dict]) -> list[str]:
    return [
        entry["id"]
        for entry in entries
        if verdicts[entry["id"]]["status"] == STATUS_REPAIR
    ]


def _print_report(entries: list[dict], verdicts: dict[str, dict], lang: str) -> None:
    """A concise per-status summary plus one line per repair/abstain finding."""
    counts = {status: 0 for status in STATUSES}
    for verdict in verdicts.values():
        counts[verdict["status"]] += 1
    _log(
        f"{lang}: {counts[STATUS_PASS]} pass, {counts[STATUS_REPAIR]} repair, "
        f"{counts[STATUS_ABSTAIN]} abstain"
    )
    by_id = {entry["id"]: entry for entry in entries}
    for verdict in verdicts.values():
        if verdict["status"] == STATUS_PASS:
            continue
        entry = by_id[verdict["id"]]
        bits = [verdict["status"]]
        if verdict["language"]:
            bits.append(verdict["language"])
        if verdict["issue"]:
            bits.append(verdict["issue"])
        label = " / ".join(bits)
        _log(
            f"  {verdict['id']} [{label}] {entry['msgid'][:50]!r}: "
            f"{verdict['reason']}"
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="review_translations.py",
        description="Review an l10n catalogue that ships a review note with a "
                    "second model and empty the msgstr it confidently marks as "
                    "needing repair.",
    )
    parser.add_argument(
        "--lang", default=DEFAULT_LANG,
        help=f"locale to review (default: {DEFAULT_LANG}); its "
             f"<LANG>/{REVIEW_NOTE_FILE} opts it in",
    )
    parser.add_argument(
        "--changed-from", default=None, metavar="PATH",
        help="review only entries whose translation changed since PATH "
             "(the Makefile passes the pre-translation snapshot)",
    )
    parser.add_argument(
        "--full", action="store_true",
        help=f"report-only audit of <LANG>/{DOMAIN}.po: one chunked reviewer "
             f"pass, no changes to any file",
    )
    parser.add_argument(
        "--model", default=None,
        help=f"reviewer model (default: {ROUTE_PREFIX}API_MODEL from the "
             f"locale's settings, then the shared default)",
    )
    parser.add_argument(
        "--timeout", type=float, default=None,
        help=f"per-request timeout in seconds (default: AI_REQUEST_TIMEOUT from "
             f"the locale's settings)",
    )
    args = parser.parse_args(argv)

    lang = args.lang.strip()
    if not lang:
        _warn("--lang must not be empty; skipping the review.")
        return EXIT_OK
    language = language_name(lang)

    note = load_review_note(lang)
    if note is None:
        _warn(f"{lang}: no {REVIEW_NOTE_FILE}; skipping the review.")
        return EXIT_OK

    path = os.path.join(L10N_DIR, lang, f"{DOMAIN}.po")
    if not os.path.isfile(path):
        _warn(f"{path}: not found; nothing to review.")
        return EXIT_OK

    only = None
    if args.changed_from and not args.full:
        if not os.path.isfile(args.changed_from):
            _warn(f"{args.changed_from}: not found; reviewing the whole catalogue.")
        else:
            try:
                only = changed_keys(args.changed_from, path)
            except OSError as exc:
                _warn(
                    f"{args.changed_from}: cannot read ({exc}); reviewing the "
                    f"whole catalogue."
                )
                only = None
            if only is not None and not only:
                _log(f"{lang}: no changed entries; nothing to review.")
                return EXIT_OK

    try:
        cfg = review_config(lang)
    except ValueError as exc:
        _warn(f"{lang}: {exc}; skipping the review.")
        return EXIT_OK
    if args.timeout is not None:
        if args.timeout <= 0:
            _warn(f"--timeout must be > 0, got {args.timeout!r}; skipping the review.")
            return EXIT_OK
        cfg.request_timeout = args.timeout
    if args.model:
        cfg.api_model = args.model.strip()
    model = cfg.get_route().model

    if args.full:
        _log(f"{lang}: read-only audit of {path} (model {model})")
        try:
            entries, verdicts = review_pass(note, path, cfg, lang, language, only)
        except ReviewError as exc:
            _warn(f"{lang}: review failed ({exc}); no report produced.")
            return EXIT_OK
        _print_report(entries, verdicts, lang)
        _log("read-only: no catalogue was modified.")
        return EXIT_OK

    _log(f"{lang}: reviewing {path} (model {model})")
    try:
        entries, verdicts = review_pass(note, path, cfg, lang, language, only)
    except ReviewError as exc:
        _warn(
            f"{lang}: review failed ({exc}); keeping the AI output, "
            f"no entries cleared."
        )
        return EXIT_OK

    repairs = _repaired_ids(entries, verdicts)
    _print_report(entries, verdicts, lang)
    if not repairs:
        _log(f"{lang}: no repair verdicts; nothing to change.")
        return EXIT_OK

    _log(f"{lang}: clearing {len(repairs)} flagged msgstr, refilling once...")
    backup = path + ".review-orig"
    try:
        shutil.copyfile(path, backup)
    except OSError as exc:
        _warn(f"{lang}: cannot back up {path} ({exc}); keeping the AI output.")
        return EXIT_OK
    changed = clear_entries(path, entries, set(repairs))
    if not changed:
        if os.path.isfile(backup):
            os.remove(backup)
        _warn(f"{lang}: nothing was cleared; keeping the AI output.")
        return EXIT_OK
    try:
        refill(lang)
    except ReviewError as exc:
        os.replace(backup, path)
        _warn(
            f"{lang}: refill failed ({exc}); the pre-review catalogue "
            f"is restored."
        )
        return EXIT_OK
    if os.path.isfile(backup):
        os.remove(backup)

    _log(f"{lang}: refill done; final review pass...")
    try:
        entries, verdicts = review_pass(note, path, cfg, lang, language, only)
    except ReviewError as exc:
        _warn(
            f"{lang}: final review failed ({exc}); the run continues with the "
            f"refilled catalogue."
        )
        return EXIT_OK

    remaining = _repaired_ids(entries, verdicts)
    if remaining:
        _print_report(entries, verdicts, lang)
        _log(
            f"{lang}: {len(remaining)} repair verdict(s) survived the refill; "
            f"stopping before check so {os.path.basename(path)} is preserved."
        )
        return EXIT_BLOCK
    _log(f"{lang}: the refill resolved every repair verdict.")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())

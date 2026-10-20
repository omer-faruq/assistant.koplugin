#!/usr/bin/env python3
"""
ai_translate.py - Drive a gettext .po translation pipeline through an LLM API.

This is the Python replacement for AI_TRANSLATE.sh. Transport is the official
OpenAI Python SDK, so one HTTP/retry/timeout policy covers both wire formats
the project uses:

  * `chat_completions` (default): `client.chat.completions.create`, the
    OpenAI-compatible Chat Completions API.
  * `responses`: `client.responses.create`, the OpenAI Responses API. Select
    it globally with API_PROTOCOL=responses in l10n/.env, or per locale with
    API_PROTOCOL in l10n/<lang>/.env. Protocol is explicit config, never
    inferred from the base URL.

Each locale may carry its own l10n/<lang>/.env (e.g. l10n/sk/.env) that
overrides the global l10n/.env. API_BASE / API_PROTOCOL / API_MODEL / API_KEY
resolve from the exported process environment first, then the locale file,
then the global file; a blank value is ignored so it cannot erase a lower
layer. API_BASE is the base URL of the OpenAI-compatible API and defaults to
https://api.openai.com/v1; the protocol appends its own path, so a configured
base never carries /chat/completions or /responses.

It avoids the truncation issue (finish_reason=length) by:

  * Communicating with the LLM via a strict JSON-in / JSON-out contract:
    the model is asked to return {"translations": [...]} (an id-keyed array,
    one element per request item) for a list of msgids, instead of emitting
    an entire .po file as free-form text.
  * Constraining the output with a strict JSON Schema (object/array/string
    types; lengths enforced by prompt + client validation), with automatic
    fallback to {"type": "json_object"} when the endpoint rejects json_schema
    (AI_JSON_SCHEMA=auto by default; off forces json_object, on forces
    json_schema without fallback; AI_JSON_MODE=0 disables the format).
  * Sending compact request items (only id/msgid plus non-empty
    msgctxt/msgid_plural/comments) as single-line JSON to save tokens.
  * Splitting the work into small chunks (default 20 msgids per request)
    so the per-response output is well below any provider's token cap.
  * On length-truncation, automatically bisecting the chunk and retrying.
  * Persisting progress as `<catalogue>.partial` after every chunk, so a
    crash, Ctrl-C, or API failure never loses already-completed work.

Retries and request timeouts are delegated to the SDK's own policy
(max_retries, timeout); the SDK owns backoff and the per-request deadline.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import random
import re
import sys
import tempfile
import time
from typing import Any, Iterable

import polib

from lang_data import (
    LANG_EN,
    LANG_MAP,
    LANG_NOTE_FILE,
    L10N_DIR,
    PLURAL_FORMS,
    check_data,
)
from llm_client import Config, RUN_SESSION_ID, is_opencode_api, log, log_http, request
from po_ops import is_empty, load as load_po

# -------------------- Logging --------------------

log_translate = logging.getLogger("ai_translate.translate")


# -------------------- Constants --------------------


PO_FILE = "assistant.po"

# Markup the translation must carry over from the msgid. AGENTS.md invariant 4:
# <b> is parsed by bold_format, not real HTML, so a dropped tag is a rendering
# bug, not a cosmetic one. A translation that also lost the tag is the visible
# footprint of a wrong-slot answer - when the model replies with the
# translation of some other msgid, the tags of the msgid it was actually given
# are the ones that go missing. That is how "<b>Testing connection...</b>" came
# to hold "Base URL" in a dozen locales.
#
# _check_markup enforces both this markup and the %N indices: a language may
# move a placeholder or attach a suffix to it (Afrikaans "%1$s nie", Uzbek
# "%1ni") and may use %s/%d, but it may not carry a %N index that no source
# form of the msgid has. Rejecting the former would stall the pipeline on
# entries the model is not wrong about; rejecting the latter catches a
# wrong-slot answer at request time instead of writing it to the catalogue.
MARKUP_RE = re.compile(r"</?[a-zA-Z][^>]*>")

# A %N index. KOReader's T() substitutes only these
# (gsub(str, "%%([1-9][0-9]?)")), so an index the msgid never had can only
# have been carried over from a different msgid - a wrong-slot answer. %s and
# %d are deliberately not matched: the plugin mixes string.format with T(), so
# the msgid's own conversion style is a per-call-site choice and cannot be
# judged from the catalogue.
PLACEHOLDER_RE = re.compile(r"%([1-9][0-9]?)")

SYSTEM_PROMPT = """You are an expert localization specialist translating user-facing strings for an AI assistant plugin in KOReader, an open-source e-book reader.

TARGET LANGUAGE: {language_en} ({lang_code}). The endonym for it is "{language}". Answer in {language_en} and in no other language. If an item looks like it belongs to a different locale than {language_en}, it is still {language_en} - translate it, do not switch language.

Domain context: this plugin is an AI assistant for a reading app. It lets readers ask questions about their current book, get translations, summaries, and X-Ray/Recap-style analysis of the text, run web-search tool calls, and capture quick notes - using cloud AI providers (Anthropic, OpenAI, Gemini, DeepSeek, Ollama, Groq, Mistral, GigaChat, OpenRouter, Gemma) and configurable models.

Translate software/AI terminology using the established conventions of {language_en}'s software and AI community, not literal dictionary translations. In particular:
  - "provider" / "AI provider" means an AI/API service provider (a company or self-hosted service supplying the model). Use the standard term for a cloud/service provider in {language_en} (e.g. the equivalent of "service provider" / "vendor"), not a literal "the one who provides".
  - "model" means a machine-learning model, not "type/pattern/template".
  - "prompt" means the instruction text sent to an AI, not "hint/encouragement".
  - "token" is an AI token; keep it or use the accepted AI term in {language_en}.
  - "streaming" means real-time streamed output.
  - "web search" means internet/online search; "tool calling" means the AI invoking external tools.
  - E-reader terms: "annotation" = a reader's margin note, "highlight" = selected/emphasized text, "notebook" = the note collection.
  - Feature names ("X-Ray", "Term X-Ray", "Recap"): keep the rendering consistent across the file and follow any translator comments. "Term X-Ray" explains the selected word by scanning every occurrence across the whole book (like an X-ray revealing hidden details); it is about one term, not the book-level "X-Ray".
  - API/product names ("Chat Completions API", "Responses API", "Messages API", "Gemini API", model names) always stay in English; translate only surrounding descriptors (e.g. "compatible" / "OpenAI-compatible").
{lang_note}
You will receive a JSON object describing the target language and a list of items to translate. Each item always has:
  - id: the item's number; repeat it on the object you answer with
  - msgid: the English source string
Optional fields appear only when applicable (absent means none):
  - msgctxt: context hint
  - msgid_plural: plural form (only present for plural entries)
  - comments: list of translator notes

Translate each item, taking into account the comments and msgctxt. Preserve all printf-style placeholders (e.g. %s, %d), the <b> tags, newlines, and leading/trailing whitespace exactly as they appear in msgid. Never answer with the translation of a different item, and never drop a placeholder or a tag.

Output rules:
- Reply with a single JSON object of the form {{"translations": [...]}}.
- "translations" is an array with one object per request item: {{"id": <the item's id>, "text": <the translation>}}.
- "id" must be copied verbatim from the request item that "text" translates. The id is how your answer is matched to the question, so a missing, duplicated or invented id is rejected and the chunk is retried. Never renumber, never reuse another item's id.
- "text" is a string for a non-plural item, and an array of exactly nplurals non-empty strings for a plural item (one that has msgid_plural).
- The array may be in any order, but it must cover every requested id exactly once.
- Do not return the msgid back unchanged as text unless the source is a technical token (URL, format spec, brand name) that must stay in English.
- Do not include any prose, markdown fences, or extra keys.
"""

USER_TEMPLATE = """Target language: {language_en} ({lang_code}), endonym "{language}"
nplurals: {nplurals}

Items to translate:
{items_json}

Respond with JSON only: {{"translations": [{{"id": <id>, "text": <translation>}}, ...]}} - one object per input item, each carrying that item's own id, and every requested id covered exactly once. "text" is a string, or an array of {nplurals} strings for an item that has msgid_plural."""


# -------------------- Connectivity check --------------------

def check_api(cfg: Config) -> int:
    """Send a minimal request to verify the configured route's connectivity.

    The route is whatever cfg resolved for its locale: a global Config tests
    the default route, a locale-bound Config (e.g. one built for --check-api-lang
    sk) tests that locale's merged settings.
    """
    route = cfg.get_route()
    label = f" [{cfg.lang_code}]" if cfg.lang_code else ""
    log.info("Checking API connectivity%s...", label)
    log.info("  Protocol: %s", route.protocol)
    log.info("  Endpoint: %s", route.endpoint)
    log.info("  Model:    %s", route.model)

    messages = [
        {
            "role": "system",
            "content": "You are a connectivity test. Reply with exactly the word OK.",
        },
        {"role": "user", "content": "ping"},
    ]

    start = time.time()
    try:
        result = request(cfg, messages, max_tokens=256, json_format=False)
    except Exception as exc:
        log.error("FAIL: %s", exc)
        return 1
    elapsed = int(time.time() - start)

    if result["finish_reason"] not in ("stop", "end_turn"):
        log.error("FAIL: unexpected finish_reason=%s (%ds)",
                  result["finish_reason"], elapsed)
        return 1

    summary = re.sub(r"\s+", " ", result["content"]).strip()[:120]
    log.info("OK: in %ds", elapsed)
    log.info("  Reply: %s", summary)
    return 0


# -------------------- Chunk translation --------------------

def _entry_to_item(idx: int, entry: polib.POEntry) -> dict[str, Any]:
    item: dict[str, Any] = {
        "id": idx,
        "msgid": entry.msgid,
    }
    if entry.msgctxt:
        item["msgctxt"] = entry.msgctxt
    if entry.msgid_plural:
        item["msgid_plural"] = entry.msgid_plural
    # `comment` is the extracted-comment field (#), which is where
    # `xgettext --add-comments=@translators` puts the translator notes.
    # `tcomment` is the hand-written `#.` field and is empty in these
    # catalogues, so reading it silently dropped all 28 @translators notes.
    if entry.comment:
        item["comments"] = [c for c in entry.comment.split("\n") if c.strip()]
    return item


_LANG_NOTE_CACHE: dict[str, str] = {}


def load_lang_note(lang_code: str) -> str:
    """Read the optional l10n/<lang_code>/ai_note.txt translator note.

    Returns the file's contents formatted as a prompt section, or "" when the
    locale ships no note. Read once per process and cached: the note is static
    for the whole run, and this sits in the per-chunk request path.
    """
    if lang_code in _LANG_NOTE_CACHE:
        return _LANG_NOTE_CACHE[lang_code]
    path = os.path.join(L10N_DIR, lang_code, LANG_NOTE_FILE)
    note = ""
    if os.path.isfile(path):
        try:
            with open(path, encoding="utf-8") as fh:
                body = fh.read().strip()
            if body:
                note = (
                    "\nTranslator notes for this locale (authoritative - they "
                    "override any general guidance above):\n" + body + "\n"
                )
        except OSError as exc:
            log.warning("[%s] cannot read %s: %s", lang_code, path, exc)
    _LANG_NOTE_CACHE[lang_code] = note
    return note


def _build_messages(
    cfg: Config, lang_code: str, lang_fullname: str, items: list[dict[str, Any]]
) -> list[dict[str, str]]:
    nplurals_match = re.search(r"nplurals\s*=\s*(\d+)", PLURAL_FORMS.get(lang_code, ""))
    nplurals = int(nplurals_match.group(1)) if nplurals_match else 1
    lang_en = LANG_EN[lang_code]

    user = USER_TEMPLATE.format(
        language=lang_fullname,
        language_en=lang_en,
        lang_code=lang_code,
        nplurals=nplurals,
        items_json=json.dumps(items, ensure_ascii=False, separators=(",", ":")),
    )
    return [
        {"role": "system", "content": SYSTEM_PROMPT.format(
            language=lang_fullname,
            language_en=lang_en,
            lang_code=lang_code,
            lang_note=load_lang_note(lang_code),
        )},
        {"role": "user", "content": user},
    ]


def _extract_balanced_json(text: str) -> str | None:
    """Extract the outermost balanced JSON object from text.

    Tracks braces and string-in/out state so nested objects and escaped
    characters inside strings are handled correctly, unlike a greedy regex.
    """
    start = text.find("{")
    if start == -1:
        return None
    depth = 0
    in_string = False
    escape = False
    for i, ch in enumerate(text[start:], start):
        if escape:
            escape = False
            continue
        if ch == "\\":
            escape = True
            continue
        if ch == '"':
            in_string = not in_string
            continue
        if in_string:
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    return None


def _extract_json(content: str) -> dict[str, Any]:
    """Parse the model's JSON content, tolerating stray markdown fences."""
    text = content.strip()
    # Strip code fences if present.
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text, count=1)
        text = re.sub(r"\s*```\s*$", "", text, count=1)
    try:
        return json.loads(text)
    except ValueError:
        json_text = _extract_balanced_json(text)
        if not json_text:
            log.error(
                "No balanced JSON object found in LLM content "
                "(first 500 chars):\n%s",
                text[:500],
            )
            raise
        try:
            return json.loads(json_text)
        except ValueError:
            log.error(
                "Failed to parse extracted JSON (first 500 chars):\n%s",
                json_text[:500],
            )
            raise


def _normalize_newlines(s: str) -> str:
    """Fix double-escaped newlines that some LLMs emit in JSON responses."""
    return s.replace("\\n", "\n")


def _check_markup(item: dict[str, Any], text: str, source: str,
                  allowed: set[str] | None = None) -> None:
    """Raise unless `text` preserves `source`'s markup and placeholders.

    `source` is the msgid this particular string is the translation of: the
    singular msgid for form 0, msgid_plural for the rest.
    `allowed` is the set of placeholder indices any source form of this entry
    may use, and defaults to `source`'s own. It exists because gettext picks
    the form from n at runtime, so for a plural entry every form has to carry
    whatever any of the source forms carries - a singular form that mentions
    %1 is grammatical sloppiness, not a wrong-slot answer, and rejecting it
    would retry a chunk that can never satisfy the check.

    Called per item during validation so a bad answer fails the chunk here
    rather than reaching the catalogue. The caller retries, then bisects, which
    re-asks for the offending entry on its own - far more likely to come back
    correct than the same entry inside a 20-item chunk.

    Both checks are footprints of the same failure: the model answering with
    the translation of some other msgid. "<b>Testing connection...</b>" came to
    hold "Base URL" in a dozen locales, and "Base URL, e.g. ..." came to hold a
    string with a %1 the msgid never had.
    """
    want = sorted(MARKUP_RE.findall(source))
    if want:
        got = sorted(MARKUP_RE.findall(text))
        if got != want:
            raise RuntimeError(
                f"id {item['id']}: translation does not preserve the msgid's "
                f"markup (expected {want}, got {got}). Copy the tags verbatim "
                f"from the msgid; msgid={source[:60]!r} text={text[:60]!r}"
            )
    if allowed is None:
        allowed = set(PLACEHOLDER_RE.findall(source))
    ghost = sorted(set(PLACEHOLDER_RE.findall(text)) - allowed)
    if ghost:
        raise RuntimeError(
            f"id {item['id']}: translation carries placeholder(s) "
            f"{['%' + g for g in ghost]} that its msgid does not have, so it "
            f"looks like the translation of a different msgid. "
            f"msgid={source[:60]!r} text={text[:60]!r}"
        )


def _validate_translations(
    items: list[dict[str, Any]],
    payload: dict[str, Any],
    nplurals: int,
) -> list[dict[str, Any]]:
    """Validate an id-keyed translations array against the request items.

    Contract: payload["translations"] is a list of {"id", "text"} objects, one
    per request item, carrying that item's own id. The id is load-bearing: a
    positional array has the right length even when the model has translated a
    different item, so a shifted answer used to pass validation silently and
    land in the catalogue as a string belonging to some other msgid. Keying by
    id turns that into a hard error the retry and bisect path already handles.

    A singular item expects "text" to be a non-empty string; a plural item
    (has msgid_plural) expects a list of nplurals non-empty strings. Order in
    the response is irrelevant. Returns [{"id", "msgstr"/"msgstr_plural"}] for
    _apply_translations.
    """
    translations = payload.get("translations")
    if not isinstance(translations, list):
        raise RuntimeError("response is missing 'translations' array")

    expected_ids = {item["id"] for item in items}
    by_id: dict[int, Any] = {}
    for t in translations:
        if not isinstance(t, dict):
            raise RuntimeError(
                f"each translation must be an object with 'id' and 'text', "
                f"got {t!r}"
            )
        if "id" not in t or "text" not in t:
            raise RuntimeError(f"translation missing 'id' or 'text': {t!r}")
        tid = t["id"]
        if not isinstance(tid, int) or isinstance(tid, bool):
            raise RuntimeError(f"translation id must be an integer, got {tid!r}")
        if tid not in expected_ids:
            raise RuntimeError(
                f"translation id {tid} was not in the request "
                f"(expected one of {sorted(expected_ids)})"
            )
        if tid in by_id:
            raise RuntimeError(f"duplicate translation id: {tid}")
        by_id[tid] = t["text"]

    missing = expected_ids - set(by_id)
    if missing:
        raise RuntimeError(
            f"response is missing {len(missing)} of {len(expected_ids)} items: "
            f"ids {sorted(missing)}"
        )

    out: list[dict[str, Any]] = []
    for item in items:
        text = by_id[item["id"]]
        if item.get("msgid_plural"):
            if not isinstance(text, list):
                raise RuntimeError(
                    f"id {item['id']}: plural item needs a list of "
                    f"{nplurals} forms, got {type(text).__name__}"
                )
            if len(text) != nplurals:
                raise RuntimeError(
                    f"id {item['id']}: plural item needs exactly {nplurals} "
                    f"forms, got {len(text)}"
                )
            if any(not isinstance(x, str) for x in text):
                raise RuntimeError(f"id {item['id']}: plural forms must be strings")
            if any(not x.strip() for x in text):
                raise RuntimeError(f"id {item['id']}: plural item has an empty form")
            plural_ok = (set(PLACEHOLDER_RE.findall(item["msgid"]))
                         | set(PLACEHOLDER_RE.findall(item.get("msgid_plural", ""))))
            for i, form in enumerate(text):
                source = item["msgid"] if i == 0 else item.get("msgid_plural", item["msgid"])
                _check_markup(item, form, source, allowed=plural_ok)
            out.append({"id": item["id"],
                        "msgstr_plural": [_normalize_newlines(f) for f in text]})
        else:
            if not isinstance(text, str):
                raise RuntimeError(
                    f"id {item['id']}: non-plural item needs a string, got {text!r}"
                )
            if not text.strip():
                raise RuntimeError(f"id {item['id']}: translation is empty")
            _check_markup(item, text, item["msgid"])
            out.append({"id": item["id"], "msgstr": _normalize_newlines(text)})
    return out


def _apply_translations(
    entries: list[polib.POEntry], items: list[dict[str, Any]],
    translations: list[dict[str, Any]],
) -> None:
    by_id = {t["id"]: t for t in translations}
    for idx, entry in enumerate(entries):
        t = by_id[idx]
        if entry.msgid_plural:
            entry.msgstr_plural = {i: v for i, v in enumerate(t["msgstr_plural"])}
        else:
            entry.msgstr = t["msgstr"]
        # A translated entry is no longer a "needs review" marker; msgfmt
        # otherwise leaves it out of the .mo.
        if "fuzzy" in entry.flags:
            entry.flags.remove("fuzzy")


JSON_RETRIES = 3


def _translate_chunk(
    cfg: Config,
    lang_code: str,
    lang_fullname: str,
    entries: list[polib.POEntry],
) -> None:
    """Translate a chunk of entries, with bisection on length-truncation.

    Retries the full API call up to JSON_RETRIES times when JSON extraction
    or validation fails, with exponential backoff. Length truncation is
    handled via bisection; a single entry that still truncates is retried
    with a boosted max_tokens budget (same content may succeed transiently,
    or need more output tokens for high-nplurals languages).
    """
    items = [_entry_to_item(i, e) for i, e in enumerate(entries)]
    nplurals_match = re.search(r"nplurals\s*=\s*(\d+)", PLURAL_FORMS.get(lang_code, ""))
    nplurals = int(nplurals_match.group(1)) if nplurals_match else 1

    sample_msgid = entries[0].msgid[:60] if entries else "<empty>"

    def attempt(
        payload_items: list[dict[str, Any]],
        max_tokens: int | None = None,
    ) -> list[dict[str, Any]]:
        messages = _build_messages(cfg, lang_code, lang_fullname, payload_items)
        result = request(cfg, messages, max_tokens=max_tokens)
        if result["finish_reason"] not in ("stop", "end_turn"):
            raise _LengthTruncation(result["finish_reason"], result["content"])
        payload = _extract_json(result["content"])
        return _validate_translations(payload_items, payload, nplurals)

    def attempt_single_with_boost() -> list[dict[str, Any]]:
        """Retry one entry with progressively larger output budgets."""
        try:
            return attempt(items)
        except _LengthTruncation as first:
            pass
        seen_budgets: set[int] = set()
        for boost in (2, 4):
            # Cap at 16384: DeepSeek-class endpoints max out at 8192
            # output tokens, OpenAI mini-tier at 16384 — higher values
            # just earn a non-retryable HTTP 400 there.
            boosted = min(cfg.max_tokens * boost, 16384)
            if boosted <= cfg.max_tokens or boosted in seen_budgets:
                continue
            seen_budgets.add(boosted)
            log_translate.warning(
                "[%s] single entry truncated (msgid=%r); "
                "retrying with max_tokens=%d",
                lang_code, sample_msgid, boosted,
            )
            try:
                return attempt(items, max_tokens=boosted)
            except _LengthTruncation:
                continue
        raise _LengthTruncation("length", "")

    last_error: Exception | None = None
    for retry in range(JSON_RETRIES):
        try:
            if len(entries) == 1:
                _apply_translations(entries, items, attempt_single_with_boost())
            else:
                _apply_translations(entries, items, attempt(items))
            return
        except _LengthTruncation as lt:
            if len(entries) == 1:
                raise RuntimeError(
                    f"[{lang_code}] single-entry chunk still truncated "
                    f"(finish_reason={lt.reason}) after boosted retries; "
                    f"msgid={entries[0].msgid!r}"
                ) from lt
            # Bisect and recurse. Attempt both halves even if the first
            # fails, so one bad entry doesn't silently drop its sibling.
            mid = len(entries) // 2
            first_err: Exception | None = None
            try:
                _translate_chunk(cfg, lang_code, lang_fullname, entries[:mid])
            except (RuntimeError, ValueError) as exc:
                first_err = exc
            _translate_chunk(cfg, lang_code, lang_fullname, entries[mid:])
            if first_err is not None:
                raise first_err
            return
        except (ValueError, RuntimeError) as exc:
            last_error = exc
            if retry < JSON_RETRIES - 1:
                sleep_for = 2 ** retry + random.uniform(0, 2 ** retry * 0.25)
                log_translate.warning(
                    "[retry %d/%d] chunk for %s (msgid=%r): %s",
                    retry + 1, JSON_RETRIES, lang_code, sample_msgid, exc,
                )
                time.sleep(sleep_for)
                continue
            raise RuntimeError(
                f"[{lang_code}] chunk failed (msgid={sample_msgid!r}) "
                f"after {JSON_RETRIES} retries: {last_error}"
            ) from last_error


class _LengthTruncation(Exception):
    def __init__(self, reason: str, content: str) -> None:
        super().__init__(reason)
        self.reason = reason
        self.content = content


# -------------------- Main translation flow --------------------

def _chunk(seq: list, size: int) -> Iterable[list]:
    for i in range(0, len(seq), size):
        yield seq[i:i + size]


def _set_header_metadata(po: polib.POFile, lang_code: str, lang_fullname: str) -> None:
    """Populate the .po file header with language metadata.

    Used when a catalogue was just created from the .pot by `msginit` and still
    has placeholder header values (e.g. "nplurals=INTEGER;
    plural=EXPRESSION;").
    """
    po.metadata["Language"] = lang_code
    po.metadata["Content-Type"] = "text/plain; charset=UTF-8"
    po.metadata["Plural-Forms"] = PLURAL_FORMS.get(
        lang_code, "nplurals=2; plural=(n != 1);"
    )
    po.metadata["Language-Team"] = f"{lang_fullname} (AI translation)"
    po.metadata["Last-Translator"] = "AI (auto)"
    po.metadata["PO-Revision-Date"] = time.strftime("%Y-%m-%d %H:%M+0000", time.gmtime())


def translate_file(cfg: Config, lang_code: str, path: str) -> int:
    """Fill the empty and fuzzy entries of one catalogue in place."""
    lang_fullname = LANG_MAP[lang_code]
    partial_path = path + ".partial"

    route = cfg.get_route()
    log_translate.info(
        "[%s] translating %s (protocol=%s endpoint=%s model=%s)",
        lang_code, lang_fullname, route.protocol, route.endpoint, route.model,
    )

    resumed = os.path.isfile(partial_path)
    if resumed:
        log_translate.warning("[%s] resuming from existing partial: %s", lang_code, partial_path)
        po = load_po(partial_path)
    else:
        po = load_po(path)

    # Guarantee UTF-8 output: polib saves with the header-declared encoding,
    # and an emptied catalogue is pure ASCII, so gettext tools may have
    # rewritten its header to `charset=ASCII`, which fails on the first
    # non-ASCII translation.
    po.encoding = "UTF-8"
    content_type = po.metadata.get("Content-Type", "")
    if "charset=" not in content_type:
        po.metadata["Content-Type"] = "text/plain; charset=UTF-8"
    elif "charset=utf-8" not in content_type.lower():
        head, _, _ = content_type.partition("charset=")
        po.metadata["Content-Type"] = f"{head}charset=UTF-8"

    # Detect whether the header is a fresh `msginit` placeholder (new locale)
    # and needs Language / Plural-Forms / Language-Team / Last-Translator
    # filled in before saving. Existing headers are preserved untouched.
    existing_plural = po.metadata.get("Plural-Forms", "")
    header_is_placeholder = "INTEGER" in existing_plural or not existing_plural
    needs_header_fix = (
        not po.metadata.get("Language") or header_is_placeholder
    )

    pending: list[polib.POEntry] = [
        e for e in po if not e.obsolete and (is_empty(e) or "fuzzy" in e.flags)
    ]

    if not pending:
        log_translate.info("[%s] nothing to translate; all entries are already filled", lang_code)
        # Do not rewrite a clean catalogue: `make ai-translate` walks every
        # locale, and an untouched file must not churn. A resumed partial still
        # needs the final rename, and a placeholder header still needs fixing.
        if not resumed and not needs_header_fix:
            return 0
    else:
        total = len(pending)
        chunks = list(_chunk(pending, cfg.chunk_size))
        log_translate.info(
            "[%s] %d entries in %d chunks of up to %d",
            lang_code, total, len(chunks), cfg.chunk_size,
        )

        def save_partial() -> None:
            if needs_header_fix:
                _set_header_metadata(po, lang_code, lang_fullname)
            # Atomic write: save to a temp file in the same directory, then rename.
            tmp_fd, tmp_path = tempfile.mkstemp(
                prefix=".ai_translate.", suffix=".tmp",
                dir=os.path.dirname(partial_path) or ".",
            )
            os.close(tmp_fd)
            try:
                po.save(tmp_path)
                os.replace(tmp_path, partial_path)
            except Exception:
                if os.path.isfile(tmp_path):
                    os.unlink(tmp_path)
                raise

        failed_chunks = 0
        for i, chunk_entries in enumerate(chunks, 1):
            t0 = time.time()
            try:
                _translate_chunk(cfg, lang_code, lang_fullname, chunk_entries)
            except RuntimeError as exc:
                # Keep going: save whatever the bisect halves completed so
                # a single bad entry doesn't block the remaining chunks.
                # Partial is kept (final is NOT written) so a re-run
                # resumes at the failed entries.
                failed_chunks += 1
                log_translate.error(
                    "[%s] [chunk %d/%d] FAILED (%d failed so far): %s",
                    lang_code, i, len(chunks), failed_chunks, exc,
                )
            save_partial()
            elapsed = time.time() - t0
            log_translate.info(
                "[%s] [chunk %d/%d] %d entries in %.1fs",
                lang_code, i, len(chunks), len(chunk_entries), elapsed,
            )

        if failed_chunks:
            raise RuntimeError(
                f"[{lang_code}] {failed_chunks}/{len(chunks)} chunk(s) failed; "
                f"partial progress saved, re-run to resume"
            )

    if needs_header_fix:
        _set_header_metadata(po, lang_code, lang_fullname)

    # Atomic rename partial -> final.
    tmp_fd, tmp_path = tempfile.mkstemp(
        prefix=".ai_translate.", suffix=".tmp", dir=os.path.dirname(path) or "."
    )
    os.close(tmp_fd)
    try:
        po.save(tmp_path)
        os.replace(tmp_path, path)
    except Exception:
        if os.path.isfile(tmp_path):
            os.unlink(tmp_path)
        raise

    if os.path.isfile(partial_path):
        os.unlink(partial_path)

    log_translate.info("[%s] done %s", lang_code, lang_fullname)
    return 0


# -------------------- CLI --------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="ai_translate.py",
        description="Translate a locale's assistant.po in place using an LLM API, "
                    "with chunked JSON-in/JSON-out requests to avoid output "
                    "truncation.",
    )
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument(
        "lang_code", nargs="?", help="Language code (e.g. 'fr', 'de', 'zh_CN')."
    )
    g.add_argument(
        "--check-api", "--ping", "-t", dest="check_api", action="store_true",
        help="Send a minimal request to verify the default route's connectivity.",
    )
    g.add_argument(
        "--check-api-lang", dest="check_api_lang", metavar="LANG_CODE",
        help="Verify connectivity using a locale's merged settings "
             "(l10n/<lang>/.env over l10n/.env; e.g. --check-api-lang sk).",
    )
    g.add_argument(
        "--check-data", dest="check_data", action="store_true",
        help="Validate LANG_MAP/LANG_EN/PLURAL_FORMS against the catalogues "
             "on disk and exit (offline; needs no API key).",
    )
    p.add_argument(
        "--log-level",
        choices=("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"),
        help="Override log level (default: INFO, or DEBUG if AI_DEBUG=1).",
    )
    return p


def _apply_log_level(level_name: str) -> None:
    level = getattr(logging, level_name.upper(), None)
    if level is None:
        return
    logging.getLogger().setLevel(level)
    log.setLevel(level)
    log_http.setLevel(level)
    log_translate.setLevel(level)


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.log_level:
        _apply_log_level(args.log_level)

    # The static-table check is offline and must not build a Config: it needs
    # no API key, endpoint or .env, so short-circuit before any of that.
    if args.check_data:
        return check_data()

    # Resolve the target locale before building the Config: a locale-bound
    # Config merges l10n/<lang>/.env over l10n/.env, while --check-api uses the
    # global settings only (lang_code=None).
    lang_code: str | None
    if args.check_api:
        lang_code = None
    elif args.check_api_lang is not None:
        if args.check_api_lang not in LANG_MAP:
            log.error("language code %r not supported", args.check_api_lang)
            return 2
        lang_code = args.check_api_lang
    else:
        if args.lang_code not in LANG_MAP:
            log.error("language code %r not supported", args.lang_code)
            return 2
        if args.lang_code not in LANG_EN:
            log.error("language code %r has no LANG_EN entry; add its English "
                      "name so the prompt can disambiguate the endonym", args.lang_code)
            return 2
        lang_code = args.lang_code

    try:
        cfg = Config(lang_code)
    except ValueError as exc:
        log.error("%s", exc)
        return 2

    route = cfg.get_route()
    cfg.require_api_key(route)

    log.info("API protocol: %s", route.protocol)
    log.info("API endpoint: %s", route.endpoint)
    log.info("API model:    %s", route.model)
    if is_opencode_api(route.base_url):
        log.info("opencode API detected; x-opencode-session=%s",
                 cfg.opencode_session or RUN_SESSION_ID)

    if args.check_api:
        return check_api(cfg)

    if args.check_api_lang is not None:
        return check_api(cfg)

    path = os.path.join(args.lang_code, PO_FILE)
    if not os.path.isfile(path):
        log.error(
            "catalogue %s not found; run `make update` first (it creates "
            "missing locales from the template).", path,
        )
        return 2

    try:
        return translate_file(cfg, args.lang_code, path)
    except KeyboardInterrupt:
        partial = path + ".partial"
        if os.path.isfile(partial):
            log.warning(
                "interrupted by user; partial output saved at %s — "
                "re-run to resume.", partial,
            )
        else:
            log.warning("interrupted by user; no partial output to save.")
        return 130
    except RuntimeError as exc:
        if logging.getLogger().isEnabledFor(logging.DEBUG):
            log.exception("translation failed")
        else:
            log.error("[%s] FAILED: %s", args.lang_code, exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())

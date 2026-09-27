#!/usr/bin/env python3
"""
ai_translate.py - Drive a gettext .po translation pipeline through an LLM API.

This is the Python replacement for AI_TRANSLATE.sh. It avoids the truncation
issue (finish_reason=length) by:

  * Communicating with the LLM via a strict JSON-in / JSON-out contract:
    the model is asked to return {"translations": [...]} (a positional array,
    one element per request item in order) for a list of msgids, instead of
    emitting an entire .po file as free-form text.
  * Constraining the output with a strict JSON Schema (object/array/string
    types; lengths enforced by prompt + client validation), with automatic
    fallback to {"type": "json_object"} when the endpoint rejects json_schema
    (AI_JSON_SCHEMA=auto by default; off forces json_object, on forces
    json_schema without fallback; AI_JSON_MODE=0 disables response_format).
  * Sending compact request items (only id/msgid plus non-empty
    msgctxt/msgid_plural/comments) as single-line JSON to save tokens.
  * Splitting the work into small chunks (default 20 msgids per request)
    so the per-response output is well below any provider's token cap.
  * On length-truncation, automatically bisecting the chunk and retrying.
  * Persisting progress as `<output>.partial` after every chunk, so a
    crash, Ctrl-C, or API failure never loses already-completed work.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import random
import re
import secrets
import shutil
import signal
import sys
import tempfile
import time
from typing import Any, Iterable

import polib
import requests
from dotenv import load_dotenv

# -------------------- Logging --------------------

_log_level_name = os.environ.get("AI_LOG_LEVEL", "").upper()
if not _log_level_name and os.environ.get("AI_DEBUG", "").lower() in ("1", "true", "yes"):
    _log_level_name = "DEBUG"
_LOG_LEVEL = getattr(logging, _log_level_name, logging.INFO)

logging.basicConfig(
    level=_LOG_LEVEL,
    format="[%(asctime)s] [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    stream=sys.stderr,
)

log = logging.getLogger("ai_translate")
log_http = logging.getLogger("ai_translate.http")
log_translate = logging.getLogger("ai_translate.translate")


# -------------------- Constants --------------------

# Endonym mapping for supported languages.
# Keep in sync with Makefile's LANGS variable and KOReader's l10n directory.
# Run `make check-langs` to detect drift.
LANG_MAP: dict[str, str] = {
    "af_ZA": "Afrikaans",
    "ar": "عربى",
    "be": "Беларуская",
    "bg_BG": "български",
    "bn": "বাংলা",
    "ca": "Catalá",
    "cs": "Čeština",
    "cy": "Cymraeg",
    "da": "Dansk",
    "de": "Deutsch",
    "el": "Ελληνικά",
    "eo": "Esperanto",
    "es": "Español",
    "et": "Eesti",
    "eu": "Euskara",
    "fa": "فارسی",
    "fi": "Suomi",
    "fr": "Français",
    "ga": "Gaeilge",
    "gl": "Galego",
    "he": "עִבְרִית",
    "hi": "हिन्दी",
    "hr": "Hrvatski",
    "hu": "Magyar",
    "ia": "Interlingua",
    "id": "Bahasa Indonesia",
    "ie": "Interlingue",
    "it_IT": "Italiano",
    "ja": "日本語",
    "ka": "ქართული",
    "kab": "Taqbaylit",
    "kn": "ಕನ್ನಡ",
    "ko_KR": "한국어",
    "lt_LT": "Lietuvių",
    "lv": "Latviešu",
    "mk": "Македонски",
    "ms": "Bahasa Melayu",
    "nb_NO": "Norsk bokmål",
    "nl_NL": "Nederlands",
    "nn": "Norsk nynorsk",
    "or": "ଓଡ଼ିଆ",
    "pl": "Polski",
    "pt_BR": "Português do Brasil",
    "pt_PT": "Português",
    "ro": "Română",
    "ro_MD": "Română (Moldova)",
    "ru": "Русский",
    "si": "සිංහල",
    "sk": "Slovenčina",
    "sl": "Slovenščina",
    "sr": "Српски",
    "sv": "Svenska",
    "th": "ภาษาไทย",
    "tr": "Türkçe",
    "uk": "Українська",
    "ur": "اردو",
    "uz": "Oʻzbekcha",
    "vi": "Tiếng Việt",
    "zh_CN": "简体中文",
    "zh_TW": "中文（台灣）",
}

# English name of every supported language. The endonym alone is not a safe
# language identifier for an LLM: "Slovenčina" is valid Slovak but reads
# literally as "Slovene", which sent the Slovak locale out in Slovenian for
# months (see l10n/sk/ai_note.txt). The English name is the disambiguating
# anchor and is always included in the prompt.
# Keep in sync with Makefile's LANGS and LANG_MAP; `make check-langs` verifies.
LANG_EN: dict[str, str] = {
    "af_ZA": "Afrikaans",
    "ar": "Arabic",
    "be": "Belarusian",
    "bg_BG": "Bulgarian",
    "bn": "Bengali",
    "ca": "Catalan",
    "cs": "Czech",
    "cy": "Welsh",
    "da": "Danish",
    "de": "German",
    "el": "Greek",
    "eo": "Esperanto",
    "es": "Spanish",
    "et": "Estonian",
    "eu": "Basque",
    "fa": "Persian",
    "fi": "Finnish",
    "fr": "French",
    "ga": "Irish",
    "gl": "Galician",
    "he": "Hebrew",
    "hi": "Hindi",
    "hr": "Croatian",
    "hu": "Hungarian",
    "ia": "Interlingua",
    "id": "Indonesian",
    "ie": "Interlingue",
    "it_IT": "Italian",
    "ja": "Japanese",
    "ka": "Georgian",
    "kab": "Kabyle",
    "kn": "Kannada",
    "ko_KR": "Korean",
    "lt_LT": "Lithuanian",
    "lv": "Latvian",
    "mk": "Macedonian",
    "ms": "Malay",
    "nb_NO": "Norwegian Bokmål",
    "nl_NL": "Dutch",
    "nn": "Norwegian Nynorsk",
    "or": "Odia",
    "pl": "Polish",
    "pt_BR": "Brazilian Portuguese",
    "pt_PT": "European Portuguese",
    "ro": "Romanian",
    "ro_MD": "Romanian (Moldova)",
    "ru": "Russian",
    "si": "Sinhala",
    "sk": "Slovak",
    "sl": "Slovenian",
    "sr": "Serbian",
    "sv": "Swedish",
    "th": "Thai",
    "tr": "Turkish",
    "uk": "Ukrainian",
    "ur": "Urdu",
    "uz": "Uzbek",
    "vi": "Vietnamese",
    "zh_CN": "Simplified Chinese",
    "zh_TW": "Traditional Chinese (Taiwan)",
}

# Static Plural-Forms table extracted from KOReader's official translations
# under /usr/lib/koreader/l10n/<lang>/koreader.po headers. Used when the
# Python script generates a fresh assistant.po from a .pot (scenario 1).
#
# Three entries are corrected against CLDR rather than copied from upstream:
# sk, uk and lt_LT all ship upstream as nplurals=4 with a no-op `n % 1 == 0`
# guard wrapped around the Czech three-form rule, so form 3 is unreachable.
# Each is genuinely a three-form language. gettext reads Plural-Forms from the
# header of the catalogue being loaded, and msgfmt bakes nplurals into the
# .mo, so a self-consistent header is all that matters here.
PLURAL_FORMS: dict[str, str] = {
    "af_ZA": "nplurals=2; plural=(n != 1);",
    "ar": "nplurals=6; plural=n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5;",
    "be": "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);",
    "bg_BG": "nplurals=2; plural=n != 1;",
    "bn": "nplurals=2; plural=n > 1;",
    "ca": "nplurals=2; plural=n != 1;",
    "cs": "nplurals=3; plural=((n==1) ? 0 : (n>=2 && n<=4) ? 1 : 2);",
    "cy": "nplurals=6; plural=(n==0) ? 0 : (n==1) ? 1 : (n==2) ? 2 : (n==3) ? 3 :(n==6) ? 4 : 5;",
    "da": "nplurals=2; plural=n != 1;",
    "de": "nplurals=2; plural=n != 1;",
    "el": "nplurals=2; plural=n != 1;",
    "eo": "nplurals=2; plural=n != 1;",
    "es": "nplurals=2; plural=n != 1;",
    "et": "nplurals=2; plural=n != 1;",
    "eu": "nplurals=2; plural=n != 1;",
    "fa": "nplurals=2; plural=n > 1;",
    "fi": "nplurals=2; plural=n != 1;",
    "fr": "nplurals=2; plural=n > 1;",
    "ga": "nplurals=5; plural=n==1 ? 0 : n==2 ? 1 : (n>2 && n<7) ? 2 :(n>6 && n<11) ? 3 : 4;",
    "gl": "nplurals=2; plural=n != 1;",
    "he": "nplurals=4; plural=(n == 1) ? 0 : ((n == 2) ? 1 : ((n > 10 && n % 10 == 0) ? 2 : 3));",
    "hi": "nplurals=2; plural=n > 1;",
    "hr": "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);",
    "hu": "nplurals=2; plural=n != 1;",
    "ia": "nplurals=2; plural=n != 1;",
    "id": "nplurals=1; plural=0;",
    "ie": "nplurals=2; plural=n != 1;",
    "it_IT": "nplurals=2; plural=n != 1;",
    "ja": "nplurals=1; plural=0;",
    "ka": "nplurals=2; plural=n != 1;",
    "kab": "nplurals=2; plural=n > 1;",
    "kn": "nplurals=2; plural=n > 1;",
    "ko_KR": "nplurals=1; plural=0;",
    "lt_LT": "nplurals=3; plural=((n % 10 == 1 && (n % 100 > 19 || n % 100 < 11)) ? 0 : ((n % 10 >= 2 && n % 10 <= 9) && (n % 100 > 19 || n % 100 < 11)) ? 1 : 2);",
    "lv": "nplurals=3; plural=(n % 10 == 0 || n % 100 >= 11 && n % 100 <= 19) ? 0 : ((n % 10 == 1 && n % 100 != 11) ? 1 : 2);",
    "mk": "nplurals=2; plural=n==1 || n%10==1 ? 0 : 1;",
    "ms": "nplurals=1; plural=0;",
    "nb_NO": "nplurals=2; plural=n != 1;",
    "nl_NL": "nplurals=2; plural=n != 1;",
    "nn": "nplurals=2; plural=n != 1;",
    "or": "nplurals=2; plural=n != 1;",
    "pl": "nplurals=4; plural=(n==1 ? 0 : (n%10>=2 && n%10<=4) && (n%100<12 || n%100>14) ? 1 : n!=1 && (n%10>=0 && n%10<=1) || (n%10>=5 && n%10<=9) || (n%100>=12 && n%100<=14) ? 2 : 3);",
    "pt_BR": "nplurals=2; plural=n > 1;",
    "pt_PT": "nplurals=2; plural=n != 1;",
    "ro": "nplurals=3; plural=n==1 ? 0 : (n==0 || (n%100 > 0 && n%100 < 20)) ? 1 : 2;",
    "ro_MD": "nplurals=3; plural=(n == 1) ? 0 : ((n == 0 || n != 1 && n % 100 >= 1 && n % 100 <= 19) ? 1 : 2);",
    "ru": "nplurals=4; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : n%10==0 || (n%10>=5 && n%10<=9) || (n%100>=11 && n%100<=14)? 2 : 3);",
    "si": "nplurals=2; plural=n > 1;",
    "sk": "nplurals=3; plural=((n==1) ? 0 : (n>=2 && n<=4) ? 1 : 2);",
    "sl": "nplurals=4; plural=n%100==1 ? 0 : n%100==2 ? 1 : n%100==3 || n%100==4 ? 2 : 3;",
    "sr": "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);",
    "sv": "nplurals=2; plural=n != 1;",
    "th": "nplurals=1; plural=0;",
    "tr": "nplurals=2; plural=n > 1;",
    "uk": "nplurals=3; plural=((n % 1 == 0 && n % 10 == 1 && n % 100 != 11) ? 0 : (n % 1 == 0 && n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14)) ? 1 : 2);",
    "ur": "nplurals=2; plural=n != 1;",
    "uz": "nplurals=2; plural=n != 1;",
    "vi": "nplurals=1; plural=0;",
    "zh_CN": "nplurals=1; plural=0;",
    "zh_TW": "nplurals=1; plural=0;",
}

TEMPLATE_FILE = "templates/assistant.pot"

# Directory holding the per-locale catalogues, resolved from this file so the
# script works no matter which directory it is invoked from.
LANG_DIR = os.path.dirname(os.path.abspath(__file__))

# Per-language translator notes, read from l10n/<lang>/ai_note.txt and appended
# to the system prompt. The file is optional and its contents are free text, so
# a native speaker can add terminology, style rules or confusion warnings for
# their own locale without touching this file. Only languages that need a
# warning carry one; see load_lang_note() and l10n/README.md.
LANG_NOTE_FILE = "ai_note.txt"

# Markup the translation must carry over from the msgid. AGENTS.md invariant 4:
# <b> is parsed by bold_format, not real HTML, so a dropped tag is a rendering
# bug, not a cosmetic one. A translation that also lost the tag is the visible
# footprint of a wrong-slot answer - when the model replies with the
# translation of some other msgid, the tags of the msgid it was actually given
# are the ones that go missing. That is how "<b>Testing connection...</b>" came
# to hold "Base URL" in a dozen locales.
#
# Only markup is enforced here, not printf placeholders: a language is allowed
# to move a placeholder or attach a suffix to it (Afrikaans "%1$s nie",
# Uzbek "%1ni"), so rejecting those would stall the pipeline on entries the
# model is not wrong about. Placeholder integrity is left to check_mix.py.
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


# -------------------- Configuration --------------------

class Config:
    """Runtime configuration loaded from .env and environment variables."""

    def __init__(self) -> None:
        load_dotenv(".env", override=False)

        self.api_key: str = os.environ.get("API_KEY", "")
        self.api_endpoint: str = os.environ.get(
            "API_ENDPOINT", "https://api.openai.com/v1/chat/completions"
        )
        self.api_model: str = os.environ.get("API_MODEL", "gpt-4o-mini")

        # OpenCode Go/Zen (API_ENDPOINT containing "opencode.ai") requires an
        # `x-opencode-session` header carrying a stable opaque id for
        # routing/prompt caching. The Makefile generates one id per run and
        # passes it via RANDOM_SESSION_ID (explicit env wins); direct
        # script runs without it fall back to a per-process id below.
        # Other endpoints never see this value (see _build_headers).
        self.opencode_session: str = os.environ.get("RANDOM_SESSION_ID", "")

        # Model recommendations for bulk gettext translation (50+ languages,
        # many low-resource). Flash/mini-tier models are preferred: the quality
        # gap on short UI strings is barely perceptible, while large models
        # cost 10-20x more for no practical gain here.
        #
        #   - Gemini 2.5 Flash (or Flash-Lite): best multilingual coverage and
        #     cost/latency for low-resource languages. Point API_ENDPOINT at
        #     Google's OpenAI-compat layer or use OpenRouter.
        #   - GPT-4.1-mini / GPT-5-mini: stay on the OpenAI-native endpoint,
        #     better JSON adherence and translation quality than gpt-4o-mini at
        #     comparable cost.
        #   - Claude Haiku 4.5: highest nuance/tone for UI copy, but requires an
        #     Anthropic-compatible proxy (OpenRouter/LiteLLM); not a native
        #     /v1/chat/completions endpoint.
        #
        # Avoid gpt-4o / Claude Sonnet-tier models for batch translation.

        self.chunk_size: int = int(os.environ.get("AI_CHUNK_SIZE", "20"))
        self.max_tokens: int = int(os.environ.get("AI_MAX_TOKENS", "8192"))
        self.request_timeout: int = int(os.environ.get("AI_REQUEST_TIMEOUT", "120"))
        self.max_retries: int = int(os.environ.get("AI_MAX_RETRIES", "8"))
        self.max_chunk_time: int = int(os.environ.get("AI_MAX_CHUNK_TIME", "900"))
        self.json_mode: bool = os.environ.get("AI_JSON_MODE", "1").lower() not in (
            "0", "false", "no",
        )
        # JSON Schema strict-mode control for response_format:
        #   auto (default): send json_schema, fall back to json_object once
        #     on HTTP 400 mentioning response_format/json_schema/unsupported.
        #   off: send {"type": "json_object"} directly.
        #   on: force json_schema; a rejection raises without fallback.
        # AI_JSON_MODE=0 still disables response_format entirely (escape hatch).
        self.json_schema_mode: str = os.environ.get("AI_JSON_SCHEMA", "auto").strip().lower() or "auto"
        if self.json_schema_mode not in ("auto", "off", "on"):
            self.json_schema_mode = "auto"

    def require_api_key(self) -> None:
        if not self.api_key:
            log.error("API_KEY environment variable not set.")
            sys.exit(1)


# Fallback id sent as `x-opencode-session` when neither the Makefile nor the
# user provides RANDOM_SESSION_ID (e.g. direct `./ai_translate.py <lang>`
# runs). Same 16-char URL-safe style as the Makefile id. Note parallel make
# jobs would each get their own id from this fallback, so prefer going
# through make for shared caching/routing.
_RUN_SESSION_ID = secrets.token_urlsafe(12)


def _is_opencode_api(endpoint: str) -> bool:
    return "opencode.ai" in (endpoint or "").lower()


def _build_headers(cfg: Config) -> dict[str, str]:
    """Request headers, adding `x-opencode-session` for the opencode API."""
    headers = {
        "Authorization": f"Bearer {cfg.api_key}",
        "Content-Type": "application/json",
    }
    if _is_opencode_api(cfg.api_endpoint):
        headers["x-opencode-session"] = cfg.opencode_session or _RUN_SESSION_ID
    return headers


# -------------------- Connectivity check --------------------

def check_api(cfg: Config) -> int:
    """Send a minimal request to verify API connectivity."""
    log.info("Checking API connectivity...")
    log.info("  Endpoint: %s", cfg.api_endpoint)
    log.info("  Model:    %s", cfg.api_model)

    payload = {
        "model": cfg.api_model,
        "temperature": 0,
        "max_tokens": 256,
        "messages": [
            {
                "role": "system",
                "content": "You are a connectivity test. Reply with exactly the word OK.",
            },
            {"role": "user", "content": "ping"},
        ],
    }

    start = time.time()
    try:
        response = requests.post(
            cfg.api_endpoint,
            json=payload,
            headers=_build_headers(cfg),
            timeout=30,
        )
    except requests.RequestException as exc:
        log.error("FAIL: network error: %s", exc)
        return 1
    elapsed = int(time.time() - start)

    if not (200 <= response.status_code < 300):
        log.error("FAIL: HTTP %d (%ds)", response.status_code, elapsed)
        log.error("Response body (first 2KB):\n%s", response.text[:2000])
        return 1

    try:
        data = response.json()
    except ValueError as exc:
        log.error("FAIL: invalid JSON response (%ds): %s", elapsed, exc)
        log.error("%s", response.text[:2000])
        return 1

    if "error" in data:
        err = data["error"]
        msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
        log.error("FAIL: API error: %s", msg)
        return 1

    try:
        choices = data.get("choices") or [{}]
        message = choices[0].get("message") or {}
        reply = message.get("content") or ""
    except (KeyError, IndexError, TypeError, AttributeError):
        log.error("FAIL: malformed response (%ds)", elapsed)
        log.error("%s", json.dumps(data, indent=2)[:2000])
        return 1

    summary = re.sub(r"\s+", " ", reply).strip()[:120]
    log.info("OK: HTTP %d in %ds", response.status_code, elapsed)
    log.info("  Reply: %s", summary)
    return 0


# -------------------- File-path decisions --------------------

def decide_paths(lang_code: str) -> tuple[str | None, str | None, str | None]:
    """Return (action, input_path, output_path).

    action is one of:
      - "translate": translate input_path and write to output_path
      - "skip":      both files already exist; nothing to do
      - "error":     inconsistent state on disk
    """
    translated = os.path.join(lang_code, "assistant.po")
    untranslated = os.path.join(lang_code, "untranslated.po")
    updated_translated = os.path.join(lang_code, "updated_translated.po")

    has_translated = os.path.isfile(translated)
    has_untranslated = os.path.isfile(untranslated)
    has_updated = os.path.isfile(updated_translated)

    if has_translated and has_updated:
        return "skip", None, None
    if not has_translated and not has_untranslated:
        # Scenario 1: new language; copy the template into place first.
        if not os.path.isfile(TEMPLATE_FILE):
            log.error("template file '%s' not found.", TEMPLATE_FILE)
            return "error", None, None
        os.makedirs(lang_code, exist_ok=True)
        shutil.copyfile(TEMPLATE_FILE, untranslated)
        return "translate", untranslated, translated
    if has_translated and has_untranslated:
        # Scenario 2: update an existing language.
        return "translate", untranslated, updated_translated

    log.error(
        "translate files not ready for %s: assistant.po=%s untranslated.po=%s "
        "updated_translated.po=%s. Run `make extract-untranslated` first (the "
        "ai-translate target does this for you, or use `make translate`).",
        lang_code, has_translated, has_untranslated, has_updated,
    )
    return "error", None, None


# -------------------- LLM call --------------------

def _parse_retry_after(resp: requests.Response) -> float | None:
    """Extract the Retry-After header (in seconds) if present and numeric."""
    raw = resp.headers.get("Retry-After")
    if not raw:
        return None
    try:
        return max(0.0, float(raw))
    except ValueError:
        return None


def _classify(
    resp: requests.Response | None, exc: BaseException | None
) -> tuple[bool, float | None, str]:
    """Return (is_retryable, retry_after_seconds, reason_string)."""
    if exc is not None:
        if isinstance(
            exc,
            (requests.ReadTimeout, requests.ConnectTimeout,
             requests.ConnectionError, requests.exceptions.ChunkedEncodingError),
        ):
            return True, None, f"network:{type(exc).__name__}"
        if isinstance(exc, ValueError):
            # JSON decode error on a 2xx response: rare, but worth one retry.
            return True, None, "json_decode"
        return False, None, f"fatal:{type(exc).__name__}"
    assert resp is not None
    if resp.status_code == 429:
        return True, _parse_retry_after(resp), "HTTP 429"
    if 500 <= resp.status_code < 600:
        return True, None, f"HTTP {resp.status_code}"
    if 400 <= resp.status_code < 500:
        return False, None, f"HTTP {resp.status_code} (client error)"
    return False, None, f"HTTP {resp.status_code}"


def _compute_backoff(
    attempt: int,
    retry_after: float | None,
    chunk_start: float,
    cfg: Config,
) -> float:
    """Exponential backoff with jitter, respecting Retry-After and time budget."""
    base = min(2 ** attempt, 60)  # 2, 4, 8, 16, 32, 60, 60, 60 ...
    jitter = random.uniform(0, base * 0.25)
    backoff = base + jitter
    if retry_after is not None:
        backoff = max(backoff, retry_after)
    remaining = cfg.max_chunk_time - (time.time() - chunk_start)
    return max(1.0, min(backoff, max(0.0, remaining - 1)))


def _build_response_format(cfg: Config) -> dict[str, Any] | None:
    """Build response_format for a chat completion request.

    Returns None when cfg.json_mode is False (AI_JSON_MODE=0 escape hatch:
    no response_format is sent). Otherwise returns either a strict
    json_schema contract (default) or {"type": "json_object"} when
    AI_JSON_SCHEMA=off.

    The schema pins down object/array/string types only. Array lengths
    (translations == request items, plural forms == nplurals) are enforced
    by the prompt plus _validate_translations instead: strict-mode
    providers reject length keywords like minItems/maxItems.
    """
    if not cfg.json_mode:
        return None
    if getattr(cfg, "json_schema_mode", "auto") == "off":
        return {"type": "json_object"}
    return {
        "type": "json_schema",
        "json_schema": {
            "name": "po_translations",
            "strict": True,
            "schema": {
                "type": "object",
                "properties": {
                    "translations": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "id": {"type": "integer"},
                                "text": {
                                    "anyOf": [
                                        {"type": "string"},
                                        {"type": "array", "items": {"type": "string"}},
                                    ]
                                },
                            },
                            "required": ["id", "text"],
                            "additionalProperties": False,
                        },
                    }
                },
                "required": ["translations"],
                "additionalProperties": False,
            },
        },
    }


def _post_chat(
    cfg: Config,
    messages: list[dict[str, str]],
    max_tokens: int | None = None,
) -> dict[str, Any]:
    """POST a chat completion request with retry on transient errors.

    Retries on: network errors (Read/Connect/Connection/ChunkedEncoding),
    HTTP 429 (respecting Retry-After), HTTP 5xx, and JSON decode failures
    on 2xx responses. Hard-fails on 4xx (other than 429) without retry.
    Caps total time spent on a single chunk at cfg.max_chunk_time seconds.
    Each retry logs a one-liner with reason, sleep duration, and elapsed
    time vs the chunk budget.

    The output contract is enforced via response_format: strict json_schema
    by default (AI_JSON_SCHEMA=auto), plain json_object when
    AI_JSON_SCHEMA=off, and no response_format when AI_JSON_MODE=0. In auto
    mode a 400 that mentions response_format/json_schema/unsupported (or
    "not supported") falls back to json_object exactly once.
    """
    payload = {
        "model": cfg.api_model,
        "temperature": 0.2,
        "max_tokens": max_tokens or cfg.max_tokens,
        "messages": messages,
    }
    response_format = _build_response_format(cfg)
    if response_format is not None:
        # Strict JSON Schema by default; requires "json" in the prompt
        # (SYSTEM_PROMPT/USER_TEMPLATE already satisfy this). Set
        # AI_JSON_MODE=0 for endpoints that reject response_format outright,
        # or AI_JSON_SCHEMA=off to use plain {"type": "json_object"}.
        payload["response_format"] = response_format
    using_schema = isinstance(response_format, dict) and response_format.get("type") == "json_schema"
    schema_mode = getattr(cfg, "json_schema_mode", "auto")
    downgraded = False

    headers = _build_headers(cfg)

    chunk_start = time.time()
    last_reason = "unknown"
    resp: requests.Response | None = None

    for attempt in range(1, cfg.max_retries + 1):
        if time.time() - chunk_start >= cfg.max_chunk_time:
            raise RuntimeError(
                f"chunk exceeded AI_MAX_CHUNK_TIME={cfg.max_chunk_time}s "
                f"after {attempt - 1} attempts; last reason: {last_reason}"
            )

        try:
            resp = requests.post(
                cfg.api_endpoint,
                json=payload,
                headers=headers,
                timeout=cfg.request_timeout,
            )
        except requests.RequestException as exc:
            retryable, retry_after, reason = _classify(None, exc)
            last_reason = reason
            if not retryable:
                raise RuntimeError(f"non-retryable network error: {exc}") from exc
            if attempt >= cfg.max_retries:
                raise RuntimeError(
                    f"exhausted {cfg.max_retries} retries on {reason}: {exc}"
                ) from exc
            sleep_for = _compute_backoff(attempt, retry_after, chunk_start, cfg)
            elapsed = int(time.time() - chunk_start)
            log_http.info(
                "[retry %d/%d] reason=%s sleep=%.1fs (elapsed=%ds/%ds)",
                attempt, cfg.max_retries, reason, sleep_for,
                elapsed, cfg.max_chunk_time,
            )
            time.sleep(sleep_for)
            continue

        # Response received. Decide what to do.
        if 200 <= resp.status_code < 300:
            try:
                return _parse_response(resp)
            except (ValueError, RuntimeError) as parse_exc:
                # JSON decode errors on 2xx are worth retrying a couple of times.
                if attempt >= min(3, cfg.max_retries):
                    raise
                last_reason = "json_decode"
                sleep_for = _compute_backoff(attempt, None, chunk_start, cfg)
                elapsed = int(time.time() - chunk_start)
                log_http.info(
                    "[retry %d/%d] reason=json_decode sleep=%.1fs "
                    "(elapsed=%ds/%ds)",
                    attempt, cfg.max_retries, sleep_for,
                    elapsed, cfg.max_chunk_time,
                )
                time.sleep(sleep_for)
                continue

        retryable, retry_after, reason = _classify(resp, None)
        last_reason = reason
        if not retryable:
            if (
                resp.status_code == 400
                and using_schema
                and not downgraded
                and schema_mode == "auto"
            ):
                body = (resp.text or "").lower()
                if (
                    "response_format" in body
                    or "json_schema" in body
                    or "unsupported" in body
                    or "not supported" in body
                ):
                    log_http.warning(
                        "json_schema rejected (HTTP 400); "
                        "falling back to json_object once: %s",
                        (resp.text or "")[:300],
                    )
                    payload["response_format"] = {"type": "json_object"}
                    using_schema = False
                    downgraded = True
                    continue
            raise RuntimeError(
                f"{reason}: {resp.text[:2000]}"
            )
        if attempt >= cfg.max_retries:
            raise RuntimeError(
                f"exhausted {cfg.max_retries} retries on {reason}: "
                f"{resp.text[:500]}"
            )
        sleep_for = _compute_backoff(attempt, retry_after, chunk_start, cfg)
        elapsed = int(time.time() - chunk_start)
        log_http.info(
            "[retry %d/%d] reason=%s sleep=%.1fs (elapsed=%ds/%ds)",
            attempt, cfg.max_retries, reason, sleep_for,
            elapsed, cfg.max_chunk_time,
        )
        time.sleep(sleep_for)

    # Defensive: if we exit the loop without returning, treat as exhausted.
    raise RuntimeError(
        f"exhausted {cfg.max_retries} retries; last reason: {last_reason}"
    )


def _parse_response(resp: requests.Response) -> dict[str, Any]:
    if not (200 <= resp.status_code < 300):
        raise RuntimeError(
            f"HTTP {resp.status_code}: {resp.text[:2000]}"
        )
    try:
        data = resp.json()
    except ValueError as exc:
        raise RuntimeError(f"invalid JSON: {exc}; body={resp.text[:500]!r}")

    if "error" in data:
        err = data["error"]
        msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
        raise RuntimeError(f"API error: {msg}")

    try:
        choice = data["choices"][0]
    except (KeyError, IndexError, TypeError):
        raise RuntimeError(f"malformed response: {json.dumps(data)[:500]}")

    finish_reason = choice.get("finish_reason", "stop")
    content = (choice.get("message") or {}).get("content") or ""

    return {
        "finish_reason": finish_reason,
        "content": content,
        "raw": data,
    }


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
    path = os.path.join(LANG_DIR, lang_code, LANG_NOTE_FILE)
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
        result = _post_chat(cfg, messages, max_tokens=max_tokens)
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

    Used for scenario 1 (new language) where we generated the .po from the .pot,
    and for scenario 2 where the source untranslated.po has placeholder header
    values from `msginit` (e.g. "nplurals=INTEGER; plural=EXPRESSION;").
    """
    po.metadata["Language"] = lang_code
    po.metadata["Plural-Forms"] = PLURAL_FORMS.get(
        lang_code, "nplurals=2; plural=(n != 1);"
    )
    po.metadata["Language-Team"] = f"{lang_fullname} (AI translation)"
    po.metadata["Last-Translator"] = "AI (auto)"
    po.metadata["PO-Revision-Date"] = time.strftime("%Y-%m-%d %H:%M+0000", time.gmtime())


def translate_file(
    cfg: Config, lang_code: str, input_path: str, output_path: str
) -> int:
    lang_fullname = LANG_MAP[lang_code]
    partial_path = output_path + ".partial"

    log_translate.info("[%s] translating %s", lang_code, lang_fullname)

    if os.path.isfile(partial_path):
        log_translate.warning("[%s] resuming from existing partial: %s", lang_code, partial_path)
        po = polib.pofile(partial_path, wrapwidth=0)
    else:
        po = polib.pofile(input_path, wrapwidth=0)

    # Detect whether the header is a fresh `msginit` placeholder (scenario 1
    # new language, or scenario 2 update whose untranslated.po was regenerated
    # by the Makefile and still has placeholder values). In both cases we need
    # to overwrite Language / Plural-Forms / Language-Team / Last-Translator
    # before saving the final output. Existing non-placeholder headers (e.g.
    # the real assistant.po copied from upstream) are preserved untouched.
    existing_plural = po.metadata.get("Plural-Forms", "")
    header_is_placeholder = "INTEGER" in existing_plural or not existing_plural
    needs_header_fix = (
        not po.metadata.get("Language") or header_is_placeholder
    )

    pending: list[polib.POEntry] = [
        e for e in po
        if (e.msgid_plural and not any(e.msgstr_plural.values()))
        or (not e.msgid_plural and not (e.msgstr or "").strip())
    ]

    if not pending:
        log_translate.info("[%s] nothing to translate; all entries are already filled", lang_code)
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
        prefix=".ai_translate.", suffix=".tmp", dir=os.path.dirname(output_path) or "."
    )
    os.close(tmp_fd)
    try:
        po.save(tmp_path)
        os.replace(tmp_path, output_path)
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
        description="Translate gettext .po files using an LLM API, with chunked "
                    "JSON-in/JSON-out requests to avoid output truncation.",
    )
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument(
        "lang_code", nargs="?", help="Language code (e.g. 'fr', 'de', 'zh_CN')."
    )
    g.add_argument(
        "--check-api", "--ping", "-t", dest="check_api", action="store_true",
        help="Send a minimal request to verify API connectivity.",
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

    cfg = Config()
    cfg.require_api_key()

    log.info("API endpoint: %s", cfg.api_endpoint)
    log.info("API model:    %s", cfg.api_model)
    if _is_opencode_api(cfg.api_endpoint):
        log.info("opencode API detected; x-opencode-session=%s",
                 cfg.opencode_session or _RUN_SESSION_ID)

    if args.check_api:
        return check_api(cfg)

    if args.lang_code not in LANG_MAP:
        log.error("language code %r not supported", args.lang_code)
        return 2
    if args.lang_code not in LANG_EN:
        log.error("language code %r has no LANG_EN entry; add its English "
                  "name so the prompt can disambiguate the endonym", args.lang_code)
        return 2

    action, input_path, output_path = decide_paths(args.lang_code)
    if action == "skip":
        log.info(
            "skip %s: translation already complete", args.lang_code,
        )
        return 0
    if action == "error":
        return 2

    assert input_path is not None and output_path is not None
    try:
        return translate_file(cfg, args.lang_code, input_path, output_path)
    except KeyboardInterrupt:
        partial = output_path + ".partial"
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

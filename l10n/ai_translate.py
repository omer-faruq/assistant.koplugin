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
  * Persisting progress as `<output>.partial` after every chunk, so a
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
import secrets
import shutil
import signal
import sys
import tempfile
import time
from typing import Any, Iterable

import polib
from dotenv import dotenv_values

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

# Settings files. The global file is l10n/.env; a locale may add
# l10n/<lang>/.env to override it. Both are resolved from LANG_DIR, and both
# are gitignored and release-excluded, so real credentials never get committed.
GLOBAL_ENV_FILE = os.path.join(LANG_DIR, ".env")
LOCALE_ENV_NAME = ".env"


def locale_env_file(lang_code: str) -> str:
    """Absolute path of a locale's optional settings file."""
    return os.path.join(LANG_DIR, lang_code, LOCALE_ENV_NAME)


def load_settings(lang_code: str | None = None) -> dict[str, str]:
    """Resolve effective settings for a locale.

    Precedence, highest first: exported process environment, l10n/<lang>/.env
    (when lang_code is given), l10n/.env. Files are read with dotenv_values, so
    the process environment is never mutated as a side effect. A blank value is
    dropped at every layer, so an empty entry in a locale file cannot erase the
    global value it was meant to leave alone. Missing keys are simply absent.
    """
    merged: dict[str, str] = {}
    paths = [GLOBAL_ENV_FILE]
    if lang_code:
        paths.append(locale_env_file(lang_code))
    for path in paths:
        for key, value in dotenv_values(path).items():
            if value is None or value == "":
                continue
            merged[key] = value
    for key, value in os.environ.items():
        if value == "":
            continue
        merged[key] = value
    return merged


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


# -------------------- Configuration --------------------

# Wire formats the SDK adapter speaks. `chat_completions` is the default for
# every locale; `responses` is the OpenAI Responses API. The selector is
# explicit config (API_PROTOCOL), read from l10n/.env or the locale's
# l10n/<lang>/.env, never derived from the base URL.
PROTOCOLS: tuple[str, ...] = ("chat_completions", "responses")

# Base URL of the OpenAI-compatible API, used when API_BASE is unset. The
# protocol selects the path appended to it to form the full endpoint.
DEFAULT_BASE_URL = "https://api.openai.com/v1"

# Path appended to API_BASE for each protocol to build the full endpoint.
PROTOCOL_PATHS: dict[str, str] = {
    "chat_completions": "/chat/completions",
    "responses": "/responses",
}
DEFAULT_MODEL = "gpt-4o-mini"

# Project-identifying User-Agent. OpenCode's Go inference docs require a
# stable client identity for routing/analytics.
USER_AGENT = "assistant.koplugin-l10n/1.0 (+https://github.com/omer-faruq/assistant.koplugin)"


def _normalize_protocol(value: str | None) -> str:
    """Return a known protocol name, defaulting to chat_completions."""
    v = (value or "chat_completions").strip().lower()
    if v not in PROTOCOLS:
        raise ValueError(
            f"unsupported API_PROTOCOL {value!r}; use one of {', '.join(PROTOCOLS)}"
        )
    return v


def _endpoint_for(base_url: str, protocol: str) -> str:
    """Build the full endpoint from API_BASE and the protocol's path.

    API_BASE is a bare base URL; the protocol appends its own path. A trailing
    slash is removed first, so "https://host/v1" and "https://host/v1/" yield
    the same endpoint.
    """
    return (base_url or "").rstrip("/") + PROTOCOL_PATHS[protocol]


class Route:
    """A resolved per-locale API route (protocol, credentials, base URL, model)."""

    __slots__ = ("lang_code", "protocol", "api_key", "base_url", "endpoint", "model")

    def __init__(
        self, lang_code: str | None, protocol: str, api_key: str,
        base_url: str, model: str,
    ) -> None:
        self.lang_code = lang_code
        self.protocol = protocol
        self.api_key = api_key
        self.base_url = base_url
        self.endpoint = _endpoint_for(base_url, protocol)
        self.model = model


class Config:
    """Runtime configuration resolved for one locale from its settings.

    A locale-bound Config merges l10n/.env with l10n/<lang>/.env; a global
    Config (lang_code=None) reads l10n/.env only. Both layer the exported
    process environment on top.

    route_prefix selects a parallel set of route keys without touching the
    shared AI_* knobs: the reviewer builds its Config with "L10N_REVIEW_", so
    it reads L10N_REVIEW_API_KEY/PROTOCOL/BASE/MODEL while still honouring the
    same AI_JSON_SCHEMA, timeout and retry settings as the translator. An
    unset prefixed key falls back to the unprefixed translator key (API_*),
    then to the built-in default, so an unconfigured reviewer silently shares
    the translator's route. default_protocol is used when neither the prefixed
    nor the unprefixed API_PROTOCOL key is set.
    """

    def __init__(
        self,
        lang_code: str | None = None,
        route_prefix: str = "",
        default_protocol: str | None = None,
    ) -> None:
        self.lang_code = lang_code
        settings = load_settings(lang_code)

        def _route_key(name: str) -> str:
            if route_prefix:
                return settings.get(f"{route_prefix}{name}", "") or settings.get(
                    name, ""
                )
            return settings.get(name, "")

        self.api_key: str = _route_key("API_KEY")
        self.api_protocol: str = _normalize_protocol(
            _route_key("API_PROTOCOL") or default_protocol
        )
        self.api_base: str = _route_key("API_BASE") or DEFAULT_BASE_URL
        self.api_model: str = _route_key("API_MODEL") or DEFAULT_MODEL

        self._route: Route | None = None
        self._clients: dict[tuple[str, str, str], Any] = {}

        # OpenCode Go/Zen (API_BASE containing "opencode.ai") requires an
        # `x-opencode-session` header carrying a stable opaque id for
        # routing/prompt caching. The Makefile generates one id per run and
        # passes it via RANDOM_SESSION_ID (explicit env wins); direct
        # script runs without it fall back to a per-process id below.
        # Other endpoints never see this value (see get_client).
        self.opencode_session: str = settings.get("RANDOM_SESSION_ID", "")

        # Model recommendations for bulk gettext translation (50+ languages,
        # many low-resource). Flash/mini-tier models are preferred: the quality
        # gap on short UI strings is barely perceptible, while large models
        # cost 10-20x more for no practical gain here.
        #
        #   - Gemini 2.5 Flash (or Flash-Lite): best multilingual coverage and
        #     cost/latency for low-resource languages. Point API_BASE at
        #     Google's OpenAI-compat layer or use OpenRouter.
        #   - GPT-4.1-mini / GPT-5-mini: stay on the OpenAI-native endpoint,
        #     better JSON adherence and translation quality than gpt-4o-mini at
        #     comparable cost.
        #   - Claude Haiku 4.5: highest nuance/tone for UI copy, but requires an
        #     Anthropic-compatible proxy (OpenRouter/LiteLLM); not a native
        #     /v1/chat/completions endpoint.
        #
        # Avoid gpt-4o / Claude Sonnet-tier models for batch translation.

        self.chunk_size: int = int(settings.get("AI_CHUNK_SIZE", "20"))
        self.max_tokens: int = int(settings.get("AI_MAX_TOKENS", "8192"))
        self.request_timeout: int = int(settings.get("AI_REQUEST_TIMEOUT", "120"))
        self.max_retries: int = int(settings.get("AI_MAX_RETRIES", "8"))
        self.json_mode: bool = settings.get("AI_JSON_MODE", "1").lower() not in (
            "0", "false", "no",
        )
        # JSON Schema strict-mode control:
        #   auto (default): send json_schema, fall back to json_object once
        #     on HTTP 400 mentioning response_format/json_schema/unsupported.
        #   off: send {"type": "json_object"} directly.
        #   on: force json_schema; a rejection raises without fallback.
        # AI_JSON_MODE=0 still disables the format entirely (escape hatch).
        self.json_schema_mode: str = settings.get(
            "AI_JSON_SCHEMA", "auto"
        ).strip().lower() or "auto"
        if self.json_schema_mode not in ("auto", "off", "on"):
            self.json_schema_mode = "auto"

    def get_route(self) -> Route:
        """Return the route for this Config's settings, built once and cached.

        The global and locale files were already merged in __init__, so the
        route is whatever API_PROTOCOL / API_BASE / API_MODEL / API_KEY
        resolved to for this Config's locale.
        """
        if self._route is None:
            self._route = Route(
                lang_code=self.lang_code,
                protocol=self.api_protocol,
                api_key=self.api_key,
                base_url=self.api_base,
                model=self.api_model,
            )
        return self._route

    def get_client(self, route: Route) -> Any:
        """Return a cached SDK client for the route (built once per run)."""
        key = (route.protocol, route.base_url, route.api_key)
        client = self._clients.get(key)
        if client is None:
            client = _build_client(self, route)
            self._clients[key] = client
        return client

    def require_api_key(self, route: Route) -> None:
        """Exit unless the route carries an API key.

        The key comes from the route's resolved settings (process environment
        or the relevant .env file); only the route this invocation actually
        uses has to be set.
        """
        if route.api_key:
            return
        if self.lang_code:
            log.error(
                "API_KEY not set (checked the process environment, "
                "l10n/%s/.env and l10n/.env).", self.lang_code,
            )
        else:
            log.error(
                "API_KEY not set (checked the process environment and l10n/.env)."
            )
        sys.exit(1)


# Fallback id sent as `x-opencode-session` when neither the Makefile nor the
# user provides RANDOM_SESSION_ID (e.g. direct `./ai_translate.py <lang>`
# runs). Same 16-char URL-safe style as the Makefile id. Note parallel make
# jobs would each get their own id from this fallback, so prefer going
# through make for shared caching/routing.
_RUN_SESSION_ID = secrets.token_urlsafe(12)


def _is_opencode_api(base_url: str) -> bool:
    return "opencode.ai" in (base_url or "").lower()


def _import_openai():
    """Import the OpenAI SDK lazily so pure-config paths stay import-light."""
    try:
        import openai
    except ImportError as exc:
        raise RuntimeError(
            "the 'openai' package is required; install it with 'pip install openai'"
        ) from exc
    return openai


def _build_client(cfg: Config, route: Route) -> Any:
    """Build an SDK client for a route.

    Deliberately one client per run/route: the SDK owns timeouts and retries
    (cfg.request_timeout, cfg.max_retries), so there is no second HTTP loop.
    """
    openai = _import_openai()
    headers = {"User-Agent": USER_AGENT}
    if _is_opencode_api(route.base_url):
        headers["x-opencode-session"] = cfg.opencode_session or _RUN_SESSION_ID
    return openai.OpenAI(
        api_key=route.api_key,
        base_url=route.base_url,
        timeout=float(cfg.request_timeout),
        max_retries=cfg.max_retries,
        default_headers=headers,
    )


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
        result = _request(cfg, messages, max_tokens=256, json_format=False)
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

# The JSON Schema for the {"translations": [...]} answer. It pins down
# object/array/string types only: strict-mode providers reject length keywords
# like minItems/maxItems, so array lengths (translations == request items,
# plural forms == nplurals) are enforced by the prompt plus
# _validate_translations instead.
TRANSLATIONS_SCHEMA: dict[str, Any] = {
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
}


def _get(obj: Any, name: str, default: Any = None) -> Any:
    """Read a field from either an SDK object or a plain dict."""
    if obj is None:
        return default
    if isinstance(obj, dict):
        return obj.get(name, default)
    return getattr(obj, name, default)


def _json_format_spec(
    cfg: Config,
    schema: dict[str, Any] | None = None,
    name: str = "po_translations",
) -> dict[str, Any] | None:
    """Protocol-neutral JSON output-format spec.

    Returns None when cfg.json_mode is False (AI_JSON_MODE=0: no format is
    sent), {"type": "json_object"} when AI_JSON_SCHEMA=off, or a
    Responses-style json_schema format otherwise. Callers adapt it to their
    wire format. schema/name default to the translation contract; the reviewer
    passes its own verdict schema.
    """
    if not cfg.json_mode:
        return None
    if getattr(cfg, "json_schema_mode", "auto") == "off":
        return {"type": "json_object"}
    return {
        "type": "json_schema",
        "name": name,
        "strict": True,
        "schema": schema if schema is not None else TRANSLATIONS_SCHEMA,
    }


def _chat_response_format(spec: dict[str, Any] | None) -> dict[str, Any] | None:
    """Convert a neutral spec to a Chat Completions response_format."""
    if spec is None:
        return None
    if spec["type"] == "json_object":
        return {"type": "json_object"}
    return {
        "type": "json_schema",
        "json_schema": {
            "name": spec["name"],
            "strict": spec["strict"],
            "schema": spec["schema"],
        },
    }


def _split_messages(
    messages: list[dict[str, str]],
) -> tuple[str | None, list[dict[str, str]]]:
    """Map chat messages to Responses `instructions` + `input`."""
    instructions: list[str] = []
    input_items: list[dict[str, str]] = []
    for message in messages:
        if message.get("role") == "system":
            instructions.append(message.get("content", ""))
        else:
            input_items.append(
                {"role": message.get("role"), "content": message.get("content", "")}
            )
    return ("\n\n".join(instructions) or None), input_items


def _chat_result(completion: Any) -> dict[str, Any]:
    """Normalize a ChatCompletion into finish_reason/content/raw."""
    choices = _get(completion, "choices", None) or []
    if not choices:
        raise RuntimeError("chat completion returned no choices")
    choice = choices[0]
    message = _get(choice, "message", None)
    refusal = _get(message, "refusal", None)
    if refusal:
        raise RuntimeError(f"chat completion refused the request: {refusal[:200]}")
    return {
        "finish_reason": _get(choice, "finish_reason", None) or "stop",
        "content": _get(message, "content", None) or "",
        "raw": completion,
    }


def _responses_refusal(response: Any) -> str | None:
    """Return the refusal text from a Responses output, if any."""
    for item in _get(response, "output", None) or []:
        if _get(item, "type", None) != "message":
            continue
        for part in _get(item, "content", None) or []:
            if _get(part, "type", None) == "refusal":
                return _get(part, "refusal", "") or ""
    return None


def _responses_result(response: Any) -> dict[str, Any]:
    """Normalize a Response into finish_reason/content/raw.

    A refusal or a failed response raises (never accepted as a translation);
    an incomplete response truncated by max_output_tokens maps to
    finish_reason=length so the existing bisection path handles it.
    """
    refusal = _responses_refusal(response)
    if refusal is not None:
        raise RuntimeError(f"Responses API refused the request: {refusal[:200]}")

    status = _get(response, "status", None)
    text = _get(response, "output_text", None) or ""
    if status == "incomplete":
        details = _get(response, "incomplete_details", None)
        reason = _get(details, "reason", None)
        if reason == "max_output_tokens":
            return {"finish_reason": "length", "content": text, "raw": response}
        raise RuntimeError(
            f"Responses API response incomplete: {reason or 'unknown'}"
        )
    if status == "failed":
        error = _get(response, "error", None)
        message = _get(error, "message", None) or error
        raise RuntimeError(f"Responses API response failed: {message}")
    if status not in (None, "completed"):
        raise RuntimeError(f"Responses API unexpected status: {status}")
    return {"finish_reason": "stop", "content": text, "raw": response}


def _is_schema_rejection(exc: BaseException) -> bool:
    """True for an HTTP 400 that blames json_schema/response_format."""
    if getattr(exc, "status_code", None) != 400:
        return False
    body = str(exc).lower()
    return (
        "response_format" in body
        or "json_schema" in body
        or "unsupported" in body
        or "not supported" in body
    )


def _as_runtime_error(exc: BaseException) -> RuntimeError:
    if isinstance(exc, RuntimeError):
        return exc
    return RuntimeError(f"{type(exc).__name__}: {exc}")


def _call_chat(
    route: Route,
    client: Any,
    messages: list[dict[str, str]],
    spec: dict[str, Any] | None,
    max_tokens: int,
) -> dict[str, Any]:
    kwargs: dict[str, Any] = {
        "model": route.model,
        "messages": messages,
        "max_tokens": max_tokens,
        # Chat Completions keeps the project's low-temperature setting; the
        # Responses path omits it because Grok rejects the parameter.
        "temperature": 0.2,
    }
    response_format = _chat_response_format(spec)
    if response_format is not None:
        kwargs["response_format"] = response_format
    completion = client.chat.completions.create(**kwargs)
    return _chat_result(completion)


def _call_responses(
    route: Route,
    client: Any,
    messages: list[dict[str, str]],
    spec: dict[str, Any] | None,
    max_output_tokens: int,
) -> dict[str, Any]:
    instructions, input_items = _split_messages(messages)
    kwargs: dict[str, Any] = {
        "model": route.model,
        "input": input_items,
        "max_output_tokens": max_output_tokens,
    }
    if instructions is not None:
        kwargs["instructions"] = instructions
    if spec is not None:
        kwargs["text"] = {"format": spec}
    response = client.responses.create(**kwargs)
    return _responses_result(response)


def _request(
    cfg: Config,
    messages: list[dict[str, str]],
    max_tokens: int | None = None,
    json_format: bool = True,
    schema: dict[str, Any] | None = None,
    schema_name: str = "po_translations",
) -> dict[str, Any]:
    """Send one request over the config's route; return finish_reason/content/raw.

    Transport errors, retries and the request timeout are the SDK's job
    (OpenAI(timeout=..., max_retries=...)), so this makes exactly one call per
    attempt and only adds the json_schema -> json_object downgrade, which the
    SDK does not perform. schema/schema_name override the structured-output
    contract (the reviewer sends its verdict schema).
    """
    route = cfg.get_route()
    client = cfg.get_client(route)
    spec = _json_format_spec(cfg, schema, schema_name) if json_format else None
    budget = max_tokens or cfg.max_tokens
    downgraded = False

    while True:
        try:
            if route.protocol == "responses":
                return _call_responses(route, client, messages, spec, budget)
            return _call_chat(route, client, messages, spec, budget)
        except Exception as exc:
            if (
                spec is not None
                and spec.get("type") == "json_schema"
                and not downgraded
                and getattr(cfg, "json_schema_mode", "auto") == "auto"
                and _is_schema_rejection(exc)
            ):
                log_http.warning(
                    "json_schema rejected (HTTP 400); falling back to "
                    "json_object once: %s",
                    str(exc)[:300],
                )
                spec = {"type": "json_object"}
                downgraded = True
                continue
            raise _as_runtime_error(exc)


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
        result = _request(cfg, messages, max_tokens=max_tokens)
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
    po.metadata["Content-Type"] = "text/plain; charset=UTF-8"
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

    route = cfg.get_route()
    log_translate.info(
        "[%s] translating %s (protocol=%s endpoint=%s model=%s)",
        lang_code, lang_fullname, route.protocol, route.endpoint, route.model,
    )

    if os.path.isfile(partial_path):
        log_translate.warning("[%s] resuming from existing partial: %s", lang_code, partial_path)
        po = polib.pofile(partial_path, wrapwidth=0)
    else:
        po = polib.pofile(input_path, wrapwidth=0)

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


# -------------------- Static data check --------------------

def catalogue_codes() -> list[str]:
    """Locales that ship an assistant.po catalogue, sorted."""
    return [name for name in sorted(os.listdir(LANG_DIR))
            if os.path.isfile(os.path.join(LANG_DIR, name, "assistant.po"))]


def check_data() -> int:
    """Validate the static language tables against the catalogues on disk.

    Offline and deterministic: it reads LANG_MAP, LANG_EN, PLURAL_FORMS and the
    per-locale assistant.po headers, so it needs no SDK, API key or .env. It
    verifies:
      - LANG_MAP, LANG_EN and PLURAL_FORMS all cover the same set of locales
      - every .po header agrees with PLURAL_FORMS on nplurals (msgfmt enforces
        this too, but the message here names the language)
      - every plural entry declares exactly nplurals forms
      - which locales ship a translator note
    """
    ok = True
    codes = catalogue_codes()
    missing_en = sorted(set(LANG_MAP) - set(LANG_EN))
    missing_pf = sorted(set(LANG_MAP) - set(PLURAL_FORMS))
    extra_en = sorted(set(LANG_EN) - set(LANG_MAP))
    on_disk_only = sorted(set(codes) - set(LANG_MAP))
    for label, vals in (("LANG_MAP without LANG_EN", missing_en),
                        ("LANG_MAP without PLURAL_FORMS", missing_pf),
                        ("LANG_EN without LANG_MAP", extra_en),
                        ("catalogue without LANG_MAP", on_disk_only)):
        if vals:
            ok = False
            print(f"FAIL {label}: {', '.join(vals)}")

    print("plural forms (PLURAL_FORMS vs the .po header):")
    for lang in codes:
        want = PLURAL_FORMS.get(lang)
        if not want:
            continue
        want_n = re.search(r"nplurals\s*=\s*(\d+)", want)
        have = polib.pofile(os.path.join(LANG_DIR, lang, "assistant.po"))
        have_pf = have.metadata.get("Plural-Forms", "")
        have_n = re.search(r"nplurals\s*=\s*(\d+)", have_pf)
        if not have_n or not want_n:
            ok = False
            print(f"  FAIL {lang}: header has no nplurals")
        elif have_n.group(1) != want_n.group(1):
            ok = False
            print(f"  FAIL {lang}: header nplurals={have_n.group(1)} but "
                  f"PLURAL_FORMS says {want_n.group(1)}")
        # nplurals must also match the number of forms actually present
        for e in have:
            if e.msgid_plural and len(e.msgstr_plural) != int(want_n.group(1)):
                ok = False
                print(f"  FAIL {lang}: {e.msgid[:40]!r} has "
                      f"{len(e.msgstr_plural)} forms, expected "
                      f"{want_n.group(1)}")

    notes = sorted(d for d in codes
                   if os.path.isfile(os.path.join(LANG_DIR, d, LANG_NOTE_FILE)))
    print(f"\nlanguages with a translator note ({len(notes)}): "
          f"{', '.join(notes) or 'none'}")
    print("OK" if ok else "FAILED")
    return 0 if ok else 1


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
    if _is_opencode_api(route.base_url):
        log.info("opencode API detected; x-opencode-session=%s",
                 cfg.opencode_session or _RUN_SESSION_ID)

    if args.check_api:
        return check_api(cfg)

    if args.check_api_lang is not None:
        return check_api(cfg)

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

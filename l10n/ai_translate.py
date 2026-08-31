#!/usr/bin/env python3
"""
ai_translate.py - Drive a gettext .po translation pipeline through an LLM API.

This is the Python replacement for AI_TRANSLATE.sh. It avoids the truncation
issue (finish_reason=length) by:

  * Communicating with the LLM via a strict JSON-in / JSON-out contract:
    the model is asked to return {"translations": [...]} for a list of
    msgids, instead of emitting an entire .po file as free-form text.
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
    "zh_TW": "中文（台灣)",
}

# Static Plural-Forms table extracted from KOReader's official translations
# under /usr/lib/koreader/l10n/<lang>/koreader.po headers. Used when the
# Python script generates a fresh assistant.po from a .pot (scenario 1).
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
    "lt_LT": "nplurals=4; plural=(n % 10 == 1 && (n % 100 > 19 || n % 100 < 11) ? 0 : (n % 10 >= 2 && n % 10 <=9) && (n % 100 > 19 || n % 100 < 11) ? 1 : n % 1 != 0 ? 2: 3);",
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
    "sk": "nplurals=4; plural=(n % 1 == 0 && n == 1 ? 0 : n % 1 == 0 && n >= 2 && n <= 4 ? 1 : n % 1 != 0 ? 2: 3);",
    "sl": "nplurals=4; plural=n%100==1 ? 0 : n%100==2 ? 1 : n%100==3 || n%100==4 ? 2 : 3;",
    "sr": "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);",
    "sv": "nplurals=2; plural=n != 1;",
    "th": "nplurals=1; plural=0;",
    "tr": "nplurals=2; plural=n > 1;",
    "uk": "nplurals=4; plural=(n % 1 == 0 && n % 10 == 1 && n % 100 != 11 ? 0 : n % 1 == 0 && n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14) ? 1 : n % 1 == 0 && (n % 10 ==0 || (n % 10 >=5 && n % 10 <=9) || (n % 100 >=11 && n % 100 <=14 )) ? 2: 3);",
    "ur": "nplurals=2; plural=n != 1;",
    "uz": "nplurals=2; plural=n != 1;",
    "vi": "nplurals=1; plural=0;",
    "zh_CN": "nplurals=1; plural=0;",
    "zh_TW": "nplurals=1; plural=0;",
}

TEMPLATE_FILE = "templates/assistant.pot"

SYSTEM_PROMPT = """You are an expert localization specialist translating user-facing strings for an AI assistant plugin in KOReader, an open-source e-book reader, into {language} ({lang_code}). The strings appear in menus, dialogs, buttons, settings, and error messages.

Domain context: this plugin is an AI assistant for a reading app. It lets readers ask questions about their current book, get translations, summaries, and X-Ray/Recap-style analysis of the text, run web-search tool calls, and capture quick notes — using cloud AI providers (Anthropic, OpenAI, Gemini, DeepSeek, Ollama, Groq, Mistral, GigaChat, OpenRouter, Gemma) and configurable models.

Translate software/AI terminology using the established conventions of the target language's software and AI community, not literal dictionary translations. In particular:
  - "provider" / "AI provider" means an AI/API service provider (a company or self-hosted service supplying the model). Use the target language's standard term for a cloud/service provider (e.g. the equivalent of "service provider" / "vendor" in that language), not a literal "the one who provides".
  - "model" means a machine-learning model, not "type/pattern/template".
  - "prompt" means the instruction text sent to an AI, not "hint/encouragement".
  - "token" is an AI token; keep it or use the language's accepted AI term.
  - "streaming" means real-time streamed output.
  - "web search" means internet/online search; "tool calling" means the AI invoking external tools.
  - E-reader terms: "annotation" = a reader's margin note, "highlight" = selected/emphasized text, "notebook" = the note collection.
  - Feature names ("X-Ray", "Recap", "Term X-Ray") may stay in English or be translated consistently across the file.

You will receive a JSON object describing the target language and a list of items to translate. Each item has:
  - id: the index of the item (use this id verbatim in your response)
  - msgctxt: optional context hint (may be null)
  - msgid: the English source string
  - msgid_plural: optional plural form (only present for plural entries; otherwise null)
  - comments: list of translator notes (may be empty)

Translate each item, taking into account the comments and msgctxt. Preserve all printf-style placeholders (e.g. %s, %d, %1$s), HTML/XML tags, newlines, and leading/trailing whitespace exactly as they appear in msgid.

Output rules:
- Reply with a single JSON object of the form {{"translations": [...]}}.
- For each item, produce exactly one entry whose "id" matches the request.
- For a non-plural item: return {{"id": <int>, "msgstr": "<translation>"}}.
- For a plural item: return {{"id": <int>, "msgstr_plural": ["<form 0>", "<form 1>", ...]}}; the array length must equal the nplurals value supplied in the request.
- Do not return the msgid back unchanged as msgstr unless the source is a technical token (URL, format spec, brand name) that must stay in English.
- Do not include any prose, markdown fences, or extra keys.
"""

USER_TEMPLATE = """Target language: {language} ({lang_code})
nplurals: {nplurals}

Items to translate:
{items_json}

Respond with JSON only, matching the contract in the system prompt."""


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
        self.max_tokens: int = int(os.environ.get("AI_MAX_TOKENS", "4096"))
        self.request_timeout: int = int(os.environ.get("AI_REQUEST_TIMEOUT", "120"))
        self.max_retries: int = int(os.environ.get("AI_MAX_RETRIES", "8"))
        self.max_chunk_time: int = int(os.environ.get("AI_MAX_CHUNK_TIME", "900"))
        self.json_mode: bool = os.environ.get("AI_JSON_MODE", "1").lower() not in (
            "0", "false", "no",
        )

    def require_api_key(self) -> None:
        if not self.api_key:
            log.error("API_KEY environment variable not set.")
            sys.exit(1)


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
            headers={
                "Authorization": f"Bearer {cfg.api_key}",
                "Content-Type": "application/json",
            },
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
        "translate files not ready for %s: translated=%s untranslated=%s updated=%s",
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


def _post_chat(cfg: Config, messages: list[dict[str, str]]) -> dict[str, Any]:
    """POST a chat completion request with retry on transient errors.

    Retries on: network errors (Read/Connect/Connection/ChunkedEncoding),
    HTTP 429 (respecting Retry-After), HTTP 5xx, and JSON decode failures
    on 2xx responses. Hard-fails on 4xx (other than 429) without retry.
    Caps total time spent on a single chunk at cfg.max_chunk_time seconds.
    Each retry logs a one-liner with reason, sleep duration, and elapsed
    time vs the chunk budget.
    """
    payload = {
        "model": cfg.api_model,
        "temperature": 0.2,
        "max_tokens": cfg.max_tokens,
        "messages": messages,
    }
    if cfg.json_mode:
        # Constrain the model to emit a JSON object. Supported by OpenAI and
        # Gemini's OpenAI-compat endpoint; requires "json" to appear in the
        # prompt (SYSTEM_PROMPT/USER_TEMPLATE already satisfy this). Set
        # AI_JSON_MODE=0 for endpoints that reject this field.
        payload["response_format"] = {"type": "json_object"}

    headers = {
        "Authorization": f"Bearer {cfg.api_key}",
        "Content-Type": "application/json",
    }

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
    return {
        "id": idx,
        "msgctxt": entry.msgctxt or None,
        "msgid": entry.msgid,
        "msgid_plural": entry.msgid_plural or None,
        "comments": list(entry.tcomment or ""),
    }


def _build_messages(
    cfg: Config, lang_code: str, lang_fullname: str, items: list[dict[str, Any]]
) -> list[dict[str, str]]:
    nplurals_match = re.search(r"nplurals\s*=\s*(\d+)", PLURAL_FORMS.get(lang_code, ""))
    nplurals = int(nplurals_match.group(1)) if nplurals_match else 1

    user = USER_TEMPLATE.format(
        language=lang_fullname,
        lang_code=lang_code,
        nplurals=nplurals,
        items_json=json.dumps(items, ensure_ascii=False, indent=2),
    )
    return [
        {"role": "system", "content": SYSTEM_PROMPT.format(
            language=lang_fullname, lang_code=lang_code
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


def _validate_translations(
    items: list[dict[str, Any]],
    payload: dict[str, Any],
    nplurals: int,
) -> list[dict[str, Any]]:
    """Ensure the response has a translation for every requested id."""
    translations = payload.get("translations")
    if not isinstance(translations, list):
        raise RuntimeError("response is missing 'translations' array")

    expected_ids = {item["id"] for item in items}
    seen_ids: set[int] = set()
    by_id: dict[int, dict[str, Any]] = {}
    for t in translations:
        if not isinstance(t, dict) or "id" not in t:
            raise RuntimeError(f"translation entry missing 'id': {t!r}")
        tid = t["id"]
        if tid in seen_ids:
            raise RuntimeError(f"duplicate translation id: {tid}")
        seen_ids.add(tid)
        by_id[tid] = t

    missing = expected_ids - seen_ids
    if missing:
        raise RuntimeError(f"response missing ids: {sorted(missing)}")

    out: list[dict[str, Any]] = []
    for item in items:
        t = by_id[item["id"]]
        if item["msgid_plural"]:
            forms = t.get("msgstr_plural")
            if not isinstance(forms, list) or len(forms) != nplurals:
                raise RuntimeError(
                    f"id {item['id']}: msgstr_plural must be a list of length "
                    f"{nplurals}, got {t.get('msgstr_plural')!r}"
                )
            if any(not isinstance(x, str) for x in forms):
                raise RuntimeError(f"id {item['id']}: msgstr_plural has non-string forms")
            if any(not x.strip() for x in forms):
                raise RuntimeError(f"id {item['id']}: msgstr_plural has empty form")
            out.append({"id": item["id"], "msgstr_plural": [_normalize_newlines(f) for f in forms]})
        else:
            msgstr = t.get("msgstr", "")
            if not isinstance(msgstr, str):
                raise RuntimeError(f"id {item['id']}: msgstr must be a string")
            if not msgstr.strip():
                raise RuntimeError(f"id {item['id']}: msgstr is empty")
            out.append({"id": item["id"], "msgstr": _normalize_newlines(msgstr)})
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
    or validation fails, with exponential backoff.  Length truncation is
    handled separately via bisection (no retry).
    """
    items = [_entry_to_item(i, e) for i, e in enumerate(entries)]
    nplurals_match = re.search(r"nplurals\s*=\s*(\d+)", PLURAL_FORMS.get(lang_code, ""))
    nplurals = int(nplurals_match.group(1)) if nplurals_match else 1

    sample_msgid = entries[0].msgid[:60] if entries else "<empty>"

    def attempt(payload_items: list[dict[str, Any]]) -> list[dict[str, Any]]:
        messages = _build_messages(cfg, lang_code, lang_fullname, payload_items)
        result = _post_chat(cfg, messages)
        if result["finish_reason"] not in ("stop", "end_turn"):
            raise _LengthTruncation(result["finish_reason"], result["content"])
        payload = _extract_json(result["content"])
        return _validate_translations(payload_items, payload, nplurals)

    last_error: Exception | None = None
    for retry in range(JSON_RETRIES):
        try:
            _apply_translations(entries, items, attempt(items))
            return
        except _LengthTruncation as lt:
            if len(entries) == 1:
                raise RuntimeError(
                    f"single-entry chunk still truncated (finish_reason={lt.reason}); "
                    f"msgid={entries[0].msgid!r}"
                ) from lt
            # Bisect and recurse.
            mid = len(entries) // 2
            _translate_chunk(cfg, lang_code, lang_fullname, entries[:mid])
            _translate_chunk(cfg, lang_code, lang_fullname, entries[mid:])
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
                f"chunk failed for {lang_code} (msgid={sample_msgid!r}) "
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

        for i, chunk_entries in enumerate(chunks, 1):
            t0 = time.time()
            _translate_chunk(cfg, lang_code, lang_fullname, chunk_entries)
            save_partial()
            elapsed = time.time() - t0
            log_translate.info(
                "[%s] [chunk %d/%d] %d entries in %.1fs",
                lang_code, i, len(chunks), len(chunk_entries), elapsed,
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

    if args.check_api:
        return check_api(cfg)

    if args.lang_code not in LANG_MAP:
        log.error("language code %r not supported", args.lang_code)
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
            log.error("FAILED: %s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())

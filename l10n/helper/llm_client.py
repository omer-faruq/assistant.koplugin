#!/usr/bin/env python3
"""Shared LLM settings, routes and structured-output requests for the l10n helpers."""

from __future__ import annotations

import logging
import os
import secrets
import sys
import threading
from typing import Any

from dotenv import dotenv_values

from lang_data import L10N_DIR

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

# Settings files. The global file is l10n/.env; a locale may add
# l10n/<lang>/.env to override it. Both are resolved from L10N_DIR, and both
# are gitignored and release-excluded, so real credentials never get committed.
GLOBAL_ENV_FILE = os.path.join(L10N_DIR, ".env")
LOCALE_ENV_NAME = ".env"


def locale_env_file(lang_code: str) -> str:
    """Absolute path of a locale's optional settings file."""
    return os.path.join(L10N_DIR, lang_code, LOCALE_ENV_NAME)


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
        self._client_lock = threading.Lock()

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
        with self._client_lock:
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
# user provides RANDOM_SESSION_ID (e.g. direct `./helper/ai_translate.py <lang>`
# runs). Same 16-char URL-safe style as the Makefile id. Note parallel make
# jobs would each get their own id from this fallback, so prefer going
# through make for shared caching/routing.
RUN_SESSION_ID = secrets.token_urlsafe(12)


def is_opencode_api(base_url: str) -> bool:
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
    if is_opencode_api(route.base_url):
        headers["x-opencode-session"] = cfg.opencode_session or RUN_SESSION_ID
    return openai.OpenAI(
        api_key=route.api_key,
        base_url=route.base_url,
        timeout=float(cfg.request_timeout),
        max_retries=cfg.max_retries,
        default_headers=headers,
    )

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


def request(
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


def list_models(cfg: Config) -> list[str]:
    """Return sorted model IDs exposed by the route's /models endpoint."""
    route = cfg.get_route()
    client = cfg.get_client(route)
    try:
        page = client.models.list()
    except Exception as exc:
        raise _as_runtime_error(exc)
    items = _get(page, "data", None)
    if items is None:
        items = list(page)
    ids = {
        mid.strip()
        for item in items
        for mid in [item if isinstance(item, str) else _get(item, "id", "")]
        if isinstance(mid, str) and mid.strip()
    }
    return sorted(ids)

#!/usr/bin/env python3
"""Review l10n catalogues with the OpenCode CLI and repair what it flags.

Why this exists: ai_translate.py only fills *empty* msgstr, so a translation
that came back in the wrong language, or with the wrong meaning, counts as done
forever. Its output-time checks catch a wrong-slot answer (lost markup or a
ghost %N), but a msgid whose translation is simply in the wrong language, or
says the wrong thing, still ships wrong. This harness asks a reviewer model one
question about the whole catalogue - is this translation actually correct for
the target language? - and, when it confidently says no, empties exactly those
msgstr so the normal pipeline refills them. It never writes a translation
itself.

One OpenCode CLI invocation reviews every entry of one catalogue; the reply is a
compact per-entry verdict (`pass`, `repair` or `abstain`), not one call per
msgid. `repair` is reserved for a strong, explicit wrong-language or
wrong-meaning finding; a short or ambiguous string abstains instead. An entry
whose msgstr equals its msgid or is nothing but format placeholders is never
sent: it is not prose to judge.

Modes:
    review_translations.py [--lang LANG]            review LANG/updated_translated.po
    review_translations.py [--lang LANG] --po PATH  review PATH instead
    review_translations.py [--lang LANG] --full      audit LANG/assistant.po, report-only

A locale opts into the review by shipping l10n/<LANG>/review_note.txt: the note
is its distinguishing guidance (which languages its catalogue is confused with,
and the tells that resolve them), and the prompt names the target language from
LANG_EN. No locale without a note is ever reviewed, so the harness carries no
per-language code.

Normal mode reviews the LLM intermediate produced by `make translate`. When it
flags entries it empties their msgstr in the intermediate, refills them once
through ai_translate.py, and reviews the result a second time; a repair verdict
that survives the refill stops the run before import (exit 3) and preserves the
intermediate. It never loops.

Every failure that is not a surviving repair verdict is best-effort: a missing
review note, a missing `opencode` binary, an authentication error, a timeout or
an invalid reply warns and leaves the pipeline running (exit 0). The point is to
hand the outer pipeline a better catalogue, never to stop a translation run.

The reviewer runs under the user's own OpenCode account with the model selected
by L10N_REVIEW_MODEL (default opencode-go/claude-haiku-5-5), read from the
process environment or from l10n/.env / l10n/<LANG>/.env. OpenCode's
data-retention and billing policy applies to the public UI strings it is sent.
See l10n/README.md.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

import polib

from ai_translate import LANG_EN, load_settings

LANG_DIR = os.path.dirname(os.path.abspath(__file__))
DOMAIN = "assistant"
INTERMEDIATE_NAME = "updated_translated.po"
REVIEW_NOTE_FILE = "review_note.txt"
AI_TRANSLATE = os.path.join(LANG_DIR, "ai_translate.py")

# A locale is reviewed only when it ships its own review_note.txt; the default
# keeps a bare invocation convenient. The reviewer agent
# (.opencode/agents/l10n-review.md) is language-agnostic: the target language
# and the confusion guidance both come from the prompt.
DEFAULT_LANG = "sk"
DEFAULT_MODEL = "opencode-go/claude-haiku-5-5"
REVIEW_AGENT = "l10n-review"
DEFAULT_TIMEOUT = 600.0

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
# Repair verdicts survived the single refill. The caller stops before import and
# keeps the intermediate; the harness never loops.
EXIT_BLOCK = 3


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
    path = os.path.join(LANG_DIR, lang, REVIEW_NOTE_FILE)
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as handle:
        return handle.read().strip()


def language_name(lang: str) -> str:
    """The English name of the target language, from ai_translate.LANG_EN.

    The prompt names the language by name so the reviewer cannot infer it from
    the locale code alone. A locale missing from the table falls back to its
    code, keeping an unknown locale reviewable.
    """
    return LANG_EN.get(lang, lang)


def default_model(lang: str) -> str:
    """The reviewer model: L10N_REVIEW_MODEL, else the built-in default.

    Read through the shared settings loader, so the process environment,
    l10n/<lang>/.env and l10n/.env are consulted in that order without relying
    on any file having been loaded into the process environment already.
    """
    return load_settings(lang).get("L10N_REVIEW_MODEL", "").strip() or DEFAULT_MODEL


def default_timeout(lang: str) -> float:
    raw = load_settings(lang).get("L10N_REVIEW_TIMEOUT", "").strip()
    if not raw:
        return DEFAULT_TIMEOUT
    try:
        value = float(raw)
    except ValueError:
        return DEFAULT_TIMEOUT
    return value if value > 0 else DEFAULT_TIMEOUT


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
    po = polib.pofile(path)
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

    The verdict contract lives in the agent's system prompt; the message fixes
    the target language, the locale's guidance and the entries sent.
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
        "once, following your output contract. Never write a translation.\n"
    )
    payload = json.dumps(
        [_compact(entry) for entry in entries],
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return header + "\nEntries (JSON array):\n" + payload + "\n"


def _event_error(event: dict) -> str:
    error = event.get("error")
    if isinstance(error, dict):
        data = error.get("data")
        if isinstance(data, dict) and isinstance(data.get("message"), str):
            return " ".join(data["message"].split())[:300]
        for key in ("message", "name"):
            value = error.get(key)
            if isinstance(value, str):
                return " ".join(value.split())[:300]
    if isinstance(error, str):
        return " ".join(error.split())[:300]
    return "unknown error"


def _text_from_events(stdout: str) -> str:
    """Concatenate the `text` payloads of an NDJSON event stream, in order.

    Fails closed on a malformed line or an error event. There is no streaming to
    reassemble: `opencode run --format json` emits one complete text block per
    step, so the payloads are joined verbatim.
    """
    chunks: list[str] = []
    for lineno, line in enumerate(stdout.splitlines(), 1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except ValueError as exc:
            raise ReviewError(
                f"opencode emitted a malformed event on line {lineno}"
            ) from exc
        if not isinstance(event, dict):
            raise ReviewError(f"opencode event {lineno} is not a JSON object")
        event_type = event.get("type")
        if event_type == "error":
            raise ReviewError(f"opencode reported an error: {_event_error(event)}")
        if event_type != "text":
            continue
        part = event.get("part")
        text = part.get("text") if isinstance(part, dict) else event.get("text")
        if isinstance(text, str):
            chunks.append(text)
    return "".join(chunks)


def run_review(prompt: str, model: str, timeout: float) -> str:
    """Run one OpenCode CLI review, returning its concatenated text reply.

    The prompt goes over stdin, never in argv, so a whole catalogue cannot
    exhaust the argument list. A missing binary, a timeout or a nonzero exit is
    a ReviewError; the caller treats any of them as an unrun review.
    """
    command = [
        "opencode", "run",
        "--standalone",
        "--agent", REVIEW_AGENT,
        "--model", model,
        "--format", "json",
    ]
    try:
        proc = subprocess.run(
            command,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError as exc:
        raise ReviewError("the 'opencode' CLI is not on PATH") from exc
    except subprocess.TimeoutExpired as exc:
        raise ReviewError(f"opencode timed out after {timeout:g}s") from exc
    except OSError as exc:
        raise ReviewError(f"cannot run the 'opencode' CLI: {exc}") from exc
    if proc.returncode != 0:
        detail = " ".join((proc.stderr or proc.stdout or "").split())[:300]
        raise ReviewError(
            f"opencode exited {proc.returncode}" + (f": {detail}" if detail else "")
        )
    return _text_from_events(proc.stdout)


def _extract_json(text: str) -> dict:
    """Parse the reviewer's JSON object, tolerating stray markdown fences.

    Strict: the reply must parse as one JSON object, so prose around it or a
    truncated stream fails the pass instead of being partially trusted.
    """
    body = text.strip()
    if body.startswith("```"):
        body = re.sub(r"^```(?:json)?\s*", "", body, count=1)
        body = re.sub(r"\s*```\s*$", "", body, count=1)
    try:
        parsed = json.loads(body)
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


def review_pass(note: str, path: str, model: str, timeout: float,
                lang: str, language: str):
    """One CLI invocation over path. Returns (entries, verdicts)."""
    entries = collect_entries(path)
    if not entries:
        raise ReviewError("no translated entries to review")
    prompt = build_prompt(entries, note, lang, language)
    text = run_review(prompt, model, timeout)
    if not text.strip():
        raise ReviewError("opencode produced no text reply")
    verdicts = parse_verdicts(text, [entry["id"] for entry in entries])
    return entries, verdicts


def clear_entries(path: str, entries: list[dict], repair_ids: set[str]) -> list[str]:
    """Empty the exact msgstr the reviewer flagged, in place.

    A flagged plural form empties every form the entry declares, because
    ai_translate.py refills a plural entry only once all of its forms are empty.
    Returns one label per changed entry.
    """
    wanted: dict[tuple[str, str], set[str]] = {}
    for entry in entries:
        if entry["id"] in repair_ids:
            wanted.setdefault((entry["msgctxt"], entry["msgid"]), set()).add(
                entry["form"]
            )
    po = polib.pofile(path, wrapwidth=0)
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
                for i in entry.msgstr_plural:
                    entry.msgstr_plural[i] = ""
                changed.append(f"{entry.msgid[:60]!r} [plural]")
        elif entry.msgstr.strip():
            entry.msgstr = ""
            changed.append(f"{entry.msgid[:60]!r}")
        if "fuzzy" in entry.flags:
            entry.flags.remove("fuzzy")
    if changed:
        po.save(path)
    return changed


def refill(intermediate_path: str, lang: str) -> None:
    """Refill the cleared intermediate through ai_translate.py, once.

    ai_translate.py decides its paths from disk: it translates
    <lang>/untranslated.po into <lang>/updated_translated.po. The cleared
    intermediate is moved into untranslated.po and ai_translate.py runs once;
    the refilled catalogue lands back at intermediate_path. The caller owns the
    backup of the pre-review intermediate and restores it if this raises.
    """
    untranslated = os.path.join(LANG_DIR, lang, "untranslated.po")
    shutil.move(intermediate_path, untranslated)
    try:
        proc = subprocess.run(
            [sys.executable, AI_TRANSLATE, lang],
            cwd=LANG_DIR,
        )
    except OSError as exc:
        raise ReviewError(f"cannot run ai_translate.py: {exc}") from exc
    if proc.returncode != 0:
        partial = intermediate_path + ".partial"
        if os.path.isfile(partial):
            os.remove(partial)
        raise ReviewError(f"ai_translate.py exited {proc.returncode}")


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
        description="Review an l10n catalogue that ships a review note with the "
                    "OpenCode CLI and empty the msgstr a reviewer confidently "
                    "marks as needing repair.",
    )
    parser.add_argument(
        "--lang", default=DEFAULT_LANG,
        help=f"locale to review (default: {DEFAULT_LANG}); its "
             f"<LANG>/{REVIEW_NOTE_FILE} opts it in",
    )
    parser.add_argument(
        "--po", default=None,
        help=f"catalogue inside the locale directory to review (default: "
             f"<LANG>/{INTERMEDIATE_NAME}, or <LANG>/{DOMAIN}.po with --full)",
    )
    parser.add_argument(
        "--full", action="store_true",
        help=f"report-only audit of <LANG>/{DOMAIN}.po: one CLI call, no "
             f"changes to any file",
    )
    parser.add_argument(
        "--model", default=None,
        help=f"reviewer model (default: L10N_REVIEW_MODEL from the locale's "
             f"settings, then {DEFAULT_MODEL})",
    )
    parser.add_argument(
        "--timeout", type=float, default=None,
        help=f"per-invocation timeout in seconds (default: L10N_REVIEW_TIMEOUT, "
             f"then {DEFAULT_TIMEOUT:g})",
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
    if shutil.which("opencode") is None:
        _warn("the 'opencode' CLI is not on PATH; skipping the review.")
        return EXIT_OK

    timeout = args.timeout if args.timeout else default_timeout(lang)
    if timeout <= 0:
        _warn(f"--timeout must be > 0, got {timeout!r}; skipping the review.")
        return EXIT_OK
    model = args.model.strip() if args.model else default_model(lang)

    if args.po:
        path = args.po
        lang_dir = os.path.abspath(os.path.join(LANG_DIR, lang))
        if os.path.dirname(os.path.abspath(path)) != lang_dir:
            _warn(f"--po must point inside {lang}/; skipping the review.")
            return EXIT_OK
    else:
        name = f"{DOMAIN}.po" if args.full else INTERMEDIATE_NAME
        path = os.path.join(LANG_DIR, lang, name)
    if not os.path.isfile(path):
        _warn(f"{path}: not found; nothing to review.")
        return EXIT_OK

    if args.full:
        _log(f"{lang}: read-only audit of {path} (one CLI call)")
        try:
            entries, verdicts = review_pass(note, path, model, timeout,
                                            lang, language)
        except ReviewError as exc:
            _warn(f"{lang}: review failed ({exc}); no report produced.")
            return EXIT_OK
        _print_report(entries, verdicts, lang)
        _log("read-only: no catalogue was modified.")
        return EXIT_OK

    _log(f"{lang}: reviewing {path} (model {model})")
    try:
        entries, verdicts = review_pass(note, path, model, timeout,
                                        lang, language)
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
        refill(path, lang)
    except ReviewError as exc:
        os.replace(backup, path)
        _warn(
            f"{lang}: refill failed ({exc}); the pre-review intermediate "
            f"is restored."
        )
        return EXIT_OK
    if os.path.isfile(backup):
        os.remove(backup)

    _log(f"{lang}: refill done; final review pass...")
    try:
        entries, verdicts = review_pass(note, path, model, timeout,
                                        lang, language)
    except ReviewError as exc:
        _warn(
            f"{lang}: final review failed ({exc}); import continues with the "
            f"refilled catalogue."
        )
        return EXIT_OK

    remaining = _repaired_ids(entries, verdicts)
    if remaining:
        _print_report(entries, verdicts, lang)
        _log(
            f"{lang}: {len(remaining)} repair verdict(s) survived the refill; "
            f"stopping before import so {os.path.basename(path)} is preserved."
        )
        return EXIT_BLOCK
    _log(f"{lang}: the refill resolved every repair verdict.")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())

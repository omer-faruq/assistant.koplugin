#!/usr/bin/env python3
"""Audit l10n/*/assistant.po for translations written in the wrong language.

Why this exists: the pipeline only fills *empty* msgstr, so a string that came
back in the wrong language counts as done forever and is never revisited.
Slovak shipped roughly 54 Slovenian strings that way and nothing noticed,
because no check ever asked "is this actually Slovak?".

Two signals, neither of which needs anyone to know the target language:

  A. CALIBRATED_AGREEMENT  (needs a KOReader checkout)
     For a pair (L, U) of same-script locales, compare how often *our* L and U
     agree with each other against how often KOReader's own reviewed
     koreader.mo translations of L and U agree. The upstream rate is the
     baseline two real languages are expected to hit, so it self-normalizes
     per pair: no dictionary, no hand-tuned threshold, no false positives from
     merely-related languages. observed >> expected means our L is echoing U.
     The detail view prints KOReader's own wording for L, which is both the
     confirmation and the suggested replacement.

  B. SIBLING_IDENTICAL  (no upstream needed)
     Raw count of msgstr shared byte-for-byte with a sibling locale. Covers
     every entry, including the ~90% of msgids with no upstream counterpart,
     and covers locales whose upstream catalogue is empty.

Findings are a triage list, not a verdict. A pair can score high while the
flagged wording is perfectly correct for that language - zh_CN and zh_TW
legitimately share many strings, and KOReader's own catalogues agree. Always
read the "koreader <lang>" column before emptying anything.

Usage:
    ./check_mix.py                                  report
    ./check_mix.py --list                           report + every flagged entry
    ./check_mix.py --empty sk --peer sl             clear sk's Slovenian strings
    ./check_mix.py --min-ratio 3 --min-obs 5

--empty needs --peer, and only clears a msgstr when all three hold: our two
catalogues agree on it, KOReader's own catalogue disagrees with it for the
target language, and KOReader's own catalogue confirms it for the peer. That
is what keeps the innocent side of a pair from being emptied. Run
`make ai-translate` afterwards to refill, then `make mo` to recompile.
"""
from __future__ import annotations

import argparse
import collections
import itertools
import os
import re
import sys
import unicodedata

import polib

LANG_DIR = os.path.dirname(os.path.abspath(__file__))
KOREADER_L10N = os.environ.get("KOREADER_L10N_DIR", "/usr/lib/koreader/l10n")
DOMAIN = "assistant"

Key = tuple[str, str, str]  # (msgctxt, msgid, plural form index)

# msgids whose translation is identical across locales by design: format
# placeholders and names that stay in English. Excluding them keeps the
# agreement counts about prose instead of about "URL: %1".
TOKEN_MSGID = re.compile(
    r"^(https?://|[^%]*\b(API|URL|KOReader|ELI5|TL;DR|AI|JSON|HTTP|HTTPS|SSE|"
    r"OpenAI|Anthropic|Gemini|Ollama|Groq|Mistral|OpenRouter|GigaChat|Gemma|"
    r"DeepSeek|X-Ray|Wikipedia|Word|Model|Platform|Protocol|Search|Filter)\b)"
)

# Markup the msgid carries and the msgstr must carry too. AGENTS.md invariant 4:
# <b> is parsed by bold_format, not real HTML, so a lost tag is a rendering
# bug. A msgstr that drops a tag the msgid has is also the visible footprint of
# a wrong-slot answer - when the model answers with the translation of a
# different msgid, the tags of the msgid it was actually given are the ones
# that go missing.
MARKUP = re.compile(r"</?[a-zA-Z][^>]*>")

# A %N index. KOReader's T() substitutes only these, so an index the msgid
# never had can only have been carried over from a different msgid. %s and %d
# are left alone: the plugin mixes string.format with T(), so the msgid's own
# conversion style is a per-call-site choice.
PLACEHOLDER = re.compile(r"%([1-9][0-9]?)")


def catalogue_codes() -> list[str]:
    return [n for n in sorted(os.listdir(LANG_DIR))
            if os.path.isfile(os.path.join(LANG_DIR, n, f"{DOMAIN}.po"))]


def load(path: str, is_mo: bool = False) -> dict[Key, str]:
    po = polib.mofile(path) if is_mo else polib.pofile(path)
    out: dict[Key, str] = {}
    for e in po:
        if e.obsolete:
            continue
        if e.msgid_plural:
            for i, v in e.msgstr_plural.items():
                if v.strip():
                    out[(e.msgctxt or "", e.msgid, str(i))] = v
        elif (e.msgstr or "").strip():
            out[(e.msgctxt or "", e.msgid, "")] = e.msgstr
    return out


def dominant_script(po: dict[Key, str]) -> str:
    c: collections.Counter = collections.Counter()
    for v in po.values():
        for ch in v:
            if ch.isalpha():
                try:
                    c[unicodedata.name(ch).split()[0]] += 1
                except ValueError:
                    c["UNK"] += 1
    return c.most_common(1)[0][0] if c else "?"


def is_token(msgid: str, msgstr: str) -> bool:
    """True when this translation is expected to read the same in every locale."""
    if msgstr.strip() == msgid.strip():
        return True  # never translated; the English source is the answer
    if TOKEN_MSGID.match(msgid):
        return True
    # Format-only translation: msgstr is nothing but the placeholders.
    if re.sub(r"%(?:\d+\$)?[sd]|%s|%d", "", msgstr).strip() == "":
        return True
    return False


def calibrated_pairs(codes, ours, ups, min_ratio, min_obs) -> list[dict]:
    """Pairs whose observed agreement dwarfs KOReader's own agreement."""
    scripts = {c: dominant_script(ups.get(c) or ours[c]) for c in codes}
    rows = []
    for a, b in itertools.combinations(codes, 2):
        if not ups.get(a) or not ups.get(b) or scripts[a] != scripts[b]:
            continue
        ref = [k for k in ups[a] if k in ups[b]]
        both = [k for k in ref if k in ours[a] and k in ours[b]]
        if len(both) < 15:
            continue
        expected = sum(1 for k in ref if ups[a][k] == ups[b][k])
        observed = sum(1 for k in both if ours[a][k] == ours[b][k])
        # Laplace smoothing keeps the ratio finite when upstream agreement is 0.
        rate = (expected + 1) / (len(ref) + 2)
        ratio = (observed + 1) / (len(both) + 2) / rate
        if observed < min_obs or ratio < min_ratio:
            continue
        rows.append({
            "a": a, "b": b, "observed": observed, "of": len(both),
            "expected": expected, "ref": len(ref), "ratio": ratio,
            "excess": observed - rate * len(both),
            "hits": [k for k in both
                     if ours[a][k] == ours[b][k] and not is_token(k[1], ours[a][k])],
        })
    rows.sort(key=lambda r: (-r["ratio"], -r["excess"]))
    return rows


def sibling_overlap(codes, ours) -> list[tuple[int, tuple[str, int], str]]:
    out = []
    for a in codes:
        peers: collections.Counter = collections.Counter()
        for b in codes:
            if a == b:
                continue
            n = sum(1 for k, v in ours[a].items()
                    if k in ours[b] and ours[b][k] == v and not is_token(k[1], v))
            if n:
                peers[b] = n
        if peers:
            out.append((sum(peers.values()), peers.most_common(1)[0], a))
    out.sort(reverse=True)
    return out


def structural_loss(codes) -> list[dict]:
    """Entries whose msgstr does not preserve the msgid's own structure.

    Needs no upstream and no language knowledge. Three distinct problems share
    the footprint:
      - the translation is right but a <b> tag is gone, so bold_format never
        fires and the message renders unstyled
      - the translation carries a %N that no source form of the msgid has,
        which can only have come from a different msgid ("Base URL, e.g. ..."
        came to hold "Connection failed: %1" in uz)
      - the translation belongs to a different msgid entirely, which is how
        "<b>Testing connection...</b>" ended up holding "Base URL" in twelve
        locales while the other forty-eight translated it correctly

    Mirrors ai_translate._check_markup, which rejects the same conditions at
    request time so a bad answer gets retried instead of written. This is the
    offline backstop for catalogues that predate that check.

    Reads the catalogues itself rather than going through load(), because a
    plural entry needs msgid_plural as well as msgid: gettext picks the form
    from n at runtime, so every form may carry whatever any source form
    carries, and comparing a form against the singular msgid alone would flag
    the %1 that all of them legitimately have.
    """
    rows = []
    for lang in codes:
        po = polib.pofile(os.path.join(LANG_DIR, lang, f"{DOMAIN}.po"))
        for e in po:
            if e.obsolete:
                continue
            allowed = set(PLACEHOLDER.findall(e.msgid))
            if e.msgid_plural:
                allowed |= set(PLACEHOLDER.findall(e.msgid_plural))
            forms = ([(i, v) for i, v in e.msgstr_plural.items()]
                     if e.msgid_plural else [(0, e.msgstr)])
            for i, msgstr in forms:
                if not (msgstr or "").strip():
                    continue
                problems = []
                lost = (set(MARKUP.findall(e.msgid))
                        - set(MARKUP.findall(msgstr)))
                if lost:
                    problems.append(f"dropped markup {sorted(lost)}")
                ghost = set(PLACEHOLDER.findall(msgstr)) - allowed
                if ghost:
                    problems.append(
                        f"placeholder {sorted('%' + g for g in ghost)} "
                        f"not in any source form")
                if problems:
                    rows.append({
                        "lang": lang,
                        "key": (e.msgctxt or "", e.msgid, str(i)),
                        "msgstr": msgstr, "lost": sorted(lost),
                        "problems": problems,
                    })
    rows.sort(key=lambda r: (r["lang"], r["key"][1]))
    return rows


def blame(ours, ups, lang, peer, keys) -> set[Key]:
    """Keys in `lang` that look like `peer`'s language rather than `lang`'s.

    Three conditions, all required, so the innocent side is never blamed:
      1. our two catalogues hold the same string for this msgid
      2. KOReader's own catalogue disagrees with it for `lang` - so our
         wording is not simply a valid variant that happens to be shared
      3. KOReader's own catalogue agrees with it for `peer` - which pins the
         provenance on `peer` instead of leaving it ambiguous
    """
    out = set()
    for k in keys:
        ours_lang = ours[lang].get(k, "")
        if not ours_lang or ours[lang].get(k) != ours[peer].get(k):
            continue
        truth = ups.get(lang, {}).get(k, "")
        if not truth or truth == ours_lang:
            continue
        if ups.get(peer, {}).get(k, "") == ours_lang:
            out.add(k)
    return out


def empty_flags(po_path: str, keys: set[Key]) -> list[str]:
    """Clear msgstr for exactly these (msgctxt, msgid, form) keys.

    Returns a human-readable line per entry changed, so the caller can show
    what was cleared without re-reading the catalogue.
    """
    po = polib.pofile(po_path, wrapwidth=0)
    wanted: dict[tuple[str, str], set[str]] = collections.defaultdict(set)
    for ctx, msgid, form in keys:
        wanted[(ctx, msgid)].add(form)
    changed: list[str] = []
    for e in po:
        forms = wanted.get((e.msgctxt or "", e.msgid))
        if not forms:
            continue
        if e.msgid_plural:
            idx = sorted(int(f) for f in forms if f != "")
            if not idx:
                continue
            if any(e.msgstr_plural.get(i, "").strip() for i in idx):
                for i in idx:
                    e.msgstr_plural[i] = ""
                changed.append(f"{e.msgid[:60]!r} [plural forms {idx}]")
        elif not forms == {""} and "" not in forms:
            # only plural forms were flagged for a non-plural entry: skip
            continue
        elif e.msgstr.strip():
            e.msgstr = ""
            changed.append(f"{e.msgid[:60]!r}")
        if "fuzzy" in e.flags:
            e.flags.remove("fuzzy")
    if changed:
        po.save(po_path)
    return changed


def check_data() -> int:
    """Validate the static language tables against the catalogues on disk.

    Lives here rather than in the Makefile so the checks stay testable and do
    not need Python embedded in a recipe. Verifies:
      - LANG_MAP, LANG_EN and PLURAL_FORMS all cover the same set of locales
      - every Plural-Forms entry parses and declares the nplurals it claims
      - every .po header agrees with PLURAL_FORMS (msgfmt enforces this too,
        but the message here names the language)
      - which locales ship a translator note
    """
    import ai_translate as at

    ok = True
    codes = catalogue_codes()
    missing_en = sorted(set(at.LANG_MAP) - set(at.LANG_EN))
    missing_pf = sorted(set(at.LANG_MAP) - set(at.PLURAL_FORMS))
    extra_en = sorted(set(at.LANG_EN) - set(at.LANG_MAP))
    on_disk_only = sorted(set(codes) - set(at.LANG_MAP))
    for label, vals in (("LANG_MAP without LANG_EN", missing_en),
                        ("LANG_MAP without PLURAL_FORMS", missing_pf),
                        ("LANG_EN without LANG_MAP", extra_en),
                        ("catalogue without LANG_MAP", on_disk_only)):
        if vals:
            ok = False
            print(f"FAIL {label}: {', '.join(vals)}")

    print("plural forms (PLURAL_FORMS vs the .po header):")
    for lang in codes:
        want = at.PLURAL_FORMS.get(lang)
        if not want:
            continue
        want_n = re.search(r"nplurals\s*=\s*(\d+)", want)
        have = polib.pofile(os.path.join(LANG_DIR, lang, f"{DOMAIN}.po"))
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
                   if os.path.isfile(os.path.join(LANG_DIR, d, at.LANG_NOTE_FILE)))
    print(f"\nlanguages with a translator note ({len(notes)}): "
          f"{', '.join(notes) or 'none'}")
    print("OK" if ok else "FAILED")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Audit l10n catalogues for wrong-language translations.")
    ap.add_argument("--check-data", action="store_true",
                    help="validate LANG_MAP/LANG_EN/PLURAL_FORMS against the "
                         "catalogues on disk and exit")
    ap.add_argument("--list", action="store_true",
                    help="print every flagged entry, not just the pair header")
    ap.add_argument("--min-ratio", type=float, default=3.0,
                    help="flag a pair when observed agreement is at least this "
                         "many times KOReader's own (default 3.0)")
    ap.add_argument("--min-obs", type=int, default=5,
                    help="minimum number of agreeing entries (default 5)")
    ap.add_argument("--top", type=int, default=10,
                    help="how many locales to show in signal B (default 10)")
    ap.add_argument("--empty", metavar="LANG",
                    help="clear LANG's msgstr that signal A attributes to "
                         "--peer, so the next ai-translate run refills them. "
                         "Requires --peer: the blame is only assigned when "
                         "KOReader's own catalogue pins the wording on one "
                         "side of the pair. Rewrites assistant.po in place.")
    ap.add_argument("--peer", metavar="LANG",
                    help="the contaminating locale, used together with --empty")
    ap.add_argument("--structural", action="store_true",
                    help="with --empty, also clear the entries signal C "
                         "flagged for this locale")
    args = ap.parse_args()

    if args.check_data:
        return check_data()

    codes = catalogue_codes()
    ours = {c: load(os.path.join(LANG_DIR, c, f"{DOMAIN}.po")) for c in codes}
    ups = {c: load(os.path.join(KOREADER_L10N, c, "koreader.mo"), True)
           for c in codes
           if os.path.isfile(os.path.join(KOREADER_L10N, c, "koreader.mo"))}
    usable = sum(1 for v in ups.values() if v)

    print(f"catalogues  : {len(codes)}")
    print(f"upstream ref: {KOREADER_L10N} "
          f"({usable} usable, {len(codes) - usable} without a populated one)")
    print(f"criteria    : ratio >= {args.min_ratio}, observed >= {args.min_obs}")
    if not usable:
        print("\nno upstream catalogues available; signal A is unavailable, "
              "signal B only. Set KOREADER_L10N_DIR to a KOReader checkout.")

    print("\n" + "=" * 76)
    print("A. CALIBRATED_AGREEMENT  ours vs KOReader's own, same pair")
    print("=" * 76)
    rows = calibrated_pairs(codes, ours, ups, args.min_ratio, args.min_obs)
    if not rows:
        print("no pairs above threshold")
    else:
        print(f"{'ratio':>6} {'ours':>9} {'koreader':>10}  pair")
        print("-" * 76)
        for r in rows:
            print(f"{r['ratio']:>6.2f} {r['observed']:>4}/{r['of']:<4} "
                  f"{r['expected']:>5}/{r['ref']:<4}  {r['a']:>7} / {r['b']:<7}")
        if args.list or args.empty:
            for r in rows:
                print(f"\n--- {r['a']} / {r['b']}  ratio {r['ratio']:.1f} ---")
                for k in r["hits"]:
                    tag = f"[{k[2]}] " if k[2] else ""
                    print(f"  {tag}{k[1][:46]!r}")
                    print(f"      {r['a']} has : {ours[r['a']][k][:54]!r}")
                    print(f"      {r['b']} has : {ours[r['b']][k][:54]!r}")
                    truth = ups.get(r["a"], {}).get(k, "")
                    if truth:
                        print(f"      koreader {r['a']}: {truth[:54]!r}")

    print("\n" + "=" * 76)
    print("B. SIBLING_IDENTICAL  msgstr shared byte-for-byte, no upstream needed")
    print("=" * 76)
    print(f"{'total':>6} {'top peer':>16}  locale")
    print("-" * 76)
    for total, (peer, n), lang in sibling_overlap(codes, ours)[:args.top]:
        print(f"{total:>6} {peer + ' (' + str(n) + ')':>16}  {lang}")

    loss = structural_loss(codes)
    print("\n" + "=" * 76)
    print("C. STRUCTURAL_LOSS  msgstr dropped markup the msgid carries")
    print("=" * 76)
    if not loss:
        print("none")
    else:
        by_msgid: dict[str, list[dict]] = collections.defaultdict(list)
        for r in loss:
            by_msgid[r["key"][1]].append(r)
        for msgid, rs in sorted(by_msgid.items(), key=lambda kv: -len(kv[1])):
            langs = ", ".join(r["lang"] for r in rs)
            print(f"\n  {msgid[:56]!r}\n    {len(rs)} locale(s): {langs}")
            if args.list or args.empty:
                for r in rs:
                    print(f"      {r['lang']:6} -> {r['msgstr'][:44]!r} "
                          f"({'; '.join(r['problems'])})")
        print(f"\n{len(loss)} entries across {len(by_msgid)} msgid(s).")

    if args.empty:
        print("\n" + "=" * 76)
        print(f"EMPTYING {args.empty}")
        print("=" * 76)
        flagged: set[Key] = set()
        if args.peer:
            flagged = blame(ours, ups, args.empty, args.peer,
                            {k for r in rows for k in r["hits"]})
        if args.structural:
            flagged |= {r["key"] for r in loss if r["lang"] == args.empty}
        if not flagged:
            print(f"  {args.empty}: nothing flagged"
                  f"{' for peer ' + args.peer if args.peer else ''}")
        else:
            path = os.path.join(LANG_DIR, args.empty, f"{DOMAIN}.po")
            for line in empty_flags(path, flagged):
                print(f"  {args.empty}: cleared {line}")
        print("\nRun `make ai-translate` to refill, then `make mo`.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

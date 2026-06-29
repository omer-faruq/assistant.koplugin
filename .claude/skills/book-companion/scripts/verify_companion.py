"""Mechanical verification gate for a generated companion. Stdlib only.

Judgment checks (spoiler leakage, explanation quality) are the LLM's job and are
NOT performed here. This script only checks what is mechanically decidable.
"""
import argparse
import json
import os
import re
import sys

_BOLD = re.compile(r"\*\*([^*]+?)\*\*")

def check_header_clean(companion_text):
    stripped = companion_text.lstrip()
    return stripped.startswith("#")

def _section(companion_text, name):
    pat = re.compile(r"^##\s+.*%s.*$" % re.escape(name), re.MULTILINE | re.IGNORECASE)
    m = pat.search(companion_text)
    if not m:
        return ""
    nxt = re.compile(r"^##\s+", re.MULTILINE).search(companion_text, m.end())
    return companion_text[m.end():(nxt.start() if nxt else len(companion_text))]

def extract_character_names(companion_text):
    section = _section(companion_text, "Character Dictionary")
    return [m.group(1).strip() for m in _BOLD.finditer(section)]

def chapter_coverage(companion_text, manifest):
    chapters = manifest.get("chapters", [])
    missing = []
    for ch in chapters:
        idx = ch.get("index")
        title = (ch.get("title") or "").strip()
        by_num = re.search(r"\bChapter\s+%s\b" % re.escape(str(idx)), companion_text)
        by_title = title and title in companion_text
        if not (by_num or by_title):
            missing.append(idx)
    return {"total": len(chapters), "covered": len(chapters) - len(missing), "missing": missing}

def names_missing_from_source(names, source_text):
    return [n for n in names if n not in source_text]

def phrases_uncovered(companion_text, foreign_phrases):
    return [p for p in foreign_phrases if p not in companion_text]

def _paths_ok(expected_stem, written_paths):
    if not written_paths:
        return False
    want = expected_stem + ".companion.md"
    return all(os.path.basename(p) == want for p in written_paths)

def verify(companion_text, source_text, manifest, candidates, expected_stem, written_paths):
    cov = chapter_coverage(companion_text, manifest)
    names = extract_character_names(companion_text)
    checks = {
        "header_clean": check_header_clean(companion_text),
        "chapter_coverage": cov,
        "names_missing_from_source": names_missing_from_source(names, source_text),
        "phrases_uncovered": phrases_uncovered(
            companion_text, candidates.get("foreign_phrases", [])),
        "filename_ok": _paths_ok(expected_stem, written_paths),
    }
    # Hard gates only: clean header, full chapter coverage, filename/paths correct.
    # names_missing_from_source and phrases_uncovered are ADVISORY — they stay in checks
    # for the LLM's judgment self-check (step 8) but do not affect ok.
    ok = (checks["header_clean"]
          and not cov["missing"]
          and checks["filename_ok"])
    return {"ok": ok, "checks": checks}

def main(argv=None):
    p = argparse.ArgumentParser(description="Verify a generated companion (mechanical checks).")
    p.add_argument("--companion", required=True)
    p.add_argument("--manifest", required=True)
    p.add_argument("--source", required=True)
    p.add_argument("--candidates", required=True)
    p.add_argument("--stem", required=True)
    p.add_argument("--paths", default="")
    args = p.parse_args(argv)
    with open(args.companion, encoding="utf-8", errors="replace") as f:
        companion = f.read()
    with open(args.source, encoding="utf-8", errors="replace") as f:
        source = f.read()
    with open(args.manifest, encoding="utf-8") as f:
        manifest = json.load(f)
    with open(args.candidates, encoding="utf-8") as f:
        candidates = json.load(f)
    paths = [s for s in args.paths.split(",") if s]
    report = verify(companion, source, manifest, candidates, args.stem, paths)
    json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
    print()
    return 0 if report["ok"] else 1

if __name__ == "__main__":
    sys.exit(main())

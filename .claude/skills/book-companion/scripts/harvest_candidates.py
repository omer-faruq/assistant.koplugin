"""Surface comprehension candidates for LLM curation. Stdlib only.

Heuristics propose; the LLM disposes. False positives are expected and fine —
the LLM curates and explains; the goal is to never silently MISS a foreign phrase.
"""
import argparse
import json
import re
import sys

_EMPHASIS = re.compile(r"(?<!\*)\*(?!\*)([^*\n]+?)\*(?!\*)|(?<!_)_(?!_)([^_\n]+?)_(?!_)")
_ACCENTED_RUN = re.compile(r"[A-Za-z]*[À-ÖØ-öø-ÿ][\w''\-]*(?:\s+[\w''\-]*[À-ÖØ-öø-ÿ][\w''\-]*)*")
_BLOCKQUOTE = re.compile(r"^\s*>\s?(.*\S)\s*$", re.MULTILINE)
_PROPER = re.compile(r"\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+)+)\b")

def _unique(seq):
    seen, out = set(), []
    for s in seq:
        s = s.strip()
        if s and s not in seen:
            seen.add(s)
            out.append(s)
    return out

def harvest(markdown):
    phrases = []
    for m in _EMPHASIS.finditer(markdown):
        phrases.append((m.group(1) or m.group(2) or "").strip())
    for m in _ACCENTED_RUN.finditer(markdown):
        phrases.append(m.group(0).strip())
    epigraphs = _unique(m.group(1) for m in _BLOCKQUOTE.finditer(markdown))
    counts = {}
    for m in _PROPER.finditer(markdown):
        counts[m.group(1)] = counts.get(m.group(1), 0) + 1
    proper = [name for name, n in sorted(counts.items(), key=lambda kv: -kv[1]) if n >= 2]
    return {"foreign_phrases": _unique(phrases), "epigraphs": epigraphs, "proper_nouns": proper}

def main(argv=None):
    p = argparse.ArgumentParser(description="Harvest comprehension candidates from Markdown.")
    p.add_argument("markdown")
    args = p.parse_args(argv)
    with open(args.markdown, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    json.dump(harvest(text), sys.stdout, indent=2, ensure_ascii=False)
    print()
    return 0

if __name__ == "__main__":
    sys.exit(main())

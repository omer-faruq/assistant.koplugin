"""Ingest a book source into normalized Markdown + a manifest. Stdlib only.

This task adds the pure structural functions; Task 5 adds conversion + CLI.
"""
import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys

import common

_HEADING = re.compile(r"^(#{1,6})[ \t]+(.*\S)[ \t]*$", re.MULTILINE)
_CHAPTER_LINE = re.compile(r"^\s*(?:CHAPTER|Chapter)\s+[\w]+.*$", re.MULTILINE)

def _choose_heading_level(markdown: str):
    """Return the ATX heading level (1–6) with the most occurrences.

    On a tie, returns the smallest (shallowest) level. Returns None if no
    headings are found.

    Heuristic: assumes the chapter level has more headings than any enclosing
    structural level (e.g. Middlemarch: 13 Book h2 vs 86 chapter h3). A
    sub-section-heavy book (chapters with many h3 sub-headings) could mis-split
    on the sub-section level; acceptable for narrative books at stdlib budget.
    """
    counts: dict[int, int] = {}
    for m in _HEADING.finditer(markdown):
        level = len(m.group(1))
        counts[level] = counts.get(level, 0) + 1
    if not counts:
        return None
    max_count = max(counts.values())
    return min(level for level, count in counts.items() if count == max_count)


def _strip_html_tags(text: str) -> str:
    return re.sub(r"<[^>]+>", "", text)


def _chapters_from_matches(text, matches):
    chapters = []
    for i, m in enumerate(matches):
        start = m.start()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        title = (m.group(2) if m.lastindex and m.lastindex >= 2 else m.group(0)).strip()
        chapters.append({"index": i + 1, "title": title,
                         "char_start": start, "char_end": end})
    if chapters:
        chapters[0]["char_start"] = 0
    return chapters

def split_into_chapters(markdown: str):
    level = _choose_heading_level(markdown)
    if level is not None:
        matches = [m for m in _HEADING.finditer(markdown) if len(m.group(1)) == level]
        return _chapters_from_matches(markdown, matches)
    chap = list(_CHAPTER_LINE.finditer(markdown))
    if chap:
        return _chapters_from_matches(markdown, chap)
    return [{"index": 1, "title": "Full Text", "char_start": 0, "char_end": len(markdown)}]

def structural_confidence(chapters, detected_from):
    return "high" if detected_from == "headings" and len(chapters) >= 3 else "low"

def classify_size(token_estimate):
    return "small" if token_estimate < common.SIZE_THRESHOLD_TOKENS else "large"

def target_parts(token_estimate):
    return min(12, max(2, math.ceil(token_estimate / 40000)))

def plan_parts(chapters, n_parts):
    if not chapters:
        return []
    total = chapters[-1]["char_end"] - chapters[0]["char_start"]
    target = max(1, total / n_parts)
    parts, bucket, acc = [], [], 0
    for ch in chapters:
        bucket.append(ch)
        acc += ch["char_end"] - ch["char_start"]
        if acc >= target and len(parts) < n_parts - 1:
            parts.append(bucket)
            bucket, acc = [], 0
    if bucket:
        parts.append(bucket)
    out = []
    for i, group in enumerate(parts):
        out.append({"index": i + 1,
                    "chapter_range": [group[0]["index"], group[-1]["index"]],
                    "char_start": group[0]["char_start"],
                    "char_end": group[-1]["char_end"]})
    return out


def _detect_from(markdown: str) -> str:
    return "headings" if (_HEADING.search(markdown) or _CHAPTER_LINE.search(markdown)) else "none"

def convert_to_markdown(source_path: str):
    ext = os.path.splitext(source_path)[1].lower()
    if ext == ".epub":
        markdown = _strip_html_tags(_epub_to_markdown(source_path))
        meta = _epub_metadata(source_path)
        return markdown, "headings", meta
    with open(source_path, "r", encoding="utf-8", errors="replace") as f:
        markdown = f.read()
    markdown = _strip_html_tags(markdown)
    return markdown, _detect_from(markdown), {
        "title": common.companion_stem(source_path), "author": "", "language": ""}

def _epub_to_markdown(source_path):
    if shutil.which("pandoc"):
        try:
            return subprocess.check_output(
                ["pandoc", "-f", "epub", "-t", "commonmark", source_path],
                text=True, stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            pass
    if shutil.which("ebook-convert"):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "out.txt")
            subprocess.check_call(["ebook-convert", source_path, out],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            with open(out, "r", encoding="utf-8", errors="replace") as f:
                return f.read()
    raise RuntimeError("Neither pandoc nor ebook-convert is available to convert ePub.")

def _epub_metadata(source_path):
    """Best-effort title/author/language from the OPF inside the ePub zip."""
    import zipfile
    meta = {"title": common.companion_stem(source_path), "author": "", "language": ""}
    try:
        with zipfile.ZipFile(source_path) as z:
            opf = next((n for n in z.namelist() if n.lower().endswith(".opf")), None)
            if not opf:
                return meta
            xml = z.read(opf).decode("utf-8", "replace")
        for key, tag in (("title", "title"), ("author", "creator"), ("language", "language")):
            m = re.search(r"<dc:%s[^>]*>(.*?)</dc:%s>" % (tag, tag), xml, re.S | re.I)
            if m:
                meta[key] = re.sub(r"\s+", " ", m.group(1)).strip()
    except Exception:
        pass
    return meta

def build_manifest(markdown, source_path, detected_from, metadata):
    chapters = split_into_chapters(markdown)
    tokens = common.estimate_tokens(markdown)
    size = classify_size(tokens)
    parts = plan_parts(chapters, target_parts(tokens)) if size == "large" else []
    return {
        "title": metadata.get("title") or common.companion_stem(source_path),
        "author": metadata.get("author", ""),
        "language": metadata.get("language", ""),
        "source_path": source_path,
        "source_stem": common.companion_stem(source_path),
        "structural_confidence": structural_confidence(chapters, detected_from),
        "word_count": len(markdown.split()),
        "token_estimate": tokens,
        "size_class": size,
        "chapters": chapters,
        "parts": parts,
    }

def main(argv=None):
    p = argparse.ArgumentParser(description="Ingest a book into normalized Markdown + manifest.")
    p.add_argument("source")
    p.add_argument("--out", required=True)
    args = p.parse_args(argv)
    markdown, detected, meta = convert_to_markdown(args.source)
    manifest = build_manifest(markdown, args.source, detected, meta)
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "normalized.md"), "w", encoding="utf-8") as f:
        f.write(markdown)
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    print(json.dumps({"size_class": manifest["size_class"],
                      "chapters": len(manifest["chapters"]),
                      "structural_confidence": manifest["structural_confidence"]}))
    return 0

if __name__ == "__main__":
    sys.exit(main())

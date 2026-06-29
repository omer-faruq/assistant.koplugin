"""Resolve a book title to a source file path via calibredb. Stdlib only."""
import argparse
import json
import os
import subprocess
import sys

DEFAULT_LIBRARY = os.environ.get("CALIBRE_LIBRARY", os.path.expanduser("~/Calibre Library"))
_PREFERENCE = (".epub", ".md", ".txt", ".mobi")

def choose_format(formats):
    for ext in _PREFERENCE:
        for path in formats:
            if path.lower().endswith(ext):
                return path
    return None

def parse_candidates(calibredb_json):
    rows = json.loads(calibredb_json or "[]")
    out = []
    for row in rows:
        formats = row.get("formats") or []
        out.append({
            "id": row.get("id"),
            "title": row.get("title"),
            "authors": row.get("authors"),
            "formats": formats,
            "source": choose_format(formats),
        })
    return out

def _calibredb_runner(library):
    def run(title):
        return subprocess.check_output([
            "calibredb", "list",
            "--search", 'title:"%s"' % title,
            "--fields", "title,authors,formats",
            "--for-machine",
            "--with-library", library,
        ], text=True)
    return run

def resolve(title, runner):
    candidates = parse_candidates(runner(title))
    if not candidates:
        return {"status": "not_found"}
    if len(candidates) == 1:
        c = candidates[0]
        if c["source"] is None:
            return {"status": "not_found"}
        return {"status": "resolved", "source": c["source"],
                "title": c["title"], "authors": c["authors"]}
    return {"status": "ambiguous", "candidates": [
        {"id": c["id"], "title": c["title"], "authors": c["authors"], "source": c["source"]}
        for c in candidates]}

def main(argv=None):
    p = argparse.ArgumentParser(description="Resolve a book title via calibredb.")
    p.add_argument("title")
    p.add_argument("--library", default=DEFAULT_LIBRARY)
    args = p.parse_args(argv)
    result = resolve(args.title, runner=_calibredb_runner(args.library))
    json.dump(result, sys.stdout, indent=2)
    print()
    return 0 if result["status"] == "resolved" else 1

if __name__ == "__main__":
    sys.exit(main())

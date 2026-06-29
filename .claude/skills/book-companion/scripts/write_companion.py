"""Write the companion to its two destinations with the exact-match filename."""
import argparse
import os
import sys

import common

def write_both(content, source_path, repo_companions_dir, book_folder):
    name = common.companion_filename(source_path)
    paths = []
    for d in (repo_companions_dir, book_folder):
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        paths.append(os.path.abspath(path))
    with open(paths[0], "rb") as f1, open(paths[1], "rb") as f2:
        if f1.read() != f2.read():
            raise ValueError("written companions differ between destinations")
    return paths

def main(argv=None):
    p = argparse.ArgumentParser(description="Write companion to repo + book folder.")
    p.add_argument("--content", required=True)
    p.add_argument("--source", required=True)
    p.add_argument("--repo-companions", required=True)
    p.add_argument("--book-folder", required=True)
    args = p.parse_args(argv)
    with open(args.content, encoding="utf-8", errors="replace") as f:
        content = f.read()
    for pth in write_both(content, args.source, args.repo_companions, args.book_folder):
        print(pth)
    return 0

if __name__ == "__main__":
    sys.exit(main())

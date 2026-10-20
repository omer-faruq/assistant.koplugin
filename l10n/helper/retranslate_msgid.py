#!/usr/bin/env python3
"""Empty one msgid's translation so the next pipeline run retranslates it.

Usage: ./helper/retranslate_msgid.py <lang_dir> <msgid>

<lang_dir> is a locale directory holding assistant.po (e.g. `ja`); <msgid>
is matched exactly, including <b> markup and %N placeholders. The matching
entry's msgstr (or msgstr_plural) and fuzzy flag are cleared, and the file
is saved in place. Normally run via `make retranslate-msgid MSGID="..."
[L10N_LANG=xx]`, which retranslates the emptied entries afterwards.

Exit status: 0 on success and when there is nothing to do (missing file or
entry, already untranslated); non-zero on bad arguments and catalogues that
cannot be read or parsed.
"""

from __future__ import annotations

import argparse
import os
import sys

from po_ops import clear_entry, load


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="retranslate_msgid.py",
        description="Empty one exact msgid's translation in a locale's "
                    "assistant.po so the next pipeline run retranslates it.",
        epilog="Normally run via `make retranslate-msgid MSGID=\"...\" "
               "[L10N_LANG=xx]`.",
    )
    parser.add_argument(
        "lang_dir",
        help="locale directory holding assistant.po, e.g. 'ja' (resolved "
             "against the current directory)",
    )
    parser.add_argument(
        "msgid",
        help="exact msgid to empty, including <b> markup and %%N placeholders",
    )
    args = parser.parse_args(argv)
    lang_dir, msgid = args.lang_dir, args.msgid

    path = f"{lang_dir}/assistant.po"
    if not os.path.isfile(path):
        print(f"[{lang_dir}] no assistant.po, skipped")
        return 0
    try:
        po = load(path)
    except OSError as exc:
        print(f"[{lang_dir}] cannot parse {path}: {exc}")
        return 2

    entry = po.find(msgid)
    if entry is None:
        print(f"[{lang_dir}] msgid not found, skipped")
        return 0

    if not clear_entry(entry):
        print(f"[{lang_dir}] already untranslated, skipped")
        return 0
    po.save()
    print(f"[{lang_dir}] emptied for retranslation")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Small polib helpers shared by the l10n helpers."""

from __future__ import annotations

import polib


def load(path: str) -> polib.POFile:
    """Load a catalogue without rewrapping its entries."""
    return polib.pofile(path, wrapwidth=0)


def is_empty(entry: polib.POEntry) -> bool:
    """True when the entry has no translation to keep."""
    if entry.msgid_plural:
        return not any(value.strip() for value in entry.msgstr_plural.values())
    return not (entry.msgstr or "").strip()


def clear_entry(entry: polib.POEntry) -> bool:
    """Empty the entry's translation and drop its fuzzy flag.

    A plural entry keeps every form slot but empties all of them, because the
    translator refills a plural entry only once all forms are empty. Returns
    True when the entry changed.
    """
    changed = False
    if "fuzzy" in entry.flags:
        entry.flags.remove("fuzzy")
        changed = True
    if entry.msgid_plural:
        if any(value.strip() for value in entry.msgstr_plural.values()):
            entry.msgstr_plural = {index: "" for index in entry.msgstr_plural}
            changed = True
    elif entry.msgstr.strip():
        entry.msgstr = ""
        changed = True
    return changed

"""Shared helpers for the book-companion scripts. Standard library only."""
import math
import os

SIZE_THRESHOLD_TOKENS = 60000

def companion_stem(source_path):
    """Basename of source_path with its final extension removed."""
    base = os.path.basename(source_path)
    root, ext = os.path.splitext(base)
    return root if ext else base

def companion_filename(source_path):
    return companion_stem(source_path) + ".companion.md"

def estimate_tokens(text):
    return max(1, math.ceil(len(text) / 4))

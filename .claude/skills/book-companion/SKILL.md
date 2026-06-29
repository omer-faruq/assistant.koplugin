---
name: book-companion
description: Use when the user wants to generate a Book Companion reference (a `.companion.md` sidecar) for a book — given a Calibre title, an ePub, or a `.md`/`.txt` file. Produces a spoiler-safe, comprehension-first companion and writes it to the repo `companions/` folder and beside the book.
---

# Book Companion Generator

Generate a `<book-stem>.companion.md` reference for the assistant.koplugin Book
Companion feature. **Comprehension over plot**: the reader's barrier is lost cultural,
historical, and linguistic knowledge — prioritize terms, references, allusions, and
untranslated phrases; keep the plot pass lean (it is scaffolding and the spoiler anchor).

Deterministic Python scripts (under `scripts/`) own ingestion, structure, verification,
and writing. **You** own the comprehension writing. Scripts feed you (manifest +
candidates) and check you (verification report).

## Inputs

One of: a **book title** (resolve via Calibre), an **ePub path**, or a **`.md`/`.txt` path**.

## Procedure

### 1. Resolve the source
- **Title:** run `python3 scripts/resolve_book.py "<title>"`.
  - `status: resolved` → use `source`.
  - `status: ambiguous` → show `candidates` (title — authors — id) and ask which.
  - `status: not_found` → ask the user to refine the title or give a path.
- **Path:** use it directly.

### 2. Ingest
Run `python3 scripts/ingest.py "<source>" --out <workdir>` (use a scratch dir).
Read `<workdir>/manifest.json`. Note `size_class`, `chapters`, `structural_confidence`.
If `structural_confidence` is `low`, warn the user the chapter pass is best-effort.

### 3. Harvest candidates
Run `python3 scripts/harvest_candidates.py "<workdir>/normalized.md" > <workdir>/candidates.json`.
This is your **coverage checklist** for foreign phrases, epigraphs, and recurring names.

### 4. Chapter pass (adaptive — driven by `size_class`)
- **small:** read `normalized.md` yourself; take ≈1–2 lean bullets per chapter and note
  glossary/allusion/foreign-phrase/character material as you go.
- **large:** for each entry in `manifest.parts`, dispatch a subagent over that
  `char_start:char_end` slice of `normalized.md`. Each subagent returns: (a) lean
  chapter bullets for its range, and (b) a harvest of names, glossary-worthy terms,
  foreign phrases, and allusions. Then merge: dedupe characters by name-as-spelled;
  union the glossary/allusion/phrase sets.

### 5. Synthesize the companion
Following `references/section-guide.md` and `references/spoiler-rules.md`, write the
companion. Lead with the comprehension sections' depth; keep the plot pass lean.
Use the Middlemarch exemplar (`references/exemplar.md`) as the quality bar.
**Spoiler discipline is mandatory** — spoiler-free identity lines; arcs only on
`↳ _Arc (spoiler):_` lines; chapter-anchored plot. Save the draft to `<workdir>/draft.md`.

### 6. Write to both destinations
Determine the book folder (for a Calibre/ePub source, the directory containing the
source file; for a path input, that file's directory). Then:
```
python3 scripts/write_companion.py --content <workdir>/draft.md --source "<source>" \
  --repo-companions companions --book-folder "<book-folder>"
```

### 7. Verify (mechanical gate)
```
python3 scripts/verify_companion.py --companion companions/<stem>.companion.md \
  --manifest <workdir>/manifest.json --source <workdir>/normalized.md \
  --candidates <workdir>/candidates.json --stem "<stem>" \
  --paths "<path1>,<path2>"
```
`<path1>,<path2>` are the two file paths that `write_companion.py` printed in step 6
(the repo `companions/` copy and the beside-the-book copy), comma-separated.
**`ok: false` is driven by three hard mechanical gates only:** stray prefix before the
first `#` heading, missing chapters (a manifest index/title absent from the companion),
or filename/paths mismatch. Fix any of those and re-run steps 5–7.

`names_missing_from_source` and `phrases_uncovered` are **advisory** lists in the
report — they do NOT affect `ok`. Review them during the step 8 judgment self-check:
a flagged name may be a hallucination or misspelling worth correcting, or merely a
multi-name group label (e.g. `**Dr. A & Dr. B**`) that harvest never sees verbatim;
a flagged phrase may be harvest noise rather than a real gap.

### 8. Judgment self-check (you, not a script)
Confirm: foreign phrases are translated and glossed; allusions are **explained**, not
named; no spoilers in §1 or identity lines; nothing fabricated beyond what the source
or well-established knowledge supports. Also eyeball `names_missing_from_source` and
`phrases_uncovered` from the step 7 report — fix genuine hallucinations or gaps, ignore
false positives (group labels, harvest noise).

## Notes
- Scripts are stdlib-only; no setup step.
- Deploying the companion to the device is a separate manual step.
- This is a public repo — never write secrets.

# Companion Section Guide

The companion is **comprehension-first**: the reader's barrier is lost cultural,
historical, and linguistic knowledge. Prioritize terms, references, allusions, and
untranslated phrases. The plot pass is lean scaffolding (and the spoiler anchor).

## Always include (core)

### 1. Quick Orientation
2–4 paragraphs: setting, period, social world, and the through-lines. Orient a cold
reader. **No later-book outcomes** (spoiler-free).

### 2. Character Dictionary
Each entry: a **spoiler-free identity line** (`**Name** *(first appears: …)* — role`),
followed *only when needed* by an indented arc line. See `spoiler-rules.md`.

### 3. Chapter-by-Chapter Plot
≈1–2 tight bullets per chapter, each under a heading that names the chapter
(`### Chapter <N>` or the book's own `### Book II, Chapter 14`). This is scaffolding —
keep it lean. Chapter-anchoring is what lets the runtime spoiler guard work.

## Include whenever the book has such content — be thorough here

### 4. Historical / Political / Social Glossary
Institutions, customs, money, law, status markers a modern reader won't know.
Define them; tie each to how it matters in the book.

### 5. Allusions & References
Biblical, classical/mythological, literary, scientific. **Explain** each — don't just
name it. Group by kind when there are many.

### 6. Foreign-Language Phrases
Every untranslated phrase, with a translation and an in-context gloss. The harvest from
`harvest_candidates.py` is your checklist; cover all of it that is genuinely foreign.

### 7. Motifs & Symbols
Recurring images and their interpretive weight.

## Adaptive

### 8. Reading the [Author]'s Narrator
Only when the narrative voice/technique is itself a comprehension barrier (e.g. free
indirect discourse, an unreliable narrator).

### Book-specific section
Add one when the work warrants it (e.g. a timeline for a time-jumping novel).

## Omission
Sections that genuinely don't apply are **omitted, not padded**. A modern
plain-language thriller likely has no §6 and a thin §4.

## Formatting

Top-level companion sections use `##` headings. Within the **Character Dictionary**,
reserve `**bold**` for character names (or direct name-group labels) so the verifier's
name-presence check stays meaningful — avoid bolding non-name labels or descriptors.

## Density
Mirror the Middlemarch exemplar's density for known-good calibration. For very long
books, tighten the chapter pass toward 1 bullet/chapter so the whole companion stays
usable at injection time.

# Book Companion

A Book Companion is a pre-authored, comprehension-first reference that the assistant plugin loads alongside a specific book. It covers the cultural, historical, and linguistic knowledge a reader needs to understand the text — glossary terms, character identities, historical context, literary allusions, and untranslated phrases — without revealing anything about the story ahead.

The design principle is comprehension over plot. A companion prioritizes what readers actually get stuck on: archaic or period vocabulary, political and historical background, classical and biblical allusions, foreign-language passages, and identifying who the named people are. Plot summary is kept to a minimum and is always chapter-anchored, so it can serve as a spoiler anchor rather than a plot guide. The companion is written for one specific book and verified against it at generation time.

## What a Book Companion Is

When you highlight a difficult passage in a book that has a companion, the plugin's "Book Companion" button appears in both the highlight popup and the dictionary popup. Tapping it sends the companion to the AI as its primary, authoritative reference and asks it to explain the passage using that reference first.

The companion does not replace the AI's general knowledge — it focuses it. If the companion covers a term, the AI answers from it. If the companion does not cover something, the AI still helps, but labels that part clearly so you know it comes from general knowledge rather than the vetted reference. The AI is also spoiler-aware: it knows your current progress through the book and will not volunteer information from chapters you have not yet reached.

For short highlights (roughly three words or fewer), the prompt switches to a concise dictionary mode — a brief definition of the word or phrase in context rather than a full comprehension explanation. For longer passages, it focuses on whatever is genuinely hard to follow: who someone is, what an allusion means, what a foreign phrase says, what the historical situation was.

## The `.companion.md` Sidecar

A companion is a plain Markdown file named `<book-stem>.companion.md`, placed in the same directory as the book file on the device.

The filename stem is derived by stripping only the final extension from the book's path. For example:

```
/Books/Middlemarch.epub  →  /Books/Middlemarch.companion.md
```

The plugin (`assistant_companion.lua`) checks for this sibling file whenever you open a book. If the file exists and is non-empty, the companion prompt becomes available. If the file is missing, unreadable, or empty, the companion prompt is hidden — the plugin treats an empty file the same as an absent one.

The name must match the book file's basename exactly. If your book is `The_Brothers_Karamazov.epub`, the companion must be `The_Brothers_Karamazov.companion.md`. The `companions/` folder in this repository stores the reference copies; to use a companion on a device, copy the `.companion.md` file from that folder to sit beside the book file.

## The Companion Prompt and Sidecar-Gated Selector

The "Book Companion" button is defined in `assistant_prompts.lua` with `use_companion = true`. This flag does two things: it causes the plugin to inject the sidecar's contents into the AI's context as a system message, and it routes the query through the Book Companion provider (if one is configured; see the next section).

The button only appears when a non-empty companion sidecar exists for the currently open book. This check is done at the time the popup is drawn. There is no manual toggle — the file's presence is the switch.

`show_on_main_popup = true` places the button directly in the highlight selection popup for one-tap access. `show_on_dictionary_popup = true` makes it available in the single-word dictionary popup as well.

The AI's behavior when the companion is loaded:

- **Companion-first**: The companion is treated as the primary, authoritative source for characters, plot, history, allusions, and terms.
- **Beyond-the-companion marking**: If the passage requires something the companion does not cover, the AI still answers but opens that portion with `⚠️ Beyond the companion:` so you know it is not from the vetted reference.
- **No companion fallback**: If the companion file could not be loaded (for example, the file disappeared after the popup was drawn), the AI begins with `_(No companion loaded — answering from general knowledge.)_` and then answers anyway.
- **Spoiler guard**: The user prompt includes your current reading progress (`{progress}%`). The AI limits its use of companion material to what has already happened in the book and will not volunteer events or character fates from later chapters unless you explicitly ask.
- **Short-highlight dictionary mode**: For passages of roughly three words or fewer, the AI leads with a concise definition rather than a full comprehension response. It prefers the companion's glossary, allusions, or character entries when the term appears there; otherwise it defines from general knowledge and marks it accordingly.

## The Book Companion Provider

The Book Companion uses a separate provider and model selection, independent of the plugin's global AI Provider. This lets you dedicate a specific model — for example, a context-heavy or literature-focused one — to companion queries without changing your main provider for other prompts.

The selection is stored in the plugin's settings under the key `book_companion_provider`. Within that provider, a per-provider model override (`book_companion_model_<provider>`) is also stored separately from the main provider's model choice.

To configure it, open the plugin's settings and look for the **Book Companion** provider section (distinct from the main AI Provider section). From there you can choose any provider and model that you have already configured in `configuration.lua`.

If no Book Companion provider is set, companion prompts run on whatever provider is currently active for the rest of the plugin. Setting it to "Not set" reverts to that behavior. The provider override is applied only for queries routed through a `use_companion = true` prompt; all other prompts continue to use your main provider.

## Generating a Companion

Companions are produced by the `book-companion` Claude skill, which lives in `.claude/skills/book-companion/`. The skill orchestrates a four-stage pipeline of deterministic Python scripts (all stdlib, no installation required) and AI-authored comprehension writing.

### The pipeline

| Stage | Script | What it does |
|-------|--------|--------------|
| Resolve | `scripts/resolve_book.py` | Finds the book in Calibre and returns a source path |
| Ingest | `scripts/ingest.py` | Normalizes the source to Markdown, detects chapter structure, emits `manifest.json` |
| Harvest | `scripts/harvest_candidates.py` | Extracts foreign phrases, epigraphs, and recurring names as a coverage checklist |
| Write | `scripts/write_companion.py` | Writes the finished companion to both the repo `companions/` folder and beside the book |
| Verify | `scripts/verify_companion.py` | Checks the companion against the manifest (chapter coverage, filename, no stray prefix) |

Writing the comprehension content — the glossary entries, allusion explanations, character identities, historical notes — is done by the AI during the skill run, guided by the candidates from the harvest stage and checked against the manifest by the verify script.

### Running the generator

Invoke the `book-companion` skill from a Claude Code session in this repository. Give it one of:

- **A book title** — the skill resolves it via `calibredb` to an ePub or text file.
- **An ePub path** — used directly.
- **A `.md` or `.txt` path** — used directly.

When resolving by title, the skill looks for the book in your Calibre library. The library location is determined in this order of precedence:

1. The `--library` flag passed to `scripts/resolve_book.py`
2. The `CALIBRE_LIBRARY` environment variable
3. The default `~/Calibre Library`

You do not need to set anything if your library is in the standard location.

### What the pipeline produces

After a successful run, the skill writes the companion to two places:

1. `companions/<stem>.companion.md` in this repository — the reference copy for version control.
2. `<book-folder>/<stem>.companion.md` beside the source book file — ready to deploy to a device.

Deploying to the device is a separate manual step: copy the `.companion.md` file (from either location) to sit beside the book file on the device's storage, matching the naming rule described in [The `.companion.md` Sidecar](#the-companionmd-sidecar).

### Verification

After writing, the skill runs `scripts/verify_companion.py`. Three hard gates must pass for the result to be accepted:

- No stray content before the first `#` heading in the companion file.
- All chapters listed in the manifest appear in the companion.
- The filename and output paths match what `write_companion.py` reported.

The verify script also produces advisory lists — names and phrases from the harvest stage that are not clearly covered in the companion. These do not block acceptance but should be reviewed: a flagged name may be a hallucination or misspelling worth correcting, and a flagged phrase may indicate a genuine gap in the glossary.

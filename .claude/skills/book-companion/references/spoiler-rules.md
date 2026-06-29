# Spoiler Rules (load-bearing)

The runtime spoiler guard (`assistant_prompts.lua` companion prompt) trusts the
companion to be authored so that material before a reader's position never leaks
later events. Author every companion to make that possible.

## Character Dictionary format

Spoiler-free identity first; arc (if any) **only** on its own line that opens with
the exact marker `↳ _Arc (spoiler):_`. The `↳` glyph provides the visual offset — do
**not** add literal leading spaces (4+ leading spaces make Markdown render the line as a
code block and break the companion). Keep the `↳ _Arc` line flush-left, as in the
Middlemarch exemplar.

```
**Dorothea Brooke** *(first appears: Book I, Ch 1)* — Ardent, intelligent young
gentlewoman and heiress; yearns for a life of great usefulness.
↳ _Arc (spoiler):_ Marries the older scholar Casaubon; widowed; eventually marries
Will Ladislaw.
```

Rules:
- The identity line must reveal **no** fate, death, marriage, betrayal, or twist.
- Everything that happens *to* a character over the book goes on the `↳ _Arc` line.
- Keep the marker verbatim and the line flush-left (no leading spaces) so it is visually
  and programmatically separable.

## Quick Orientation
Describes the world and premise, **not** the ending. No outcomes.

## Chapter-by-Chapter Plot
Each bullet belongs to the chapter where the event happens, so a reader at chapter N
only ever sees up to chapter N. Never foreshadow a later chapter's reveal in an
earlier chapter's bullets.

## Self-check before finishing
Re-read §1 and every identity line. If any sentence states something a reader would
consider a spoiler, move it to an `↳ _Arc` line or a later chapter bullet.

# UI / Dialogs

KOReader UI is niche. **Reuse existing scaffolding** (`ChatGPTViewer`, `assistant_dialog.lua`, `assistant_provider_registry.lua`) rather than building new widget trees. When hand-building, scan `/usr/lib/koreader/frontend/ui/widget/` and `/usr/lib/koreader/plugins/` for reference patterns first.

## General conventions

- Dialog buttons: cancellation/close on the **left**, action buttons (Save/OK) on the **right** (KOReader `InputDialog` convention).
- Menu/UI labels: Title Case for titles, settings items, checkboxes, dialog labels; keep short words (`to`, `for`, `as`, `and`, `in`) lowercase.
- Success/confirmation → `Notification:notify(msg, Notification.SOURCE_ALWAYS_SHOW)` (non-blocking). Errors/failures/ack → `UIManager:show(InfoMessage:new{...})` (blocks).

## Ask dialog checkbox layout (`assistant_dialog.lua`)

Side-by-side rows: `HorizontalGroup{ HorizontalSpan(left_gap) + CheckButton(width=half_w) + HorizontalSpan(gap) + CheckButton(width=half_w) }`.

- Each `CheckButton` needs an explicit `width = half_w` or it overflows (`checkbutton.lua:77`).
- Left inset `left_gap = (dialog_width - available_w - input_extra)/2` where `input_extra = 2*(Size.border.inputtext + Size.padding.small + Size.margin.default)` — aligns to the InputText border; don't hardcode `Size.padding.large`.
- Actual labels are emoji-prefixed: `✉ Attach Prior Text`, `✎ Current Chapter Only`, `🌐 Web Search`, `⌨ Copy to Clipboard`.

## Hand-built dialogs (no input field)

`InputDialog` **always** creates and renders an `InputText` — there is no flag to hide it. For checkbox-only / pure-picker forms, build the widget tree by hand. Reference: `Registry.showParametersDialog` in `assistant_provider_registry.lua`.

Recipe (mirror `ConfirmBox`/`ProviderDialog`):

`CenterContainer(full-screen Geom) → MovableContainer → FrameContainer(background COLOR_WHITE, radius/border) → VerticalGroup{ TitleBar, content widgets…, CenterContainer(ButtonTable) }`.

Keep `frame`/`movable` in locals upvalue-captured by the dirty callbacks.

Pitfalls learned there:

- **Paint hooks are mandatory**: a bare `InputContainer` is never painted. Set `modal = true` and define `onShow`/`onCloseWidget` that call `UIManager:setDirty(self/nil, function() return "ui", movable.dimen end)`. Without them the dialog silently never appears (or never clears).
- **Children must be positional**: containers traverse `[1]`, `[2]`, …; `MovableContainer:new{ frame = ... }` stores children in the hash part and renders nothing. Build sub-widgets into locals, then pass them positionally.
- **`CheckButton` needs an explicit `width`** when its parent has no `getAddedWidgetAvailableWidth()` (it dereferences that method otherwise).
- **Never store widget references on module-level tables** (e.g. writing `item.checkbox = ...` back onto a shared catalog): it pins the whole closed dialog tree in memory and leaks state across dialog instances. Keep widget refs in locals.
- **Declare locals before closures that use them**: button callbacks built in a `buttons` table close over dialog locals; a local declared *after* the table silently captures a nil **global** and crashes only when the button is tapped (`attempt to index global 'x' (a nil value)`). Declare shared locals (`dialog`, checkbox tables, …) above any closure that references them, and note why.
- **Missing children crash at first paint, not construction**: a stale/nil child reference leaves a container without `[1]`; construction succeeds and the crash surfaces only on repaint (`framecontainer.lua:55 self[1]:getSize()`). Reproduce with a runui script: show the dialog, then `UIManager:scheduleIn(2, function() UIManager:forceRePaint(); UIManager:quit() end); UIManager:run()` — and exercise button callbacks programmatically (`button_table:getButtonById("ok").callback()`, or `buttons_layout[row][col]` positionally when the entry has no `id`) to cover tap-time paths headlessly.

## Result viewer shapes (`assistant_viewer.lua`)

`ChatGPTViewer` has two shapes, selected by the Response Settings `minimalist_mode` switch (default off):

- **Standard** — two button rows (navigation/clipboard, then actions with Close rightmost) plus the page-button scroll feedback; the reply carries the `☺ Question` / `❖ Deeply Thought` / `✦ Response` / `✦ Search` carriers emitted by `TextUtils.formatSingleMessage`.
- **Minimalist** — a single Close button, no navigation row, no Ask/Annotate/Save actions, no scroll feedback; the reply is assembled by `TextUtils.formatAnswerOnly` (no carriers, no prompt name, no reasoning block, no follow-up questions).

The switch is read at two points on purpose: when the result is **assembled** (the dialogs pass `minimal` into the formatter, so the text is built in the shape it is displayed) and when the **viewer** is built (the button rows). Turning it on clears `show_reasoning` / `auto_prompt_suggest` and greys both out in the menu, so the stored text can never disagree with the menu state.

**Produce what you display.** The renderer is left with styling only (`_renderMarkdown` does not filter); every display decision is taken upstream:

- **At answer time** — `Querier` folds reasoning into the answer only while `show_reasoning` is on (`strip_think_tags`), and the follow-up switch keeps `<suggestions>` out of the history.
- **At assembly time** — a turn answered before a switch was turned off still carries what the switch now hides, so the templates drop it: `TextUtils.splitReasoning` splits off a reasoning fence (`formatSingleMessage` emits the `❖ Deeply Thought` block only while the switch is on, `formatAnswerOnly` never does) and `TextUtils.stripSuggestions` removes a leftover `<suggestions>` block.

Flipping a display switch calls `ChatGPTViewer:_refreshText()`, which re-assembles the reply through the caller's `rebuild_text` and repaints — so the change is immediate instead of waiting for the next answer. The rebuilt widget keeps the current page, clamped by `scrollToPage` when the text shrinks.

## KOReader widget internals (last resort)

Check the public API first, then read the widget source under `/usr/lib/koreader/frontend/ui/widget/` to trace the `widget[1]`/`[2]` tree; swap a sub-widget and nil `_size`/`_offsets`/`dimen` up the tree to re-layout. Always comment the widget-tree path.

## Safe symbols in model output

Viewer HTML falls back through `Noto Sans CJK TC → … → FreeSans → Noto Sans`. Glyph coverage of the bundled fonts (checked with fontTools cmap over `noto/`, `freefont/`, `droid/`) decides what prompts may emit:

- Safe: `★ ◆ ● ○ ❖ ✓ ▪ ‣ ⚠ → ⇧ ⏎ ✦ ⮞` (all covered by FreeSans and/or Noto CJK).
- Tofu: color emoji (`U+1F300` and up; only `U+1F4A1` exists in FreeSerif) and anything with `VS16` forcing emoji presentation — use bare `⚠`, never `⚠️`.
- Noto Sans/Serif base cover almost none of the above; never rely on them alone.
- Coverage is necessary but not sufficient — visually confirm with `./test/runui.sh unicode_icons`.

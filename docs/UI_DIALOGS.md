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

- **Standard** — two button rows (navigation/clipboard, then actions with Close rightmost) plus the page-button scroll feedback; the reply is a chat transcript emitted by `TextUtils.formatSingleMessage`: each user turn is a right-aligned `<div class="user-bubble">` (titled by the preset prompt name when one ran, then the typed text), reasoning is a `<div class="thought-block">`, and the answer is bare, left-aligned body text. There are no per-turn carrier labels.
- **Minimalist** — no navigation row (no page buttons, Find or Copy), no page-button scroll feedback, and an action row reduced to the actions that act on the answer itself: `Annotate` (when a highlight context exists), caller `extra_buttons` (the dictionary viewer adds `Vocabulary Builder`) and `Close`. `Ask Another Question` and `Save` are the chrome it removes. The reply is assembled by `TextUtils.formatAnswerOnly` (no bubbles, no prompt name, no reasoning block, no follow-up questions).

The switch is read at two points on purpose: when the result is **assembled** (the dialogs pass `minimal` into the formatter, so the text is built in the shape it is displayed) and when the **viewer** is built (the button rows). Turning it on clears `show_reasoning` / `auto_prompt_suggest` and greys both out in the menu, so the stored text can never disagree with the menu state.

**Produce what you display.** The renderer is left with styling only (`_renderMarkdown` does not filter); every display decision is taken upstream:

- **At answer time** — `Querier` folds reasoning into the answer only while `show_reasoning` is on (`strip_think_tags`), and the follow-up switch keeps `<suggestions>` out of the history.
- **At assembly time** — a turn answered before a switch was turned off still carries what the switch now hides, so the templates drop it: `TextUtils.splitReasoning` splits off a reasoning fence (`formatSingleMessage` wraps it in a `.thought-block` only while the switch is on, `formatAnswerOnly` never does) and `TextUtils.stripSuggestions` removes a leftover `<suggestions>` block.

Flipping a display switch calls `ChatGPTViewer:_refreshText()`, which re-assembles the reply through the caller's `rebuild_text` and repaints — so the change is immediate instead of waiting for the next answer. The rebuilt widget keeps the current page, clamped by `scrollToPage` when the text shrinks.

## MuPDF CSS support (viewer constraint)

The viewer HTML goes through MuPDF's own engine (`source/html/` in ArtifexSoftware/mupdf), whose entire property table is `css-properties.gperf` — **85 entries, no more**. `ScrollHtmlWidget` embeds our CSS in a `<head><style>`, so anything absent from that table is silently dropped. Design viewer CSS against that list, not against a browser's.

Supported: `background-color`, `border` + `border-{top,right,bottom,left}` + `-color`/`-style`/`-width`, `color`, `display` (block/inline only), `font-*`, `height`, `letter-spacing`, `line-height`, `list-style-*`, `margin` + `margin-*`, `overflow-wrap`, `padding` + `padding-*`, `text-align`, `text-decoration`, `text-indent`, `text-transform`, `vertical-align`, `white-space`, `width`, `word-spacing`, `direction`, `float`, `clear`, `position`/`top`/`right`/`bottom`/`left`.

**Not supported** — do not design around them:

- `border-radius`: absent from the property table entirely. No CSS-level workaround either. Tracked upstream as koreader/koreader#8183 (open since 2021, still unsupported in 2026.3). Only real options are Unicode `╭╮╰╯` glyphs (Noto Sans/Serif do **not** carry them — needs `font-family: 'FreeSans'` or DejaVu) or painting the panel in Lua outside the HTML flow.
- `background-image`: explicitly unimplemented (`html-imp.h`, `css-apply.c` `add_shorthand_background()`); kills the image-based workaround.
- `max-width`, `box-shadow`, `opacity`, `flex`, `grid`, `transform`, `border-image`, `outline`, `box-sizing`.
- Selector: only `:root`, `:empty`, `:first-child`, `:nth-child`, `:link` — no `:hover`.

Consequences for the chat layout: a right-aligned bubble uses `margin-left: 38%` (a fixed percentage, which MuPDF honors) — not `margin-left: auto`, not `max-width`. `text-align: right` right-aligns the *text* but the element's background still spans the full width, so it cannot substitute for the margin trick. `float` and `display: table` both misbehave (float needs a clearing element; display-table backgrounds over-extend). Rectangular backgrounds with a `border-left` accent are the substitute for rounded corners.

**`margin-left` doubles as `max-width`.** MuPDF shrink-to-fits a block within the width its margin leaves, so the margin is both the alignment offset and the width cap: `margin-left: 38%` right-aligns the bubble and caps it at 62% of the page, while a short turn still hugs its text. Lowering the margin widens long turns; raising it narrows them. This is the only working equivalent of `max-width` + `margin-left: auto`.

**Do not set `width` on a bubble.** There is no `box-sizing`, so `width` is the content box: padding and border are added on top and overflow it. A `width: 50%` + `margin-left: 50%` bubble renders *narrower* than the shrink-to-fit one, and `width: 62%` bleeds off the right edge. Verified with `./test/runui.sh bubble_width`.

**`max-width` and `margin-left: auto` fail silently and together.** A plausible-looking `max-width: 50%; margin-left: auto` rule loses both properties and degrades to a full-width, left-aligned block with no error anywhere. This is why the CSS carries a test asserting neither property ever reappears.

## Screenshotting a UI test (WSL2)

`Screen:shot()` does not exist on the SDL3 backend (`frontend/device/sdl/device.lua` implements only `init/resize/_newBB/_render/refreshFullImp/setWindowTitle/setWindowIcon/close`), so `screenshoter.lua` cannot be reused. Read the framebuffer directly instead:

```lua
UIManager:scheduleIn(2, function()
    UIManager:forceRePaint()
    UIManager:scheduleIn(0.5, function()
        Screen.bb:writeToFile("/tmp/shot.png", "png")
        UIManager:quit()
    end)
end)
```

Note the `forceRePaint` + follow-up tick: the blitbuffer only holds painted pixels, so screenshotting on the same tick as `UIManager:show` yields a stale or blank frame.

System-level capture is unavailable under WSL2 — WSLg's weston never paints the X root drawable, so `scrot`, `import -window root`, and `ffmpeg -f x11grab` all return solid black. Per-window X11 capture (`import -window <id>`) or a Windows-side PowerShell capture both work; the framebuffer route above is simpler and is what the runui scripts use.

## KOReader widget internals (last resort)

Check the public API first, then read the widget source under `/usr/lib/koreader/frontend/ui/widget/` to trace the `widget[1]`/`[2]` tree; swap a sub-widget and nil `_size`/`_offsets`/`dimen` up the tree to re-layout. Always comment the widget-tree path.

## Safe symbols in model output

Viewer HTML falls back through `Noto Sans CJK TC → … → FreeSans → Noto Sans`. Glyph coverage of the bundled fonts (checked with fontTools cmap over `noto/`, `freefont/`, `droid/`) decides what prompts may emit:

- Safe: `★ ◆ ● ○ ❖ ✓ ▪ ‣ ⚠ → ⇧ ⏎ ✦ ⮞ ‹ ›` (all covered by FreeSans and/or Noto CJK).
- `🌐` `U+1F310` renders too, and is the plugin's web-search icon (`Prompts.WEBSEARCH_ICON`, and the search-keyword marker in `assistant_tool_executor.lua`). It comes out monochrome from a text font rather than as color emoji, so it reads as a small text glyph — do not assume other `U+1F300`+ code points behave the same way.
- Tofu: anything forcing **color emoji** presentation, which the bundled fonts lack. The usual culprit is `VS16` (a variation selector forces the emoji, color form): use bare `⚠`, never `⚠️`. `🔍`/`🔎` are tofu — for a magnifier use `U+2315` `⌕`, which draws a real lens and handle, or the globe above when the meaning is a web search. Verified with `./test/runui.sh magnifier_probe`.
- Noto Sans/Serif base cover almost none of the above; never rely on them alone.
- Coverage is necessary but not sufficient — visually confirm with `./test/runui.sh unicode_icons`.

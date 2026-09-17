-- Markdown CSS debug viewer (uses the project's real Markdown control).
-- Usage: ./test/runui.sh markdown_css
--
-- Shows a ChatGPTViewer filled with headings, lists, tables, code and
-- quotes so VIEWER_CSS effects can be eyeballed on device/emulator.
-- This file is dev-only (test/ is excluded from release zips).

-- Add project root to path before requiring wbuilder
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local wb = require("test/wbuilder")
local UIManager = wb.UIManager
local ChatGPTViewer = require("assistant_viewer")

local SAMPLE = [[
# Heading 1 - Markdown CSS Debug
- Top item A with a [link](https://example.com) inside a list item
- Top item B
  - Nested item B1
  - Nested item B2
    - Deep item B2a
    - Deep item B2b
  - Nested item B3
- Top item C

## Heading 2 - Sections stay compact on e-ink
- Top item A with a [link](https://example.com) inside a list item
- Top item B
  - Nested item B1
  - Nested item B2
    - Deep item B2a
    - Deep item B2b
  - Nested item B3
- Top item C

### Heading 3 - Default size from here down
- Top item A with a [link](https://example.com) inside a list item
- Top item B
  - Nested item B1
  - Nested item B2
    - Deep item B2a
    - Deep item B2b
  - Nested item B3
- Top item C

#### Heading 4 - Smaller title
- Top item A with a [link](https://example.com) inside a list item
- Top item B
  - Nested item B1
  - Nested item B2
    - Deep item B2a
    - Deep item B2b
  - Nested item B3
- Top item C

##### Heading 5 - Small title
- Top item A with a [link](https://example.com) inside a list item
- Top item B
  - Nested item B1
  - Nested item B2
    - Deep item B2a
    - Deep item B2b
  - Nested item B3
- Top item C

###### Heading 6 - Smallest title
- Top item A with a [link](https://example.com) inside a list item
- Top item B
  - Nested item B1
  - Nested item B2
    - Deep item B2a
    - Deep item B2b
  - Nested item B3
- Top item C

Paragraph with **bold**, *italic*, ***bold italic***, ~~strikethrough~~,
`inline code`, and a [link](https://example.com). CJK mixed: 这是一段中文，
**加粗中文**与`行内代码`混排，用来检查 CJK 字体与换行。

> Blockquote level 1: viewer text should be slightly smaller with margin.
>
> > Nested quote level 2: check indent does not run away.
> > Second line of the nested quote.

---

## Unordered list (3 levels, discs at every depth)

- Top item A with a [link](https://example.com) inside a list item
- Top item B
  - Nested item B1
  - Nested item B2
    - Deep item B2a
    - Deep item B2b
  - Nested item B3
- Top item C

## Ordered list (3 levels)

1. First step
2. Second step
   1. Sub step 2.1
   2. Sub step 2.2
      1. Deep step 2.2.1
      2. Deep step 2.2.2
3. Third step

## Task list

- [ ] Unchecked task item
- [x] Checked task item

## Code block

```lua
local function hello(name)
    -- fenced code should wrap, not overflow
    return "hello, " .. (name or "world")
end
print(hello("koreader"))
```

```text
local function hello(name)
    -- fenced code should wrap, not overflow
    return "hello, " .. (name or "world")
end
print(hello("koreader"))
```


## Simple table

| Name | Role | Note |
| --- | --- | --- |
| Ada | Engineer | Short text |
| Grace | Scientist | A bit longer note here |
| Lin | Designer | Mixed 中文备注测试 |

## Wide table (header nowrap, body wraps)

| Component | Description | Status |
| --- | --- | --- |
| ScrollHtmlWidget | Renders this HTML through MuPDF with VIEWER_CSS | OK |
| assistant_mdparser | hoedown C binding if present, else pure Lua fallback | OK |
| A very long header label that must stay on one line | Body cells should wrap instead of widening the column forever and ever | Pending review of overflow-wrap behavior |

---

Final paragraph after a rule, with footnote reference.[^1]

[^1]: Footnote text renders if the parser supports footnotes.

## Follow-up suggestions (links must be block-ish tappable rows)

- [What is inline versus block layout?](#q:What%20is%20inline%20versus%20block%20layout%3F)
- [How does MuPDF handle inline-block?](#q:How%20does%20MuPDF%20handle%20inline-block%3F)
]]

-- Minimal assistant mock: just enough for ChatGPTViewer:init().
-- Notebook stays disabled (doc_settings set), Add Note skipped (no ui).
local mock_assistant = {
    settings = {
        readSetting = function(dummy, key, def)
            -- On: exercise .suggestion-link styling below.
            if key == "auto_prompt_suggest" then return true end
            return def
        end,
    },
    ui = {
        doc_settings = true,
    },
    ui_language_is_rtl = false,
    showSettings = function() end,
}

local viewer = ChatGPTViewer:new{
    title = "Markdown CSS",
    text = SAMPLE,
    assistant = mock_assistant,
    disable_add_note = true,
    add_default_buttons = true,
}

UIManager:show(viewer)
UIManager:run()

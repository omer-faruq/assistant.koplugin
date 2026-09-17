-- Markdown CSS debug viewer (uses the project's real Markdown control).
-- Usage: ./test/runui.sh markdown_css
--
-- SAMPLE mirrors the complex answer shapes produced by
-- assistant_prompts.lua (xray, book_info, key_points, ELI5, grammar,
-- vocabulary, reasoning, suggestions) so VIEWER_CSS effects can be
-- eyeballed on device/emulator.
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
# The Lord of the Rings

## Heading scale (h1/h2 capped, h3-h6 default)

# Heading 1
## Heading 2
### Heading 3
#### Heading 4
##### Heading 5
###### Heading 6

# Characters

- **Frodo Baggins** — a small, quiet hobbit of the Shire who inherits a plain gold ring that proves to be the One Ring. He volunteers to carry it to Mordor though he has no warrior skill, and his quiet endurance carries the quest further than strength ever could. _<u>bearer of the One Ring</u>_
- **Samwise Gamgee** — Frodo's gardener and steadfast companion, whose loyalty never wavers from the Shire to Mount Doom. He carries Frodo, in every sense, through the darkest chapters. _<u>ally of Frodo</u>_
  - Travels with a [map of Mordor](https://example.com) inside a list item
  - Nested note two
    - Deep note about lembas bread
    - Deep note about the light of Earendil
- **Gandalf** — a wandering wizard of quiet humor and sudden fire, sent to rally the free peoples against Sauron. He falls in Moria and returns changed. _<u>guide and catalyst of the Fellowship</u>_

# Locations

1. The Shire
2. Rivendell
   1. The Council of Elrond
   2. The Fellowship is formed
      1. Nine walkers are chosen
      2. The Fellowship departs south
3. Mordor

## Mixed nesting (markers must follow the inner list type)

- Bullet parent
  1. Numbered child one
  2. Numbered child two
- Bullet parent two

1. Numbered parent
   - Bullet child one
   - Bullet child two
2. Numbered parent two

# Timeline

- **Chapter 1:** Bilbo vanishes from his birthday party and leaves the Ring to Frodo.
- **Chapter 2:** Gandalf confirms the Ring's identity and urges Frodo to flee the Shire.
- **Chapter 3:** The hobbits reach Rivendell after flight, pursuit, and Strider's aid.

### Re-immersion

* **Where the action stopped:** the Fellowship rests in Lothlorien after losing Gandalf in Moria.
* **Protagonist's current objective:** reach Mordor quietly with the Ring.
* **Open conflict or mystery:** what became of Merry and Pippin after the breaking.
* **Narrative element in focus:** the slow weight of the Ring on Frodo. (object, place, or symbol)
* **Prevailing emotional state/tone:** grief mixed with resolve.
* **Outstanding questions:** can the Fellowship hold together without Gandalf.

### 1. Book Information

* **Genre**: Fantasy, Adventure
* **Publication Date**: 29 July 1954
* **Publisher**: Allen and Unwin
* **Plot Summary**: A hobbit inherits a magic ring and must destroy it in Mount Doom.

### 2. About the Author

J.R.R. Tolkien (1892-1973) was an Oxford professor of Anglo-Saxon with **bold** opinions on myth, *italic* affection for languages, and `inline code` nowhere near his desk. CJK mixed: 托尔金的中土世界构建极为完整，**精灵语**与`年表`混排，用来检查 CJK 字体与换行。

# 3. Historical and Cultural Context

> All that is gold does not glitter, not all those who wander are lost.
>
> > Verse from Bilbo's poem about Aragorn; check nested indent stays sane.
> > Second line of the nested quote.

# 4. Similar Books Recommendations

| Title | Author | Why recommended |
| --- | --- | --- |
| The Silmarillion | J.R.R. Tolkien | Same world, deeper myths |
| The Name of the Wind | Patrick Rothfuss | A gifted outcast tells his own legend |
| Lin | Designer | Mixed 中文备注测试 |

## Wide table (header nowrap, body wraps)

| Component | Description | Status |
| --- | --- | --- |
| ScrollHtmlWidget | Renders this HTML through MuPDF with VIEWER_CSS | OK |
| assistant_mdparser | hoedown C binding if present, else pure Lua fallback | OK |
| A very long header label that must stay on one line | Body cells should wrap instead of widening the column forever and ever | Pending review of overflow-wrap behavior |

# 📌 Core Arguments

* The Ring corrupts through **absolute power**, not strength of arms.
* Small, *ordinary* courage moves history more than kings and wizards.

# 📊 Essential Facts and Conclusions

* Published 1954-1955; three volumes, one continuous story.
* Central claim: mercy and endurance defeat domination.

# 💡 Core Idea

A magic ring must be thrown into a volcano before it enslaves everyone.

# 🍎 Fun Analogy

Like carrying a heavy, whispering backpack that tells you to keep it.

# 1. Structure and Clauses

* **Sentence Type**: Complex
* **Analysis**: Main clause carries the quest; subordinate clauses add motive.

# 2. Parts of Speech and Tenses

* Past tense narration; proper nouns mark peoples and places.

1. __reluctant__: unwilling, hesitant : not wanting to do something
2. __endurance__: stamina, persistence : the ability to keep going

```lua
local function hello(name)
    -- fenced code should wrap, not overflow
    return "hello, " .. (name or "world")
end
print(hello("koreader"))
```

---

#### ※ Deeply Thought

```text
The user asks about a classic book, so internal knowledge suffices and no web search is needed. The answer follows the book_info structure with four sections.
```

---

Final paragraph with **bold**, *italic*, ***bold italic***, ~~strikethrough~~ and footnote.[^1]

[^1]: Footnote text renders if the parser supports footnotes.

##### You may find these topics interesting:

- [Who is Tom Bombadil?](#q:Who%20is%20Tom%20Bombadil%3F)
- [Why does the Ring corrupt its bearer?](#q:Why%20does%20the%20Ring%20corrupt%20its%20bearer%3F)
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

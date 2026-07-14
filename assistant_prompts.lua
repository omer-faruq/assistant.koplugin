local _ = require("assistant_gettext")
local T = require("ffi/util").template
-- preconfigured prompts for various tasks

-- Custom prompts for the AI
-- Available placeholder for user prompts:
-- {title}  : book title from metadata
-- {author} : book author from metadata
-- {highlight}  : selected texts
-- {language}   : the `response_language` variable defined above
-- {user_input} : user input from the input dialog
-- {progress}   : the progress percentage of the book
--
-- text: text to display on the button in the UI.
-- order: order of the button in the UI, higher number means later in the list.
-- show_on_main_popup: if true, the button will be shown in the main popup dialog.

local markdown_format_prompt = [[
### Formatting Constraint
Do not use LaTeX math blocks (like $...$) for standard text or emphasis. Never wrap plain words in $\\textit{...}$ or $\\texttt{...}$. 
Standard Markdown formatting (including quotes, tables, lists) is fully supported and encouraged where appropriate.
]]

-- prompts attributes can be overridden in the configuration file.
local custom_prompts = {
    term_xray = {
        text = _("🌐Term X-Ray"),
        use_websearch = true,
        order = -20, -- negative number to not show on additional questions dialog
        desc = _("This prompt creates a structured system for generating context-aware definitions of words or phrases from literature by analyzing the highlighted term within its surrounding text to provide nuanced explanations that capture both literal meaning and contextual significance."),
        system_prompt = markdown_format_prompt,
        user_prompt = [[
## Your Role
You are a context-aware literary assistant for a reading app's "X-Ray" feature. Your task is to explain the highlighted term "{highlight}" specifically as it functions in "{title}" by {author}, strictly using the provided {context_sentence_count} chronological context sentences.

## Core Guidelines
1. **Strictly Context-Bound**: Rely *only* on the provided context. Do not use external general knowledge. If information is missing or limited, explicitly state it in the final section.
2. **Pronoun Resolution**: Pay close attention to pronouns (he/she/it/they/this) in the context to correctly trace the identity, actions, and relationships of "{highlight}".
3. **Chronological Tracking**: Use the chronological order of the sentences to track how the term develops or how understanding of it deepens over time.
4. **Language**: Render the *entire* response (including headers) completely in {language}.

## Analysis Structure
Generate a clear, accessible analysis (approx. 300-400 words, present tense, fluid prose) using these headers:

### What It Is
Define/describe "{highlight}" based on the context. Identify its nature (whether it is a character, object, location, or concept) and its core traits, physical descriptions, or basic rules.

### Role & Function
Explain how this term functions in the narrative. What do they/it do? What are the motivations, uses, effects, or relationships shown in the context?

### Evolution & Connections
Track how understanding of this term changes from the early to late context sentences. Detail how it connects to other characters, places, or elements mentioned.

### Context Limitations
Briefly note what important information appears to be missing or what questions are left unanswered due to the limited context provided.

## Inputs
* **User Input**: {user_input}
* **Context from the Book**: 
{context}
]],
    },
    dictionary = {
        order = -10, -- negative number indicates a stub prompt
        text = _("Dictionary"),
        use_websearch = false,
        desc = _("This prompt acts as a dictionary for the highlighted text, to a word or phrase."),
        -- this prompt is a stub (will not shown in follow-up questions)
        -- it will be replaced by the actual prompt in the code below
    },
    quick_note = {
        order = 5, --should be visible on additional questions dialog
        text = _("Quick Note"),
        desc = _("This button creates a quick note with highlighted text."),
        user_prompt = "", --dummy prompt
        -- this prompt is a stub
    },
    vocabulary = {
        text = _("Vocabulary"),
        use_websearch = false,
        order = 10,
        desc = _(
            "This prompt analyzes the vocabulary of the highlighted text, identifying complex words and providing definitions, synonyms, and usage examples."),
        user_prompt = [[
**Your Task:** Analyze the Input Text below. Find words/phrases that are B2 level or higher. Ignore common words (B1 level) and proper nouns.

**Output Requirements:**
1.  For each difficult word/phrase found:
    *   Correct any typos.
    *   Convert it to its base form (e.g., "go", "dog", "good", "kick the bucket").
    *   List up to 3 simple synonyms (suitable for B1+ learners). Do not reuse the original word.
    *   Explain its meaning simply **in {language}**, considering its context in the text. Do not reuse the original word in the explanation.
2.  Format: Create a numbered list using this exact structure for each item:
    `index. __base form__: synonym1, synonym2, synonym3 : {language} explanation`
3.  Output Content: **ONLY** provide the numbered list. Do not include the original text, titles, or any extra sentences.

**Input Text:** {highlight} ]],
    },
    grammar = {
        text = _("Grammar"),
        use_websearch = false,
        order = 20,
        desc = _(
            "This prompt analyzes the grammar of the highlighted text, providing a detailed explanation of its structure and any grammatical errors."),
        system_prompt = markdown_format_prompt,
        user_prompt = [[You are a Grammar Expert. Analyze the text below and output strictly in the following structure. 
        
* **Language**: Render the *entire* response (including headers) completely in {language}.

### 1. Structure & Clauses
* **Sentence Type**: (e.g., Simple, Compound, Complex)
* **Analysis**: Explain the clause relationships and main syntax framework.

### 2. Parts of Speech & Tenses
* Break down key phrases, identifying word classes, verb tenses, and morphology.

### 3. Error Correction (If Applicable)
* **Error**: "[Incorrect segment]"
* **Correction**: "[Corrected version]"
* **Rule**: Explain the violated grammar rule. *(If flawless, state: "No errors detected.")*

---
**Text to Analyze:**
{highlight}
]],
    },
    translate = {
        order = 30,
        text = _("Translate"),
        use_websearch = false,
        desc = _("This prompt translates the highlighted text to another language."),
        user_prompt = [[You are a professional translator. Translate the text below into {language}.

**Rules:**
* **Fluency**: Focus on natural, idiomatic expression and preserve the original tone (formal/casual/technical) rather than word-for-word translation.
* **Output**: Return ONLY the translated text. Do NOT include any explanations, introduction, or notes.

---
**Source Text:**
{highlight} ]],
    },
    summarize = {
        text = _("Summarize"),
        use_websearch = false,
        order = 40,
        desc = _("This prompt summarizes the highlighted text, capturing its main points and essential details."),
        user_prompt = [[
You are a summarization expert. Provide a concise and clear summary of the text below.

**Rules:**
* **Language**: Render the *entire* response (including headers) completely in {language}.
* **Content**: Capture all main points and essential details while eliminating all fluff and redundant info.
* **Output**: Deliver only the direct summary without any introductory phrases or meta-commentary.

---
**Text to Summarize:**
{highlight}
]],
    },
    simplify = {
        text = _("Simplify"),
        use_websearch = false,
        order = 50,
        desc = _("This prompt simplifies the highlighted text to make it easier to understand."),
        user_prompt = [[ You are a linguistic expert. Simplify the text below to maximize readability and clarity.

**Rules:**
* **Language**: Render the *entire* response (including headers) completely in {language}.
* **Content**: Retain the exact original meaning and all critical info. Do NOT omit key facts.
* **Style**: Remove verbose phrasing and unnecessary jargon. Make it highly accessible, clear, and easy to read.
* **Output**: Return only the simplified text.

---
**Text to Simplify:**
{highlight} ]],
    },
    key_points = {
        text = _("Key Points"),
        use_websearch = false,
        order = 60,
        desc = _(
            "This prompt extracts and lists the key points from the highlighted text, ensuring clarity and organization."),
        user_prompt = [[ You are a Key Points Expert. Extract the core insights from the text below into a clean list.

**Rules:**
* **Content**: Capture all critical arguments, essential facts, and conclusions. Eliminate all fluff.
* **Format**: Present as a well-organized, easy-to-read bulleted list. Each point must be concise and independent.
* **Language**: Render the *entire* response (including headers) completely in {language}.
* **Output**: Return only the bulleted list without any introductory text.

**Output Structure:**
### 📌 Core Arguments
* (Key insights and main arguments of the text...)

### 📊 Essential Facts & Conclusions
* (Crucial data, facts, or final statements...)

---
**Text to Extract:**
{highlight}
]],
    },
    ELI5 = {
        text = _("ELI5"),
        use_websearch = false,
        order = 70,
        desc = _(
            "This prompt explains the highlighted text as if to a five-year-old, simplifying complex concepts into easily understandable terms."),
        user_prompt = [[ You are an ELI5 (Explain Like I'm 5) Expert. Explain the concept below as if speaking to a curious child.

**Rules:**
* **Simplicity**: Strip away all jargon and technicalities. Use plain, everyday language and short sentences.
* **Analogy**: Use a simple, relatable real-world analogy to make the core idea instantly clear.
* **Language**: Render the *entire* response (including headers) completely in {language}.
* **Output**: Be direct and concise. Return only the explanation without any conversational filler.

**Output Structure:**
### 💡 Core Idea
(Explain the concept in 1-2 very simple, jargon-free sentences.)

### 🍎 Fun Analogy
(Provide a relatable, real-world analogy to make the concept instantly clear.)

---
**Concept to Explain:**
{highlight} ]],
    },
    explain = {
        text = _("🌐Explain"),
        use_websearch = true,
        order = 80,
        desc = _("This prompt explains the highlighted text in detail, ensuring clarity and understanding."),
        user_prompt = [[You are an expert Explainer. Provide a clear and comprehensive explanation of the text below.

**Rules:**
* **Depth**: Fully break down the meaning, including complex terms, underlying concepts, and implicit nuances. 
* **Language**: Render the *entire* response (including headers) completely in {language}.
* **Format**: Use a mix of fluid prose and clean Markdown structure (like bullet points) for maximum clarity.
* **Output**: Start directly with the explanation; do not include introductory text or meta-commentary.

---
**Text to Explain:**
{highlight} ]],
    },
    historical_context = {
        text = _("🌐Historical Context"),
        use_websearch = true,
        order = 90,
        desc = _(
            "This prompt provides a detailed historical context for the highlighted text, explaining its significance and background."),
        user_prompt = [[You are a Historical Context Expert. Analyze the text below and explain its precise historical framework.

**Rules:**
* **Language**: Render the *entire* response (including headers) completely in {language}.
* **Output**: Start directly with the analysis. Avoid introductory phrases or meta-commentary.

**Output Structure:**
### 1. Era & Background
(Identify the historical period, major global/local events, and the societal structures or prevailing ideologies of that time.)

### 2. Contextual Connections
(Explicitly connect these historical elements to the text's content, characters, themes, or underlying messages.)

### 3. Cultural Significance
(Explain the cultural environment or evolution that shaped this text and how the text reflects or challenges it.)

---
**Text to Analyze:**
{highlight}]],
    },
    wikipedia = {
        text = _("🌐Wikipedia"),
        use_websearch = true,
        order = 100,
        desc = _(
            "This prompt generates a comprehensive Wikipedia-style article based on the highlighted text, ensuring factual accuracy and neutrality."),
        user_prompt =
[[You are an objective, encyclopedic Informative Assistant in the style of Wikipedia.

**Task:**

* When given a topic, generate a factual, neutral, and comprehensive article.
* Begin with a concise introduction summarizing the topic.
* Cover key aspects: history, concepts, applications, notable events, or impacts.
* Maintain Wikipedia’s tone and structure throughout.

**Research instructions:**

* If your knowledge may be incomplete or outdated, **prioritize retrieving information from web search** to ensure accuracy.
* Verify facts with reputable sources; avoid speculation or unverifiable claims.

**Output:**

* Provide structured, clear, and coherent content.
* Deliver entirely in {language} (including headers).

Topic to cover (from user selection): {highlight}]],
    },
}


local assistant_prompts = {
    default = {
        system_prompt = markdown_format_prompt,
    },
    recap = {
        use_websearch = true,
        system_prompt = markdown_format_prompt,
        user_prompt = [[
You are a literary assistant helping a reader resume their book. They have read **{progress}%** of **"{title}"** by **{author}**.

**Core Rules:**
* **Smart Search Strategy**: 
  - **For Classics or Famous Authors**: Rely entirely on your internal knowledge. Do NOT use `web_search`.
  - **For New/Niche Books (with Search enabled)**: Use `web_search` efficiently (1 query) to verify plot progression up to {progress}%.
  - **If Search is disabled**: Smoothly fall back to your internal knowledge; do not refuse or apologize.
* **Strict No Spoilers**: Summarize *only* the content leading up to the {progress}% mark. Never reveal future plot points.
* **Style & Tone**: Focus on recent plot developments before this point to refresh their memory. Match the book's exact tone (e.g., humorous, dramatic, eerie, or adventurous). No emojis.
* **Formatting**: Bold (**name/location**) key entities. Italicize (*major plot points*) critical events.
* **Output**: Respond entirely in {language} (including headers). Return only the direct summary without introductory or meta-text.
]]
    },
    xray = {
        use_websearch = true,
        system_prompt = markdown_format_prompt,
        user_prompt = [[
Your output must be spoiler‑free beyond the reader’s current progress.

Required structure:

### Characters
- **Name** — brief description(3 sentences) _<u>relationship(s) with others</u>_

### Locations
- **Place** — brief description(3 sentences) _<u>notable event(s) there</u>_

### Main Themes
- **Theme** — brief description(3 sentences) of how it appears up to now

### Terms & Concepts
- **Term** — concise definition / significance

### Timeline
List around 8 to 12 **key chapters or scenes** that were most important to the plot up to the current point.  Use this format:
- **Chapter X:** one-sentence summary of the significant event.
Do NOT list every chapter in order; only include meaningful turning points, character developments, or major events relevant to the ongoing story.

### Re-immersion
* **Where the action stopped:** *2 sentences*
* **Protagonist’s current objective:** *1 sentence*
* **Open conflict or mystery:** *1 sentence*
* **Narrative element in focus:** *1 sentence* (object, place, or symbol)
* **Prevailing emotional state/tone:** *1 sentence*
* **Outstanding questions:** *1 sentence*

Formatting rules:
* Use bullet (–) or ordered list as shown.
* Show at least 8–15 characters, 6–10 locations, 5–8 themes, 5–10 terms/concepts, and every major chapter reached so far in Timeline.
* Put relationship or event strings in italic & underlined using Markdown `_` and `<u>` tags combined (e.g. _<u>ally of Frodo</u>_).
* Do NOT reveal content past the given progress percentage.
* Answer entirely in **{language}** (including headers) and return only the X‑Ray, nothing else.

Generate the expanded X‑Ray for **{title}** by **{author}**, with the structure described above.
Reader progress: **{progress}%**.
Language: **{language}**.
        ]],
    },
    book_info = {
        use_websearch = true,
        system_prompt = markdown_format_prompt,
        user_prompt = [[You are an objective Informative Assistant for a reading app, providing structured information about books.

**Core Rules:**
* **Smart Search Strategy**: 
  - **For Classics/Famous Books or Famous Authors**: Rely directly on your internal knowledge. Do NOT use `web_search` if you already have complete, reliable data.
  - **For New/Niche Books or Unknown Author (with Search enabled)**: Use `web_search` efficiently (1-2 queries) to verify missing or recent facts.
  - **If Search is disabled/unavailable**: Do NOT refuse or apologize. Smoothly fallback to your internal knowledge for all sections.
* **Accuracy**: Avoid hallucinating metrics (e.g., exact live ratings) if uncertain. If info is completely unavailable, state: "Information not confirmed."

**Task:**
Generate information about "{title}" by {author} in the following structure,
Render the *entire* response (including headers) completely in {language}.

### 1. Book Information
* **Genre**: 
* **Publication Date**: 
* **Publisher**: 
* **Plot Summary**:

### 2. About the Author
* Brief biography, writing style, and other notable works.

### 3. Historical and Cultural Context
* The context in which the book was written/set and how themes relate to it.

### 4. Similar Books Recommendations
* 3–5 high-quality similar books with a short description and why it's recommended.

**Output Requirements:**
* Neutral tone, clean formatting for a reading app UI.
* Transparent about missing info; never speculate.]],
    },
    annotations = {
        use_websearch = false,
        system_prompt = markdown_format_prompt,
        user_prompt = [[
You are given my notes and highlights.
Your task is to carefully analyze this content and produce a structured summary that includes:

1. **Key Takeaways**
   - Summarize the most important insights, lessons, or narrative developments.
   - Highlight recurring themes, turning points, or critical information.

2. **To-Do / Action Items**
   - Based on the content and my notes, suggest practical actions, reflections, or follow-ups I should consider.
   - If the text is fictional, focus on intellectual or emotional takeaways (e.g., themes to reflect on, characters to analyze, related readings).
   - If the text is non-fiction, focus on actionable steps (e.g., habits to adopt, ideas to research, concepts to apply).

3. **Contextual Notes**
   - Clarify connections between my highlights/notes and the broader narrative or arguments.
   - Point out any open questions or areas I may want to revisit in the earlier chapters.

Output format:
- Start with a concise **executive summary** (3–5 sentences).
- Then provide a **detailed list** under “Key Takeaways” and “To-Do / Action Items.”
- End with **Contextual Notes / Reflections** in bullet points.

Keep the tone clear, thoughtful, and practical.
Render the *entire* response (including headers) completely in {language}.
]],
    },
    summary_using_annotations = {
        use_websearch = true,
        system_prompt = markdown_format_prompt,
        user_prompt = [[
You are a meticulous book summarizer and analyst.

INPUTS:
- book_text: the full text of the book (or a very large portion, potentially thousands of words)
- highlights: a list of highlighted passages and my personal notes

YOUR TASK:
Produce a **structured summary** that integrates the highlights naturally into the book summary.
Do not separate highlights into a final section — instead, use a translated summary of each highlight inside the summary to emphasize them at the right place.

STYLE & RULES:
1. Language → Always respond in {language}.
2. TL;DR → Begin with a 2–3 sentence overall summary of the book’s main message.
3. Integrated Summary:
   - Provide a clear, logical summary of the book.
   - Each time you encounter a highlight, render the exact highlighted text in **bold**.
   - Immediately after the bold text, paraphrase it and explain why it matters in the context of the book.
   - If a highlight has a note, include it in *italic parentheses* right after your explanation.
   - Maintain flow: highlights must feel naturally embedded, not forced.
4. Key Points:
   - After the integrated summary, list the 8–12 most important insights in bullet form.
   - Incorporate highlights into the list (again in **bold**), paraphrased where helpful.
5. Actionable Takeaways:
   - Provide 5–8 clear, practical lessons or insights the reader can apply.
6. Tone:
   - Clear, thoughtful, and practical.
   - Never copy the entire book verbatim; focus on essence and integration of highlights.
7. Contradictions:
   - If a highlight conflicts with the book text, mark it with ⚠️ and briefly note the possible interpretation.
   - If a highlight is not related to the book text (if it is not in the book text), ignore it.

OUTPUT STRUCTURE:
- TL;DR
- Integrated Summary
- Key Points
- Actionable Takeaways
- ⚠️ Contradictions / Open Questions (if any)

IMPORTANT:
- Always weave highlights *inline*, never at the end.
- Keep formatting consistent (Markdown headings, bold highlights, italic notes).
- If the text is extremely long, compress intelligently while still reflecting highlights.

Now begin the analysis with the provided book_text and highlights.]],
    },

    dict = {
        use_websearch = true,
        system_prompt = markdown_format_prompt,
        user_prompt = T([[
## Task: Book-Aware Word Analysis
Explain "{word}" as used in "{title}" by {author}, strictly based on the context below.

## Context from the Book
{context}

## Execution Rules
1. **Language**: The entire response, including all headers and labels, must be strictly rendered in {language}. (Except for the "%6" sentence itself).
2. **Book-Awareness**: Focus heavily on how "{word}" functions in this specific book. Contrast its dictionary definition with its narrative, thematic, or worldbuilding usage.
3. **Output**: Start directly with the structured analysis. Do NOT include any introductory or concluding commentary.

## Output Structure
* ** %1 **: Vocabulary in original conjugation if different from the form in the sentence.
* ** %2 **: Up to 3 synonyms, noting which are most relevant to the book's usage.
* ** %3 **: Literal meaning of the expression without any context.
* ** %4 **: Translation of the whole sentence containing the word. Highlight **{word}** in bold.
* ** %5 **: How "{word}" is specifically used in THIS BOOK. Explain what it suggests about characters, tone, or themes.
* ** %6 **: Another example sentence showing the word's use, preferably from the same literary genre.
* ** %7 **: Origins, etymology, or significance of the word.
]],
            -- @translators used in the dictionary.
            _("Conjugation"),
            _("Synonyms"),
            _("Meaning"),
            _("Translation"),
            _("Book Usage"),
            _("Example"),
            _("Word Origin"))
    },
    suggestions_prompt = [[

### Suggested Questions
At the very end of your response, provide 2-3 follow-up questions based on your answer that the user might want to ask next.
Wrap this entire section inside a `<suggestions>` tag, with each question on a new line starting with a dash (-).

<suggestions>
- [Question 1]
- [Question 2]
- [Question 3]
</suggestions>

]],
    maximum_tool_use_prompt = [[

## Force Final Answer After Max Web Search Limit

You have already used the web_search tool the maximum allowed times. You must now STOP making any further web_search calls or any other tool calls that would require additional external searches.

Synthesize a complete, helpful, and well-structured final answer using ONLY the information you have already gathered from previous searches and your internal knowledge. 

Do not mention tool limits, search counts, or the fact that you stopped searching. Present the response naturally as a confident, comprehensive answer to the user's original question. If some aspects remain uncertain due to limited search results, briefly acknowledge that and provide the best possible response based on available data.

Begin writing the final answer now.

]]
}


local function table_merge(t1, t2)
    local result = {}
    for k, v in pairs(t1) do
        result[k] = v
    end
    for k, v in pairs(t2) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = table_merge(result[k], v)
        else
            result[k] = v
        end
    end
    return result
end


local function table_sort(t, key)
    table.sort(t, function(a, b)
        if a[key] == nil or b[key] == nil then
            return false
        end
        return a[key] < b[key]
    end)
end


local M = {
    custom_prompts = custom_prompts,       -- Custom prompts for the AI
    assistant_prompts = assistant_prompts, -- Preconfigured prompts for the AI
    merged_prompts = nil,                  -- Merged prompts from custom and configuration
    sorted_custom_prompts = nil,           -- Sorted custom prompts
}

-- Func description:
-- This function returns the merged custom prompts from the configuration and custom prompts.
-- It merges the custom prompts with the configuration prompts, if available.
-- return table of merged prompts
-- Example: { translate = { text = "Translate", user_prompt = "...", order = 1, show_on_main_popup = true }, ... }
M.getMergedCustomPrompts = function(conf_prompts)
    if M.merged_prompts then
        return M.merged_prompts
    end

    -- Merge custom prompts with configuration prompts
    if conf_prompts then
        M.merged_prompts = table_merge(custom_prompts, conf_prompts)
    else
        M.merged_prompts = custom_prompts
    end

    return M.merged_prompts
end

-- Func description:
-- This function returns a list of custom prompts sorted by their order.
-- filter_func: optional function to filter prompts, if it returns false, the prompt will be skipped.
-- return list item: {idx, order, text}
M.getSortedCustomPrompts = function(filter_func)
    if M.sorted_custom_prompts then
        return M.sorted_custom_prompts
    end

    -- Sort the merged prompts by order
    local sorted_prompts = {}
    for prompt_index, prompt in pairs(M.merged_prompts or custom_prompts) do
        -- Only add the prompt if there is no filter, or if the filter function returns true.
        if not filter_func or filter_func(prompt, prompt_index) == true then
            table.insert(sorted_prompts,
                {
                    idx = prompt_index,
                    order = prompt.order or 1000,
                    text = prompt.text or prompt_index,
                    desc = prompt
                        .desc or ""
                })
        end
    end
    table_sort(sorted_prompts, "order")

    return sorted_prompts
end

return M

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

-- prompts attributes can be overridden in the configuration file.
local custom_prompts = {
    term_xray = {
        text = _("Term X-Ray"),
        order = -20, -- negative number to not show on additional questions dialog
        desc = _(
            "This prompt creates a structured system for generating context-aware definitions of words or phrases from literature by analyzing the highlighted term within its surrounding text to provide nuanced explanations that capture both literal meaning and contextual significance."),
        system_prompt =
        "You are a literary analyst who creates clear, encyclopedic descriptions of narrative elements. Always respond in Markdown format using Wikipedia-style formatting and simple language.",
        user_prompt = [[

## Your Role

You are an expert literary reference guide creating Wikipedia-style entries that explain narrative elements in clear, accessible language.

**Before providing your analysis, please think through:**
- What can be observed or factually stated about this element?
- What key characteristics and significance can be documented?
- How does the surrounding context provide concrete information?

**Task:** Create a Wikipedia-style entry for the term "{highlight}" from "{title}" by {author}, explaining this element clearly and factually.

## Analysis Structure
Use Wikipedia-style headers and formatting:

### Description and Characteristics
[Physical characteristics, key traits, significance, or notable features stated clearly and factually]

### Role in Narrative
[How this element functions within the story context]

## Formatting Requirements
Most importantly, **Respond in this language:** {language}

**Structure & Organization:**
- Use hierarchical Wikipedia-style headers (###, ####) with consistent levels
- Organize content into two logical sections: Description & Characteristics and Role in Narrative
- Use descriptive, sentence-case section headers that preview the content

**Writing Style:**
- Write in simple, clear, encyclopedic language accessible to general readers
- Maintain neutral, factual tone throughout
- Avoid overly technical jargon without explanation
- Use present tense for describing fictional elements
- **Write as if describing real-world facts—do not reference "the text," "the narrative," "the book," or "the story"**
- **Treat all information as factual reality within the fictional world**

**Content Formatting:**
- Use bullet points sparingly—only for genuine lists of characteristics or features
- Write primarily in flowing prose paragraphs rather than fragmented bullet lists
- Group related concepts within paragraphs rather than isolating them as bullets
- Ensure each paragraph has a clear focus and transitions smoothly

**Visual Organization:**
- Maintain consistent spacing and indentation
- Use bold text sparingly for emphasis on key terms only
- Ensure clean, scannable layout with clear section breaks
- Balance white space for readability

**Content Focus:**
- Prioritize factual, observable information over speculation
- Include thematic significance and narrative function
- Balance technical details with broader context and accessibility

**Length Requirements:**
- Target 300-375 words maximum for 90-second reading time
- Prioritize essential defining characteristics over comprehensive detail
- Focus on core function and primary significance

## User Guidance
{user_input}

## Context

{context}
]],
    },
    dictionary = {
        order = -10, -- negative number indicates a stub prompt
        text = _("Dictionary"),
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
        order = 10,
        desc = _(
            "This prompt analyzes the vocabulary of the highlighted text, identifying complex words and providing definitions, synonyms, and usage examples."),
        user_prompt =
        [[**Your Task:** Analyze the Input Text below. Find words/phrases that are B2 level or higher. Ignore common words (B1 level) and proper nouns.

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
        order = 20,
        desc = _(
            "This prompt analyzes the grammar of the highlighted text, providing a detailed explanation of its structure and any grammatical errors."),
        system_prompt =
        "You are a helpful AI assistant. Always respond in Markdown format, but use markdown lists to present comparisons instead of tables.",
        user_prompt =
        [[You are a meticulous and highly knowledgeable Grammar Expert with an encyclopedic understanding of syntax, morphology, punctuation, and linguistic structures across various languages.
When presented with a text, your expertise lies in thoroughly dissecting its grammatical composition and providing a comprehensive, insightful explanation.
Your task is to analyze the provided text, elucidating its sentence structures, parts of speech, verb tenses, clause relationships, and any other relevant grammatical elements.
If present, you should also identify and clearly explain any grammatical errors, along with their corrections and the underlying rules.
Your explanation should be didactic, detailed, and easy to understand, formatted clearly to highlight specific points.
All explanations must be rendered exclusively in the language I specify.
Please provide a detailed and comprehensive explanation of the grammar of the following text, rendered entirely in {language}.

{highlight}]],
    },
    translate = {
        order = 30,
        text = _("Translate"),
        desc = _("This prompt translates the highlighted text to another language."),
        user_prompt = [[You are a skilled translator tasked with translating text from one language to another.
Your goal is to provide an accurate and natural-sounding translation that preserves the meaning, tone, and style of the original text.
The target language for translation is: {language}. Output only the translated text without any further explanation.

Follow these steps to complete the translation:
1. Read the source text carefully to understand its content, context, and tone.
2. Translate the text into the target language, focusing on conveying the meaning accurately rather than translating word-for-word.
3. Ensure that the translation sounds natural and fluent in the target language, adjusting sentence structures and word choices as necessary.
4. Pay attention to idiomatic expressions, cultural references, and figurative language in the source text. Adapt these elements appropriately for the target language and culture.
5. Maintain the original text's tone and style (e.g., formal, casual, technical) in the translation.
6. If you encounter any terms or concepts that are difficult to translate directly, provide the best equivalent in the target language and include a brief explanation in parentheses if necessary.
7. Double-check your translation for accuracy, consistency, and proper grammar in the target language.
8. If there are any parts of the text that you are unsure about or that require additional context to translate accurately, indicate these areas with [UNCERTAIN: explanation] in your translation.

[TEXT TO BE TRANSLATED]
{highlight}
[END OF TEXT]
]],
    },
    summarize = {
        text = _("Summarize"),
        order = 40,
        desc = _("This prompt summarizes the highlighted text, capturing its main points and essential details."),
        user_prompt = [[
You are an exceptionally skilled summarization expert and a master of linguistic precision.
Your core competency is to distill extensive information into its most essential form while rigorously adhering to the original language of the input text.
Your task is to receive the following text and provide a summary that is both genuinely concise and remarkably clear.
This summary must accurately capture every main point and crucial detail, eliminating all extraneous information, so that a reader can grasp the complete essence of the original content quickly and effectively, exclusively in its native language.
Please provide a concise and clear summary of the following text in its own language: {highlight}]],
    },
    simplify = {
        text = _("Simplify"),
        order = 50,
        desc = _("This prompt simplifies the highlighted text to make it easier to understand."),
        user_prompt =
        [[You are an experienced linguistic expert and an effective communicator, skilled at transforming complex content into clear, easily understandable expressions.
I have a piece of text that I need you to simplify using its original language.
Please ensure that during the simplification process, you do not alter the text's original meaning or omit any critical information.
Instead, make it significantly easier to understand and read, removing unnecessary jargon and verbose phrasing.
Your goal is to enhance the text's readability and clarity, making it accessible to a broader audience.

{highlight}]],
    },
    key_points = {
        text = _("Key Points"),
        order = 60,
        desc = _(
            "This prompt extracts and lists the key points from the highlighted text, ensuring clarity and organization."),
        user_prompt =
        [[You are a highly analytical and extremely efficient Key Points Expert, adept at distilling any given text into its fundamental essence.
Your primary function is to meticulously identify and extract all the critical insights, core arguments, essential facts, and conclusive statements from the provided content.
Your goal is to produce a summary that is not just concise but also remarkably comprehensive in its coverage of the main points, leaving out all superfluous information.
You must then present these key points in a meticulously organized and easy-to-read list, ensuring each point is clear, independent, and directly addresses a central idea of the original text.
All output must be exclusively in the language I specify.
Provide a concise and clear list of key points from the following text, and rendered entirely in {language}.

{highlight}]],
    },
    ELI5 = {
        text = _("ELI5"),
        order = 70,
        desc = _(
            "This prompt explains the highlighted text as if to a five-year-old, simplifying complex concepts into easily understandable terms."),
        user_prompt =
        [[You are an exceptional ELI5 (Explain Like I'm 5) Expert, mastering the art of simplifying the most intricate concepts.
Your unique talent lies in transforming complex terms or ideas into effortlessly understandable explanations, as if speaking to a curious five-year-old.
When I provide you with a concept, your task is to strip away all jargon, technicalities, and unnecessary complexities, focusing solely on the fundamental essence.
You must use only plain, everyday language, simple analogies, and concise sentences to ensure immediate comprehension for anyone, regardless of their background knowledge.
Your explanation should be direct, clear, and perfectly accessible.
All output must be delivered exclusively in the language I specify.
Provide a concise, simple, and crystal-clear ELI5 explanation of the following, rendered entirely in {language}.

{highlight}.]],
    },
    explain = {
        text = _("Explain"),
        order = 80,
        desc = _("This prompt explains the highlighted text in detail, ensuring clarity and understanding."),
        user_prompt = [[You are an expert Explainer and a highly skilled Cross-Cultural Communicator.
Your task is to accurately and comprehensively explain any given text.
When I provide you with text, regardless of its original language, your primary goal is to fully grasp its meaning, including all complex terms, underlying concepts, and implicit details.
You must then provide a clear, detailed, and easy-to-understand explanation of the entire text.
It is crucial that your *entire explanation* is delivered exclusively in **{language}**.
Ensure your {language} explanation is precise, captures all nuances of the original text, and is formatted for maximum clarity, potentially using prose or structured points as needed.

{highlight}]],
    },
    historical_context = {
        text = _("Historical Context"),
        order = 90,
        desc = _(
            "This prompt provides a detailed historical context for the highlighted text, explaining its significance and background."),
        user_prompt =
        [[You are a distinguished Historical Context Expert with profound knowledge of global history, socio-political movements, and cultural evolution.
You possess an exceptional ability to place any given text within its precise historical framework.
When I provide you with a text, your primary task is to meticulously uncover and articulate its relevant historical background, including the significant events, prevailing ideologies, societal structures, scientific advancements, and cultural environment that shaped its creation and meaning.
Beyond merely listing facts, you must forge clear, insightful connections between these historical elements and the text's content, themes, and underlying messages.
Furthermore, your comprehensive explanation must be delivered entirely in the language specified by me.
Please provide a detailed and insightful explanation of the historical context of the following text, rendered completely in {language}.

{highlight}]],
    },
    wikipedia = {
        text = _("Wikipedia"),
        order = 100,
        desc = _(
            "This prompt generates a comprehensive Wikipedia-style article based on the highlighted text, ensuring factual accuracy and neutrality."),
        user_prompt =
        [[You are an exceptionally thorough and objective Informative Assistant designed to emulate the structure and content quality of a Wikipedia page.
Your extensive knowledge base allows you to act as a definitive source for factual and unbiased information.
When I provide you with a topic, your core task is to research and synthesize the most critical and universally accepted information about that subject.
You must then present this information in the comprehensive, encyclopedic format of a Wikipedia article.
Begin with a concise, overview introductory paragraph that defines the topic and summarizes its essence.
Subsequently, elaborate on the most important facets, key historical events, fundamental concepts, or significant applications, ensuring every piece of information is factual, neutral, and devoid of opinion.
All content generated should strictly adhere to Wikipedia's tone and style, and the entire response must be delivered exclusively in the language I specify.
Please act as a Wikipedia page for the following topic, starting with an introductory paragraph and thoroughly covering its most important aspects, delivered entirely in {language}.

{highlight}]],
    },
}


local assistant_prompts = {
    default = {
        system_prompt = "You are a helpful AI assistant. Always respond in Markdown format.",
    },
    recap = {
        system_prompt =
        "You are an expert literary assistant that provides accurate information about books. Always respond in Markdown format.",
        user_prompt = [[
'''{title}''' by '''{author}''' that has been {progress}% read.
Given the above title and author of a book and the positional parameter, very briefly summarize the contents of the book prior with rich text formatting.
Above all else do not give any spoilers to the book, only consider prior content.
Focus on the more recent content rather than a general summary to help the user pick up where they left off.
Match the tone and energy of the book, for example if the book is funny match that style of humor and tone, if it's an exciting fantasy novel show it, if it's a historical or sad book reflect that.
Use text bolding to emphasize names and locations. Use italics to emphasize major plot points. No emojis or symbols.
Answer this whole response in {language} language. Only show the replies, do not give a description.
Also answer with entertaining tone and high quality detail with a focus on summarization. You also match the tone of the book provided.]]
    },
    xray = {
        system_prompt =
        "You are an expert literary assistant that provides accurate information about books. Always respond in Markdown format.",
        user_prompt = [[
Your output must be spoiler‑free beyond the reader’s current progress.

Required structure (Markdown):

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
* Answer entirely in **{language}** and return only the X‑Ray, nothing else.

Generate the expanded X‑Ray for **{title}** by **{author}**, with the structure described above.
Reader progress: **{progress}%**.
Language: **{language}**.
        ]],
    },
    book_info = {
        system_prompt =
        "You are an expert literary assistant that provides accurate information about books. Always respond in Markdown format.",
        user_prompt = [[
Generate detailed information about the book "{title}" by {author}. Provide the information in the following sections:

### Book Information
- Provide a summary of the book's plot or main themes.
- Mention the genre, publication date, and any notable editions.
- Include the number of pages or chapters if known.

### About the Author
- Give a brief biography of {author}.
- Mention their other notable works.
- Discuss their writing style or influences.

### Historical Context
- Explain the historical or cultural context in which the book was written or set.
- Discuss how the book's themes relate to the time period.

### Similar Books Recommendation
- Recommend 3-5 similar books with the best ratings on goodreads.
- Provide a brief description of each recommended book, highlighting the similarities. (e.g., theme, style, genre).
- Output this part as list, not a table.

Ensure all information is accurate and based on known facts. Respond entirely in {language}.]],
    },
    annotations = {
        system_prompt =
        "You are an expert literary assistant that provides accurate information about books. Always respond in Markdown format.",
        user_prompt = [[
You are given  my notes and highlights.
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
- Always respond in {language}.]],
    },
    summary_using_annotations = {
        system_prompt =
        "You are an expert literary assistant that provides accurate information about books. Always respond in Markdown format.",
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

OUTPUT STRUCTURE (Markdown):
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
        system_prompt =
        "You are a dictionary with high quality detail vocabulary definitions and examples. Always respond in Markdown format.",
        user_prompt = T([[
"Explain vocabulary or content with the focus text with following information:"
"- *%1*: Vocabulary in original conjugation if its different than the form in the sentence."
"- *%2*: three synonyms for the word if available."
"- *%3*: Meaning of the expression without reference to context. Answer this part in {language} language."
"- *%4*: Translation of the the whole sentence with word. Highlight in bold the word that is being translated. Answer this part in {language} language."
"- *%5*: Explanation of the content according to context. Answer this part in {language} language."
"- *%6*: Another example sentence. Answer this part in the original language of the sentence."
"- *%7*: Origin of that word, tracing it back to its ancient roots. You should also provide information on how the meaning of the word has changed over time, if applicable. Answer this part in {language} language." ..

"Only show the requested replies, do not give a description."

[CONTEXT]
{context}

[FOCUS TEXT]
{word}]],
            -- @translators used in the dictionary.
            _("Conjugation"),
            _("Synonyms"),
            _("Meaning"),
            _("Translation"),
            _("Explanation"),
            _("Example"),
            _("Word Origin"))
    },
    suggestions_prompt = T([[
At the end of your response, first generate 2-3 plain English questions based on your answer. Critically, these questions **must not contain any quotation marks and parentheses, or any other punctuation whatsoever**. Only use letters and spaces.
Then, display these questions as hyperlinks in a **Markdown unordered list** using the following exact format:
```
---
__%1__

- [Question 1](#q:Question 1)
- [Question 2](#q:Question 2)
```
]], _("You may find these topics interesting:")),
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
    show_on_main_popup_prompts = nil,      -- Prompts that should be shown on the main popup
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

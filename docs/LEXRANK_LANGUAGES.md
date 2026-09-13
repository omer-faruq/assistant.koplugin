# LexRank Language Support

The LexRank implementation supports multiple languages for text analysis and sentence ranking. This document explains how to add support for new languages.

## Currently Supported Languages

- **English** (`en`) - Full support with comprehensive stop words
- **Spanish** (`es`) - Full support with Spanish-specific tokenization
- **French** (`fr`) - Full support with accented character handling
- **German** (`de`) - Full support with umlauts and ß character
- **Turkish** (`tr`) - Full support with Turkish-specific tokenization

## Language Detection

The system automatically maps language codes to supported languages:

- Accepts various formats: `"en"`, `"en_US"`, `"English"`, `"english"`
- Falls back to English if the language is not supported
- Normalizes language codes for consistent lookup

## Adding a New Language

To add support for a new language, follow these steps:

### 1. Create Language Module

Add your language module to `assistant_lexrank_languages.lua` in the language registry:

```lua
-- Example: Italian language module
local ItalianLanguage = {
    stop_words = {
        "il", "lo", "la", "i", "gli", "le", "un", "uno", "una", "di", "a", "da",
        "in", "con", "su", "per", "tra", "fra", "e", "o", "che", "chi", "cui",
        "non", "più", "molto", "poco", "tutto", "ogni", "altro", "stesso",
        "come", "quando", "dove", "perché", "se", "ma", "però", "quindi"
        -- Add more stop words as needed
    },
    sentence_delimiters = {".", "!", "?", ";"},
    min_sentence_length = 10,
    min_word_length = 2,
    entity_pattern = "^[A-ZÀÈÉÌÍÎÒÓÙ]",  -- Detect proper nouns with uppercase (including accented chars)

    -- Optional: Custom tokenization for special character handling
    tokenize_words = function(self, sentence)
        if not sentence then return {} end
        local words = {}
        -- Handle Italian-specific characters: àèéìíîòóù
        for word in sentence:gmatch("[%w%%àèéìíîòóù]+") do
            local clean_word = word:lower()
            if #clean_word >= self.min_word_length and not self.stop_words_set[clean_word] then
                table.insert(words, clean_word)
            end
        end
        return words
    end
}
```

### 2. Register the Language

Add your language to the `language_registry` table:

```lua
local language_registry = {
    ["en"] = EnglishLanguage,
    ["es"] = SpanishLanguage,
    ["fr"] = FrenchLanguage,
    ["de"] = GermanLanguage,
    ["it"] = ItalianLanguage,  -- Add your language here
}
```

### 3. Update Language Mapping

Add language code mappings in the `normalize_language_code` function. **Important**: Only add mappings for languages that are actually implemented in the `language_registry`.

The language mapping uses a clean, maintainable format where you simply add one line per language:

```lua
local language_mappings = {
    en = { "english", "en", "en_us", "en_gb", "en-us", "en-gb" },
    es = { "spanish", "español", "es", "es_es", "es_mx", "es_ar", "es_co", "es-es", "es-mx" },
    fr = { "french", "français", "francais", "fr", "fr_fr", "fr_ca", "fr_be", "fr_ch", "fr-fr", "fr-ca" },
    de = { "german", "deutsch", "de", "de_de", "de_at", "de_ch", "de-de", "de-at" },
    it = { "italian", "italiano", "it", "it_it", "it-it" }  -- Add this line for Italian
}
```

**Format explanation:**
- **Key**: The base language code (`it`)
- **Value**: Array of all variants that should map to this language
- **Variants**: Include native names, English names, locale codes, both underscore and hyphen formats

**Benefits of this format:**
- ✅ **Easy to maintain**: One line per language, no repetition
- ✅ **Clear grouping**: All variants for a language are together
- ✅ **Less error-prone**: Base language code appears only once
- ✅ **Contributor-friendly**: Simple to understand and extend

**What gets auto-generated:**
The system automatically creates a lookup table, so `"english"` → `"en"`, `"italiano"` → `"it"`, etc.

## Language Module Structure

Each language module must include:

### Required Fields

- **`stop_words`** (array): List of common words to ignore during analysis
- **`sentence_delimiters`** (array): Characters that mark sentence boundaries
- **`min_sentence_length`** (number): Minimum character length for valid sentences
- **`min_word_length`** (number): Minimum character length for valid words
- **`entity_pattern`** (string): Regex pattern to detect proper nouns (words starting with capital letters in the script)

### Optional Fields

- **`tokenize_words`** (function): Custom word tokenization for language-specific needs
- **`stemming_patterns`** (array): Patterns for basic stemming to improve term matching

### Stemming Patterns

Stemming patterns help find related words when searching for the highlighted term. Each pattern should remove common suffixes:

```lua
stemming_patterns = {
    { pattern = "ing$", replacement = "" },   -- English gerund
    { pattern = "ed$", replacement = "" },    -- English past tense
    { pattern = "ción$", replacement = "" },  -- Spanish noun suffix
    { pattern = "ment$", replacement = "" },  -- French adverb suffix
    { pattern = "ung$", replacement = "" }    -- German noun suffix
}
```

**Benefits:**
- **Better matching**: "running" finds "run", "runner", "runs"
- **Language-specific**: Each language has appropriate suffix patterns
- **Fallback search**: Used only when direct term search fails

### Language-Specific Considerations

#### Stop Words
- Include the most common 50-100 words in the language
- Focus on articles, prepositions, pronouns, and auxiliary verbs
- Research existing NLP stop word lists for your language

#### Tokenization
- Use appropriate character patterns for word matching
- Include language-specific characters (accents, special letters)
- Consider word boundaries specific to your language

#### Entity Pattern Examples by Language Type

The `entity_pattern` field defines how to detect proper nouns for entity extraction. Here are examples for different scripts:

**Latin-based languages** (Spanish, French, Italian):
```lua
-- Pattern for entity detection - starts with uppercase letter (including accented chars)
entity_pattern = "^[A-ZÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞŸ]",

-- Tokenization pattern for word extraction
for word in sentence:gmatch("[%w%%àáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿ]+") do
```

**Germanic languages** (German, Dutch):
```lua
-- Pattern for entity detection - starts with uppercase letter (including umlauts)
entity_pattern = "^[A-ZÄÖÜSS]",

-- Tokenization pattern for word extraction
for word in sentence:gmatch("[%w%%äöüÄÖÜßđ]+") do
```

**Cyrillic languages** (Russian, Bulgarian):
```lua
-- Pattern for entity detection - starts with uppercase Cyrillic letter
entity_pattern = "^[А-Я]",

-- Tokenization pattern for word extraction
for word in sentence:gmatch("[%w%%абвгдеёжзийклмнопрстуфхцчшщъыьэюя]+") do
```

**Note on non-Latin scripts:** For languages without case distinction (Arabic, CJK), entity detection may require alternative approaches. The system gracefully falls back to frequency-based identification when case-based detection isn't available.

## Context Expansion and Pronouns

The system includes context expansion to capture pronouns and implicit references when analyzing terms. This feature is language-agnostic in its core implementation, but understanding language-specific pronoun patterns helps optimize the feature for each language.

### How Context Expansion Works

When users analyze a term using Term X-Ray:
1. The algorithm finds sentences containing the term
2. It expands the context window to include surrounding sentences
3. Users can configure the window size via `term_xray_context_sentences_before` and `term_xray_context_sentences_after`

This captures pronouns and related context that might not explicitly mention the term.

### Pronoun Patterns by Language

Understanding your language's pronoun system helps determine optimal context window sizes:

#### English
- **Character pronouns:** he, she, they, their, him, her, them
- **Object pronouns:** it, that, this, which, what
- **Context window:** Default 2+2 sentences usually sufficient
- **Note:** English pronouns are explicit and relatively short-range references

#### Romance Languages (Spanish, French, Italian)
- **Character pronouns:** él, ella, ellos, ellas (Spanish); il, elle, ils, elles (French)
- **Object pronouns:** lo, la, los, las; le, la, les (with gender/number agreement)
- **Additional complexity:** Clitic pronouns attach to verbs
- **Suggested window:** 2-3 sentences before/after (pronouns may reference earlier clauses)
- **Example (Spanish):** "María entró en la casa. Ella estaba triste." (Maria entered the house. She was sad.)

#### Germanic Languages (German)
- **Character pronouns:** er, sie, es, ihr, ihnen (formal/informal distinction)
- **Object pronouns:** ihn, sie, es (nominative/accusative/dative cases)
- **Additional complexity:** Word order and case system may separate pronouns from antecedents
- **Suggested window:** 2-3 sentences before/after
- **Example (German):** "Der König sah den Schatz. Er wollte ihn haben." (The king saw the treasure. He wanted to have it.)

#### Slavic Languages (Russian, Polish, Czech)
- **Character pronouns:** он, она, оно, они (Russian); with case inflection
- **Object pronouns:** его, её, их (genitive forms for accusative)
- **Additional complexity:** No articles, reliance on pronouns for reference; word order more flexible
- **Suggested window:** 2-3 sentences before/after (pronouns have longer range)
- **Example (Russian):** "Король увидел сокровище. Он хотел его взять." (The king saw the treasure. He wanted to take it.)

#### Turkish
- **Character pronouns:** o (he/she/it); onlar (they); possessive suffixes (-ı, -i, -ı, -i, -su, -sü, -sı, -si)
- **Object marking:** Explicit object suffixes on verbs (-yi, -ı, -ı, -i, etc.)
- **Additional complexity:** Agglutination; pronouns often implicit due to verb conjugation
- **Suggested window:** 2-3 sentences (implicit references through verb conjugation)
- **Example (Turkish):** "Kral hazineyi gördü. Onu almak istedi." (The king saw the treasure. He wanted to take it.)

#### Arabic (Right-to-Left)
- **Character pronouns:** هو (he), هي (she), هم (they), etc.
- **Attached pronouns:** Often attached as suffixes to verbs/nouns (كتابه = his book)
- **Additional complexity:** Subject often omitted in finite verbs (conjugation implies subject)
- **Suggested window:** 2-3 sentences (especially important to capture verb conjugation context)
- **Note:** Directionality is right-to-left; context ordering still follows document flow

#### East Asian Languages (Chinese, Japanese, Korean)
- **Character pronouns:** 他 (tā/he), 她 (tā/she) in Chinese; 彼 (kare/he), 彼女 (kanojo/she) in Japanese; 그 (geu/he), 그녀 (geunyeo/she) in Korean
- **Special consideration:** Pronouns often omitted when context is clear
- **Additional complexity:** Classifiers, particles, and context markers carry meaning
- **Suggested window:** 3-4 sentences before/after (more context needed due to omitted pronouns)
- **Example (Chinese):** "王看到宝藏。他想要它。" (King saw treasure. [He] wanted to take it.) - subject often implied

### Configuring Context Window for Your Language

The default configuration uses `term_xray_context_sentences_before = 2` and `term_xray_context_sentences_after = 2`.

Recommendations by language type:
- **English, Germanic languages with clear pronouns:** Default 2+2 works well
- **Romance languages with case marking:** Consider 2-3 before/after
- **Slavic languages with flexible word order:** Consider 3 before/after
- **East Asian languages with pronoun omission:** Consider 3-4 before/after

Users can adjust these values in their configuration file:
```lua
features = {
    term_xray_context_sentences_before = 2,  -- Adjust for your language
    term_xray_context_sentences_after = 2,   -- Increase for languages with longer references
}
```

## Testing Your Language

After adding a new language:

1. Test with sample text in your language
2. Verify stop words are being filtered correctly
3. Check sentence segmentation works properly
4. Ensure special characters are handled correctly

## Usage

Once added, the language will be automatically detected and used:

```lua
-- The system will automatically use the appropriate language module
local ranked_sentences = LexRank.rank_sentences(text, 0.1, 0.1, "it")
```

## Contributing

When contributing a new language:

1. **Create the language module** with stop words and tokenization
2. **Register in language_registry**: `["it"] = ItalianLanguage`
3. **Add to language_mappings**: `it = { "italian", "italiano", "it", "it_it", "it-it" }`
4. **Test thoroughly** with real text samples
5. **Include comprehensive stop words** (minimum 50 words)
6. **Handle language-specific characters** properly
7. **Update this documentation** with your language
8. **Consider edge cases** specific to your language
9. **Consider prompt localization** (optional but recommended)

### Entity Pattern for Named Entity Detection

When adding a new language, include an `entity_pattern` field in your language module. This pattern is used to detect proper nouns (capitalized words in most scripts):

**Latin-script languages:**
```lua
entity_pattern = "^[A-Z]",  -- Basic English/simple Latin
entity_pattern = "^[A-ZÀÈÉÌÍÎÒÓÙ]",  -- Italian with accents
entity_pattern = "^[A-ZÁÉÍÓÚÑ]",  -- Spanish with accents
entity_pattern = "^[A-ZÄÖÜSS]",  -- German with umlauts
```

**Cyrillic languages:**
```lua
entity_pattern = "^[А-Я]",  -- Russian uppercase
entity_pattern = "^[A-ZА-Я]",  -- Mixed Latin/Cyrillic
```

**For languages without case distinction** (Arabic, Hebrew, CJK):
- If your language doesn't use case, you can use a more sophisticated pattern
- Or consider using frequency-based entity detection as an alternative
- Entity detection is optional; the system works fine without it

The pattern should match the first character of likely proper nouns. It's used dynamically by the entity extraction algorithm to identify capitalized words that may be names of people, places, or important concepts.

### Prompt Localization (Optional)

The Term X-Ray and Dictionary prompts in `assistant_prompts.lua` contain English-specific examples of pronouns and language patterns. These examples don't apply directly to non-English languages. If contributing a new language, you may optionally provide localized versions of the prompts that:

1. Replace English pronoun examples with your language's pronouns
2. Reflect your language's grammar and syntax
3. Use examples from your language's literature if applicable

For example, the Term X-Ray prompt mentions:
- "Character pronouns: he, she, they"
- "Thing pronouns: it, that, this"

For Spanish, these would be:
- "Character pronouns: él, ella, ellos, ellas"
- "Thing pronouns: lo, la, los, las"

**Note:** This is entirely optional. The system works well with the default English prompts even for non-English texts, though localized prompts will provide better guidance for translators and localization teams.

**Simple 3-step process:**
1. Add language module
2. Register language
3. Add mappings

*Optional 4th step: Provide localized prompt examples for your language*

## Language-Specific Resources

- **Stop Words**: Search for "stopwords [language]" or consult NLP libraries
- **Tokenization**: Research language-specific word boundary rules
- **Unicode**: Use appropriate Unicode character ranges for your language
- **Linguistic Resources**: Consult linguistic databases for your language

## Fallback Behavior

If a requested language is not supported:
- The system automatically falls back to English
- No errors are thrown - graceful degradation

This ensures the LexRank system continues to work even with unsupported languages while encouraging contributors to add support for additional languages.
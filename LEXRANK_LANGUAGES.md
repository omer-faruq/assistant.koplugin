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

#### Examples by Language Type

**Latin-based languages** (Spanish, French, Italian):
```lua
-- Pattern includes accented characters
for word in sentence:gmatch("[%w%%àáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿ]+") do
```

**Germanic languages** (German, Dutch):
```lua
-- Pattern includes umlauts and special characters
for word in sentence:gmatch("[%w%%äöüÄÖÜßđ]+") do
```

**Cyrillic languages** (Russian, Bulgarian):
```lua
-- Pattern for Cyrillic characters
for word in sentence:gmatch("[%w%%абвгдеёжзийклмнопрстуфхцчшщъыьэюя]+") do
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

**Simple 3-step process:**
1. Add language module
2. Register language
3. Add mappings

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
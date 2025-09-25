-- Language-specific modules for LexRank
-- This module provides language detection and language-specific processing

local LexRankLanguages = {}

-- Language code mapping and normalization
local function normalize_language_code(lang_code)
    if not lang_code then
        return "en"
    end

    -- Convert to lowercase and keep the full code for lookup
    local normalized = lang_code:lower()

    -- Define language mappings in an easier-to-maintain format
    -- Each entry maps multiple variants to a single base language
    local language_mappings = {
        en = { "english", "en", "en_us", "en_gb", "en-us", "en-gb" },
        es = { "spanish", "español", "es", "es_es", "es_mx", "es_ar", "es_co", "es-es", "es-mx" },
        fr = { "french", "français", "francais", "fr", "fr_fr", "fr_ca", "fr_be", "fr_ch", "fr-fr", "fr-ca" },
        de = { "german", "deutsch", "de", "de_de", "de_at", "de_ch", "de-de", "de-at" },
        tr = { "turkish", "türkçe", "turkce", "tr", "tr_tr", "tr-tr" }
    }

    -- Build the lookup table from the mappings
    local language_map = {}
    for base_lang, variants in pairs(language_mappings) do
        for _, variant in ipairs(variants) do
            language_map[variant] = base_lang
        end
    end

    return language_map[normalized] or "en"  -- Default to English
end

-- Base language module template (for documentation/reference)
-- local BaseLanguage = {
--     stop_words = {},
--     sentence_delimiters = {".", "!", "?", ";"},
--     min_sentence_length = 10,
--     min_word_length = 2
-- }

-- English language module
local EnglishLanguage = {
    stop_words = {
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "has", "he",
        "in", "is", "it", "its", "of", "on", "that", "the", "to", "was", "were", "will",
        "with", "would", "i", "you", "your", "we", "they", "them", "this", "these", "those",
        "have", "had", "do", "does", "did", "can", "could", "should", "may", "might",
        "must", "shall", "am", "been", "being", "into", "through", "during", "before",
        "after", "above", "below", "up", "down", "out", "off", "over", "under", "again",
        "further", "then", "once", "here", "there", "when", "where", "why", "how", "all",
        "any", "both", "each", "few", "more", "most", "other", "some", "such", "no",
        "nor", "not", "only", "own", "same", "so", "than", "too", "very", "just", "now"
    },
    sentence_delimiters = { ".", "!", "?", ";" },
    min_sentence_length = 10,
    min_word_length = 2,

    -- Simple stemming patterns for English
    stemming_patterns = {
        { pattern = "ing$", replacement = "" },
        { pattern = "ed$", replacement = "" },
        { pattern = "es$", replacement = "" },
        { pattern = "s$", replacement = "" },
        { pattern = "ly$", replacement = "" },
        { pattern = "er$", replacement = "" },
        { pattern = "est$", replacement = "" }
    },

    tokenize_words = function(self, sentence)
        if not sentence then return {} end
        local words = {}
        for word in sentence:gmatch("%w+") do
            local clean_word = word:lower()
            if #clean_word >= self.min_word_length and not self.stop_words_set[clean_word] then
                table.insert(words, clean_word)
            end
        end
        return words
    end
}

-- Spanish language module
local SpanishLanguage = {
    stop_words = {
        "el", "la", "de", "que", "y", "a", "en", "un", "ser", "se", "no", "te", "lo", "le",
        "da", "su", "por", "son", "con", "para", "al", "una", "era", "dos", "pero", "todo",
        "era", "muy", "son", "fue", "han", "más", "bien", "ver", "sin", "año", "día", "vez",
        "otro", "como", "cada", "años", "este", "esta", "estos", "estas", "del", "las", "los",
        "uno", "donde", "cuando", "quien", "porque", "antes", "después", "desde", "hasta"
    },
    sentence_delimiters = { ".", "!", "?", ";" },
    min_sentence_length = 10,
    min_word_length = 2,

    -- Simple stemming patterns for Spanish
    stemming_patterns = {
        { pattern = "ando$", replacement = "" },   -- gerund -ando
        { pattern = "iendo$", replacement = "" },  -- gerund -iendo
        { pattern = "ado$", replacement = "" },    -- past participle -ado
        { pattern = "ida$", replacement = "" },    -- past participle -ida
        { pattern = "mente$", replacement = "" },  -- adverb -mente
        { pattern = "ción$", replacement = "" },   -- noun -ción
        { pattern = "sión$", replacement = "" },   -- noun -sión
        { pattern = "os$", replacement = "" },     -- plural masculine
        { pattern = "as$", replacement = "" },     -- plural feminine
        { pattern = "es$", replacement = "" },     -- plural
        { pattern = "s$", replacement = "" }       -- plural
    },

    tokenize_words = function(self, sentence)
        if not sentence then return {} end
        local words = {}
        for word in sentence:gmatch("[%w%%ññáéíóúüñ]+") do
            local clean_word = word:lower()
            if #clean_word >= self.min_word_length and not self.stop_words_set[clean_word] then
                table.insert(words, clean_word)
            end
        end
        return words
    end
}

-- French language module
local FrenchLanguage = {
    stop_words = {
        "le", "de", "et", "à", "un", "il", "être", "en", "avoir", "que", "pour",
        "dans", "ce", "son", "une", "sur", "avec", "ne", "se", "pas", "tout", "plus",
        "par", "grand", "ou", "où", "mais", "si", "des", "du", "au", "aux", "la", "les",
        "ces", "cette", "celui", "celle", "ceux", "celles", "qui", "quoi", "dont",
        "donc", "alors", "comme", "sans", "sous", "entre", "pendant", "après", "avant"
    },
    sentence_delimiters = { ".", "!", "?", ";" },
    min_sentence_length = 10,
    min_word_length = 2,

    -- Simple stemming patterns for French
    stemming_patterns = {
        { pattern = "ment$", replacement = "" },   -- adverb -ment
        { pattern = "ation$", replacement = "" },  -- noun -ation
        { pattern = "tion$", replacement = "" },   -- noun -tion
        { pattern = "sion$", replacement = "" },   -- noun -sion
        { pattern = "eur$", replacement = "" },    -- agent noun -eur
        { pattern = "euse$", replacement = "" },   -- agent noun -euse
        { pattern = "ant$", replacement = "" },    -- present participle -ant
        { pattern = "ent$", replacement = "" },    -- present participle -ent
        { pattern = "és$", replacement = "" },     -- past participle plural
        { pattern = "ées$", replacement = "" },    -- past participle feminine plural
        { pattern = "é$", replacement = "" },      -- past participle
        { pattern = "ée$", replacement = "" },     -- past participle feminine
        { pattern = "s$", replacement = "" }       -- plural
    },

    tokenize_words = function(self, sentence)
        if not sentence then return {} end
        local words = {}
        for word in sentence:gmatch("[%w%%àâäéèêëïîôöùûüÿçñ]+") do
            local clean_word = word:lower()
            if #clean_word >= self.min_word_length and not self.stop_words_set[clean_word] then
                table.insert(words, clean_word)
            end
        end
        return words
    end
}

-- German language module
local GermanLanguage = {
    stop_words = {
        "der", "die", "und", "in", "den", "von", "zu", "das", "mit", "sich", "des", "auf",
        "für", "ist", "im", "dem", "nicht", "ein", "eine", "als", "auch", "es", "an", "werden",
        "aus", "er", "hat", "dass", "sie", "nach", "wird", "bei", "einer", "um", "am", "sind",
        "noch", "wie", "einem", "über", "einen", "so", "zum", "war", "haben", "nur", "oder",
        "aber", "vor", "zur", "bis", "mehr", "durch", "man", "sein", "wurde", "sei", "ich",
        "du", "wir", "ihr", "mich", "mir", "uns", "euch", "sich", "ihm", "ihn", "ihr", "ihnen"
    },
    sentence_delimiters = { ".", "!", "?", ";" },
    min_sentence_length = 10,
    min_word_length = 2,

    -- Simple stemming patterns for German
    stemming_patterns = {
        { pattern = "ung$", replacement = "" },    -- noun -ung
        { pattern = "heit$", replacement = "" },   -- noun -heit
        { pattern = "keit$", replacement = "" },   -- noun -keit
        { pattern = "lich$", replacement = "" },   -- adjective/adverb -lich
        { pattern = "isch$", replacement = "" },   -- adjective -isch
        { pattern = "end$", replacement = "" },    -- present participle -end
        { pattern = "ern$", replacement = "" },    -- verb -ern
        { pattern = "en$", replacement = "" },     -- verb infinitive/plural -en
        { pattern = "er$", replacement = "" },     -- comparative/agent -er
        { pattern = "st$", replacement = "" },     -- superlative/2nd person -st
        { pattern = "te$", replacement = "" },     -- past tense -te
        { pattern = "s$", replacement = "" }       -- genitive/plural -s
    },

    tokenize_words = function(self, sentence)
        if not sentence then return {} end
        local words = {}
        for word in sentence:gmatch("[%w%%äöüÄÖÜß]+") do
            local clean_word = word:lower()
            if #clean_word >= self.min_word_length and not self.stop_words_set[clean_word] then
                table.insert(words, clean_word)
            end
        end
        return words
    end
}

-- Turkish language module
local TurkishLanguage = {
    stop_words = {
        "acaba", "acep", "acıkça", "acıkçası", "adeta", "ama", "amma", "anca", "ancak", "aslında",
        "az", "bana", "bazen", "bazı", "belki", "ben", "beni", "beriki", "bile", "biri",
        "birileri", "birisi", "birkaç", "birşey", "biz", "bizim", "bizimki", "bu", "buna", "bunda",
        "bundan", "bunlar", "bunu", "bunun", "burası", "cümlesi", "çünkü", "çoğu", "çok", "da",
        "daha", "dahi", "de", "defa", "değil", "denli", "diye", "düşünce", "eğer", "elbette",
        "en", "fakat", "gerek", "gibi", "gibisinden", "hem", "hep", "hepsi", "her", "hiç",
        "için", "ile", "ilen", "ise", "işte", "kadar", "kah", "kez", "ki", "kim", "kimi",
        "kimisi", "kimse", "lakin", "madem", "mademki", "mamafih", "meğer", "meğerse", "mu", "mü",
        "nasıl", "neden", "nedeniyle", "nerde", "nerede", "nereye", "niçin", "niye", "o", "onca",
        "ona", "onda", "ondan", "onlar", "onu", "onun", "oysa", "oysaki", "pek", "peki",
        "rağmen", "sadece", "sanki", "sen", "siz", "sonra", "şayet", "şey", "şöyle", "şu",
        "tam", "tüm", "ve", "veya", "veyahut", "ya", "yani", "yok", "yoksa", "zaten", "zira"
    },
    sentence_delimiters = { ".", "!", "?", ";" },
    min_sentence_length = 10,
    min_word_length = 2,

    tokenize_words = function(self, sentence)
        if not sentence then
            return {}
        end
        local words = {}
        for word in sentence:gmatch("[%w%%çğıöşüÇĞİÖŞÜ]+") do
            local clean_word = word:lower()
            if #clean_word >= self.min_word_length and not self.stop_words_set[clean_word] then
                table.insert(words, clean_word)
            end
        end
        return words
    end
}

-- Convert stop words arrays to hash sets for O(1) lookup
local function prepare_language_module(module)
    if not module.stop_words_set then
        module.stop_words_set = {}
        for _, word in ipairs(module.stop_words) do
            module.stop_words_set[word] = true
        end
    end
    return module
end

-- Registry of available languages
local language_registry = {
    ["en"] = EnglishLanguage,
    ["es"] = SpanishLanguage,
    ["fr"] = FrenchLanguage,
    ["de"] = GermanLanguage,
    ["tr"] = TurkishLanguage
}

-- Apply stemming patterns to a word for fuzzy matching
function LexRankLanguages.stem_word(word, language_code)
    local language_module = LexRankLanguages.get_language_module(language_code)

    if not language_module.stemming_patterns then
        return word -- No stemming patterns available
    end

    local stemmed_word = word:lower()

    -- Apply stemming patterns in order (longest first for better results)
    for _, pattern_info in ipairs(language_module.stemming_patterns) do
        local new_word = stemmed_word:gsub(pattern_info.pattern, pattern_info.replacement)
        if new_word ~= stemmed_word and #new_word >= 3 then -- Ensure minimum root length
            stemmed_word = new_word
            break -- Apply only the first matching pattern
        end
    end

    return stemmed_word
end

-- Get language module for a given language code
function LexRankLanguages.get_language_module(language_code)
    local normalized_code = normalize_language_code(language_code)
    local module = language_registry[normalized_code]

    if not module then
        -- Fallback to English if language not supported
        module = language_registry["en"]
    end

    return prepare_language_module(module)
end

-- Get list of supported languages
function LexRankLanguages.get_supported_languages()
    local supported = {}
    for code, _ in pairs(language_registry) do
        table.insert(supported, code)
    end
    return supported
end

-- Add a new language module (for contributors)
function LexRankLanguages.register_language(language_code, language_module)
    local normalized_code = normalize_language_code(language_code)
    language_registry[normalized_code] = language_module
end

return LexRankLanguages
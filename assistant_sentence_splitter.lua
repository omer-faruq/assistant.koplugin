-- Language-aware sentence splitting for Term X-Ray.
--
-- Splits book text into sentence strings and detects the dominant language of a
-- sample. It is a pure text utility: there is no ranking, scoring, stop-word,
-- entity or stemming logic here.

local util = require("util")
local ASUtils = require("assistant_utils")

local SentenceSplitter = {}

-- Build the language-code alias map once at module initialization.
local language_mappings = {
    en = { "english", "en", "en_us", "en_gb", "en-us", "en-gb" },
    es = { "spanish", "español", "es", "es_es", "es_mx", "es_ar", "es_co", "es-es", "es-mx" },
    fr = { "french", "français", "francais", "fr", "fr_fr", "fr_ca", "fr_be", "fr_ch", "fr-fr", "fr-ca" },
    de = { "german", "deutsch", "de", "de_de", "de_at", "de_ch", "de-de", "de-at" },
    tr = { "turkish", "türkçe", "turkce", "tr", "tr_tr", "tr-tr" },
    zh = { "chinese", "中文", "简体中文", "繁體中文", "zh", "zh_cn", "zh-hans", "zh_hans", "zh-tw", "zh-hant", "cmn" },
    ja = { "japanese", "日本語", "ja", "ja_jp", "jp", "ja-jp" },
    ko = { "korean", "한국어", "ko", "ko_kr", "kr", "ko-kr" }
}

-- Build the lookup table once at initialization.
local language_map_cache = {}
for base_lang, variants in pairs(language_mappings) do
    for _idx, variant in ipairs(variants) do
        language_map_cache[variant] = base_lang
    end
end

-- Sentence delimiter sets. Latin scripts share ASCII punctuation; CJK also uses
-- the full-width forms and the ellipsis. Multi-byte delimiters are matched as
-- whole characters by the tokenizer, never through a byte class.
local ASCII_SENTENCE_DELIMITERS = { ".", "!", "?", ";" }
local CJK_SENTENCE_DELIMITERS = { "。", "！", "？", "；", "…", ".", "!", "?", ";" }

-- Language registry. Each entry carries only what sentence splitting needs.
local language_registry = {
    en = { sentence_delimiters = ASCII_SENTENCE_DELIMITERS, min_sentence_length = 10 },
    es = { sentence_delimiters = ASCII_SENTENCE_DELIMITERS, min_sentence_length = 10 },
    fr = { sentence_delimiters = ASCII_SENTENCE_DELIMITERS, min_sentence_length = 10 },
    de = { sentence_delimiters = ASCII_SENTENCE_DELIMITERS, min_sentence_length = 10 },
    tr = { sentence_delimiters = ASCII_SENTENCE_DELIMITERS, min_sentence_length = 10 },
    zh = { sentence_delimiters = CJK_SENTENCE_DELIMITERS, min_sentence_length = 10 },
    ja = { sentence_delimiters = CJK_SENTENCE_DELIMITERS, min_sentence_length = 10 },
    ko = { sentence_delimiters = CJK_SENTENCE_DELIMITERS, min_sentence_length = 10 },
}

-- Normalize a language code to one of the supported base languages.
local function normalize_language_code(lang_code)
    if not lang_code then
        return "en"
    end

    local normalized = lang_code:lower()
    return language_map_cache[normalized] or "en"
end

-- Get the language module for a code, falling back to English.
function SentenceSplitter.get_language_module(language_code)
    local normalized_code = normalize_language_code(language_code)
    return language_registry[normalized_code] or language_registry["en"]
end

-- Resolve a language argument that may be either a ready-made language module
-- table or a language code string.
local function resolve_language_module(language_code_or_module)
    if type(language_code_or_module) == "table" then
        return language_code_or_module
    end
    return SentenceSplitter.get_language_module(language_code_or_module)
end

-- Language-aware sentence tokenization.
-- Iterates full UTF-8 characters and compares whole characters against the
-- delimiter set. Multi-byte delimiters (for example the CJK "。") must never be
-- matched through a byte class, which would slice their bytes apart and corrupt
-- the output. Each sentence keeps its trailing delimiter; the trailing text after
-- the last delimiter is treated as a sentence too.
function SentenceSplitter.tokenize_sentences(text, language_code_or_module)
    if not text or text == "" then
        return {}
    end

    local language_module = resolve_language_module(language_code_or_module)
    local min_sentence_length = language_module.min_sentence_length

    local delim_set = {}
    local delimiters = language_module.sentence_delimiters
    for i = 1, #delimiters do
        delim_set[delimiters[i]] = true
    end

    local sentences = {}
    local sentence_start = 1
    local byte_pos = 1

    for char in text:gmatch(util.UTF8_CHAR_PATTERN) do
        local char_end = byte_pos + #char - 1

        if delim_set[char] then
            local sentence = text:sub(sentence_start, char_end)
            local trimmed = sentence:gsub("^%s*(.-)%s*$", "%1")
            if #trimmed >= min_sentence_length then
                table.insert(sentences, trimmed)
            end
            sentence_start = char_end + 1
        end

        byte_pos = char_end + 1
    end

    -- Trailing text after the last delimiter is handled the same way.
    if sentence_start <= #text then
        local sentence = text:sub(sentence_start)
        local trimmed = sentence:gsub("^%s*(.-)%s*$", "%1")
        if #trimmed >= min_sentence_length then
            table.insert(sentences, trimmed)
        end
    end

    return sentences
end

-- Detect the language code of a text sample.
-- An explicit, supported fallback other than "en" is always respected (it
-- represents a deliberate user choice). Otherwise the text is sampled: CJK
-- script requires enough characters both in absolute terms and as a share of
-- the non-space characters. Kana implies Japanese, Hangul implies Korean, and
-- any other sufficiently CJK text is treated as Chinese.
function SentenceSplitter.detect_language_code(text, fallback_code)
    local normalized_fallback = normalize_language_code(fallback_code)

    if normalized_fallback ~= "en" then
        return normalized_fallback
    end

    if not text or text == "" then
        return normalized_fallback
    end

    -- Bound the work on very long inputs; keep the prefix on a UTF-8 boundary.
    local sample = text
    if #sample > 4000 then
        sample = ASUtils.truncateToHeadUtf8Safe(sample, 4000)
    end

    local cjk_count = 0
    local non_space_count = 0
    local has_kana = false
    local has_hangul = false

    for char in sample:gmatch(util.UTF8_CHAR_PATTERN) do
        if not char:match("^%s$") then
            non_space_count = non_space_count + 1
        end

        if util.isCJKChar(char) then
            cjk_count = cjk_count + 1

            local first_byte = char:byte(1)
            if first_byte == 0xE3 then
                -- Hiragana (\227\129) and Katakana (\227\130, \227\131).
                local second_byte = char:byte(2)
                if second_byte == 0x81 or second_byte == 0x82 or second_byte == 0x83 then
                    has_kana = true
                end
            elseif first_byte >= 0xEA and first_byte <= 0xED then
                -- Hangul syllables / Jamo (\234-\237).
                has_hangul = true
            end
        end
    end

    if cjk_count < 20 or non_space_count == 0 or (cjk_count / non_space_count) < 0.30 then
        return normalized_fallback
    end

    if has_kana then
        return "ja"
    end
    if has_hangul then
        return "ko"
    end
    return "zh"
end

return SentenceSplitter

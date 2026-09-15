-- Term X-Ray anchor extraction.
--
-- Pure occurrence-anchored (keyword-in-context) helpers: find where a term
-- occurs in the split book text and assemble the bounded context around those
-- anchors. No ranking, scoring or configuration access: callers pass every
-- tunable through `opts`.

local ASUtils = require("assistant_utils")

local TermXray = {}

-- Fallbacks mirror the shipped configuration defaults, so the module also
-- behaves sensibly when a caller omits an option.
local DEFAULT_SENTENCES_BEFORE = 2
local DEFAULT_SENTENCES_AFTER = 2
local DEFAULT_MAX_OCCURRENCES = 40
local DEFAULT_MAX_CHARACTERS = 60000
local MIN_MAX_CHARACTERS = 1000

-- Case- and whitespace-insensitive normalization used for term matching. Book
-- text extracted from a document can carry line breaks, doubled spaces or
-- non-breaking spaces where the on-page selection had a single space, so
-- "Vasil Levski Boulevard" must still match "Vasil Levski\nBoulevard".
function TermXray.normalize_for_match(s)
    if type(s) ~= "string" then return "" end
    local collapsed = s:lower():gsub("\194\160", " "):gsub("%s+", " ")
    return collapsed:match("^%s*(.-)%s*$") or collapsed
end

-- Find the document indices of sentences containing `term`.
--
-- Matching is case-insensitive and literal (no patterns). When the exact term
-- is absent it retries once with edge punctuation stripped, so "word." can
-- match "word". Returns an ascending, possibly empty list.
function TermXray.find_term_indices(sentences, term)
    if not sentences or type(term) ~= "string" or term == "" then
        return {}
    end

    local function scan(needle)
        local indices = {}
        if needle == "" then
            return indices
        end
        for sentence_index, sentence in ipairs(sentences) do
            if sentence and TermXray.normalize_for_match(sentence):find(needle, 1, true) then
                indices[#indices + 1] = sentence_index
            end
        end
        return indices
    end

    local indices = scan(TermXray.normalize_for_match(term))
    if #indices > 0 then
        return indices
    end

    local stripped = ASUtils.strip_selection_punctuation(term)
    if stripped and stripped ~= term then
        indices = scan(TermXray.normalize_for_match(stripped))
    end

    return indices
end

-- Build the Term X-Ray context around term occurrences.
--
-- `opts` fields: sentences_before, sentences_after, max_occurrences,
-- max_characters.
--
-- Occurrence selection: every occurrence is an anchor. When there are more
-- occurrences than `max_occurrences`, a fixed number are sampled evenly over the
-- whole list, always including the first and last occurrence. Each anchor widens
-- to `[i - before, i + after]`, clamped to the sentence list. Sentences are
-- assembled in document order under a character budget that skips (does not stop
-- at) a sentence crossing the limit, so late-book coverage survives it.
function TermXray.build_anchor_context(all_sentences, term_indices, opts)
    opts = opts or {}

    local N = all_sentences and #all_sentences or 0
    if N == 0 or not term_indices or #term_indices == 0 then
        return { text = "", sentence_count = 0 }
    end

    local before = opts.sentences_before or DEFAULT_SENTENCES_BEFORE
    local after = opts.sentences_after or DEFAULT_SENTENCES_AFTER
    local max_occurrences = opts.max_occurrences or DEFAULT_MAX_OCCURRENCES
    local max_characters = math.max(MIN_MAX_CHARACTERS, opts.max_characters or DEFAULT_MAX_CHARACTERS)

    -- Pick the occurrences to anchor on. Past the cap, sample evenly over the
    -- whole list so the first and last occurrence are always represented.
    local occurrence_count = #term_indices
    local picked = {}
    if occurrence_count > max_occurrences then
        if max_occurrences <= 1 then
            picked[1] = term_indices[1]
        else
            local seen = {}
            for k = 0, max_occurrences - 1 do
                local pos = 1 + math.floor(k * (occurrence_count - 1) / (max_occurrences - 1))
                local anchor = term_indices[pos]
                if not seen[anchor] then
                    seen[anchor] = true
                    picked[#picked + 1] = anchor
                end
            end
        end
    else
        for k = 1, occurrence_count do
            picked[k] = term_indices[k]
        end
    end

    -- Union the before/after windows of every picked occurrence.
    local chosen = {}
    for k = 1, #picked do
        local anchor = picked[k]
        if anchor >= 1 and anchor <= N then
            local first = math.max(1, anchor - before)
            local last = math.min(N, anchor + after)
            for j = first, last do
                chosen[j] = true
            end
        end
    end

    local ordered = {}
    for index in pairs(chosen) do
        ordered[#ordered + 1] = index
    end
    table.sort(ordered)

    local parts = {}
    local chars = 0
    local sentence_count = 0
    for k = 1, #ordered do
        local sentence = all_sentences[ordered[k]]
        if chars + #sentence + 1 <= max_characters then
            parts[#parts + 1] = sentence
            chars = chars + #sentence + 1
            sentence_count = sentence_count + 1
        end
    end

    return { text = table.concat(parts, " "), sentence_count = sentence_count }
end

return TermXray

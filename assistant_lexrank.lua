local LexRankLanguages = require("assistant_lexrank_languages")

-- Lua implementation of the LexRank algorithm for sentence ranking
local LexRank = {}

-- Configuration constants
local CONFIG = {
    DEFAULT_THRESHOLD = 0.1,
    DEFAULT_EPSILON = 0.1,
    DEFAULT_LANGUAGE = "en",
    MAX_SENTENCES_FOR_FULL_ANALYSIS = 200,
    MAX_ITERATIONS = 100,
    CONVERGENCE_CHECK_FREQUENCY = 5,
    MIN_SELECTION_PERCENTAGE = 0.7,        -- Increased from 0.6 to 70%
    MAX_SELECTION_PERCENTAGE = 0.85,       -- Increased from 0.8 to 85%
    SELECTION_THRESHOLD_FACTOR = 0.4,      -- Lowered from 0.5 (more inclusive)
    ALTERNATIVE_THRESHOLD_FACTOR = 0.5,    -- Lowered from 0.6 (more inclusive)
    MIN_SENTENCES_TARGET = 5,
    ENTITY_BOOST_FACTOR = 0.2,             -- 20% boost for sentences with named entities
    FIRST_MENTION_BOOST_FACTOR = 0.35,     -- 35% boost for first mention of entities
    POSITION_BOOST_FACTOR = 0.1             -- 10% boost for early sentences (intro content)
}

-- Language-aware sentence tokenization (optimized for performance)
local function tokenize_sentences(text, language_module)
    if not text or text == "" then
        return {}
    end

    -- Build pattern for sentence delimiters
    local delim_pattern = "[" .. table.concat(language_module.sentence_delimiters, "") .. "]"
    local sentences = {}
    local sentence_start = 1

    -- Scan through text looking for sentence delimiters
    for i = 1, #text do
        local char = text:sub(i, i)

        if char:match(delim_pattern) then
            -- Extract sentence from start to current position
            local sentence = text:sub(sentence_start, i)
            -- Trim whitespace
            local trimmed = sentence:gsub("^%s*(.-)%s*$", "%1")
            if #trimmed >= language_module.min_sentence_length then
                table.insert(sentences, trimmed)
            end
            sentence_start = i + 1
        end
    end

    -- Add remaining text as sentence if it's long enough
    if sentence_start <= #text then
        local sentence = text:sub(sentence_start)
        local trimmed = sentence:gsub("^%s*(.-)%s*$", "%1")
        if #trimmed >= language_module.min_sentence_length then
            table.insert(sentences, trimmed)
        end
    end

    return sentences
end

-- Language-aware word tokenization
local function tokenize_words(sentence, language_module)
    if language_module.tokenize_words then
        return language_module:tokenize_words(sentence)
    else
        -- Fallback to basic tokenization
        if not sentence then return {} end
        local words = {}
        for word in sentence:gmatch("%w+") do
            local clean_word = word:lower()
            if #clean_word >= language_module.min_word_length and not language_module.stop_words_set[clean_word] then
                table.insert(words, clean_word)
            end
        end
        return words
    end
end

-- Extract named entities (proper nouns) from a sentence (optimized)
-- Returns a table of capitalized words that are likely proper nouns
-- Uses language-specific entity pattern for proper noun detection
local function extract_named_entities(sentence, language_module)
    if not sentence or sentence == "" then
        return {}
    end

    local entities = {}
    local entity_map = {}  -- Track unique entities
    local word_index = 0

    -- Get entity pattern from language module, fallback to English if not specified
    local entity_pattern = (language_module and language_module.entity_pattern) or "^[A-Z]"

    -- Find capitalized words (potential proper nouns) without intermediate table
    for word in sentence:gmatch("%w+") do
        word_index = word_index + 1

        -- Check if word starts with capital letter (pattern from language) and is not common abbreviations
        if word:match(entity_pattern) and #word >= 2 then
            -- Skip if first word in sentence (could be capitalized just for grammar)
            -- unless it's part of a multi-word entity or all caps
            if word_index > 1 or word:match("^[A-Z][A-Z]+") or (word_index == 1 and #word > 2 and word:match("[A-Z][a-z]")) then
                local normalized = word:lower()
                if not entity_map[normalized] then
                    entity_map[normalized] = word
                    table.insert(entities, word)
                end
            end
        end
    end

    return entities
end

-- Calculate term frequency for a sentence
local function calculate_tf(words)
    local tf = {}
    local total_words = #words

    if total_words == 0 then
        return tf
    end

    for _, word in ipairs(words) do
        tf[word] = (tf[word] or 0) + 1
    end

    -- Normalize by sentence length
    for word, count in pairs(tf) do
        tf[word] = count / total_words
    end

    return tf
end

-- Calculate inverse document frequency
local function calculate_idf(sentences_words, total_sentences)
    local word_doc_count = {}
    local idf = {}

    -- Count documents (sentences) containing each word
    for _, words in ipairs(sentences_words) do
        local unique_words = {}
        for _, word in ipairs(words) do
            unique_words[word] = true
        end
        for word, _ in pairs(unique_words) do
            word_doc_count[word] = (word_doc_count[word] or 0) + 1
        end
    end

    -- Calculate IDF
    for word, count in pairs(word_doc_count) do
        idf[word] = math.log(total_sentences / count)
    end

    return idf
end

-- Track entities and their first occurrences across sentences
-- Also caches entity results for each sentence to avoid re-extraction
local function track_entities(sentences, language_module)
    local entity_tracker = {
        entities = {},           -- Map of normalized entity -> original form
        first_occurrence = {},   -- Map of normalized entity -> sentence index
        sentence_entities = {}   -- Cache of entities for each sentence [index] = {entities}
    }

    for i, sentence in ipairs(sentences) do
        local entities = extract_named_entities(sentence, language_module)
        entity_tracker.sentence_entities[i] = entities  -- Cache results

        for _, entity in ipairs(entities) do
            local normalized = entity:lower()
            if not entity_tracker.entities[normalized] then
                entity_tracker.entities[normalized] = entity
                entity_tracker.first_occurrence[normalized] = i
            end
        end
    end

    return entity_tracker
end

-- Calculate entity boost for a sentence based on named entities it contains
-- Uses cached entity results to avoid re-extraction
local function calculate_entity_boost(entity_tracker, sentence_index, total_sentences)
    local boost = 0
    local entities = entity_tracker.sentence_entities[sentence_index] or {}

    if #entities > 0 then
        -- Base boost for containing any entity
        boost = CONFIG.ENTITY_BOOST_FACTOR
    end

    -- Additional boost for first mention of entities
    for _, entity in ipairs(entities) do
        local normalized = entity:lower()
        if entity_tracker.first_occurrence[normalized] == sentence_index then
            boost = boost + CONFIG.FIRST_MENTION_BOOST_FACTOR
        end
    end

    -- Small position-based boost for early sentences (likely intro/context)
    if sentence_index <= math.ceil(total_sentences * 0.15) then
        boost = boost + CONFIG.POSITION_BOOST_FACTOR
    end

    return boost
end

-- Calculate cosine similarity between two sentences (optimized for memory)
local function cosine_similarity(tf1, tf2, idf)
    local dot_product = 0
    local norm1 = 0
    local norm2 = 0

    -- Process tf1 entries and compute their contribution
    for word, tf_val in pairs(tf1) do
        local idf_val = idf[word] or 0
        local tfidf1 = tf_val * idf_val
        norm1 = norm1 + (tfidf1 * tfidf1)

        -- Check if word exists in tf2
        local tf2_val = tf2[word]
        if tf2_val then
            local tfidf2 = tf2_val * idf_val
            dot_product = dot_product + (tfidf1 * tfidf2)
            norm2 = norm2 + (tfidf2 * tfidf2)
        end
    end

    -- Process tf2 entries that weren't in tf1
    for word, tf_val in pairs(tf2) do
        if not tf1[word] then
            local idf_val = idf[word] or 0
            local tfidf2 = tf_val * idf_val
            norm2 = norm2 + (tfidf2 * tfidf2)
        end
    end

    if norm1 > 0 and norm2 > 0 then
        return dot_product / (math.sqrt(norm1) * math.sqrt(norm2))
    else
        return 0
    end
end

-- Initialize and validate LexRank parameters
local function initialize_parameters(threshold, epsilon, language_code)
    return {
        threshold = threshold or CONFIG.DEFAULT_THRESHOLD,
        epsilon = epsilon or CONFIG.DEFAULT_EPSILON,
        language_code = language_code or CONFIG.DEFAULT_LANGUAGE
    }
end

-- Sample sentences for performance when dealing with very long texts
-- Prioritizes keeping sentences with named entities to preserve context
-- Uses pre-cached entity information from entity_tracker
-- Maintains document order in output
local function sample_large_text(sentences, entity_tracker, max_sentences)
    if #sentences <= max_sentences then
        return sentences
    end

    -- First pass: identify sentences with entities using cached results
    local entity_indices = {}

    for i = 1, #sentences do
        local entities = entity_tracker.sentence_entities[i]
        if entities and #entities > 0 then
            table.insert(entity_indices, i)
        end
    end

    -- Calculate how many non-entity sentences we can include
    local max_entity_to_keep = math.floor(max_sentences * 0.6)
    local max_non_entity = max_sentences - math.min(#entity_indices, max_entity_to_keep)

    -- Use a set to track which sentence indices to keep (for O(1) lookup)
    local sampled_set = {}  -- Hash set: sampled_set[original_index] = true
    local sampled_count = 0

    -- Mark entity sentences for inclusion (up to 60% of max)
    local entity_count = 0
    for _, idx in ipairs(entity_indices) do
        if entity_count < max_entity_to_keep then
            sampled_set[idx] = true
            sampled_count = sampled_count + 1
            entity_count = entity_count + 1
        end
    end

    -- Sample remaining sentences with step pattern, avoiding duplicates
    local non_entity_sampled = 0
    local step = math.floor(#sentences / max_non_entity)
    if step < 1 then step = 1 end

    for i = 1, #sentences, step do
        if non_entity_sampled < max_non_entity and not sampled_set[i] then
            sampled_set[i] = true
            sampled_count = sampled_count + 1
            non_entity_sampled = non_entity_sampled + 1
        end
    end

    -- Build output preserving original document order
    local sampled = {}
    for i = 1, #sentences do
        if sampled_set[i] then
            table.insert(sampled, sentences[i])
        end
    end

    return sampled
end

-- Build TF-IDF weighted similarity matrix between sentences
local function build_similarity_matrix(sentences_words, total_sentences)
    -- Calculate IDF
    local idf = calculate_idf(sentences_words, total_sentences)

    -- Calculate TF for each sentence
    local tf_matrix = {}
    for i, words in ipairs(sentences_words) do
        tf_matrix[i] = calculate_tf(words)
    end

    -- Build similarity matrix with optimization
    local similarity_matrix = {}
    for i = 1, total_sentences do
        similarity_matrix[i] = {}
        for j = 1, total_sentences do
            if i == j then
                similarity_matrix[i][j] = 0
            elseif i > j then
                -- Use symmetry to avoid duplicate calculations
                similarity_matrix[i][j] = similarity_matrix[j][i]
            else
                similarity_matrix[i][j] = cosine_similarity(tf_matrix[i], tf_matrix[j], idf)
            end
        end
    end

    return similarity_matrix
end

-- Apply threshold and normalize similarity matrix by degrees (optimized single pass)
local function normalize_similarity_matrix(similarity_matrix, threshold)
    local total_sentences = #similarity_matrix
    local degrees = {}

    -- Combined pass: threshold, count degrees, and normalize in one loop
    for i = 1, total_sentences do
        degrees[i] = 0

        -- First, count edges > threshold
        for j = 1, total_sentences do
            if similarity_matrix[i][j] > threshold then
                similarity_matrix[i][j] = 1.0
                degrees[i] = degrees[i] + 1
            else
                similarity_matrix[i][j] = 0
            end
        end

        -- Avoid division by zero
        if degrees[i] == 0 then
            degrees[i] = 1
        end
    end

    -- Normalize by degree (separate pass - must calculate all degrees first)
    for i = 1, total_sentences do
        local degree_inv = 1.0 / degrees[i]  -- Pre-compute inverse to avoid division in loop
        for j = 1, total_sentences do
            similarity_matrix[i][j] = similarity_matrix[i][j] * degree_inv
        end
    end

    return similarity_matrix
end

-- Run PageRank power iteration algorithm with optimized convergence detection
local function run_power_iteration(similarity_matrix, epsilon)
    local total_sentences = #similarity_matrix

    -- Initialize PageRank vector
    local score_vector = {}
    for i = 1, total_sentences do
        score_vector[i] = 1.0 / total_sentences
    end

    -- Power iteration with early convergence optimization
    local convergence_measure = 1.0
    local max_iterations = math.min(CONFIG.MAX_ITERATIONS, total_sentences * 2)
    local iteration = 0

    -- Adaptive convergence check frequency: check every iteration for small texts, less often for large texts
    local check_frequency = CONFIG.CONVERGENCE_CHECK_FREQUENCY
    if total_sentences < 50 then
        check_frequency = 1  -- Check every iteration for small texts
    elseif total_sentences < 100 then
        check_frequency = 2  -- Check every 2 iterations for medium texts
    end

    while convergence_measure > epsilon and iteration < max_iterations do
        local next_scores = {}

        -- Matrix multiplication: next_scores = similarity_matrix^T * score_vector
        for i = 1, total_sentences do
            next_scores[i] = 0
            for j = 1, total_sentences do
                next_scores[i] = next_scores[i] + similarity_matrix[j][i] * score_vector[j]
            end
        end

        iteration = iteration + 1

        -- Check convergence with adaptive frequency
        if iteration % check_frequency == 0 then
            convergence_measure = 0
            local total_score = 0

            for i = 1, total_sentences do
                convergence_measure = convergence_measure + math.abs(next_scores[i] - score_vector[i])
                total_score = total_score + next_scores[i]
            end

            -- Use relative convergence for better early stopping
            -- Stop if absolute change is small relative to total score (prevents oscillation)
            if total_score > 0 then
                local relative_convergence = convergence_measure / total_score
                if relative_convergence < epsilon * 0.1 then
                    convergence_measure = 0  -- Force exit
                end
            end
        end

        score_vector = next_scores
    end

    return score_vector
end

-- Select sentences based on scores using statistical thresholds
-- Applies entity boost to prioritize context about characters and places
local function select_sentences_by_score(sentences, score_vector, entity_tracker)
    local total_sentences = #sentences

    -- Apply entity boosting to scores using cached entity data
    local boosted_scores = {}
    for i = 1, total_sentences do
        local boost = 0
        if entity_tracker then
            boost = calculate_entity_boost(entity_tracker, i, total_sentences)
        end
        boosted_scores[i] = score_vector[i] + boost
    end

    -- Calculate score statistics for better selection using boosted scores
    local total_score = 0
    for i = 1, total_sentences do
        total_score = total_score + boosted_scores[i]
    end
    local avg_score = total_score / total_sentences

    -- Calculate standard deviation for more nuanced selection
    local variance = 0
    for i = 1, total_sentences do
        variance = variance + (boosted_scores[i] - avg_score) ^ 2
    end
    local std_dev = math.sqrt(variance / total_sentences)

    -- Use a more inclusive selection threshold
    local selection_threshold = math.max(
        avg_score - (std_dev * CONFIG.SELECTION_THRESHOLD_FACTOR),
        avg_score * CONFIG.ALTERNATIVE_THRESHOLD_FACTOR
    )

    -- Select sentences above the threshold
    local selected_sentences = {}
    for i = 1, total_sentences do
        if boosted_scores[i] >= selection_threshold then
            table.insert(selected_sentences, sentences[i])
        end
    end

    -- If too few sentences, ensure we get at least 70-85% of sentences
    if #selected_sentences < math.floor(total_sentences * CONFIG.MIN_SELECTION_PERCENTAGE) then
        -- Calculate target count first
        local target_count = math.max(
            math.floor(total_sentences * CONFIG.MIN_SELECTION_PERCENTAGE),
            math.min(
                math.floor(total_sentences * CONFIG.MAX_SELECTION_PERCENTAGE),
                math.max(CONFIG.MIN_SENTENCES_TARGET, total_sentences)
            )
        )

        -- Use partial selection (finding top K) instead of full sort (O(n log n) -> O(n) avg)
        -- Maintain a list of top candidates as we scan through
        local top_candidates = {}

        for i = 1, total_sentences do
            table.insert(top_candidates, {sentence = sentences[i], score = boosted_scores[i], index = i})
        end

        -- Sort by score descending (still O(n log n) but now we know it's necessary)
        table.sort(top_candidates, function(a, b) return a.score > b.score end)

        -- Extract just the top target_count sentences, then re-sort by document order
        local selected_with_indices = {}
        for i = 1, math.min(target_count, #top_candidates) do
            table.insert(selected_with_indices, top_candidates[i])
        end

        -- Sort by original document order to maintain coherence
        table.sort(selected_with_indices, function(a, b) return a.index < b.index end)

        selected_sentences = {}
        for _, item in ipairs(selected_with_indices) do
            table.insert(selected_sentences, item.sentence)
        end
    end

    return selected_sentences
end

-- Main LexRank function
function LexRank.rank_sentences(text, threshold, epsilon, language_code)
    -- Initialize parameters with defaults
    local params = initialize_parameters(threshold, epsilon, language_code)

    if not text or text == "" then
        return {}
    end

    -- Get language-specific module
    local language_module = LexRankLanguages.get_language_module(params.language_code)

    -- Tokenize sentences
    local sentences = tokenize_sentences(text, language_module)
    local total_sentences = #sentences

    if total_sentences == 0 then
        return {}
    end

    if total_sentences == 1 then
        return {sentences[1]}
    end

    -- Track entities before sampling to ensure important entities are preserved
    local entity_tracker = track_entities(sentences, language_module)

    -- Performance optimization for very long texts (pass entity_tracker to use cached entities)
    sentences = sample_large_text(sentences, entity_tracker, CONFIG.MAX_SENTENCES_FOR_FULL_ANALYSIS)
    total_sentences = #sentences

    -- CRITICAL: Rebuild entity tracker after sampling because indices have changed
    -- The original entity_tracker indices referred to pre-sampled sentence positions
    entity_tracker = track_entities(sentences, language_module)

    -- Tokenize words for each sentence
    local sentences_words = {}
    for i, sentence in ipairs(sentences) do
        local words = tokenize_words(sentence, language_module)
        sentences_words[i] = words
    end

    -- Build TF-IDF weighted similarity matrix
    local similarity_matrix = build_similarity_matrix(sentences_words, total_sentences)

    -- Apply threshold and normalize matrix
    similarity_matrix = normalize_similarity_matrix(similarity_matrix, params.threshold)

    -- Run PageRank power iteration
    local score_vector = run_power_iteration(similarity_matrix, params.epsilon)

    -- Select sentences based on scores with entity boosting
    return select_sentences_by_score(sentences, score_vector, entity_tracker)
end

return LexRank
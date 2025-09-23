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
    MIN_SELECTION_PERCENTAGE = 0.6,
    MAX_SELECTION_PERCENTAGE = 0.8,
    SELECTION_THRESHOLD_FACTOR = 0.5,
    ALTERNATIVE_THRESHOLD_FACTOR = 0.6,
    MIN_SENTENCES_TARGET = 5
}

-- Language-aware sentence tokenization
local function tokenize_sentences(text, language_module)
    if not text or text == "" then
        return {}
    end

    -- Build pattern for sentence delimiters
    local delim_pattern = "[" .. table.concat(language_module.sentence_delimiters, "") .. "]"
    local sentences = {}
    local current_sentence = ""

    for i = 1, #text do
        local char = text:sub(i, i)
        current_sentence = current_sentence .. char

        if char:match(delim_pattern) then
            -- Check if this is end of sentence (not in abbreviation)
            local trimmed = current_sentence:gsub("^%s*(.-)%s*$", "%1")
            if #trimmed >= language_module.min_sentence_length then
                table.insert(sentences, trimmed)
            end
            current_sentence = ""
        end
    end

    -- Add remaining text as sentence if it's long enough
    local trimmed = current_sentence:gsub("^%s*(.-)%s*$", "%1")
    if #trimmed >= language_module.min_sentence_length then
        table.insert(sentences, trimmed)
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

-- Calculate cosine similarity between two sentences
local function cosine_similarity(tf1, tf2, idf)
    local dot_product = 0
    local norm1 = 0
    local norm2 = 0

    -- Get all unique words from both sentences
    local all_words = {}
    for word, _ in pairs(tf1) do
        all_words[word] = true
    end
    for word, _ in pairs(tf2) do
        all_words[word] = true
    end

    for word, _ in pairs(all_words) do
        local tfidf1 = (tf1[word] or 0) * (idf[word] or 0)
        local tfidf2 = (tf2[word] or 0) * (idf[word] or 0)

        dot_product = dot_product + (tfidf1 * tfidf2)
        norm1 = norm1 + (tfidf1 * tfidf1)
        norm2 = norm2 + (tfidf2 * tfidf2)
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
local function sample_large_text(sentences, max_sentences)
    if #sentences <= max_sentences then
        return sentences, sentences
    end

    local sample_sentences = {}
    local step = math.floor(#sentences / max_sentences)

    for i = 1, #sentences, step do
        table.insert(sample_sentences, sentences[i])
        -- Include next sentence to maintain some context
        if i + 1 <= #sentences then
            table.insert(sample_sentences, sentences[i + 1])
        end
    end

    return sample_sentences, sentences
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

-- Apply threshold and normalize similarity matrix by degrees
local function normalize_similarity_matrix(similarity_matrix, threshold)
    local total_sentences = #similarity_matrix
    local degrees = {}

    -- Apply threshold and calculate degrees
    for i = 1, total_sentences do
        degrees[i] = 0
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

    -- Normalize similarity matrix by degrees
    for i = 1, total_sentences do
        for j = 1, total_sentences do
            similarity_matrix[i][j] = similarity_matrix[i][j] / degrees[i]
        end
    end

    return similarity_matrix
end

-- Run PageRank power iteration algorithm
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

        -- Check convergence less frequently for better performance
        if iteration % CONFIG.CONVERGENCE_CHECK_FREQUENCY == 0 then
            convergence_measure = 0
            for i = 1, total_sentences do
                convergence_measure = convergence_measure + math.abs(next_scores[i] - score_vector[i])
            end
        end

        score_vector = next_scores
    end

    return score_vector
end

-- Select sentences based on scores using statistical thresholds
local function select_sentences_by_score(sentences, score_vector)
    local total_sentences = #sentences

    -- Calculate score statistics for better selection
    local total_score = 0
    for i = 1, total_sentences do
        total_score = total_score + score_vector[i]
    end
    local avg_score = total_score / total_sentences

    -- Calculate standard deviation for more nuanced selection
    local variance = 0
    for i = 1, total_sentences do
        variance = variance + (score_vector[i] - avg_score) ^ 2
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
        if score_vector[i] >= selection_threshold then
            table.insert(selected_sentences, sentences[i])
        end
    end

    -- If too few sentences, ensure we get at least 60-80% of sentences
    if #selected_sentences < math.floor(total_sentences * CONFIG.MIN_SELECTION_PERCENTAGE) then
        local sentence_scores = {}
        for i = 1, total_sentences do
            table.insert(sentence_scores, {
                sentence = sentences[i],
                score = score_vector[i],
                index = i
            })
        end

        -- Sort by score descending
        table.sort(sentence_scores, function(a, b) return a.score > b.score end)

        -- Take top 60-80% of sentences
        local target_count = math.max(
            math.floor(total_sentences * CONFIG.MIN_SELECTION_PERCENTAGE),
            math.min(
                math.floor(total_sentences * CONFIG.MAX_SELECTION_PERCENTAGE),
                math.max(CONFIG.MIN_SENTENCES_TARGET, total_sentences)
            )
        )

        selected_sentences = {}
        for i = 1, math.min(target_count, total_sentences) do
            table.insert(selected_sentences, sentence_scores[i].sentence)
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

    -- Performance optimization for very long texts
    local sampled_sentences, _ = sample_large_text(sentences, CONFIG.MAX_SENTENCES_FOR_FULL_ANALYSIS)
    sentences = sampled_sentences
    total_sentences = #sentences

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

    -- Select sentences based on scores
    return select_sentences_by_score(sentences, score_vector)
end

return LexRank
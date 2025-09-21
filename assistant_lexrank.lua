local logger = require("logger")
local LexRankLanguages = require("assistant_lexrank_languages")

-- Lua implementation of the LexRank algorithm for sentence ranking
local LexRank = {}

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

-- Main LexRank function
function LexRank.rank_sentences(text, threshold, epsilon, language_code)
    threshold = threshold or 0.1
    epsilon = epsilon or 0.1
    language_code = language_code or "en"

    if not text or text == "" then
        return {}
    end

    -- Get language-specific module
    local language_module = LexRankLanguages.get_language_module(language_code)

    -- Tokenize sentences
    local sentences = tokenize_sentences(text, language_module)
    local total_sentences = #sentences

    if total_sentences == 0 then
        return {}
    end

    if total_sentences == 1 then
        return {sentences[1]}
    end

    -- Tokenize words for each sentence
    local sentences_words = {}
    local tf_matrix = {}

    for i, sentence in ipairs(sentences) do
        local words = tokenize_words(sentence, language_module)
        sentences_words[i] = words
        tf_matrix[i] = calculate_tf(words)
    end

    -- Calculate IDF
    local idf = calculate_idf(sentences_words, total_sentences)

    -- Build similarity matrix
    local similarity_matrix = {}
    for i = 1, total_sentences do
        similarity_matrix[i] = {}
        for j = 1, total_sentences do
            if i == j then
                similarity_matrix[i][j] = 0
            else
                similarity_matrix[i][j] = cosine_similarity(tf_matrix[i], tf_matrix[j], idf)
            end
        end
    end

    -- Apply threshold and calculate degrees
    local degrees = {}
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

    -- Initialize PageRank vector
    local p_vector = {}
    for i = 1, total_sentences do
        p_vector[i] = 1.0 / total_sentences
    end

    -- Power iteration
    local lambda_val = 1.0
    local max_iterations = 100
    local iteration = 0

    while lambda_val > epsilon and iteration < max_iterations do
        local next_p = {}

        -- Matrix multiplication: next_p = similarity_matrix^T * p_vector
        for i = 1, total_sentences do
            next_p[i] = 0
            for j = 1, total_sentences do
                next_p[i] = next_p[i] + similarity_matrix[j][i] * p_vector[j]
            end
        end

        -- Calculate convergence measure
        lambda_val = 0
        for i = 1, total_sentences do
            lambda_val = lambda_val + math.abs(next_p[i] - p_vector[i])
        end

        p_vector = next_p
        iteration = iteration + 1
    end

    -- Calculate average score
    local total_score = 0
    for i = 1, total_sentences do
        total_score = total_score + p_vector[i]
    end
    local avg_score = total_score / total_sentences

    -- Select sentences above average
    local selected_sentences = {}
    for i = 1, total_sentences do
        if p_vector[i] >= avg_score then
            table.insert(selected_sentences, sentences[i])
        end
    end

    -- If no sentences are above average, return top half
    if #selected_sentences == 0 then
        local sentence_scores = {}
        for i = 1, total_sentences do
            table.insert(sentence_scores, {sentence = sentences[i], score = p_vector[i], index = i})
        end

        -- Sort by score descending
        table.sort(sentence_scores, function(a, b) return a.score > b.score end)

        local half_count = math.max(1, math.floor(total_sentences / 2))
        for i = 1, half_count do
            table.insert(selected_sentences, sentence_scores[i].sentence)
        end
    end

    return selected_sentences
end

return LexRank
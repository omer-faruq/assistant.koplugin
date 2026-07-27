#!/bin/bash
# AI_TRANSLATE.sh
#
# Purpose:
# This script automates the translation of gettext .po files using a Large Language Model (LLM) API,
# such as OpenAI's GPT models. It can be used to either create a new translation file for a language
# or update an existing one with new strings.
#
# Workflow:
# 1.  It takes a single argument: the language code (e.g., 'fr', 'de', 'zh_CN').
# 2.  It validates the language code against a predefined list and checks for the API_KEY.
# 3.  It determines the input and output files based on the state of the language directory:
#     - For a NEW language (no 'koreader.po' or 'untranslated.po' exists):
#       - Input:  'templates/koreader.pot' (copied to '<LANG_CODE>/untranslated.po')
#       - Output: '<LANG_CODE>/koreader.po' (a fully translated file)
#     - For an EXISTING language with updates (both 'koreader.po' and 'untranslated.po' exist):
#       - Input:  '<LANG_CODE>/untranslated.po' (containing only new strings to translate)
#       - Output: '<LANG_CODE>/updated_translated.po' (containing only the translations for the new strings)
# 4.  It constructs a JSON payload containing the model name, a system prompt, and the content of the input file.
# 5.  It sends the payload to the specified API endpoint using cURL.
# 6.  It parses the JSON response to extract the translated content and saves it to the output file.
#
# Dependencies:
# - curl: For making API requests.
# - jq:   For creating and parsing JSON data.
#
# Environment Variables:
# - API_KEY: (Required) Your secret API key for the translation service.

# Exit immediately if a command exits with a non-zero status.
set -euo pipefail

[[ -f ./.env ]] && source ./.env 

# -------------------- Configuration --------------------
API_ENDPOINT=${API_ENDPOINT:-"https://api.openai.com/v1/chat/completions"}
API_MODEL=${API_MODEL:-"gpt-4o-mini"}
AUTH_HEADER="Authorization: Bearer ${API_KEY}"
PROMPT_TEMPLATE=$(cat <<'EOF'
You are an expert localization specialist tasked with translating a gettext `.po` file from English to __YOUR_LANGUAGE__.

<metadata-handling>
1. Header Entry Modifications:
   - Update file header with current translation metadata
   - Populate `Plural-Forms` field according to __YOUR_LANGUAGE__ language rules
   - Set `Language` field to "__YOUR_LANGUAGE__" with language code
   - Fill `Language-Team` with "[AI Translation Model Name]"
   - Fill `Last-Translator` with "[AI Model Version]"

2. Special Annotation Handling:
   - When `@translators` comment is present, use it as additional context for translation
   - Pay extra attention to technical or contextual hints provided in comments
</metadata-handling>

<translation-context>
- Carefully analyze the source text's context, technical terminology, and intended meaning
- Prioritize clarity, conciseness, and natural-sounding translation
- Maintain the original message's intent and technical precision
</translation-context>

<translation-guidelines>
- Ensure UI-friendly translation: clear, concise, and easily understandable
- Preserve original formatting and placeholders
- Handle technical terms consistently
- Adapt translation to __YOUR_LANGUAGE__ linguistic conventions
</translation-guidelines>

<output-requirements>
- Provide only the translated PO file content
- Do not use markdown formatting
- Maintain the original file structure
</output-requirements>

<pre-translation-process>
1. Analyze source text thoroughly
2. Identify key terminology and context
3. Develop translation strategy
4. Perform translation
5. Review for accuracy, naturalness, and technical precision
</pre-translation-process>

Proceed with the translation, ensuring high-quality, context-aware localization of the provided gettext PO file.
EOF
)

# Associative array mapping language codes to full language names.
declare -A LANG_MAP=(
  ["en"]="English"
  ["en_GB"]="English (United Kingdom)"
  ["ca"]="Catalá"
  ["cs"]="Čeština"
  ["da"]="Dansk"
  ["de"]="Deutsch"
  ["eo"]="Esperanto"
  ["es"]="Español"
  ["eu"]="Euskara"
  ["fi"]="Suomi"
  ["fr"]="Français"
  ["gl"]="Galego"
  ["it_IT"]="Italiano"
  ["he"]="עִבְרִית"
  ["hr"]="Hrvatski"
  ["hu"]="Magyar"
  ["lt_LT"]="Lietuvių"
  ["lv"]="Latviešu"
  ["nl_NL"]="Nederlands"
  ["nb_NO"]="Norsk bokmål"
  ["pl"]="Polski"
  ["pl_PL"]="Polski2"
  ["pt_PT"]="Português"
  ["pt_BR"]="Português do Brasil"
  ["ro"]="Română"
  ["ro_MD"]="Română (Moldova)"
  ["sk"]="Slovenčina"
  ["sv"]="Svenska"
  ["th"]="ภาษาไทย"
  ["vi"]="Tiếng Việt"
  ["tr"]="Türkçe"
  ["vi_VN"]="Viet Nam"
  ["ar"]="عربى"
  ["bg_BG"]="български"
  ["bn"]="বাংলা"
  ["el"]="Ελληνικά"
  ["fa"]="فارسی"
  ["hi"]="हिन्दी"
  ["ja"]="日本語"
  ["ka"]="ქართული"
  ["kk"]="Қазақ"
  ["ko_KR"]="한국어"
  ["ru"]="Русский"
  ["sr"]="Српски"
  ["uk"]="Українська"
  ["zh"]="中文"
  ["zh_CN"]="简体中文"
  ["zh_TW"]="中文（台灣)"
)

TEMPLATE_FILE="templates/koreader.pot"
# -------------------- Validation --------------------
# Check if exactly one argument (the language code) is provided.
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <LANGUAGE_CODE>" >&2
  exit 1
fi

LANG_CODE="$1"

# Check if the provided language code is in our supported list.
[[ -v LANG_MAP["$LANG_CODE"] ]] || {
  echo "Error: Language code '$LANG_CODE' not supported." >&2
  exit 1
}

# Check if the main template file exists.
[[ -f "$TEMPLATE_FILE" ]] || {
  echo "Error: Template file '$TEMPLATE_FILE' not found." >&2
  exit 1
}

# Check if the API_KEY is set in the environment.
[[ -v API_KEY ]] || {
  echo "Error: API_KEY environment variable not set." >&2
  exit 1
}

# Customize the prompt with the target language name.
LANG_FULLNAME="${LANG_MAP["$LANG_CODE"]}"
PROMPT=$(sed "s|__YOUR_LANGUAGE__|$LANG_FULLNAME|g" <<< "$PROMPT_TEMPLATE")
echo "Translation in progress for $LANG_CODE ($LANG_FULLNAME)."

# -------------------- Create directory --------------------
# Ensure the target language directory exists.
mkdir -p "$LANG_CODE"
TRANSLATED_FILE="$LANG_CODE/koreader.po"
UNTRANSLATED_FILE="$LANG_CODE/untranslated.po"
UPDATED_TRANSLATED_FILE="$LANG_CODE/updated_translated.po"

# Determine which file to use as input for translation and where to save the output.
INPUTFILE=
OUTPUTFILE=

# Scenario 1: New language translation.
# If neither a translated file nor an untranslated file exists, start from the template.
if [[ ! -f "$TRANSLATED_FILE" && ! -f "$UNTRANSLATED_FILE" ]] then
  # when the target language is untranslated
  cp "$TEMPLATE_FILE" "$UNTRANSLATED_FILE"
  INPUTFILE=$UNTRANSLATED_FILE
  OUTPUTFILE=$TRANSLATED_FILE
elif [[ -f "$TRANSLATED_FILE" && -f "$UPDATED_TRANSLATED_FILE" ]] then
  echo "the translated file exits, skip for $LANG_CODE ($LANG_FULLNAME)"
  exit 0
# Scenario 2: Updating an existing language.
# If an untranslated file exists alongside the main translated file, translate only the new strings.
elif [[ -f "$TRANSLATED_FILE" && -f "$UNTRANSLATED_FILE" ]] then
  # when target language is updated
  INPUTFILE=$UNTRANSLATED_FILE
  OUTPUTFILE=$UPDATED_TRANSLATED_FILE
else
  echo "translate file not ready for $LANG_CODE ($LANG_FULLNAME)"
  exit 1
fi


# Build the JSON payload for the API request using jq.
# - temperature: 0.2 for reproducible output
# - max_tokens: allow long .po files (some providers cap much lower by default)
# - response_format: force plain text so providers don't wrap in JSON
PAYLOAD=$(jq -n \
  --arg model "${API_MODEL}" \
  --arg content "$PROMPT" \
  --rawfile file_content "$INPUTFILE" \
  '{
     model: $model,
     temperature: 0.2,
     max_tokens: 16384,
     messages: [
       {role: "system", content: $content},
       {role: "user",    content: $file_content}
     ],
   }')

# Send the request to the API endpoint using cURL.
# Write response to a temp file rather than a shell variable (safer for large payloads).
# --retry-all-errors: retry on --max-time timeouts and any HTTP error (requires curl >= 7.71)
# --max-time 300: allow long generations for large .po files
# --retry-max-time 900: cap total time spent across retries
RESPONSE_FILE=$(mktemp -t ai_translate_${LANG_CODE}_XXXXXX.json)
CURL_LOG=$(mktemp -t ai_translate_${LANG_CODE}_XXXXXX.log)
trap 'rm -f "$RESPONSE_FILE" "$CURL_LOG"' EXIT

HTTP_CODE=$(curl -sS --retry 5 --retry-delay 5 --retry-all-errors \
  --max-time 300 --retry-max-time 900 \
  -o "$RESPONSE_FILE" -w "%{http_code}" \
  -X POST "$API_ENDPOINT" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  --data-raw "$PAYLOAD" 2> "$CURL_LOG") || {
    echo "Error: curl failed for $LANG_CODE ($LANG_FULLNAME):" >&2
    cat "$CURL_LOG" >&2
    exit 1
  }

if [[ "$HTTP_CODE" != 2* ]]; then
  echo "Error: HTTP $HTTP_CODE from API for $LANG_CODE ($LANG_FULLNAME)." >&2
  echo "Response body:" >&2
  head -c 2000 "$RESPONSE_FILE" >&2
  echo >&2
  exit 1
fi

# Validate the JSON response strictly. Any of these conditions cause a hard fail
# WITHOUT creating OUTPUTFILE, so a re-run correctly resumes this language:
#   - JSON parse error
#   - .error field present
#   - finish_reason is not "stop" (e.g. "length" -> truncated output)
#   - empty content
CONTENT=$(jq -er '
  if type != "object" then error("response is not a JSON object")
  elif has("error") then
    error("API error: " + (.error.message // (.error|tostring)))
  elif (.choices | length) == 0 then
    error("no choices in response")
  else
    (.choices[0]) as $c
    | ($c.finish_reason // "stop") as $reason
    | ($c.message.content // "") as $text
    | if $reason != "stop" and $reason != "end_turn" then
        error("truncated response: finish_reason=" + $reason)
      elif $text == "" then
        error("empty content in response")
      else
        $text
      end
  end
' "$RESPONSE_FILE") || {
    echo "Error: invalid API response for $LANG_CODE ($LANG_FULLNAME)." >&2
    echo "Response body (first 2KB):" >&2
    head -c 2000 "$RESPONSE_FILE" >&2
    echo >&2
    exit 1
  }

# Atomically write the translated content to the output file.
# Using a .tmp + mv ensures a partial/interrupted write never leaves a
# half-written OUTPUTFILE that would confuse subsequent re-runs.
printf '%s' "$CONTENT" > "$OUTPUTFILE.tmp"
mv "$OUTPUTFILE.tmp" "$OUTPUTFILE"

echo "Translation completed for $LANG_CODE ($LANG_FULLNAME)."

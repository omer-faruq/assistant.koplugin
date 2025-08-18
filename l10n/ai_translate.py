"""
AI-powered translation script for .po files using OpenAI-compatible APIs.

This script reads a .po file containing untranslated entries, sends them
to a chat completion API for translation, and saves the result to a new
.po file. It is designed to be part of a larger Makefile workflow.

Configuration is done via environment variables:
- OPENAI_API_KEY: Required. Your API key.
- OPENAI_BASE_URL: Optional. The API endpoint. Defaults to OpenAI's official URL.
- OPENAI_MODEL: Optional. The model to use. Defaults to 'gpt-5-nano'.

Usage:
    python3 ai_translate.py \
        --input-file <path_to_untranslated.po> \
        --output-file <path_to_save_translations.po> \
        --language <lang_code>
"""
import argparse
import json
import os
import sys
from datetime import datetime
from openai import OpenAI, APIError
import polib

# --- Configuration ---
DEFAULT_MODEL = "gpt-5-nano"

SYSTEM_PROMPT_TEMPLATE = """
You are an expert translator specializing in software localization for the Gettext .po file format.
Your task is to translate a list of source strings into {language_name}.
- The user will provide a JSON array of source strings (msgid).
- You MUST return a JSON object with a single key named 'translations' which contains an array of the translated strings.
- The order of the translated strings in the output array must exactly match the order of the source strings in the input array.
- The translation should be accurate, context-aware, and suitable for a user interface.
- Keep the tone natural for the target language.
- Do not return anything other than a valid JSON object with the specified structure.
"""

LANG_MAP = {
    "ar": "Arabic", "bg_BG": "Bulgarian", "bn": "Bengali", "ca": "Catalan",
    "cs": "Czech", "da": "Danish", "de": "German", "el": "Greek",
    "en": "English", "en_GB": "English (United Kingdom)", "eo": "Esperanto",
    "es": "Spanish", "eu": "Basque", "fa": "Persian", "fi": "Finnish",
    "fr": "French", "gl": "Galician", "he": "Hebrew", "hi": "Hindi",
    "hr": "Croatian", "hu": "Hungarian", "it_IT": "Italian", "ja": "Japanese",
    "ka": "Georgian", "kk": "Kazakh", "ko_KR": "Korean", "lt_LT": "Lithuanian",
    "lv": "Latvian", "nb_NO": "Norwegian Bokmål", "nl_NL": "Dutch",
    "pl": "Polish", "pl_PL": "Polish (Poland)", "pt_PT": "Portuguese", "pt_BR": "Portuguese (Brazil)",
    "ro": "Romanian", "ro_MD": "Romanian (Moldova)", "ru": "Russian",
    "sk": "Slovak", "sr": "Serbian", "sv": "Swedish", "th": "Thai",
    "tr": "Turkish", "uk": "Ukrainian", "vi": "Vietnamese", "vi_VN": "Vietnamese (Vietnam)",
    "zh": "Chinese", "zh_CN": "Simplified Chinese", "zh_TW": "Traditional Chinese (Taiwan)"
}

def main():
    """Main function to run the translation process."""
    parser = argparse.ArgumentParser(
        description="Translate .po files using an AI model as part of a Makefile workflow.",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("--input-file", required=True, help="Path to the .po file with untranslated entries.")
    parser.add_argument("--output-file", required=True, help="Path to save the translated .po file.")
    parser.add_argument("--language", required=True, help="Language code for translation (e.g., 'zh_CN').")
    args = parser.parse_args()

    # --- 1. Load Configuration ---
    api_key = os.getenv("OPENAI_API_KEY")
    base_url = os.getenv("OPENAI_BASE_URL")
    model = os.getenv("OPENAI_MODEL", DEFAULT_MODEL)

    if not api_key:
        print("Error: OPENAI_API_KEY environment variable is not set.", file=sys.stderr)
        sys.exit(1)

    language_name = LANG_MAP.get(args.language, args.language)
    print(f"Starting translation for {args.language} ({language_name}) using model {model}.")

    # --- 2. Read and Parse .po File ---
    try:
        po_file = polib.pofile(args.input_file, encoding='utf-8')
    except (FileNotFoundError, OSError) as e:
        print(f"Error: Cannot read input file '{args.input_file}': {e}", file=sys.stderr)
        sys.exit(1)

    # The input file is pre-filtered by `msgattrib`, so all entries need translation.
    entries_to_translate = list(po_file)

    if not entries_to_translate:
        print(f"No entries found in '{args.input_file}'. Creating empty output file.")
        # Create an empty output file so the make process doesn't fail
        open(args.output_file, 'w').close()
        sys.exit(0)

    source_texts = [entry.msgid for entry in entries_to_translate]
    print(f"Found {len(source_texts)} entries to translate.")

    # --- 3. Call AI for Translation ---
    try:
        client = OpenAI(api_key=api_key, base_url=base_url)
        system_prompt = SYSTEM_PROMPT_TEMPLATE.format(language_name=language_name)
        user_content = json.dumps(source_texts, ensure_ascii=False)

        print("Sending request to AI API...")
        response = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content},
            ],
            response_format={"type": "json_object"},
            temperature=0.2,
        )
        
        response_content = response.choices[0].message.content
        
        try:
            data = json.loads(response_content)
            if 'translations' not in data or not isinstance(data['translations'], list):
                raise ValueError("AI response JSON is missing 'translations' key or it's not a list.")
            translated_texts = data['translations']
        except (json.JSONDecodeError, ValueError) as e:
            print(f"Error: Could not decode or parse the AI's response.", file=sys.stderr)
            print(f"Details: {e}", file=sys.stderr)
            print("--- Raw AI Response ---", file=sys.stderr)
            print(response_content, file=sys.stderr)
            sys.exit(1)

    except APIError as e:
        print(f"Error: An API error occurred: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"An unexpected error occurred: {e}", file=sys.stderr)
        sys.exit(1)

    print("Received translations from AI.")

    # --- 4. Validate and Update .po File ---
    if len(translated_texts) != len(source_texts):
        print(f"Error: Mismatch in translation count.", file=sys.stderr)
        print(f"Expected {len(source_texts)} translations, but received {len(translated_texts)}.", file=sys.stderr)
        sys.exit(1)

    for entry, translation in zip(entries_to_translate, translated_texts):
        entry.msgstr = translation
        # Entry might be fuzzy if the source was fuzzy, let's clear the flag.
        if 'fuzzy' in entry.flags:
            entry.flags.remove('fuzzy')

    # --- 5. Update Metadata before saving ---
    try:
        print("Updating PO file metadata...")

        now_str = datetime.now().astimezone().strftime('%Y-%m-%d %H:%M%z')
        translator_str = f"AI Translator ({model})"
        
        # Update metadata dictionary
        po_file.metadata['PO-Revision-Date'] = now_str
        po_file.metadata['Last-Translator'] = translator_str
        po_file.metadata['Language-Team'] = LANG_MAP.get(args.language, args.language)
        po_file.metadata['Language'] = args.language
        
        if 'Project-Id-Version' not in po_file.metadata or not po_file.metadata['Project-Id-Version']:
             po_file.metadata['Project-Id-Version'] = 'koreader-assistant'

        print("Metadata updated successfully.")
    except Exception as e:
        print(f"Warning: Could not update PO metadata. Error: {e}", file=sys.stderr)

    # --- 6. Save Changes to Output File ---
    try:
        po_file.save(args.output_file)
        print(f"Successfully saved {len(entries_to_translate)} translations to '{args.output_file}'")
    except Exception as e:
        print(f"Error: Failed to save the output file '{args.output_file}': {e}", file=sys.stderr)
        sys.exit(1)

    print(f"--- Translation for {args.language} completed successfully! ---")

if __name__ == "__main__":
    main()

# Translation Workflow

This directory contains all files related to the localization of the Assistant plugin. The translation process is managed by a `Makefile` and uses the standard `gettext` toolchain in combination with a Python script for AI-powered translations.

## How to Update Translations (for Developers)

The entire translation pipeline can be run with a single command.

### Prerequisites

1.  **Gettext Tools**: Ensure you have `xgettext`, `msgmerge`, `msgattrib`, and `msgcat` installed. On macOS, you can install them with Homebrew: `brew install gettext`.
2.  **Python 3**: The AI translation script requires Python 3.
3.  **Python Dependencies**: Install the required libraries:
    ```bash
    pip install -r requirements.txt
    ```
4.  **API Key**: Set the `OPENAI_API_KEY` environment variable. You can also optionally set `OPENAI_BASE_URL` and `OPENAI_MODEL`.
    ```bash
    export OPENAI_API_KEY="your_api_key_here"
    ```

### Running the Workflow

To generate the template, update all language files, and translate all untranslated strings using AI, simply run:

```bash
make translate
```

This command executes the following steps in sequence:
1.  **template**: Extracts strings from the Lua source code into `templates/koreader.pot`.
2.  **update**: Merges the new template into each language's `.po` file.
3.  **extract-untranslated**: Creates a temporary `untranslated.po` file for each language.
4.  **ai-translate**: Runs the `ai_translate.py` script on each `untranslated.po` file.
5.  **import-translation**: Merges the newly translated strings and updated metadata back into the main `.po` files.
6.  **check**: Verifies the syntax of the final `.po` files.
7.  **clean**: Removes all temporary files.

## How to Contribute

### Adding a New Language

1.  **Create a directory** for the new language using its language code (e.g., `fr` for French).
    ```bash
    mkdir fr
    ```
2.  **Create an empty `.po` file** inside the new directory.
    ```bash
    touch fr/koreader.po
    ```
3.  **Add the language to the Python script**: Open `l10n/ai_translate.py` and add the new language code and its English name to the `LANG_MAP` dictionary.
4.  **Run the translation workflow**:
    ```bash
    make translate
    ```
    The new file will be automatically populated with all source strings and their AI translations.

### Correcting an Existing Translation

If you find a translation that is incorrect or could be improved:

1.  **Find the `.po` file** for the language (e.g., `l10n/fr/koreader.po`).
2.  **Edit the file** directly. Find the `msgid` (the source English string) and modify the `msgstr` (the translated string) below it.
3.  **Commit your changes**. The automated workflow is designed to not overwrite existing manual translations, so your corrections will be preserved.

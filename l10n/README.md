# Multi-language support

The plugin uses the same language translation logic as KOReader.

## How it Works

The localization process uses standard `gettext` tools (`.pot` template file and `.po` language files).

-   `templates/koreader.pot`: The template file containing all translatable strings from the source code.
-   `<LANG_CODE>/koreader.po`: The translation file for a specific language.

The `Makefile` in this directory automates most of the translation process using gettext tools.

The `AI_TRANSLATE.sh` bash script calls curl / jq to process the request for a LLM translate.

## Env and Tools

Get tools ready for the process.

```bash
apt install gettext make curl jq 
```

Create an `.env` file in the following format for LLM access.

```
API_ENDPOINT=https://api.openai.com/v1/chat/completions
API_MODEL=...MODEL...
API_KEY=...KEY...
```

## Updating Translations

When the source code changes, new strings might be added or modified. To update all language files:

```
make
```

## Language Abbreviation Table

```lua
    language_names = {
        en = "English",
        en_GB = "English (United Kingdom)",
        ca = "Catalá",
        cs = "Čeština",
        da = "Dansk",
        de = "Deutsch",
        eo = "Esperanto",
        es = "Español",
        eu = "Euskara",
        fi = "Suomi",
        fr = "Français",
        gl = "Galego",
        it_IT = "Italiano",
        he = "עִבְרִית",
        hr = "Hrvatski",
        hu = "Magyar",
        lt_LT = "Lietuvių",
        lv = "Latviešu",
        nl_NL = "Nederlands",
        nb_NO = "Norsk bokmål",
        pl = "Polski",
        pl_PL = "Polski2",
        pt_PT = "Português",
        pt_BR = "Português do Brasil",
        ro = "Română",
        ro_MD = "Română (Moldova)",
        sk = "Slovenčina",
        sv = "Svenska",
        th = "ภาษาไทย",
        vi = "Tiếng Việt",
        tr = "Türkçe",
        vi_VN = "Viet Nam",
        ar = "عربى",
        bg_BG = "български",
        bn = "বাংলা",
        el = "Ελληνικά",
        fa = "فارسی",
        hi = "हिन्दी",
        ja = "日本語",
        ka = "ქართული",
        kk = "Қазақ",
        ko_KR = "한국어",
        ru = "Русский",
        sr = "Српски",
        uk = "Українська",
        zh = "中文",
        zh_CN = "简体中文",
        zh_TW = "中文（台灣)",
    }
```

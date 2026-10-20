#!/usr/bin/env python3
"""Language tables and the offline catalogue check shared by the l10n helpers."""

from __future__ import annotations

import os
import re

import polib

# Catalogue root (l10n/); this module lives in l10n/helper/.
L10N_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Per-language translator notes, read from l10n/<lang>/ai_note.txt and appended
# to the system prompt. The file is optional and its contents are free text, so
# a native speaker can add terminology, style rules or confusion warnings for
# their own locale without touching the prompt code. Only languages that need a
# warning carry one; see load_lang_note() and l10n/README.md.
LANG_NOTE_FILE = "ai_note.txt"

# Endonym mapping for supported languages.
# Keep in sync with Makefile's LANGS variable and KOReader's l10n directory.
# Run `make check-langs` to detect drift.
LANG_MAP: dict[str, str] = {
    "af_ZA": "Afrikaans",
    "ar": "عربى",
    "be": "Беларуская",
    "bg_BG": "български",
    "bn": "বাংলা",
    "ca": "Catalá",
    "cs": "Čeština",
    "cy": "Cymraeg",
    "da": "Dansk",
    "de": "Deutsch",
    "el": "Ελληνικά",
    "eo": "Esperanto",
    "es": "Español",
    "et": "Eesti",
    "eu": "Euskara",
    "fa": "فارسی",
    "fi": "Suomi",
    "fr": "Français",
    "ga": "Gaeilge",
    "gl": "Galego",
    "he": "עִבְרִית",
    "hi": "हिन्दी",
    "hr": "Hrvatski",
    "hu": "Magyar",
    "ia": "Interlingua",
    "id": "Bahasa Indonesia",
    "ie": "Interlingue",
    "it_IT": "Italiano",
    "ja": "日本語",
    "ka": "ქართული",
    "kab": "Taqbaylit",
    "kn": "ಕನ್ನಡ",
    "ko_KR": "한국어",
    "lt_LT": "Lietuvių",
    "lv": "Latviešu",
    "mk": "Македонски",
    "ms": "Bahasa Melayu",
    "nb_NO": "Norsk bokmål",
    "nl_NL": "Nederlands",
    "nn": "Norsk nynorsk",
    "or": "ଓଡ଼ିଆ",
    "pl": "Polski",
    "pt_BR": "Português do Brasil",
    "pt_PT": "Português",
    "ro": "Română",
    "ro_MD": "Română (Moldova)",
    "ru": "Русский",
    "si": "සිංහල",
    "sk": "Slovenčina",
    "sl": "Slovenščina",
    "sr": "Српски",
    "sv": "Svenska",
    "th": "ภาษาไทย",
    "tr": "Türkçe",
    "uk": "Українська",
    "ur": "اردو",
    "uz": "Oʻzbekcha",
    "vi": "Tiếng Việt",
    "zh_CN": "简体中文",
    "zh_TW": "中文（台灣）",
}

# English name of every supported language. The endonym alone is not a safe
# language identifier for an LLM: "Slovenčina" is valid Slovak but reads
# literally as "Slovene", which sent the Slovak locale out in Slovenian for
# months (see l10n/sk/ai_note.txt). The English name is the disambiguating
# anchor and is always included in the prompt.
# Keep in sync with Makefile's LANGS and LANG_MAP; `make check-langs` verifies.
LANG_EN: dict[str, str] = {
    "af_ZA": "Afrikaans",
    "ar": "Arabic",
    "be": "Belarusian",
    "bg_BG": "Bulgarian",
    "bn": "Bengali",
    "ca": "Catalan",
    "cs": "Czech",
    "cy": "Welsh",
    "da": "Danish",
    "de": "German",
    "el": "Greek",
    "eo": "Esperanto",
    "es": "Spanish",
    "et": "Estonian",
    "eu": "Basque",
    "fa": "Persian",
    "fi": "Finnish",
    "fr": "French",
    "ga": "Irish",
    "gl": "Galician",
    "he": "Hebrew",
    "hi": "Hindi",
    "hr": "Croatian",
    "hu": "Hungarian",
    "ia": "Interlingua",
    "id": "Indonesian",
    "ie": "Interlingue",
    "it_IT": "Italian",
    "ja": "Japanese",
    "ka": "Georgian",
    "kab": "Kabyle",
    "kn": "Kannada",
    "ko_KR": "Korean",
    "lt_LT": "Lithuanian",
    "lv": "Latvian",
    "mk": "Macedonian",
    "ms": "Malay",
    "nb_NO": "Norwegian Bokmål",
    "nl_NL": "Dutch",
    "nn": "Norwegian Nynorsk",
    "or": "Odia",
    "pl": "Polish",
    "pt_BR": "Brazilian Portuguese",
    "pt_PT": "European Portuguese",
    "ro": "Romanian",
    "ro_MD": "Romanian (Moldova)",
    "ru": "Russian",
    "si": "Sinhala",
    "sk": "Slovak",
    "sl": "Slovenian",
    "sr": "Serbian",
    "sv": "Swedish",
    "th": "Thai",
    "tr": "Turkish",
    "uk": "Ukrainian",
    "ur": "Urdu",
    "uz": "Uzbek",
    "vi": "Vietnamese",
    "zh_CN": "Simplified Chinese",
    "zh_TW": "Traditional Chinese (Taiwan)",
}

# Static Plural-Forms table extracted from KOReader's official translations
# under /usr/lib/koreader/l10n/<lang>/koreader.po headers. Used when the
# Python script generates a fresh assistant.po from a .pot (scenario 1).
#
# Three entries are corrected against CLDR rather than copied from upstream:
# sk, uk and lt_LT all ship upstream as nplurals=4 with a no-op `n % 1 == 0`
# guard wrapped around the Czech three-form rule, so form 3 is unreachable.
# Each is genuinely a three-form language. gettext reads Plural-Forms from the
# header of the catalogue being loaded, and msgfmt bakes nplurals into the
# .mo, so a self-consistent header is all that matters here.
PLURAL_FORMS: dict[str, str] = {
    "af_ZA": "nplurals=2; plural=(n != 1);",
    "ar": "nplurals=6; plural=n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5;",
    "be": "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);",
    "bg_BG": "nplurals=2; plural=n != 1;",
    "bn": "nplurals=2; plural=n > 1;",
    "ca": "nplurals=2; plural=n != 1;",
    "cs": "nplurals=3; plural=((n==1) ? 0 : (n>=2 && n<=4) ? 1 : 2);",
    "cy": "nplurals=6; plural=(n==0) ? 0 : (n==1) ? 1 : (n==2) ? 2 : (n==3) ? 3 :(n==6) ? 4 : 5;",
    "da": "nplurals=2; plural=n != 1;",
    "de": "nplurals=2; plural=n != 1;",
    "el": "nplurals=2; plural=n != 1;",
    "eo": "nplurals=2; plural=n != 1;",
    "es": "nplurals=2; plural=n != 1;",
    "et": "nplurals=2; plural=n != 1;",
    "eu": "nplurals=2; plural=n != 1;",
    "fa": "nplurals=2; plural=n > 1;",
    "fi": "nplurals=2; plural=n != 1;",
    "fr": "nplurals=2; plural=n > 1;",
    "ga": "nplurals=5; plural=n==1 ? 0 : n==2 ? 1 : (n>2 && n<7) ? 2 :(n>6 && n<11) ? 3 : 4;",
    "gl": "nplurals=2; plural=n != 1;",
    "he": "nplurals=4; plural=(n == 1) ? 0 : ((n == 2) ? 1 : ((n > 10 && n % 10 == 0) ? 2 : 3));",
    "hi": "nplurals=2; plural=n > 1;",
    "hr": "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);",
    "hu": "nplurals=2; plural=n != 1;",
    "ia": "nplurals=2; plural=n != 1;",
    "id": "nplurals=1; plural=0;",
    "ie": "nplurals=2; plural=n != 1;",
    "it_IT": "nplurals=2; plural=n != 1;",
    "ja": "nplurals=1; plural=0;",
    "ka": "nplurals=2; plural=n != 1;",
    "kab": "nplurals=2; plural=n > 1;",
    "kn": "nplurals=2; plural=n > 1;",
    "ko_KR": "nplurals=1; plural=0;",
    "lt_LT": "nplurals=3; plural=((n % 10 == 1 && (n % 100 > 19 || n % 100 < 11)) ? 0 : ((n % 10 >= 2 && n % 10 <= 9) && (n % 100 > 19 || n % 100 < 11)) ? 1 : 2);",
    "lv": "nplurals=3; plural=(n % 10 == 0 || n % 100 >= 11 && n % 100 <= 19) ? 0 : ((n % 10 == 1 && n % 100 != 11) ? 1 : 2);",
    "mk": "nplurals=2; plural=n==1 || n%10==1 ? 0 : 1;",
    "ms": "nplurals=1; plural=0;",
    "nb_NO": "nplurals=2; plural=n != 1;",
    "nl_NL": "nplurals=2; plural=n != 1;",
    "nn": "nplurals=2; plural=n != 1;",
    "or": "nplurals=2; plural=n != 1;",
    "pl": "nplurals=4; plural=(n==1 ? 0 : (n%10>=2 && n%10<=4) && (n%100<12 || n%100>14) ? 1 : n!=1 && (n%10>=0 && n%10<=1) || (n%10>=5 && n%10<=9) || (n%100>=12 && n%100<=14) ? 2 : 3);",
    "pt_BR": "nplurals=2; plural=n > 1;",
    "pt_PT": "nplurals=2; plural=n != 1;",
    "ro": "nplurals=3; plural=n==1 ? 0 : (n==0 || (n%100 > 0 && n%100 < 20)) ? 1 : 2;",
    "ro_MD": "nplurals=3; plural=(n == 1) ? 0 : ((n == 0 || n != 1 && n % 100 >= 1 && n % 100 <= 19) ? 1 : 2);",
    "ru": "nplurals=4; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : n%10==0 || (n%10>=5 && n%10<=9) || (n%100>=11 && n%100<=14)? 2 : 3);",
    "si": "nplurals=2; plural=n > 1;",
    "sk": "nplurals=3; plural=((n==1) ? 0 : (n>=2 && n<=4) ? 1 : 2);",
    "sl": "nplurals=4; plural=n%100==1 ? 0 : n%100==2 ? 1 : n%100==3 || n%100==4 ? 2 : 3;",
    "sr": "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);",
    "sv": "nplurals=2; plural=n != 1;",
    "th": "nplurals=1; plural=0;",
    "tr": "nplurals=2; plural=n > 1;",
    "uk": "nplurals=3; plural=((n % 1 == 0 && n % 10 == 1 && n % 100 != 11) ? 0 : (n % 1 == 0 && n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14)) ? 1 : 2);",
    "ur": "nplurals=2; plural=n != 1;",
    "uz": "nplurals=2; plural=n != 1;",
    "vi": "nplurals=1; plural=0;",
    "zh_CN": "nplurals=1; plural=0;",
    "zh_TW": "nplurals=1; plural=0;",
}

# -------------------- Static data check --------------------

def catalogue_codes() -> list[str]:
    """Locales that ship an assistant.po catalogue, sorted."""
    return [name for name in sorted(os.listdir(L10N_DIR))
            if os.path.isfile(os.path.join(L10N_DIR, name, "assistant.po"))]


def check_data() -> int:
    """Validate the static language tables against the catalogues on disk.

    Offline and deterministic: it reads LANG_MAP, LANG_EN, PLURAL_FORMS and the
    per-locale assistant.po headers, so it needs no SDK, API key or .env. It
    verifies:
      - LANG_MAP, LANG_EN and PLURAL_FORMS all cover the same set of locales
      - every .po header agrees with PLURAL_FORMS on nplurals (msgfmt enforces
        this too, but the message here names the language)
      - every plural entry declares exactly nplurals forms
      - which locales ship a translator note
    """
    ok = True
    codes = catalogue_codes()
    missing_en = sorted(set(LANG_MAP) - set(LANG_EN))
    missing_pf = sorted(set(LANG_MAP) - set(PLURAL_FORMS))
    extra_en = sorted(set(LANG_EN) - set(LANG_MAP))
    on_disk_only = sorted(set(codes) - set(LANG_MAP))
    for label, vals in (("LANG_MAP without LANG_EN", missing_en),
                        ("LANG_MAP without PLURAL_FORMS", missing_pf),
                        ("LANG_EN without LANG_MAP", extra_en),
                        ("catalogue without LANG_MAP", on_disk_only)):
        if vals:
            ok = False
            print(f"FAIL {label}: {', '.join(vals)}")

    print("plural forms (PLURAL_FORMS vs the .po header):")
    for lang in codes:
        want = PLURAL_FORMS.get(lang)
        if not want:
            continue
        want_n = re.search(r"nplurals\s*=\s*(\d+)", want)
        have = polib.pofile(os.path.join(L10N_DIR, lang, "assistant.po"))
        have_pf = have.metadata.get("Plural-Forms", "")
        have_n = re.search(r"nplurals\s*=\s*(\d+)", have_pf)
        if not have_n or not want_n:
            ok = False
            print(f"  FAIL {lang}: header has no nplurals")
        elif have_n.group(1) != want_n.group(1):
            ok = False
            print(f"  FAIL {lang}: header nplurals={have_n.group(1)} but "
                  f"PLURAL_FORMS says {want_n.group(1)}")
        # nplurals must also match the number of forms actually present
        for e in have:
            if e.msgid_plural and len(e.msgstr_plural) != int(want_n.group(1)):
                ok = False
                print(f"  FAIL {lang}: {e.msgid[:40]!r} has "
                      f"{len(e.msgstr_plural)} forms, expected "
                      f"{want_n.group(1)}")

    notes = sorted(d for d in codes
                   if os.path.isfile(os.path.join(L10N_DIR, d, LANG_NOTE_FILE)))
    print(f"\nlanguages with a translator note ({len(notes)}): "
          f"{', '.join(notes) or 'none'}")
    print("OK" if ok else "FAILED")
    return 0 if ok else 1

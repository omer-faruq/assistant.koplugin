# ── Variables ─────────────────────────────────────────────────────────
DOMAIN        = assistant
TEMPLATE_DIR  = templates

MSGINIT_BIN   = msginit
MSGFMT_BIN    = msgfmt
MSGMERGE_BIN  = msgmerge
MSGATTRIB_BIN = msgattrib
XGETTEXT_BIN  = xgettext

# Shared xgettext options so `template` (writes templates/$(DOMAIN).pot) and
# `stats` (extracts into a temp dir) always agree on what counts as a string.
XGETTEXT_OPTS = --from-code=utf-8 \
	--keyword=C_:1c,2 --keyword=N_:1,2 --keyword=NC_:1c,2,3 \
	--add-comments=@translators \
	--package-name=assistant.koplugin \
	--no-wrap \
	--no-location \
	--sort-by-file \
	--package-version=$(shell grep version ../_meta.lua | grep -Eo '[0-9.]+')

# Ordered cheap -> expensive for the AI translator. Primary key is nplurals
# (1 -> 6): the prompt demands msgstr_plural arrays of exactly nplurals
# non-empty forms, and a mismatch fails the whole 20-entry chunk (up to 3
# retries); high-nplurals languages also overflow AI_MAX_TOKENS sooner and
# fall into the bisect/boosted-token path. That is why ga (5) / ar, cy (6) /
# ka stall in practice -- they sit at the tail now. Secondary key inside each
# tier is script token efficiency + model resource level. ai-translate builds
# its job queue in this order, so workers finish the cheap languages before
# grinding through the stall-prone tail. check-langs sorts both sides, so
# this order never affects drift checks.
LANGS      := zh_CN zh_TW ja id ms ko_KR vi th \
         es pt_BR pt_PT ca gl fr it_IT nl_NL de sv da nb_NO nn af_ZA eo ia fi et hu eu tr uz bg_BG mk el fa hi ur bn ie kab si kn or ka \
         cs hr sr ro ro_MD lv be \
         pl sk sl ru uk lt_LT he \
         ga cy ar
MO_FILES   := $(LANGS:%=%/$(DOMAIN).mo)
PO_FILES   := $(wildcard */$(DOMAIN).po)

# Locales opted into the LLM review: a LANGS entry that ships both a
# review_note.txt (the per-locale guidance the reviewer needs) and a committed
# catalogue. Derived once at parse time so the pipeline and the review targets
# agree on the same set; a locale without a note is never reviewed.
REVIEW_HOOKED := $(strip $(foreach lang,$(LANGS),$(if $(wildcard $(lang)/review_note.txt),$(if $(wildcard $(lang)/$(DOMAIN).po),$(lang)))))

# Effective parallelism for ai-translate.
# Priority: explicit -jN / --jobs=N on the command line > bare -j (nproc) > 4.
# GNU Make 4.4's .MAKEFLAGS directive does not actually inject a default
# -jN into MAKEFLAGS when the user didn't pass one, so we extract the
# effective value from MAKEFLAGS ourselves and pass it explicitly to the
# xargs worker pool.
JOBS := $(shell echo '$(MAKEFLAGS)' | sed -nE 's/.*-j ?([0-9]+).*/\1/p' | head -1)
ifeq ($(JOBS),)
JOBS := $(shell if echo '$(MAKEFLAGS)' | grep -qE ' (-j|--jobs)( |$$)'; then nproc; else echo 4; fi)
endif

# Stable `l10n`+alphanumeric session id per make run, shared by parallel jobs.
# Sent as `x-opencode-session` only for opencode.ai endpoints.
RANDOM_SESSION_ID ?= $(shell python3 -c "import secrets, string; print('l10n' + ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(12)))")
export RANDOM_SESSION_ID

# ── Targets ───────────────────────────────────────────────────────────

.DEFAULT_GOAL := all

.PHONY: help all translate template update ai-translate check check-langs check-api stats clean init-dirs mo retranslate-fuzzy retranslate-msgid review-translations review-hooked

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "  mo              Compile .po -> .mo (offline, incremental)"
	@echo "  translate       Full pipeline: template -> update -> ai-translate -> review -> check -> clean -> mo (needs .env)"
	@echo "  template        Regenerate templates/assistant.pot"
	@echo "  update          Merge pot into po"
	@echo "  check           msgfmt --check"
	@echo "  check-api       Ping configured API endpoint"
	@echo "  check-langs     Detect drift vs KOReader supported languages"
	@echo "  stats           Estimate untranslated strings from current source (read-only)"
	@echo "  clean           Remove transient translation files"
	@echo "  ai-translate    Run AI translation (all or L10N_LANG=xx)"
	@echo "  retranslate-fuzzy  Re-translate fuzzy entries (all or L10N_LANG=xx)"
	@echo "  retranslate-msgid  Empty one MSGID everywhere and re-translate it: make retranslate-msgid MSGID=\"...\" [L10N_LANG=xx]"
	@echo "  review-translations  Review the entries changed by this run in every note-hooked locale (run by translate)"
	@echo "  review-hooked   Read-only full-catalogue audit of every note-hooked locale (chunked reviewer pass each, no writes)"
	@echo "  init-dirs       Create missing language directories"

# Default target: full pipeline + MO compilation (virtual)
all: translate

# Compile .po files to .mo files
%.mo: %.po
	@mkdir -p $(dir $@)
	@$(MSGFMT_BIN) --no-hash -o $@ $<

mo: $(MO_FILES)

# This target runs the full translation pipeline:
# 1. Extracts strings from source code into a .pot template.
# 2. Merges the template into each language .po (msgmerge).
# 3. Translates empty and fuzzy entries in each .po in place.
# 4. Reviews the entries changed by this run with a second model and refills
#    flagged entries.
# 5. Checks the syntax of the final .po files.
# 6. Removes transient files.
# 7. Compiles the final .po files into .mo files.
translate:
	@if [ ! -f .env ]; then \
		echo "\033[0;31mError: AI access environment file \`.env' is not found.\033[0m"; \
		echo "Please set it before running translation. See: README.md"; \
		exit 1; \
	fi
	@echo "[1/7] Generating POT template file..."
	@$(MAKE) template
	@echo "[2/7] Merging POT file into PO files..."
	@$(MAKE) update
	@echo "[3/7] Translating empty and fuzzy entries..."
	@$(MAKE) ai-translate
	@echo "[4/7] Reviewing changed entries of note-hooked locales..."
	@$(MAKE) review-translations
	@echo "[5/7] Checking PO files..."
	@$(MAKE) check
	@echo "[6/7] Cleaning transient files..."
	@$(MAKE) clean
	@echo "[7/7] Compiling .mo files..."
	@$(MAKE) mo
	@echo "\nTranslation process completed successfully!"


# LLM review of the entries changed by this translation run, run by `translate`
# after ai-translate. A locale opts in by shipping l10n/<lang>/review_note.txt
# (REVIEW_HOOKED); ai-translate leaves <lang>/assistant.po.pre-ai as the
# pre-run snapshot, so the reviewer sees only the entries this run changed
# instead of re-reviewing the whole catalogue. A repair verdict that survives
# the refill stops the run before check, with the catalogue preserved; a setup
# failure (no note, no credential, timeout, invalid reply) only warns and keeps
# the AI output.
review-translations:
	@set -e; \
	for lang in $(REVIEW_HOOKED); do \
		if [ -n "$(L10N_LANG)" ] && [ "$$lang" != "$(L10N_LANG)" ]; then continue; fi; \
		if [ ! -f "$$lang/$(DOMAIN).po.pre-ai" ]; then \
			echo "  [review] $$lang: no pre-run snapshot; run 'make ai-translate' first; skipping."; \
			continue; \
		fi; \
		echo "  [review] reviewing changed entries of $$lang/$(DOMAIN).po..."; \
		if ! ./helper/review_translations.py --lang $$lang --changed-from "$$lang/$(DOMAIN).po.pre-ai"; then \
			echo "\033[0;31m[review] $$lang: repair verdicts survived the refill; stopping before check (catalogue preserved).\033[0m"; \
			exit 1; \
		fi; \
	done

# Read-only full-catalogue audit of every hooked locale: one chunked reviewer
# pass per <lang>/assistant.po, no writes to any file. For the historical
# contamination audit; the normal `make` never scans the whole old catalogue.
review-hooked:
	@set -e; \
		if [ -z "$(REVIEW_HOOKED)" ]; then \
			echo "  [review] no locale ships a review_note.txt; nothing to audit."; \
			exit 0; \
		fi; \
		for lang in $(REVIEW_HOOKED); do \
			echo "  [review] full read-only audit of $$lang/$(DOMAIN).po..."; \
			./helper/review_translations.py --lang $$lang --full; \
		done

init-dirs: template
	@echo "Ensuring language directories and initial .po files exist..."
	@for lang in $(LANGS); do \
		if [ ! -f "$$lang/$(DOMAIN).po" ]; then \
			echo "Initializing language: $$lang"; \
			mkdir -p $$lang; \
			$(MSGINIT_BIN) -l $$lang --no-translator -i $(TEMPLATE_DIR)/$(DOMAIN).pot -o $$lang/$(DOMAIN).po; \
		fi; \
	done

# Merge the fresh POT into every catalogue. msgmerge keeps existing translations
# and marks changed entries fuzzy, which is the state the translator consumes.
# msgattrib drops obsolete entries so the committed catalogues stay clean.
update: init-dirs
	@set -e; for lang in $(LANGS); do \
		po_file="$$lang/$(DOMAIN).po"; \
		$(MSGMERGE_BIN) --update --backup=none --no-wrap --no-location --sort-by-file "$$po_file" $(TEMPLATE_DIR)/$(DOMAIN).pot; \
		$(MSGATTRIB_BIN) --no-obsolete --no-wrap --no-location --sort-by-file "$$po_file" -o "$$po_file.tmp"; \
		mv "$$po_file.tmp" "$$po_file"; \
	done

check:
	@echo "Checking syntax of existing .po files..."
	@rc=0; has_fuzzy=0; \
	for po_file in $(PO_FILES); do \
		dir=$$(dirname $$po_file); printf "%-8s" "$$dir"; \
		out=$$( $(MSGFMT_BIN) -v --check -o /dev/null $$po_file 2>&1 ); \
		echo "$$out"; \
		echo "$$out" | grep -q "fuzzy" && has_fuzzy=1; \
		$(MSGFMT_BIN) --check -o /dev/null $$po_file 2>/dev/null || rc=1; \
	done; \
	if [ $$has_fuzzy -eq 1 ]; then \
		echo "\033[0;33mHint: fuzzy translations found. Run 'make retranslate-fuzzy' or 'L10N_LANG=xx make retranslate-fuzzy' to re-translate.\033[0m"; \
	fi; \
	exit $$rc

# Send a minimal ping to the configured API endpoint to verify connectivity,
# authentication, and model availability. Useful for debugging before running
# a full translation batch.
check-api:
	@./helper/ai_translate.py --check-api

# Detect drift between this project's supported languages and KOReader's.
# - Set KOREADER_L10N_DIR to override the default reference path.
# - Also verifies LANGS (Makefile) is consistent with LANG_MAP (helper/lang_data.py).
# Read-only: this target never modifies any files.
check-langs:
	@ref="$(KOREADER_L10N_DIR)"; \
	[ -z "$$ref" ] && ref=/usr/lib/koreader/l10n; \
	tmp=$$(mktemp -d) && trap "rm -rf $$tmp" EXIT; \
	echo "$(LANGS)" | tr ' ' '\n' | sort -u > "$$tmp/langs"; \
	python3 -c "import sys; sys.path.insert(0, 'helper'); from lang_data import LANG_MAP; [print(k) for k in LANG_MAP]" \
		| sort -u > "$$tmp/map"; \
	rc=0; \
	if [ ! -d "$$ref" ]; then \
		echo "\033[0;33mKOReader l10n dir '$$ref' not found; skipping KOReader comparison.\033[0m"; \
	else \
		ls "$$ref" | sort -u > "$$tmp/kor"; \
		missing=$$(comm -23 "$$tmp/kor" "$$tmp/langs"); \
		extra=$$(comm -13 "$$tmp/kor" "$$tmp/langs"); \
		if [ -n "$$missing" ]; then \
			echo "\033[0;33mLanguages in KOReader but NOT in this project:\033[0m"; \
			echo "$$missing" | sed 's/^/  /'; \
		fi; \
		if [ -n "$$extra" ]; then \
			echo "\033[0;33mLanguages in this project but NOT in KOReader:\033[0m"; \
			echo "$$extra" | sed 's/^/  /'; \
		fi; \
		if [ -z "$$missing" ] && [ -z "$$extra" ]; then \
			echo "LANGS is in sync with KOReader ($$ref)."; \
		fi; \
	fi; \
	only_map=$$(comm -23 "$$tmp/map" "$$tmp/langs"); \
	only_langs=$$(comm -13 "$$tmp/map" "$$tmp/langs"); \
	if [ -n "$$only_map" ] || [ -n "$$only_langs" ]; then \
		echo "\033[0;31mLANG_MAP (helper/lang_data.py) is out of sync with LANGS (Makefile):\033[0m"; \
		[ -n "$$only_map" ]   && { echo "  Only in LANG_MAP:"; echo "$$only_map"   | sed 's/^/    /'; }; \
		[ -n "$$only_langs" ] && { echo "  Only in LANGS:";    echo "$$only_langs" | sed 's/^/    /'; }; \
		rc=1; \
	else \
		echo "LANG_MAP and LANGS are consistent."; \
	fi; \
	echo "Checking LANG_MAP / LANG_EN / PLURAL_FORMS consistency..."; \
	./helper/ai_translate.py --check-data || rc=1; \
	exit $$rc

# Read-only estimate of the translation workload introduced by the current
# source tree. Extracts a fresh POT straight from the Lua sources into a temp
# dir, merges it into a temp copy of every .po, and reports how many entries
# each language still needs. Nothing in the repo is written, so a committed
# POT/.po is neither required nor updated. Use it to decide whether a
# translation run is worth the token cost.
stats:
	@tmp=$$(mktemp -d) && trap "rm -rf $$tmp" EXIT; \
	echo "Extracting strings from source..."; \
	LC_ALL=C $(XGETTEXT_BIN) $(XGETTEXT_OPTS) \
		`find .. -type f -name "*.lua" | sort` \
		-o "$$tmp/$(DOMAIN).pot" || exit 1; \
	src_n=$$(grep -c '^msgid ' "$$tmp/$(DOMAIN).pot"); \
	src_n=$$((src_n - 1)); \
	echo "Source msgids: $$src_n"; \
	printf "%-8s %7s %7s %13s\n" "LANG" "DONE%" "FUZZY" "UNTRANSLATED"; \
	tt=0; tf=0; tu=0; touched=0; maxu=0; \
	for po_file in $(PO_FILES); do \
		dir=$$(dirname $$po_file); \
		if ! LC_ALL=C $(MSGMERGE_BIN) --quiet --no-wrap --no-location "$$po_file" "$$tmp/$(DOMAIN).pot" -o "$$tmp/merged.po" 2>/dev/null; then \
			echo "$$dir: merge failed, skipped"; continue; \
		fi; \
		stats=$$(LC_ALL=C $(MSGFMT_BIN) --statistics -o /dev/null "$$tmp/merged.po" 2>&1); \
		t=$$(echo "$$stats" | grep -oE '[0-9]+ translated' | grep -oE '[0-9]+' | head -1); \
		f=$$(echo "$$stats" | grep -oE '[0-9]+ fuzzy' | grep -oE '[0-9]+' | head -1); \
		u=$$(echo "$$stats" | grep -oE '[0-9]+ untranslated' | grep -oE '[0-9]+' | head -1); \
		t=$${t:-0}; f=$${f:-0}; u=$${u:-0}; \
		total=$$((t+f+u)); pct=0; [ $$total -gt 0 ] && pct=$$((t*100/total)); \
		printf "%-8s %6d%% %7d %13d\n" "$$dir" "$$pct" "$$f" "$$u"; \
		tt=$$((tt+t)); tf=$$((tf+f)); tu=$$((tu+u)); \
		if [ $$((f+u)) -gt 0 ]; then touched=$$((touched+1)); fi; \
		if [ $$((f+u)) -gt $$maxu ]; then maxu=$$((f+u)); fi; \
	done; \
	grand=$$((tt+tf+tu)); gpct=0; [ $$grand -gt 0 ] && gpct=$$((tt*100/grand)); \
	echo "----------------------------------------------------------"; \
	printf "%-8s %6d%% %7d %13d\n" "TOTAL" "$$gpct" "$$tf" "$$tu"; \
	echo "Remaining: $$((tu+tf)) entries across $$touched language(s), up to $$maxu per language."

# Remove transient files left by a run: resumable partials, pre-translation
# snapshots used by the reviewer, and the legacy intermediate .po files from
# the old extract/import pipeline.
clean:
	@echo "Cleaning transient translation files..."
	@find . -type f \( \
		-name '*.partial' -o -name '*.pre-ai' -o -name '*.review-orig' \
		-o -name 'untranslated.po' -o -name '_untranslated.po' -o -name '_fuzzy.po' \
		-o -name 'updated_translated.po' -o -name 'updated.po' -o -name '*.po.tmp' \
	\) -print -delete

# Translate every selected locale in place. The pre-translation copy is what
# `review-translations` diffs against, so the reviewer only sees entries this
# run touched; keeping an existing .pre-ai preserves that baseline across a
# resumed run until `clean` removes it.
ai-translate:
	@set -e; \
	langs="$(LANGS)"; \
	if [ -n "$(L10N_LANG)" ]; then langs="$(L10N_LANG)"; fi; \
	for lang in $$langs; do \
		if [ -f "$$lang/$(DOMAIN).po" ] && [ ! -f "$$lang/$(DOMAIN).po.pre-ai" ]; then \
			cp "$$lang/$(DOMAIN).po" "$$lang/$(DOMAIN).po.pre-ai"; \
		fi; \
	done; \
	echo "$$langs" | tr ' ' '\n' | xargs -r -P $(JOBS) -n1 ./helper/ai_translate.py

# Fuzzy entries (msgmerge's "needs review" marker) are part of the normal
# pending set, so a plain translation run re-translates them.
retranslate-fuzzy:
	@echo "Re-translating fuzzy entries..."
	@$(MAKE) ai-translate
	@$(MAKE) check || true
	@$(MAKE) clean

# Empty one exact MSGID in every (or one L10N_LANG) .po file and run the
# translator once to refill it, so a terminology fix is retranslated by the
# script instead of hand-edited in 60 files. Needs .env (ai-translate step).
retranslate-msgid:
	@if [ -z "$(MSGID)" ]; then \
		echo "Usage: make retranslate-msgid MSGID=\"<exact msgid>\" [L10N_LANG=xx]"; \
		exit 1; \
	fi
	@echo "Emptying msgid for retranslation: $(MSGID)"
	@for lang in $(LANGS); do \
		if [ -n "$(L10N_LANG)" ] && [ "$$lang" != "$(L10N_LANG)" ]; then continue; fi; \
		./helper/retranslate_msgid.py "$$lang" "$(MSGID)" || exit 1; \
	done
	@$(MAKE) ai-translate
	@echo "Refilled; running 'make check'..."
	@$(MAKE) check || true
	@$(MAKE) clean
	@echo "Compiling .mo files..."
	@$(MAKE) mo



template:
	mkdir -p $(TEMPLATE_DIR)
	$(XGETTEXT_BIN) $(XGETTEXT_OPTS) \
		`find .. -type f -name "*.lua" | sort` \
		-o $(TEMPLATE_DIR)/$(DOMAIN).pot

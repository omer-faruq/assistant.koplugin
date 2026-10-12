# ── Variables ─────────────────────────────────────────────────────────
DOMAIN        = assistant
TEMPLATE_DIR  = templates

MSGINIT_BIN   = msginit
MSGFMT_BIN    = msgfmt
MSGMERGE_BIN  = msgmerge
MSGATTRIB_BIN = msgattrib
MSGCAT_BIN    = msgcat
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

# Locales that opt into the Jev check: they ship both a catalogue and
# the per-locale hook l10n/<lang>/jev_note.txt, and are a supported LANGS entry.
# `translate` loops exactly these; a locale without the hook is never contacted.
JEV_HOOKED := $(shell for lang in $(LANGS); do if [ -f "$$lang/$(DOMAIN).po" ] && [ -f "$$lang/jev_note.txt" ]; then echo $$lang; fi; done)

# Per-locale pattern targets, expanded here so .PHONY names every concrete
# target make derives from a pattern rule (the pattern itself cannot be listed).
EXTRACT_LOCALE_TARGETS := $(patsubst %/$(DOMAIN).po,extract-untranslated-%,$(PO_FILES))
IMPORT_LOCALE_TARGETS  := $(patsubst %/$(DOMAIN).po,import-translation-%,$(PO_FILES))
AI_TRANSLATE_TARGETS   := $(LANGS:%=ai-translate-%)

# Effective parallelism for ai-translate.
# Priority: explicit -jN / --jobs=N on the command line > bare -j (nproc) > 4.
# GNU Make 4.4's .MAKEFLAGS directive does not actually inject a default
# -jN into MAKEFLAGS when the user didn't pass one, so we extract the
# effective value from MAKEFLAGS ourselves and pass it explicitly to the
# sub-make.
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

.PHONY: help all translate template update extract-untranslated ai-translate check-ai-results import-translation check check-langs check-mix check-api stats clean init-dirs mo retranslate-fuzzy retranslate-msgid retranslate-jev jev-check-translated \
	$(EXTRACT_LOCALE_TARGETS) $(IMPORT_LOCALE_TARGETS) $(AI_TRANSLATE_TARGETS)

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "  mo              Compile .po -> .mo (offline, incremental)"
	@echo "  translate       Full pipeline: template -> update -> extract -> ai-translate -> jev-check -> import -> check -> clean -> mo (needs .env)"
	@echo "  template        Regenerate templates/assistant.pot"
	@echo "  update          Merge pot into po"
	@echo "  check           msgfmt --check"
	@echo "  check-api       Ping configured API endpoint"
	@echo "  check-langs     Detect drift vs KOReader supported languages"
	@echo "  check-mix       Detect translations written in the wrong language"
	@echo "  stats           Estimate untranslated strings from current source (read-only)"
	@echo "  clean           Remove intermediate files"
	@echo "  ai-translate    Run AI translation (all or L10N_LANG=xx)"
	@echo "  retranslate-fuzzy  Re-extract and re-translate fuzzy entries (all or L10N_LANG=xx)"
	@echo "  retranslate-msgid  Empty one MSGID everywhere and re-translate it: make retranslate-msgid MSGID=\"...\" [L10N_LANG=xx]"
	@echo "  retranslate-jev  Refill one locale after check_mix.py --jev --retranslate-jev emptied it: make retranslate-jev L10N_LANG=xx"
	@echo "  jev-check-translated  Jev-check AI output and retranslate flagged entries for hooked locales (run by translate)"
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
# 2. Merges the template into language .po files.
# 3. Extracts all untranslated strings.
# 4. Runs the AI translation script on them, writing updated_translated.po.
# 5. Jev-checks that output and refills the entries it flags (hooked locales).
# 6. Merges the new translations back into the .po files.
# 7. Checks the syntax of the final .po files.
# 8. Cleans up all intermediate files.
# 9. Compiles the final .po files into .mo files.
translate:
	@if [ ! -f .env ]; then \
		echo "\033[0;31mError: AI access environment file \`.env' is not found.\033[0m"; \
		echo "Please set it before running translation. See: README.md"; \
		exit 1; \
	fi
	@echo "[1/9] Generating POT template file..."
	@$(MAKE) template
	@echo "[2/9] Merging POT file into PO files..."
	@$(MAKE) update
	@echo "[3/9] Generating untranslated files..."
	@$(MAKE) extract-untranslated
	@echo "[4/9] Running AI translation and verifying results..."
	@$(MAKE) ai-translate
	@echo "[5/9] Jev-checking AI output (hooked locales)..."
	@$(MAKE) jev-check-translated
	@echo "[6/9] Merging untranslated files..."
	@$(MAKE) import-translation
	@echo "[7/9] Checking PO files..."
	@$(MAKE) check
	@echo "[8/9] Cleaning up intermediate files..."
	@$(MAKE) clean
	@echo "[9/9] Compiling .mo files..."
	@$(MAKE) mo
	@echo "\nTranslation process completed successfully!"


# Jev check of the AI output, run by `translate` after ai-translate and before
# import-translation. For every hooked locale it audits <lang>/updated_translated.po
# and empties the msgstr the classifier confidently places in the peer language.
# If anything was emptied, the catalogue goes back through ai_translate.py as its
# untranslated input: only empty msgstr are filled, so good translations are kept
# and the flagged ones are retranslated. The result replaces updated_translated.po,
# so import-translation picks up the corrected version. A Jev audit failure only
# warns and keeps the AI output; a failed refill stops the run like any other
# ai-translate failure. Only locales that ship l10n/<lang>/jev_note.txt are looped.
jev-check-translated:
	@set -e; \
		if [ -z "$(JEV_HOOKED)" ]; then \
			echo "No locale ships a Jev hook; skipping the Jev check."; \
		else \
			for lang in $(JEV_HOOKED); do \
				if [ ! -f "$$lang/updated_translated.po" ]; then \
					echo "  [jev] $$lang: no updated_translated.po this run; nothing to check."; \
					continue; \
				fi; \
				echo "  [jev] checking $$lang/updated_translated.po..."; \
				if ! ./check_mix.py --jev $$lang --jev-clear-only --intermediate; then \
					echo "\033[0;33m[jev] check for $$lang failed; keeping the AI output.\033[0m"; \
					continue; \
				fi; \
				cleared=$$(LC_ALL=C $(MSGFMT_BIN) --statistics -o /dev/null "$$lang/updated_translated.po" 2>&1 | grep -oE '[0-9]+ untranslated' | grep -oE '[0-9]+' | head -1); \
				if [ "$${cleared:-0}" -gt 0 ]; then \
					echo "  [jev] $$lang: $$cleared entries cleared; retranslating them."; \
					mv "$$lang/updated_translated.po" "$$lang/untranslated.po"; \
					./ai_translate.py $$lang; \
				fi; \
			done; \
		fi

init-dirs: template
	@echo "Ensuring language directories and initial .po files exist..."
	@for lang in $(LANGS); do \
		if [ ! -f "$$lang/$(DOMAIN).po" ]; then \
			echo "Initializing language: $$lang"; \
			mkdir -p $$lang; \
			$(MSGINIT_BIN) -l $$lang --no-translator -i $(TEMPLATE_DIR)/$(DOMAIN).pot -o $$lang/$(DOMAIN).po; \
		fi; \
	done

update: init-dirs
	@set -x;for po_file in $(PO_FILES); do \
		$(MSGMERGE_BIN) --update --backup=none --no-wrap --no-location --sort-by-file $$po_file $(TEMPLATE_DIR)/$(DOMAIN).pot; \
	done

# Regenerate <dir>/untranslated.po when it is missing *or older than* the
# catalogue it was derived from. Testing only for existence left a stale file
# behind after a run that refilled assistant.po, and the next run then queued
# entries that were already translated.
#
# The aggregate composes the per-locale pattern target for every catalogue, so
# a single-locale refill (retranslate-jev) reuses the same recipe without
# touching any other locale's intermediate files.
extract-untranslated: $(EXTRACT_LOCALE_TARGETS)

# The recipe is shared by the static rule (concrete locales known at parse time,
# so .PHONY applies) and the implicit pattern rule (a brand-new locale the
# pipeline is creating, not yet in PO_FILES).
define EXTRACT_UNTRANSLATED_RECIPE
	@set -e; dir=$*; \
	if [ ! -f "$$dir/$(DOMAIN).po" ]; then \
		echo "No catalogue $$dir/$(DOMAIN).po yet; skipping extraction for a new locale."; \
	elif [ ! -f "$$dir/untranslated.po" ] || [ "$$dir/$(DOMAIN).po" -nt "$$dir/untranslated.po" ]; then \
		$(MSGATTRIB_BIN) --no-wrap --no-location --untranslated --force-po "$$dir/$(DOMAIN).po" -o "$$dir/_untranslated.po"; \
		$(MSGATTRIB_BIN) --no-wrap --no-location --fuzzy --clear-fuzzy --empty --force-po "$$dir/$(DOMAIN).po" -o "$$dir/_fuzzy.po"; \
		$(MSGCAT_BIN) --no-wrap --no-location --use-first "$$dir/_untranslated.po" "$$dir/_fuzzy.po" -o "$$dir/untranslated.po"; \
	else \
		echo "Skipping extraction for $$dir, untranslated.po is up to date."; \
	fi
endef

# Static pattern rule: each concrete locale target gets an explicit rule (so
# .PHONY applies without disabling it) while `$*` still carries the locale.
$(EXTRACT_LOCALE_TARGETS): extract-untranslated-%:
	$(EXTRACT_UNTRANSLATED_RECIPE)

extract-untranslated-%:
	$(EXTRACT_UNTRANSLATED_RECIPE)

# The aggregate imports every locale's updated_translated.po. The pattern rule
# below is the same work scoped to one locale, so a single-locale refill never
# imports another locale's leftover intermediates.
import-translation: $(IMPORT_LOCALE_TARGETS)

define IMPORT_TRANSLATION_RECIPE
	@set -e; lang=$*; \
	if [ ! -f "$$lang/$(DOMAIN).po" ]; then \
		echo "\033[0;31mError: no catalogue $$lang/$(DOMAIN).po to import into.\033[0m"; exit 1; \
	fi; \
	if [ -f "$$lang/updated_translated.po" ]; then \
		tmp="$$lang/$(DOMAIN).po.new"; \
		$(MSGCAT_BIN) --no-location --no-wrap --use-first --sort-output "$$lang/updated_translated.po" "$$lang/$(DOMAIN).po" -o "$$lang/updated.po"; \
		$(MSGATTRIB_BIN) --no-obsolete --no-wrap --no-location --sort-by-file "$$lang/updated.po" -o "$$tmp"; \
		mv "$$tmp" "$$lang/$(DOMAIN).po"; \
		rm -f "$$lang/updated.po"; \
	fi
endef

$(IMPORT_LOCALE_TARGETS): import-translation-%:
	$(IMPORT_TRANSLATION_RECIPE)

import-translation-%:
	$(IMPORT_TRANSLATION_RECIPE)

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
	@./ai_translate.py --check-api

# Detect drift between this project's supported languages and KOReader's.
# - Set KOREADER_L10N_DIR to override the default reference path.
# - Also verifies LANGS (Makefile) is consistent with LANG_MAP (ai_translate.py).
# Read-only: this target never modifies any files.
check-langs:
	@ref="$(KOREADER_L10N_DIR)"; \
	[ -z "$$ref" ] && ref=/usr/lib/koreader/l10n; \
	tmp=$$(mktemp -d) && trap "rm -rf $$tmp" EXIT; \
	echo "$(LANGS)" | tr ' ' '\n' | sort -u > "$$tmp/langs"; \
	python3 -c "from ai_translate import LANG_MAP; [print(k) for k in LANG_MAP]" \
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
		echo "\033[0;31mLANG_MAP (ai_translate.py) is out of sync with LANGS (Makefile):\033[0m"; \
		[ -n "$$only_map" ]   && { echo "  Only in LANG_MAP:"; echo "$$only_map"   | sed 's/^/    /'; }; \
		[ -n "$$only_langs" ] && { echo "  Only in LANGS:";    echo "$$only_langs" | sed 's/^/    /'; }; \
		rc=1; \
	else \
		echo "LANG_MAP and LANGS are consistent."; \
	fi; \
	echo "Checking LANG_MAP / LANG_EN / PLURAL_FORMS consistency..."; \
	./check_mix.py --check-data || rc=1; \
	exit $$rc

# Read-only audit for translations written in the wrong language. Compares each
# locale pair against KOReader's own reviewed catalogues (override the path with
# KOREADER_L10N_DIR), so it needs no knowledge of the target language. Findings
# are a triage list, not a verdict: read the report before acting on it.
check-mix:
	@./check_mix.py $(CHECK_MIX_ARGS)

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

clean:
	@echo "Cleaning intermediate translation files..."
	# Keep the current domain's .po ($(DOMAIN).po) and the legacy koreader.po
	# (still present during the migration window) — delete all other .po files.
	@find . -type f -name "*.po" ! -name "$(DOMAIN).po" ! -name "koreader.po" -print -delete

ai-translate:
	@set -e; \
	if [ -n "$(L10N_LANG)" ]; then \
		echo "Translating single language $(L10N_LANG)..."; \
		$(MAKE) ai-translate-$(L10N_LANG); \
	else \
		TO_TRANSLATE=$$(for lang in $(LANGS); do if [ -s "$$lang/untranslated.po" ]; then echo $$lang; fi; done); \
		if [ -z "$$TO_TRANSLATE" ]; then \
			echo "All languages are up to date. Nothing to translate."; \
		else \
			TO_TRANSLATE_TARGETS=$$(for lang in $$TO_TRANSLATE; do echo "ai-translate-$$lang"; done); \
			TOTAL_LANGS=$$(echo $$TO_TRANSLATE | wc -w); \
			echo "Starting parallel translation for $$TOTAL_LANGS language(s), cheapest first:" $$TO_TRANSLATE; \
			L10N_TO_LIST="$$TO_TRANSLATE"; export L10N_TO_LIST; \
			if ! $(MAKE) -k -j $(JOBS) $$TO_TRANSLATE_TARGETS; then \
				FAILED=$$(for lang in $$TO_TRANSLATE; do \
					if [ -s "$$lang/untranslated.po" ] && [ ! -f "$$lang/updated_translated.po" ] && [ ! -f "$$lang/$(DOMAIN).po.new" ]; then \
						if [ ! -f "$$lang/$(DOMAIN).po" ] || [ "$$lang/untranslated.po" -nt "$$lang/$(DOMAIN).po" ]; then \
							echo $$lang; \
						fi; \
					fi; \
				done); \
				echo "\033[0;33mSome languages failed to translate. Re-run 'make translate' (or 'make ai-translate') to resume.\033[0m"; \
				if [ -n "$$FAILED" ]; then echo "Failed languages: $$FAILED"; fi; \
				exit 1; \
			fi; \
		fi; \
	fi

# extract-untranslated-% is a prerequisite rather than a documented manual
# step: ai_translate.py's scenario-2 path needs <lang>/untranslated.po to
# exist, and without this dependency `make ai-translate L10N_LANG=xx` dies with
# "translate files not ready". The per-locale target is idempotent - it skips a
# language whose untranslated.po is already there - so this is safe to depend
# on, and scoping it to the one locale keeps the job from touching any other
# locale's intermediates.
$(AI_TRANSLATE_TARGETS): ai-translate-%: extract-untranslated-%
	@set -e; \
	lang=$*; \
	IS_NEW=0; if [ ! -f "$$lang/$(DOMAIN).po" ]; then IS_NEW=1; fi; \
	./ai_translate.py $$lang && { \
		if [ $$IS_NEW -eq 1 ]; then \
			if [ ! -f "$$lang/$(DOMAIN).po" ]; then \
				echo "\033[0;31mError: AI translation for new language '$$lang' failed. File '$$lang/$(DOMAIN).po' not created.\033[0m"; exit 1; \
			fi; \
		elif [ -s "$$lang/untranslated.po" ] && [ ! -f "$$lang/updated_translated.po" ]; then \
			echo "\033[0;31mError: AI translation for '$$lang' failed. File '$$lang/updated_translated.po' not created.\033[0m"; exit 1; \
		fi; \
		if [ -n "$${L10N_TO_LIST:-}" ]; then \
			done_n=0; total_n=0; \
			for l in $${L10N_TO_LIST}; do \
				total_n=$$((total_n+1)); \
				if [ ! -s "$$l/untranslated.po" ] || [ -f "$$l/updated_translated.po" ] || \
				   { [ -f "$$l/$(DOMAIN).po" ] && [ "$$l/$(DOMAIN).po" -nt "$$l/untranslated.po" ]; }; then \
					done_n=$$((done_n+1)); \
				fi; \
			done; \
			echo "\033[0;32m[$$lang] done. Progress: $$done_n/$$total_n languages translated, $$((total_n - done_n)) remaining.\033[0m"; \
		fi; \
	} || exit 1

retranslate-fuzzy:
	@echo "Forcing re-translation of fuzzy entries..."
	@for lang in $(LANGS); do \
		if [ -n "$(L10N_LANG)" ] && [ "$$lang" != "$(L10N_LANG)" ]; then continue; fi; \
		rm -f $$lang/untranslated.po $$lang/_untranslated.po $$lang/_fuzzy.po $$lang/updated_translated.po; \
	done
	@$(MAKE) extract-untranslated
	@$(MAKE) ai-translate
	@$(MAKE) import-translation
	@echo "Fuzzy re-translation imported; running 'make check'..."
	@$(MAKE) check || true

# Empty one exact MSGID in every (or one L10N_LANG) .po file and run it back
# through the pipeline, so a terminology fix is retranslated by the script
# instead of hand-edited in 60 files. Needs .env (ai-translate step).
retranslate-msgid:
	@if [ -z "$(MSGID)" ]; then \
		echo "Usage: make retranslate-msgid MSGID=\"<exact msgid>\" [L10N_LANG=xx]"; \
		exit 1; \
	fi
	@echo "Emptying msgid for retranslation: $(MSGID)"
	@for lang in $(LANGS); do \
		if [ -n "$(L10N_LANG)" ] && [ "$$lang" != "$(L10N_LANG)" ]; then continue; fi; \
		./retranslate_msgid.py "$$lang" "$(MSGID)" || exit 1; \
	done
	@for lang in $(LANGS); do \
		if [ -n "$(L10N_LANG)" ] && [ "$$lang" != "$(L10N_LANG)" ]; then continue; fi; \
		rm -f $$lang/untranslated.po $$lang/_untranslated.po $$lang/_fuzzy.po $$lang/updated_translated.po; \
	done
	@$(MAKE) extract-untranslated
	@$(MAKE) ai-translate
	@$(MAKE) import-translation
	@echo "Retranslation imported; running 'make check'..."
	@$(MAKE) check || true
	@echo "Cleaning up intermediate files..."
	@$(MAKE) clean
	@echo "Compiling .mo files..."
	@$(MAKE) mo

# Refill exactly one locale after check_mix.py --jev --retranslate-jev has
# emptied the entries it confidently placed in the peer language. Scoped to
# L10N_LANG so no other locale's catalogue, pending import or .mo is touched;
# unlike retranslate-msgid it never runs the global `clean`. The locale is
# validated against LANGS and an existing catalogue before any step runs. On
# failure the target stops where it is, keeps the partials for that locale, and
# prints the exact resume command; the locale's intermediates are removed only
# after every step (including `make check`) succeeds.
retranslate-jev:
	@set -e; \
	if [ -z "$(L10N_LANG)" ]; then \
		echo "Usage: make retranslate-jev L10N_LANG=xx"; \
		exit 1; \
	fi; \
	if ! printf '%s\n' $(LANGS) | grep -qxF '$(L10N_LANG)'; then \
		echo "\033[0;31mError: '$(L10N_LANG)' is not a supported locale (see LANGS).\033[0m"; \
		exit 1; \
	fi; \
	if [ ! -f "$(L10N_LANG)/$(DOMAIN).po" ]; then \
		echo "\033[0;31mError: no catalogue $(L10N_LANG)/$(DOMAIN).po to refill.\033[0m"; \
		exit 1; \
	fi; \
	if [ ! -f .env ]; then \
		echo "\033[0;31mError: AI access environment file \`.env' is not found.\033[0m"; \
		echo "Please set it before running retranslation. See: README.md"; \
		exit 1; \
	fi; \
	lang=$(L10N_LANG); \
	echo "[1/5] Extracting untranslated entries for $$lang..."; \
	$(MAKE) extract-untranslated-$$lang; \
	echo "[2/5] Translating $$lang..."; \
	$(MAKE) ai-translate-$$lang; \
	echo "[3/5] Importing $$lang translations..."; \
	$(MAKE) import-translation-$$lang; \
	echo "[4/5] Checking PO files..."; \
	check_rc=0; \
	$(MAKE) check || check_rc=$$?; \
	echo "[5/5] Compiling $$lang/$(DOMAIN).mo..."; \
	$(MAKE) "$$lang/$(DOMAIN).mo"; \
	if [ $$check_rc -ne 0 ]; then \
		echo "\033[0;31mError: 'make check' failed (exit $$check_rc); $$lang intermediates are preserved.\033[0m"; \
		echo "Resume with: make retranslate-jev L10N_LANG=$$lang"; \
		exit $$check_rc; \
	fi; \
	echo "Cleaning up intermediates for $$lang..."; \
	rm -f "$$lang/untranslated.po" "$$lang/_untranslated.po" "$$lang/_fuzzy.po" "$$lang/updated_translated.po" "$$lang/updated.po"

template:
	mkdir -p $(TEMPLATE_DIR)
	$(XGETTEXT_BIN) $(XGETTEXT_OPTS) \
		`find .. -type f -name "*.lua" | sort` \
		-o $(TEMPLATE_DIR)/$(DOMAIN).pot

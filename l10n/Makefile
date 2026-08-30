.PHONY: all translate template update extract-untranslated ai-translate check-ai-results import-translation check check-langs check-api clean init-dirs mo

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

all: mo

# This target runs the full translation pipeline:
# 1. Extracts strings from source code into a .pot template.
# 2. Merges the template into language .po files.
# 3. Extracts all untranslated strings.
# 4. Runs the AI translation script on them.
# 5. Verifies that AI translation produced output files.
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
	@echo "[1/7] Generating POT template file..."
	@$(MAKE) template
	@echo "[2/7] Merging POT file into PO files..."
	@$(MAKE) update
	@echo "[3/7] Generating untranslated files..."
	@$(MAKE) extract-untranslated
	@echo "[4/7] Running AI translation and verifying results..."
	@$(MAKE) ai-translate
	@echo "[5/7] Merging untranslated files..."
	@$(MAKE) import-translation
	@echo "[6/7] Checking PO files..."
	@$(MAKE) check
	@echo "[7/7] Cleaning up intermediate files..."
	@$(MAKE) clean
	@echo "[8/8] Compiling .mo files..."
	@$(MAKE) mo
	@echo "\nTranslation process completed successfully!"


DOMAIN = assistant
TEMPLATE_DIR = templates
MSGINIT_BIN = msginit
MSGFMT_BIN = msgfmt
MSGMERGE_BIN = msgmerge
MSGATTRIB_BIN = msgattrib
MSGCAT_BIN = msgcat
XGETTEXT_BIN = xgettext

LANGS := zh_CN zh_TW af_ZA ar be bg_BG bn ca cs cy da de el eo es et eu fa fi fr ga gl he hi hr hu ia id ie it_IT ja ka kab kn ko_KR lt_LT lv mk ms nb_NO nl_NL nn or pl pt_BR pt_PT ro ro_MD ru si sk sl sr sv th tr uk ur uz vi

PO_FILES  := $(wildcard */$(DOMAIN).po)

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

extract-untranslated:
	@set -x;for po_file in $(PO_FILES); do \
		dir=$$(dirname $$po_file); \
		if [ ! -f "$$dir/untranslated.po" ]; then \
			$(MSGATTRIB_BIN) --no-wrap --no-location --untranslated --force-po $$po_file -o $$dir/_untranslated.po; \
			$(MSGATTRIB_BIN) --no-wrap --no-location --fuzzy --clear-fuzzy --empty --force-po $$po_file -o $$dir/_fuzzy.po; \
			$(MSGCAT_BIN) --no-wrap --no-location --use-first $$dir/_untranslated.po $$dir/_fuzzy.po -o $$dir/untranslated.po; \
		else \
			echo "Skipping extraction for $$dir, untranslated.po already exists."; \
		fi; \
	done

import-translation:
	@for po_file in $(PO_FILES); do \
		dir=$$(dirname $$po_file); \
		if [ -f "$$dir/updated_translated.po" ]; then \
			$(MSGCAT_BIN) --no-location --no-wrap --use-first --sort-output $$dir/updated_translated.po $$po_file -o $$dir/updated.po && \
			$(MSGATTRIB_BIN) --no-obsolete --no-wrap --no-location --sort-by-file $$dir/updated.po -o $$po_file; \
			rm -f $$dir/updated.po; \
		fi; \
	done

check:
	@echo "Checking syntax of existing .po files..."
	@rc=0; \
	for po_file in $(PO_FILES); do \
		dir=$$(dirname $$po_file); printf "%-8s" "$$dir"; \
		$(MSGFMT_BIN) -v --check -o /dev/null $$po_file || rc=1; \
	done; \
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
	exit $$rc

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
			echo "Starting parallel translation for targets: $$TO_TRANSLATE_TARGETS"; \
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

ai-translate-%:
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
	} || exit 1

template:
	mkdir -p $(TEMPLATE_DIR)
	$(XGETTEXT_BIN) --from-code=utf-8 \
		--keyword=C_:1c,2 --keyword=N_:1,2 --keyword=NC_:1c,2,3 \
		--add-comments=@translators \
		--package-name=assistant.koplugin \
		--no-wrap \
		--no-location \
		--sort-by-file \
		--package-version=`grep version ../_meta.lua | grep -Eo '[0-9.]+'` \
		`find .. -type f -name "*.lua" | sort` \
		-o $(TEMPLATE_DIR)/$(DOMAIN).pot


# Compile .po files to .mo files
# for future use
SELF := $(lastword $(MAKEFILE_LIST))
MO_FILES = $(PO_FILES:%.po=%.mo)
%.mo: %.po
	@$(MSGFMT_BIN) --no-hash -o $@ $<
mo:
	$(MAKE) --file=$(SELF) $(MO_FILES)

.PHONY: all translate template update extract-untranslated ai-translate check-ai-results import-translation check clean init-dirs

all: translate

# This target runs the full translation pipeline:
# 1. Extracts strings from source code into a .pot template.
# 2. Merges the template into language .po files.
# 3. Extracts all untranslated strings.
# 4. Runs the AI translation script on them.
# 5. Verifies that AI translation produced output files.
# 6. Merges the new translations back into the .po files.
# 7. Checks the syntax of the final .po files.
# 8. Cleans up all intermediate files.
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
	@echo "\nTranslation process completed successfully!"


DOMAIN = koreader
TEMPLATE_DIR = templates
MSGINIT_BIN = msginit
MSGFMT_BIN = msgfmt
MSGMERGE_BIN = msgmerge
MSGATTRIB_BIN = msgattrib
MSGFILTER_BIN = msgfilter
MSGCAT_BIN = msgcat
XGETTEXT_BIN = xgettext

LANGS :=  zh_CN zh_TW ar bg_BG bn ca cs da de el eo es eu fa fi fr gl he hi hr hu it_IT ja ka kk ko_KR lt_LT lv nb_NO nl_NL pl pt_BR pt_PT ro ro_MD ru sk sr sv th tr uk vi vi_VN

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
		$(MSGMERGE_BIN) --update --backup=none --no-wrap --sort-by-file $$po_file $(TEMPLATE_DIR)/$(DOMAIN).pot; \
	done

extract-untranslated:
	@set -x;for po_file in $(PO_FILES); do \
		dir=$$(dirname $$po_file); \
		if [ ! -f "$$dir/untranslated.po" ]; then \
			$(MSGATTRIB_BIN) --untranslated --force-po $$po_file -o $$dir/_untranslated.po; \
			$(MSGATTRIB_BIN) --fuzzy --clear-fuzzy --empty --force-po $$po_file -o $$dir/_fuzzy.po; \
			$(MSGCAT_BIN) --use-first $$dir/_untranslated.po $$dir/_fuzzy.po -o $$dir/untranslated.po; \
		else \
			echo "Skipping extraction for $$dir, untranslated.po already exists."; \
		fi; \
	done

import-translation:
	@for po_file in $(PO_FILES); do \
		dir=$$(dirname $$po_file); \
		if [ -f "$$dir/updated_translated.po" ]; then \
			$(MSGCAT_BIN) --use-first --sort-output $$dir/updated_translated.po $$po_file -o updated.po && \
			$(MSGATTRIB_BIN) --no-obsolete --no-wrap --sort-by-file -i updated.po -o $$po_file; \
		fi; \
	done

check:
	@echo "Checking syntax of existing .po files..."
	@for po_file in $(PO_FILES); do \
		dir=$$(dirname $$po_file); printf "%-8s" "$$dir"; \
		$(MSGFMT_BIN) -v --check -o /dev/null $$po_file; \
	done

clean:
	@echo "Cleaning intermediate translation files..."
	@find . -type f -name "*.po" ! -name "koreader.po" -print -delete

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
			$(MAKE) -j 4 $$TO_TRANSLATE_TARGETS; \
		fi; \
	fi

ai-translate-%:
	@set -e; \
	lang=$*; \
	IS_NEW=0; if [ ! -f "$$lang/$(DOMAIN).po" ]; then IS_NEW=1; fi; \
	./AI_TRANSLATE.sh $$lang && { \
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

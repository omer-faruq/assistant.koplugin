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
	@if [ -z "$(API_KEY)" ]; then \
		echo "\033[0;31mError: API_KEY environment variable is not set.\033[0m"; \
		echo "Please set it before running translation. e.g., export API_KEY=your_key"; \
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
MSGFMT_BIN = msgfmt
MSGMERGE_BIN = msgmerge
MSGATTRIB_BIN = msgattrib
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
			cp $(TEMPLATE_DIR)/$(DOMAIN).pot $$lang/$(DOMAIN).po; \
		fi; \
	done

update: init-dirs
	@for po_file in $(PO_FILES); do \
		$(MSGMERGE_BIN) --update --backup=none --no-wrap --sort-by-file $$po_file $(TEMPLATE_DIR)/$(DOMAIN).pot; \
		$(MSGATTRIB_BIN) --no-obsolete --no-wrap --sort-by-file -i $$po_file -o $$po_file.updated; \
		mv $$po_file.updated $$po_file; \
	done

extract-untranslated:
	@for po_file in $(PO_FILES); do \
		dir=$$(dirname $$po_file); \
		if [ ! -f "$$dir/untranslated.po" ]; then \
			$(MSGATTRIB_BIN) --untranslated $$po_file -o $$dir/untranslated.po; \
		else \
			echo "Skipping extraction for $$dir, untranslated.po already exists."; \
		fi; \
	done

import-translation:
	@for po_file in $(PO_FILES); do \
		dir=$$(dirname $$po_file); \
		if [ -f "$$dir/updated_translated.po" ]; then \
			$(MSGCAT_BIN) --use-first $$dir/updated_translated.po $$po_file -o updated.po && \
			$(MSGATTRIB_BIN) --no-obsolete --no-wrap --sort-by-file -i updated.po -o $$po_file; \
		fi; \
	done

check:
	@echo "Checking syntax of existing .po files..."
	@for po_file in $(PO_FILES); do \
		$(MSGFMT_BIN) -v --check -o /dev/null $$po_file; \
	done

clean:
	@echo "Cleaning intermediate translation files..."
	@find . -type f \( -name "untranslated.po" -o -name "updated_translated.po" -o -name "updated.po" \) -print -delete

ai-translate:
	@set -e; \
	if [ -n "$(L10N_LANG)" ]; then \
		echo "Translating single language $(L10N_LANG)..."; \
		IS_NEW=0; if [ ! -f "$(L10N_LANG)/$(DOMAIN).po" ]; then IS_NEW=1; fi; \
		./AI_TRANSLATE.sh $(L10N_LANG) && { \
			if [ $$IS_NEW -eq 1 ]; then \
				if [ ! -f "$(L10N_LANG)/$(DOMAIN).po" ]; then \
					echo "\033[0;31mError: AI translation for new language '$(L10N_LANG)' failed. File '$(L10N_LANG)/$(DOMAIN).po' not created.\033[0m"; exit 1; \
				fi; \
			elif [ -s "$(L10N_LANG)/untranslated.po" ] && [ ! -f "$(L10N_LANG)/updated_translated.po" ]; then \
				echo "\033[0;31mError: AI translation for '$(L10N_LANG)' failed. File '$(L10N_LANG)/updated_translated.po' not created.\033[0m"; exit 1; \
			fi; \
		} || exit 1; \
	else \
		TO_TRANSLATE=$$(for lang in $(LANGS); do if [ -s "$$lang/untranslated.po" ]; then echo $$lang; fi; done); \
		TOTAL=$$(echo $$TO_TRANSLATE | wc -w); \
		COUNT=0; \
		for lang in $$TO_TRANSLATE; do \
			COUNT=$$((COUNT+1)); \
			echo "Translating language $$COUNT of $$TOTAL ($$lang)..."; \
			./AI_TRANSLATE.sh $$lang && { \
				if [ ! -f "$$lang/updated_translated.po" ]; then \
					echo "\033[0;31mError: AI translation for '$$lang' failed.\033[0m"; \
					echo "File '$$lang/updated_translated.po' was not created, but '$$lang/untranslated.po' was not empty."; \
					echo "This might be due to an API error or network issue."; \
					echo "Please check the output above for any error messages from the AI translation script."; \
					echo "You can try running the translation for this language again with: make ai-translate L10N_LANG=$$lang"; \
					exit 1; \
				fi; \
				if [ -n "$$API_WAIT" ]; then \
					echo "... waiting $$API_WAIT seconds to avoid API rate limits."; \
					sleep $$API_WAIT; \
				fi; \
			} || exit 1; \
		done; \
		if [ -z "$$TO_TRANSLATE" ]; then \
			echo "All languages are up to date. Nothing to translate."; \
		fi; \
	fi

template:
	mkdir -p $(TEMPLATE_DIR)
	$(XGETTEXT_BIN) --from-code=utf-8 \
		--keyword=C_:1c,2 --keyword=N_:1,2 --keyword=NC_:1c,2,3 \
		--add-comments=@translators \
		--package-name=assistant.koplugin \
		--no-wrap \
		--sort-by-file \
		--package-version=`grep version ../_meta.lua | grep -Eo '[0-9.]+'` \
		`find .. -name "*.lua" | sort` \
		-o $(TEMPLATE_DIR)/$(DOMAIN).pot

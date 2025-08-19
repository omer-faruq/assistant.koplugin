.PHONY: all translate template update extract-untranslated ai-translate import-translation check clean

all: translate

# This target runs the full translation pipeline:
# 1. Extracts strings from source code into a .pot template.
# 2. Merges the template into language .po files.
# 3. Extracts all untranslated strings.
# 4. Runs the AI translation script on them.
# 5. Merges the new translations back into the .po files.
# 6. Checks the syntax of the final .po files.
# 7. Cleans up all intermediate files.
translate:
	@echo "[1/7] Generating POT template file..."
	@$(MAKE) template
	@echo "[2/7] Merging POT file into PO files..."
	@$(MAKE) update
	@echo "[3/7] Generating untranslated files..."
	@$(MAKE) extract-untranslated
	@echo "[4/7] Running AI translation..."
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

PO_FILES  := $(wildcard */$(DOMAIN).po)
LANGS     := $(patsubst %/,%,$(filter-out templates/,$(wildcard */)))

update: template
	@for po_file in $(PO_FILES); do \
		$(MSGMERGE_BIN) --update --no-fuzzy-matching --backup=none $$po_file $(TEMPLATE_DIR)/$(DOMAIN).pot; \
		$(MSGATTRIB_BIN) --no-obsolete -i $$po_file -o $$po_file; \
	done

extract-untranslated:
	@for po_file in $(PO_FILES); do \
		dir=$$(dirname $$po_file); \
		$(MSGATTRIB_BIN) --untranslated $$po_file -o $$dir/untranslated.po; \
	done

import-translation:
	@for po_file in $(PO_FILES); do \
		dir=$$(dirname $$po_file); \
		if [ -f $$dir/updated_translated.po ]; then \
			$(MSGCAT_BIN) --use-first $$dir/updated_translated.po $$po_file -o updated.po; \
			mv updated.po $$po_file; \
		fi; \
	done

check:
	@echo "Checking syntax of existing .po files..."
	@for po_file in $(PO_FILES); do \
		$(MSGFMT_BIN) --check -o /dev/null $$po_file; \
	done

clean:
	@echo "Cleaning intermediate translation files..."
	@find . -type f \( -name "untranslated.po" -o -name "updated_translated.po" -o -name "updated.po" \) -print -delete

ai-translate:
	@set -e; \
	TOTAL=$$(echo $(LANGS) | wc -w); \
	COUNT=0; \
	for LANG in $(LANGS); do \
		COUNT=$$((COUNT+1)); \
		echo "\n[$$COUNT/$$TOTAL] Processing language: $$LANG"; \
		INPUT_FILE=$$LANG/untranslated.po; \
		OUTPUT_FILE=$$LANG/updated_translated.po; \
		if [ -s $$INPUT_FILE ]; then \
			python3 ai_translate.py --input-file $$INPUT_FILE --output-file $$OUTPUT_FILE --language $$LANG; \
		else \
			echo "No untranslated strings found for $$LANG. Skipping."; \
		fi; \
	done

template:
	mkdir -p $(TEMPLATE_DIR)
	$(XGETTEXT_BIN) --from-code=utf-8 \
		--keyword=C_:1c,2 --keyword=N_:1,2 --keyword=NC_:1c,2,3 \
		--add-comments=@translators \
		$$(find .. -name "*.lua" | sort) \
		-o $(TEMPLATE_DIR)/$(DOMAIN).pot
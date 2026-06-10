# =============================================================================
# lions-book Makefile
# =============================================================================
# Build the plastex HTML version of the Lions Commentary and fix the
# cross-links from commentary line numbers to the flat source view (all.html).
#
# Requirements:
#   - uv (https://docs.astral.sh/uv/)
#   - Python >= 3.9 (see .python-version)
#
# Main targets:
#   make lions        - full build: run plastex + post-process line links
#   make postprocess  - re-apply only the link fixer (useful after manual edits)
#   make clean        - remove generated output
#
# The old "sed" post-processing has been replaced by a Python script that:
#   - is cross-platform
#   - repairs the previously broken HTML produced by the old sed
#   - uses proper zero-padded line numbers matching all.html anchors
#   - produces valid HTML
#
# After adding .gitignore you will probably want to do once:
#   git rm -r --cached lionc/ lionstex/*.aux lionstex/*.log ... (build artifacts)
# =============================================================================

.PHONY: lions postprocess links clean help

LIONC_DIR := lionc
SCRIPT := scripts/fix-line-refs.py

# -----------------------------------------------------------------------------
# Main target
# -----------------------------------------------------------------------------
lions: $(LIONC_DIR) postprocess
	@echo "Build complete. Output is in $(LIONC_DIR)/"
	@echo "Open index.html or lions.html in a browser."

$(LIONC_DIR):
	@echo "==> Running plastex..."
	cd lionstex && uv run plastex -c plastex.ini -d ../$(LIONC_DIR) lionc.tex

# -----------------------------------------------------------------------------
# Post-processing (the important part that used to be fragile sed)
# -----------------------------------------------------------------------------
postprocess:
	@echo "==> Fixing line number cross-references..."
	uv run python $(SCRIPT) --input-dir $(LIONC_DIR)

# Legacy target name (kept for muscle memory). Same as postprocess.
links: postprocess

# -----------------------------------------------------------------------------
# Cleanup (cross-platform)
# -----------------------------------------------------------------------------
clean:
	@echo "==> Removing generated output..."
	python -c "import shutil; shutil.rmtree('$(LIONC_DIR)', ignore_errors=True)"
	@echo "Clean."

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
help:
	@echo "lions-book build targets:"
	@echo "  make lions        Build HTML commentary from TeX + fix line links"
	@echo "  make postprocess  Only run the line-reference fixer (no plastex)"
	@echo "  make clean        Remove the $(LIONC_DIR)/ directory"
	@echo "  make help         This message"
	@echo ""
	@echo "Typical local workflow:"
	@echo "  make clean && make lions"
	@echo "  # then open index.html or lions.html"

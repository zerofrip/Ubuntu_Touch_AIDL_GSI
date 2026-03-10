# =============================================================================
# Makefile — Ubuntu GSI Build Convenience Targets
# =============================================================================

.DEFAULT_GOAL := help

.PHONY: help build check clean install lint

help: ## Show available targets
	@echo ""
	@echo "Ubuntu GSI — Build Targets"
	@echo "══════════════════════════════════════════════════"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""

check: ## Validate build environment (dependencies, disk space)
	@bash scripts/check_environment.sh

build: ## Run the full GSI build pipeline
	@bash build.sh

clean: ## Remove all build artifacts
	@echo "Cleaning build artifacts..."
	rm -rf builder/out/system.img
	rm -rf builder/out/linux_rootfs.squashfs
	rm -rf builder/out/gsi_sys
	rm -rf builder/out/ubuntu-rootfs
	@echo "Done."

install: ## Flash GSI to connected device (interactive)
	@bash scripts/install.sh

lint: ## Run ShellCheck on all project shell scripts
	@echo "Running ShellCheck..."
	@find . -name '*.sh' \
		-not -path './third_party/*' \
		-not -path './builder/out/*' \
		-print0 | xargs -0 shellcheck --severity=warning && \
		echo "All scripts passed." || \
		echo "ShellCheck found issues (see above)."

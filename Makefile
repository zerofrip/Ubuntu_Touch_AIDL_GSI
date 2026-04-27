# =============================================================================
# Makefile — Ubuntu GSI Halium-style build system (AIDL variant)
# =============================================================================

.DEFAULT_GOAL := help

.PHONY: help all build phh rootfs erofs vbmeta system flash flash-system flash-vbmeta \
        check check-device clean lint deepclean gui-install

help: ## Show available targets
	@echo ""
	@echo "Ubuntu GSI — Halium-style build system (AIDL)"
	@echo "══════════════════════════════════════════════════"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""

all: build ## Build everything

build: ## Full pipeline: phh -> rootfs -> erofs -> vbmeta -> system
	@bash build.sh

phh: ## Fetch the PHH Treble GSI base
	@bash scripts/fetch_phh_gsi.sh

rootfs: ## Build Ubuntu chroot rootfs (requires sudo)
	@sudo bash scripts/build_rootfs.sh

erofs: ## Pack chroot rootfs as erofs
	@bash scripts/build_rootfs_erofs.sh

vbmeta: ## Generate vbmeta-disabled.img
	@bash scripts/build_vbmeta_disabled.sh

system: ## Compose system.img (requires sudo for loop-mount)
	@sudo bash scripts/build_system_img.sh

flash: ## Flash system + vbmeta-disabled
	@bash scripts/flash.sh

flash-system: ## Flash system only
	@bash scripts/flash.sh --system-only

flash-vbmeta: ## Flash vbmeta-disabled only
	@bash scripts/flash.sh --vbmeta-only

check: ## Validate host build environment
	@bash scripts/check_environment.sh

check-device: ## Pre-flash device compatibility checks
	@bash scripts/check_device.sh

lint: ## Run shellcheck on shell scripts
	@echo "Running shellcheck..."
	@find . -name '*.sh' \
		-not -path './third_party/*' \
		-not -path './deprecated/*' \
		-not -path './builder/out/*' \
		-not -path './builder/cache/*' \
		-print0 | xargs -0 shellcheck --severity=warning && \
		echo "All scripts passed." || \
		(echo "ShellCheck found issues."; exit 1)

clean: ## Remove build artifacts (keep PHH cache)
	@echo "Cleaning build artifacts..."
	rm -f builder/out/system.img
	rm -f builder/out/linux_rootfs.erofs
	rm -f builder/out/vbmeta-disabled.img
	rm -rf builder/out/system_staging
	rm -rf builder/out/ubuntu-rootfs
	@echo "Done."

deepclean: clean ## Also remove PHH download cache
	@echo "Deep clean: removing PHH cache"
	rm -rf builder/cache
	@echo "Done."

gui-install: ## Install Lomiri stack manually in chroot
	@sudo bash gui/install_lomiri.sh

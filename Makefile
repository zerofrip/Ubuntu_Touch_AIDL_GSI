# =============================================================================
# Makefile — Ubuntu GSI Halium-style build system (AIDL variant)
# =============================================================================

.DEFAULT_GOAL := help

.PHONY: help all build build-minimal build-android8-16 phh phh-custom phh-custom-minimal fetch-clicks rootfs rootfs-minimal erofs vbmeta system userdata release flash flash-system flash-vbmeta \
        check check-device clean lint deepclean gui-install

help: ## Show available targets
	@echo ""
	@echo "Ubuntu GSI — Halium-style build system (AIDL)"
	@echo "══════════════════════════════════════════════════"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""

all: build ## Build everything

build: ## Full pipeline: phh -> rootfs -> erofs -> vbmeta -> system -> userdata -> release package
	@bash build.sh

build-minimal: ## Full pipeline with minimal rootfs profile
	@GSI_ROOTFS_PROFILE=minimal bash build.sh

build-android8-16: ## Build android-12.0 through android-16.0 vendor branches sequentially
	@bash scripts/build_android8_to16_aidl.sh

phh: ## Fetch the PHH Treble GSI base
	@bash scripts/fetch_phh_gsi.sh

phh-custom: ## Build PHH from local source tree and cache it
	@PHH_GSI_SOURCE=custom bash scripts/fetch_phh_gsi.sh

phh-custom-minimal: ## Build smaller PHH preset (td arm64-ab vanilla)
	@PHH_GSI_SOURCE=custom PHH_CUSTOM_TARGET=android-15.0 PHH_CUSTOM_VARIANT=td-arm64-ab-vanilla bash scripts/fetch_phh_gsi.sh

fetch-clicks: ## Download Core Apps clicks (rootfs/clicks.core-apps.list)
	@bash scripts/fetch_openstore_clicks.sh

rootfs: ## Build Ubuntu chroot rootfs (requires sudo)
	@sudo bash scripts/build_rootfs.sh

rootfs-minimal: ## Build minimal Ubuntu chroot rootfs (requires sudo)
	@sudo GSI_ROOTFS_PROFILE=minimal bash scripts/build_rootfs.sh

erofs: ## Pack chroot rootfs as erofs
	@bash scripts/build_rootfs_erofs.sh

vbmeta: ## Generate vbmeta-disabled.img
	@bash scripts/build_vbmeta_disabled.sh

system: ## Compose system.img (requires sudo for loop-mount)
	@sudo bash scripts/build_system_img.sh

userdata: ## Build userdata.img containing rootfs.erofs A/B seed
	@bash scripts/build_userdata_img.sh

release: ## Package versioned release artifacts (android-XX_system.img)
	@bash scripts/package_release_artifacts.sh

flash: ## Flash system + vbmeta-disabled + userdata (with size checks)
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

clean: ## Remove build artifacts (keep versioned PHH cache)
	@echo "Cleaning build artifacts..."
	rm -f builder/out/system.img
	rm -f builder/out/android-*_system.img
	rm -f builder/out/linux_rootfs.erofs
	rm -f builder/out/vbmeta-disabled.img
	rm -f builder/out/userdata.img
	rm -rf builder/out/system_staging
	rm -rf builder/out/userdata_staging
	rm -rf builder/out/ubuntu-rootfs
	@echo "Done."

deepclean: clean ## Also remove PHH download cache
	@echo "Deep clean: removing PHH cache"
	rm -rf builder/cache
	@echo "Done."

gui-install: ## Install Lomiri stack manually in chroot
	@sudo bash gui/install_lomiri.sh

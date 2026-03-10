#!/bin/bash
# =============================================================================
# scripts/check_environment.sh — Host Build Environment Validator
# =============================================================================
# Verifies all required tools, minimum versions, and disk space before building.
# Run this before invoking build.sh to catch missing dependencies early.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

pass()  { echo -e "  ${GREEN}✔ PASS${NC}  $1"; }
fail()  { echo -e "  ${RED}✘ FAIL${NC}  $1"; ERRORS=$((ERRORS + 1)); }
warn()  { echo -e "  ${YELLOW}⚠ WARN${NC}  $1"; WARNINGS=$((WARNINGS + 1)); }
info()  { echo -e "  ${CYAN}ℹ INFO${NC}  $1"; }

ERRORS=0
WARNINGS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}         Ubuntu GSI — Build Environment Check                 ${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# ---------------------------------------------------------------------------
# 1. Required build tools
# ---------------------------------------------------------------------------
echo -e "${BOLD}[1/5] Required Build Tools${NC}"

check_cmd() {
    local cmd="$1"
    local pkg="${2:-$1}"
    if command -v "$cmd" > /dev/null 2>&1; then
        local ver
        ver=$("$cmd" --version 2>&1 | head -1) || ver="(version unknown)"
        pass "$cmd  →  $ver"
    else
        fail "$cmd not found. Install: sudo apt install $pkg"
    fi
}

check_cmd mksquashfs squashfs-tools
check_cmd mkfs.ext4  e2fsprogs
check_cmd jq         jq
check_cmd tar        tar
check_cmd git        git

echo ""

# ---------------------------------------------------------------------------
# 2. Download tools (at least one required)
# ---------------------------------------------------------------------------
echo -e "${BOLD}[2/5] Download Tools (wget or curl)${NC}"

HAS_DL=0
if command -v wget > /dev/null 2>&1; then
    pass "wget available"
    HAS_DL=1
else
    info "wget not found"
fi
if command -v curl > /dev/null 2>&1; then
    pass "curl available"
    HAS_DL=1
else
    info "curl not found"
fi
if [ "$HAS_DL" -eq 0 ]; then
    fail "Neither wget nor curl found. Install at least one: sudo apt install wget"
fi

echo ""

# ---------------------------------------------------------------------------
# 3. Optional device tools
# ---------------------------------------------------------------------------
echo -e "${BOLD}[3/5] Device Flash Tools (optional)${NC}"

for tool in adb fastboot; do
    if command -v "$tool" > /dev/null 2>&1; then
        pass "$tool available"
    else
        warn "$tool not found — needed only for flashing. Install: sudo apt install android-tools-adb android-tools-fastboot"
    fi
done

echo ""

# ---------------------------------------------------------------------------
# 4. Disk space
# ---------------------------------------------------------------------------
echo -e "${BOLD}[4/5] Disk Space${NC}"

REQUIRED_MB=2048
AVAIL_MB=$(df -BM "$REPO_ROOT" | awk 'NR==2 {gsub(/M/,"",$4); print $4}')

if [ "$AVAIL_MB" -ge "$REQUIRED_MB" ]; then
    pass "Available: ${AVAIL_MB}MB (required: ${REQUIRED_MB}MB)"
else
    fail "Only ${AVAIL_MB}MB available — need at least ${REQUIRED_MB}MB"
fi

echo ""

# ---------------------------------------------------------------------------
# 5. Submodule status
# ---------------------------------------------------------------------------
echo -e "${BOLD}[5/5] Git Submodules${NC}"

if [ -f "$REPO_ROOT/.gitmodules" ]; then
    UNINIT=$(git -C "$REPO_ROOT" submodule status 2>/dev/null | grep -c '^-' || true)
    if [ "$UNINIT" -gt 0 ]; then
        warn "$UNINIT submodule(s) not initialized. Run: git submodule update --init --recursive"
    else
        pass "All submodules initialized"
    fi
else
    info "No .gitmodules found (submodules not required)"
fi

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
if [ "$ERRORS" -gt 0 ]; then
    echo -e "  ${RED}${BOLD}RESULT: $ERRORS error(s), $WARNINGS warning(s)${NC}"
    echo -e "  ${RED}Fix the errors above before building.${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    exit 1
elif [ "$WARNINGS" -gt 0 ]; then
    echo -e "  ${YELLOW}${BOLD}RESULT: All checks passed with $WARNINGS warning(s)${NC}"
    echo -e "  ${YELLOW}Warnings are non-blocking but may limit functionality.${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    exit 0
else
    echo -e "  ${GREEN}${BOLD}RESULT: All checks passed — ready to build!${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    exit 0
fi

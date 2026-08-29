#!/bin/bash
# =============================================================================
# scripts/prune_phh_system.sh — Strip non-essential PHH apps for Halium GSI
# =============================================================================
# Removes consumer Android apps / media that Lomiri does not need, to shrink
# system.img below GitHub's 2GB release asset limit where possible.
#
# Usage: bash scripts/prune_phh_system.sh <sys_root>
# Disable: GSI_SYSTEM_PRUNE=0
# =============================================================================

set -euo pipefail

SYS_ROOT="${1:-}"
if [ -z "$SYS_ROOT" ] || [ ! -d "$SYS_ROOT" ]; then
    echo "[prune_phh_system] ERROR: sys_root directory required" >&2
    exit 1
fi

# Accept flat staging (/app) or nested PHH layout (/system/app).
if [ ! -d "$SYS_ROOT/app" ] && [ -d "$SYS_ROOT/system/app" ]; then
    SYS_ROOT="$SYS_ROOT/system"
fi

if [ "${GSI_SYSTEM_PRUNE:-1}" = "0" ]; then
    echo "[prune_phh_system] GSI_SYSTEM_PRUNE=0 — skipping"
    exit 0
fi

before="$(du -sh "$SYS_ROOT" 2>/dev/null | cut -f1 || echo unknown)"
echo "[prune_phh_system] Before: $before ($SYS_ROOT)"

# Consumer / demo apps — Halium stops Android UI after boot_completed.
# Keep framework packages, Settings*, SystemUI*, KeyChain, PermissionController,
# PackageInstaller, CertInstaller, and similar boot-critical priv-apps.
APP_DENYLIST=(
    BasicDreams
    Browser2
    Calendar
    Camera2
    DeskClock
    EasterEgg
    Email
    Gallery2
    HTMLViewer
    Music
    MusicFX
    QuickSearchBox
    Stk
    WallpaperCropper
    BookmarkProvider
    CompanionDeviceManager
    PacProcessor
    PrintRecommendationService
    PrintSpooler
    SimAppDialog
    Traceur
    WallpaperBackup
    LiveWallpapersPicker
    PhotoTable
    ExactCalculator
    Camera
    Gallery
    Browser
    Quickstep
    LatinIME
    PicoTts
)

# Avoid telephony / storage providers required for framework boot.
PRIV_DENYLIST=(
    BackupRestoreConfirmation
    CallLogBackup
    CellBroadcastApp
    CellBroadcastLegacyApp
    ContactsProviderBackup
    MmsService
    ProxyHandler
    SharedStorageBackup
    StatementService
    Tag
    WallpaperCropper
    ManagedProvisioning
    OsuLogin
    CarrierDefaultApp
    BuiltInPrintService
    Contacts
    Dialer
)

remove_pkg_dir() {
    local base="$1"
    local name="$2"
    local path="$base/$name"
    if [ -e "$path" ]; then
        rm -rf "$path"
        echo "[prune_phh_system] removed ${path#"$SYS_ROOT"/}"
    fi
}

if [ -d "$SYS_ROOT/app" ]; then
    for name in "${APP_DENYLIST[@]}"; do
        remove_pkg_dir "$SYS_ROOT/app" "$name"
    done
fi

if [ -d "$SYS_ROOT/priv-app" ]; then
    for name in "${PRIV_DENYLIST[@]}"; do
        remove_pkg_dir "$SYS_ROOT/priv-app" "$name"
    done
fi

# Large non-essential media (keep bootanimation if present — small relative cost).
for rel in \
    media/audio/alarms \
    media/audio/notifications \
    media/audio/ringtones \
    media/audio/ui \
    usr/share/zoneinfo-icu \
    usr/hyphen-data \
    fonts/NotoColorEmoji.ttf \
    fonts/NotoSansCJK-Regular.ttc \
    fonts/NotoSerifCJK-Regular.ttc
do
    if [ -e "$SYS_ROOT/$rel" ]; then
        rm -rf "$SYS_ROOT/$rel"
        echo "[prune_phh_system] removed $rel"
    fi
done

# Drop preinstalled Google/Partner stubs if a PHH variant shipped them.
for base in app priv-app product/app product/priv-app system_ext/app system_ext/priv-app; do
    [ -d "$SYS_ROOT/$base" ] || continue
    find "$SYS_ROOT/$base" -maxdepth 1 -type d \( \
        -name 'Google*' -o -name 'Chrome*' -o -name 'YouTube*' -o \
        -name 'Maps*' -o -name 'Gmail*' -o -name 'Photos*' -o \
        -name 'Drive*' -o -name 'Velvet*' -o -name 'Phonesky*' -o \
        -name 'PrebuiltGmail*' -o -name 'Videos*' \
        \) -print0 2>/dev/null | while IFS= read -r -d '' d; do
        rm -rf "$d"
        echo "[prune_phh_system] removed ${d#"$SYS_ROOT"/}"
    done
done

after="$(du -sh "$SYS_ROOT" 2>/dev/null | cut -f1 || echo unknown)"
echo "[prune_phh_system] After:  $after"

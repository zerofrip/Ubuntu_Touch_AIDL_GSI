#!/bin/bash
# =============================================================================
# rootfs/overlay/usr/lib/ubuntu-gsi/setup-wizard.sh — GUI Setup Wizard
# =============================================================================
# Graphical first-boot setup wizard that runs after Lomiri starts.
# Uses zenity for touch-friendly dialogs. Onboard (on-screen keyboard)
# is launched automatically so users can type without a physical keyboard.
#
# Triggered by: /data/uhl_overlay/.setup_wizard_pending (created by firstboot.sh)
# Marker file:  /data/uhl_overlay/.setup_wizard_complete
# =============================================================================

set -euo pipefail

WIZARD_PENDING="/data/uhl_overlay/.setup_wizard_pending"
WIZARD_COMPLETE="/data/uhl_overlay/.setup_wizard_complete"
LOG="/data/uhl_overlay/setup-wizard.log"

log() { echo "[$(date -Iseconds)] [Setup Wizard] $1" >> "$LOG"; }

# Exit if wizard is not pending or already complete
if [ ! -f "$WIZARD_PENDING" ] || [ -f "$WIZARD_COMPLETE" ]; then
    exit 0
fi

# ---------------------------------------------------------------------------
# Ensure display environment
# ---------------------------------------------------------------------------
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DISPLAY="${DISPLAY:-:0}"

log "Setup Wizard starting"

# ---------------------------------------------------------------------------
# Launch on-screen keyboard (onboard) in background
# ---------------------------------------------------------------------------
OSK_PID=""
launch_osk() {
    if command -v onboard >/dev/null 2>&1; then
        onboard --size=400x200 &
        OSK_PID=$!
        log "Onboard launched (PID=$OSK_PID)"
    else
        log "WARNING: onboard not found — on-screen keyboard unavailable"
    fi
}

kill_osk() {
    if [ -n "$OSK_PID" ] && kill -0 "$OSK_PID" 2>/dev/null; then
        kill "$OSK_PID" 2>/dev/null || true
        wait "$OSK_PID" 2>/dev/null || true
        log "Onboard stopped"
    fi
}

trap kill_osk EXIT

launch_osk

# ---------------------------------------------------------------------------
# Welcome screen
# ---------------------------------------------------------------------------
zenity --info \
    --title="Ubuntu GSI Setup" \
    --text="Ubuntu GSI へようこそ!\n\nこのウィザードで初期設定を行います。\n\n• ユーザー名の変更\n• パスワードの設定\n• タイムゾーンの設定\n• 言語の設定" \
    --ok-label="開始" \
    --width=400 --height=300 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1. Username setup
# ---------------------------------------------------------------------------
log "Step 1: Username setup"

CURRENT_USER="ubuntu"
NEW_USERNAME=""

NEW_USERNAME=$(zenity --entry \
    --title="ユーザー設定" \
    --text="ユーザー名を入力してください。\n(空欄で「ubuntu」を使用)" \
    --entry-text="ubuntu" \
    --width=400 --height=200 2>/dev/null) || NEW_USERNAME=""

NEW_USERNAME="${NEW_USERNAME:-ubuntu}"

# Sanitize username: lowercase, alphanumeric + underscore, max 32 chars
NEW_USERNAME=$(echo "$NEW_USERNAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]//g' | cut -c1-32)
if [ -z "$NEW_USERNAME" ]; then
    NEW_USERNAME="ubuntu"
fi

log "Username selected: $NEW_USERNAME"

# ---------------------------------------------------------------------------
# 2. Password setup
# ---------------------------------------------------------------------------
log "Step 2: Password setup"

PASSWORD_SET=false
for _attempt in 1 2 3; do
    PASSWORD=$(zenity --password \
        --title="パスワード設定" \
        --width=400 --height=200 2>/dev/null) || PASSWORD=""

    if [ -z "$PASSWORD" ]; then
        zenity --warning \
            --title="パスワード設定" \
            --text="パスワードは必須です。もう一度入力してください。" \
            --width=300 --height=150 2>/dev/null || true
        continue
    fi

    PASSWORD_CONFIRM=$(zenity --password \
        --title="パスワード確認" \
        --width=400 --height=200 2>/dev/null) || PASSWORD_CONFIRM=""

    if [ "$PASSWORD" = "$PASSWORD_CONFIRM" ]; then
        PASSWORD_SET=true
        break
    else
        zenity --error \
            --title="パスワード設定" \
            --text="パスワードが一致しません。もう一度入力してください。" \
            --width=300 --height=150 2>/dev/null || true
    fi
done

if [ "$PASSWORD_SET" = false ]; then
    log "Password setup failed — keeping default"
    PASSWORD="ubuntu"
fi

# ---------------------------------------------------------------------------
# 3. Timezone setup
# ---------------------------------------------------------------------------
log "Step 3: Timezone setup"

# Common timezones for the selection list
TZ_LIST="Asia/Tokyo|Asia/Shanghai|Asia/Seoul|Asia/Kolkata|Asia/Singapore|Europe/London|Europe/Berlin|Europe/Paris|America/New_York|America/Chicago|America/Denver|America/Los_Angeles|Pacific/Auckland|UTC"

SELECTED_TZ=$(echo "$TZ_LIST" | tr '|' '\n' | zenity --list \
    --title="タイムゾーン設定" \
    --text="タイムゾーンを選択してください:" \
    --column="タイムゾーン" \
    --width=400 --height=450 2>/dev/null) || SELECTED_TZ="UTC"

SELECTED_TZ="${SELECTED_TZ:-UTC}"
log "Timezone selected: $SELECTED_TZ"

# ---------------------------------------------------------------------------
# 4. Language setup
# ---------------------------------------------------------------------------
log "Step 4: Language setup"

LANG_LIST="ja_JP.UTF-8|en_US.UTF-8|zh_CN.UTF-8|ko_KR.UTF-8|de_DE.UTF-8|fr_FR.UTF-8|es_ES.UTF-8|pt_BR.UTF-8"

SELECTED_LANG=$(echo "$LANG_LIST" | tr '|' '\n' | zenity --list \
    --title="言語設定" \
    --text="システム言語を選択してください:" \
    --column="言語" \
    --width=400 --height=400 2>/dev/null) || SELECTED_LANG="en_US.UTF-8"

SELECTED_LANG="${SELECTED_LANG:-en_US.UTF-8}"
log "Language selected: $SELECTED_LANG"

# ---------------------------------------------------------------------------
# 5. Confirmation
# ---------------------------------------------------------------------------
zenity --question \
    --title="設定確認" \
    --text="以下の設定で初期化します:\n\n  ユーザー名: $NEW_USERNAME\n  タイムゾーン: $SELECTED_TZ\n  言語: $SELECTED_LANG\n\n続行しますか?" \
    --ok-label="適用" \
    --cancel-label="キャンセル" \
    --width=400 --height=300 2>/dev/null || {
    log "User cancelled setup — keeping defaults"
    date -Iseconds > "$WIZARD_COMPLETE"
    rm -f "$WIZARD_PENDING"
    exit 0
}

# ---------------------------------------------------------------------------
# 6. Apply settings (requires pkexec for privileged operations)
# ---------------------------------------------------------------------------
log "Applying settings..."

# Helper: run command as root
run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        pkexec "$@"
    fi
}

# --- Username ---
if [ "$NEW_USERNAME" != "$CURRENT_USER" ] && ! id -u "$NEW_USERNAME" >/dev/null 2>&1; then
    log "Renaming user $CURRENT_USER -> $NEW_USERNAME"
    run_as_root usermod -l "$NEW_USERNAME" "$CURRENT_USER" 2>>"$LOG" || true
    run_as_root usermod -d "/home/$NEW_USERNAME" -m "$NEW_USERNAME" 2>>"$LOG" || true
    run_as_root groupmod -n "$NEW_USERNAME" "$CURRENT_USER" 2>>"$LOG" || true
    log "User renamed to $NEW_USERNAME"
else
    log "Keeping username: $NEW_USERNAME"
fi

# --- Password ---
echo "$NEW_USERNAME:$PASSWORD" | run_as_root chpasswd 2>>"$LOG"
log "Password set for $NEW_USERNAME"

# Remove NOPASSWD sudo (now that user has set a password)
if [ -f /etc/sudoers.d/ubuntu-gsi ]; then
    echo "$NEW_USERNAME ALL=(ALL) ALL" | run_as_root tee /etc/sudoers.d/ubuntu-gsi >/dev/null
    run_as_root chmod 440 /etc/sudoers.d/ubuntu-gsi
    log "Sudo NOPASSWD removed — password now required"
fi

# Clear password from memory
PASSWORD=""
PASSWORD_CONFIRM=""

# --- Timezone ---
run_as_root ln -sf "/usr/share/zoneinfo/$SELECTED_TZ" /etc/localtime 2>>"$LOG" || true
echo "$SELECTED_TZ" | run_as_root tee /etc/timezone >/dev/null 2>>"$LOG" || true
log "Timezone set to $SELECTED_TZ"

# --- Language ---
if [ -f /etc/locale.gen ]; then
    run_as_root sed -i "s/^# *${SELECTED_LANG}/${SELECTED_LANG}/" /etc/locale.gen 2>>"$LOG" || true
    run_as_root locale-gen 2>>"$LOG" || true
fi
cat <<EOF | run_as_root tee /etc/default/locale >/dev/null
LANG=$SELECTED_LANG
LC_ALL=$SELECTED_LANG
EOF
log "Language set to $SELECTED_LANG"

# ---------------------------------------------------------------------------
# 7. Mark wizard complete
# ---------------------------------------------------------------------------
date -Iseconds > "$WIZARD_COMPLETE"
rm -f "$WIZARD_PENDING"

log "Setup Wizard completed successfully"

zenity --info \
    --title="セットアップ完了" \
    --text="初期設定が完了しました!\n\nユーザー名: $NEW_USERNAME\nタイムゾーン: $SELECTED_TZ\n言語: $SELECTED_LANG\n\nシステムを再起動すると設定が反映されます。" \
    --ok-label="OK" \
    --width=400 --height=300 2>/dev/null || true

# Ask for reboot
zenity --question \
    --title="再起動" \
    --text="設定を完全に反映するため、今すぐ再起動しますか?" \
    --ok-label="再起動" \
    --cancel-label="後で" \
    --width=300 --height=150 2>/dev/null && {
    log "User requested reboot"
    run_as_root systemctl reboot
}

#!/bin/bash
# =============================================================================
# compat/compat-engine.sh — PHH/TrebleDroid-style runtime quirk applier
# =============================================================================
# Reads compat/quirks.json, matches the running platform via
# compat/lib/detect-platform.sh, applies sysfs/proc/udev/systemd actions
# and emits /run/ubuntu-gsi/compat-status.json for diagnostics.
#
# Equivalent of:
#   - device_phh_treble/phh-on-boot.sh + phh-prop-handler.sh
#   - vendor_hardware_overlay (per-brand overlay selection)
#   - TrebleDroid/treble_app Misc.kt runtime toggles
# but expressed in Linux primitives because the GSI runs Ubuntu userspace,
# not Android framework.
# =============================================================================

set -u

# ---------------------------------------------------------------------------
# Paths & defaults
# ---------------------------------------------------------------------------
COMPAT_ROOT="${COMPAT_ROOT:-/usr/lib/ubuntu-gsi/compat}"
COMPAT_QUIRKS="${COMPAT_QUIRKS:-$COMPAT_ROOT/quirks.json}"
COMPAT_DETECT="${COMPAT_DETECT:-$COMPAT_ROOT/lib/detect-platform.sh}"
COMPAT_RUN_DIR="${COMPAT_RUN_DIR:-/run/ubuntu-gsi/compat}"
COMPAT_STATUS="${COMPAT_STATUS:-/run/ubuntu-gsi/compat-status.json}"
COMPAT_RUNTIME_ENV="${COMPAT_RUNTIME_ENV:-/etc/default/ubuntu-gsi-compat.runtime}"
COMPAT_USER_ENV="${COMPAT_USER_ENV:-/etc/default/ubuntu-gsi-compat}"
COMPAT_LOG="${COMPAT_LOG:-/var/log/ubuntu-gsi-compat.log}"
COMPAT_LOCK="${COMPAT_LOCK:-/run/ubuntu-gsi/compat.lock}"

mkdir -p "$COMPAT_RUN_DIR" /etc/default 2>/dev/null || true
mkdir -p "$(dirname "$COMPAT_LOG")" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    local ts
    ts=$(date -Iseconds 2>/dev/null || date +%s)
    printf '[%s] [compat-engine] %s\n' "$ts" "$*" | tee -a "$COMPAT_LOG"
}

warn() { log "WARN: $*"; }

# ---------------------------------------------------------------------------
# Single-instance lock
# ---------------------------------------------------------------------------
exec 9>"$COMPAT_LOCK" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
    flock -n 9 || { log "Another compat-engine instance is running; exiting"; exit 0; }
fi

# ---------------------------------------------------------------------------
# Source platform detection (creates $COMPAT_RUN_DIR/platform.env)
# ---------------------------------------------------------------------------
if [ -r "$COMPAT_DETECT" ]; then
    # shellcheck source=/dev/null
    . "$COMPAT_DETECT"
else
    warn "Platform detector missing: $COMPAT_DETECT"
fi

# Sane defaults so the engine can run on a host without /vendor.
: "${COMPAT_PLATFORM:=}"
: "${COMPAT_BRAND:=}"
: "${COMPAT_MANUFACTURER:=}"
: "${COMPAT_MODEL:=}"
: "${COMPAT_FINGERPRINT:=}"
: "${COMPAT_SOC_VENDOR:=unknown}"
: "${COMPAT_VENDOR_FP:=unknown}"

log "Platform: '${COMPAT_PLATFORM}' brand='${COMPAT_BRAND}' model='${COMPAT_MODEL}' soc=${COMPAT_SOC_VENDOR}"

# ---------------------------------------------------------------------------
# Allow user override (/etc/default/ubuntu-gsi-compat)
# ---------------------------------------------------------------------------
if [ -r "$COMPAT_USER_ENV" ]; then
    # shellcheck source=/dev/null
    . "$COMPAT_USER_ENV"
fi

# Master kill switch
if [ "${UBUNTU_GSI_COMPAT_DISABLE:-0}" = "1" ]; then
    log "UBUNTU_GSI_COMPAT_DISABLE=1 — skipping all quirks"
    cat > "$COMPAT_STATUS" <<EOF
{ "applied": [], "skipped": [], "disabled": true }
EOF
    exit 0
fi

# ---------------------------------------------------------------------------
# Match helpers
#
# glob_match PATTERN VALUE
#   PATTERN supports the same shell-glob syntax as bash 'case' (with '|' as
#   alternation, e.g. "msm*|kona*"). Returns 0 on match.
# ---------------------------------------------------------------------------
glob_match() {
    local pattern="$1" value="$2"
    [ -z "$pattern" ] && return 0
    [ -z "$value" ]   && return 1
    local IFS='|'
    # shellcheck disable=SC2086
    set -- $pattern
    for p; do
        # SC2254: glob is intentional here — patterns come from quirks.json
        # shellcheck disable=SC2254
        case "$value" in
            $p) return 0 ;;
        esac
    done
    return 1
}

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
APPLIED_RULES=()
SKIPPED_RULES=()
APPLIED_ACTIONS=0
FAILED_ACTIONS=0

# ---------------------------------------------------------------------------
# Action executors
# ---------------------------------------------------------------------------
do_sysfs() {
    local path="$1" value="$2"
    [ -e "$path" ] || { log "  - sysfs miss: $path"; return 1; }
    if printf '%s' "$value" >"$path" 2>/dev/null; then
        log "  ✔ sysfs $path = $value"
        APPLIED_ACTIONS=$((APPLIED_ACTIONS + 1))
        return 0
    else
        warn "  ✗ sysfs failed: $path"
        FAILED_ACTIONS=$((FAILED_ACTIONS + 1))
        return 1
    fi
}

do_proc() { do_sysfs "$@"; }

do_modprobe() {
    local mod="$1"
    if command -v modprobe >/dev/null 2>&1 && modprobe -q "$mod" 2>/dev/null; then
        log "  ✔ modprobe $mod"
        APPLIED_ACTIONS=$((APPLIED_ACTIONS + 1))
    else
        log "  - modprobe skipped: $mod"
    fi
}

do_rmmod() {
    local mod="$1"
    if command -v rmmod >/dev/null 2>&1 && rmmod "$mod" 2>/dev/null; then
        log "  ✔ rmmod $mod"
        APPLIED_ACTIONS=$((APPLIED_ACTIONS + 1))
    fi
}

do_enable_service() {
    local unit="$1"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now "$unit" 2>/dev/null || \
            systemctl enable "$unit" 2>/dev/null || true
        log "  ✔ systemctl enable $unit (best-effort)"
        APPLIED_ACTIONS=$((APPLIED_ACTIONS + 1))
    fi
}

do_disable_service() {
    local unit="$1"
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl disable --now "$unit" 2>/dev/null || true
    log "  ✔ systemctl disable $unit"
    APPLIED_ACTIONS=$((APPLIED_ACTIONS + 1))
}

do_mask_service() {
    local unit="$1"
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl mask "$unit" 2>/dev/null || true
    log "  ✔ systemctl mask $unit"
    APPLIED_ACTIONS=$((APPLIED_ACTIONS + 1))
}

do_mkdir() {
    local path="$1" mode="${2:-}"
    mkdir -p "$path" 2>/dev/null || true
    [ -n "$mode" ] && chmod "$mode" "$path" 2>/dev/null || true
    log "  ✔ mkdir $path ($mode)"
    APPLIED_ACTIONS=$((APPLIED_ACTIONS + 1))
}

do_symlink() {
    local src="$1" dst="$2"
    [ -e "$src" ] || { log "  - symlink miss: $src -> $dst"; return 1; }
    ln -sf "$src" "$dst" 2>/dev/null || true
    log "  ✔ ln -sf $src $dst"
    APPLIED_ACTIONS=$((APPLIED_ACTIONS + 1))
}

do_env() {
    local key="$1" value="$2"
    printf '%s=%q\n' "$key" "$value" >>"$COMPAT_RUNTIME_ENV.tmp"
    log "  ✔ env $key=$value"
    APPLIED_ACTIONS=$((APPLIED_ACTIONS + 1))
}

do_log() {
    log "  i $*"
}

# ---------------------------------------------------------------------------
# JSON parser — prefer jq, fall back to a python3 helper, finally a pure-bash
# extractor. jq is part of the AOSP submodule build deps, so it's normally
# available in the rootfs (libjq1).
# ---------------------------------------------------------------------------
have_jq=0
have_py=0
command -v jq      >/dev/null 2>&1 && have_jq=1
command -v python3 >/dev/null 2>&1 && have_py=1

if [ "$have_jq" = 1 ]; then
    log "JSON parser: jq"
elif [ "$have_py" = 1 ]; then
    log "JSON parser: python3 fallback"
else
    warn "Neither jq nor python3 found — quirks.json processing will be limited"
fi

# Convert JSON quirks.json to a flat record stream that bash can iterate.
# Each rule becomes a header record, then one record per action.
# Records are NUL-separated to survive arbitrary content.
emit_records() {
    if [ "$have_jq" = 1 ]; then
        jq -r --arg z $'\x1f' '
            .rules[] |
            ( "RULE" + $z + (.id // "") + $z + (.description // "") + $z
              + ((.match.platform   // "")) + $z
              + ((.match.brand      // "")) + $z
              + ((.match.manufacturer // "")) + $z
              + ((.match.model      // "")) + $z
              + ((.match.fingerprint// "")) ),
            ( .actions[]? |
              "ACT" + $z + (.type // "") + $z
                    + (.path // "") + $z
                    + (.value // "") + $z
                    + (.module // "") + $z
                    + (.unit  // "") + $z
                    + (.src   // "") + $z
                    + (.dst   // "") + $z
                    + (.mode  // "") + $z
                    + (.key   // "") + $z
                    + (.message // "") )
        ' "$COMPAT_QUIRKS"
    elif [ "$have_py" = 1 ]; then
        python3 - "$COMPAT_QUIRKS" <<'PY'
import json, sys
SEP = "\x1f"
with open(sys.argv[1]) as f:
    data = json.load(f)
for r in data.get("rules", []):
    m = r.get("match", {}) or {}
    print(SEP.join([
        "RULE",
        r.get("id", ""),
        r.get("description", ""),
        m.get("platform", "") or "",
        m.get("brand", "") or "",
        m.get("manufacturer", "") or "",
        m.get("model", "") or "",
        m.get("fingerprint", "") or "",
    ]))
    for a in r.get("actions", []) or []:
        print(SEP.join([
            "ACT",
            a.get("type", "") or "",
            a.get("path", "") or "",
            a.get("value", "") or "",
            a.get("module", "") or "",
            a.get("unit", "") or "",
            a.get("src", "") or "",
            a.get("dst", "") or "",
            a.get("mode", "") or "",
            a.get("key", "") or "",
            a.get("message", "") or "",
        ]))
PY
    else
        # Last-ditch fallback: emit a single baseline rule + log action so the
        # engine keeps running on systems without jq or python3.
        local US=$'\x1f'
        printf 'RULE%sdefault-baseline%sfallback%s%s%s%s%s\n' \
            "$US" "$US" "$US" "$US" "$US" "$US" "$US"
        printf 'ACT%slog%s%s%s%s%s%s%s%s%s%sfallback (no jq/python3)\n' \
            "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US"
    fi
}

# ---------------------------------------------------------------------------
# Apply pipeline
# ---------------------------------------------------------------------------
: > "$COMPAT_RUNTIME_ENV.tmp"

current_rule_id=""
current_rule_active=0

# f11 is reserved for future action fields; keep it in the read list so the
# field count stays in sync with emit_records().
# shellcheck disable=SC2034
while IFS=$'\x1f' read -r kind f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11; do
    [ -z "${kind:-}" ] && continue
    case "$kind" in
        RULE)
            current_rule_id="$f1"
            local_desc="$f2"
            m_platform="$f3"
            m_brand="$f4"
            m_manuf="$f5"
            m_model="$f6"
            m_fp="$f7"

            current_rule_active=1
            if ! glob_match "$m_platform"   "$COMPAT_PLATFORM";    then current_rule_active=0; fi
            if ! glob_match "$m_brand"      "$COMPAT_BRAND";       then current_rule_active=0; fi
            if ! glob_match "$m_manuf"      "$COMPAT_MANUFACTURER";then current_rule_active=0; fi
            if ! glob_match "$m_model"      "$COMPAT_MODEL";       then current_rule_active=0; fi
            if ! glob_match "$m_fp"         "$COMPAT_FINGERPRINT"; then current_rule_active=0; fi

            if [ "$current_rule_active" = 1 ]; then
                APPLIED_RULES+=("$current_rule_id")
                log "▶ Rule '$current_rule_id': $local_desc"
            else
                SKIPPED_RULES+=("$current_rule_id")
            fi
            ;;
        ACT)
            [ "$current_rule_active" = 1 ] || continue
            atype="$f1"; apath="$f2"; aval="$f3"; amod="$f4"; aunit="$f5"
            asrc="$f6"; adst="$f7"; amode="$f8"; akey="$f9"; amsg="$f10"
            case "$atype" in
                sysfs)            do_sysfs "$apath" "$aval" || true ;;
                proc)             do_proc  "$apath" "$aval" || true ;;
                modprobe)         do_modprobe "$amod" ;;
                rmmod)            do_rmmod "$amod" ;;
                enable_service)   do_enable_service "$aunit" ;;
                disable_service)  do_disable_service "$aunit" ;;
                mask_service)     do_mask_service "$aunit" ;;
                mkdir)            do_mkdir "$apath" "$amode" ;;
                symlink)          do_symlink "$asrc" "$adst" ;;
                env)              do_env "$akey" "$aval" ;;
                log)              do_log "$amsg" ;;
                "")               : ;;
                *)                warn "Unknown action type: $atype" ;;
            esac
            ;;
    esac
done < <(emit_records)

# ---------------------------------------------------------------------------
# Promote env tmp -> final
# ---------------------------------------------------------------------------
if [ -s "$COMPAT_RUNTIME_ENV.tmp" ]; then
    {
        echo "# Auto-generated by /usr/lib/ubuntu-gsi/compat/compat-engine.sh"
        echo "# DO NOT EDIT BY HAND. Override toggles in $COMPAT_USER_ENV."
        cat "$COMPAT_RUNTIME_ENV.tmp"
    } > "$COMPAT_RUNTIME_ENV"
    log "Wrote runtime env: $COMPAT_RUNTIME_ENV"
fi
rm -f "$COMPAT_RUNTIME_ENV.tmp" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Optional: invoke prop-handler.sh for any toggles set by quirks
# ---------------------------------------------------------------------------
if [ -x "$COMPAT_ROOT/prop-handler.sh" ]; then
    log "Invoking prop-handler.sh for runtime toggles"
    UBUNTU_GSI_COMPAT_RUNTIME="$COMPAT_RUNTIME_ENV" \
        "$COMPAT_ROOT/prop-handler.sh" apply-all || true
fi

# ---------------------------------------------------------------------------
# Emit /run/ubuntu-gsi/compat-status.json
# ---------------------------------------------------------------------------
join_quoted() {
    local first=1 r out=''
    for r in "$@"; do
        [ -z "$r" ] && continue
        if [ $first -eq 1 ]; then
            out="\"$r\""
            first=0
        else
            out="$out, \"$r\""
        fi
    done
    printf '%s' "$out"
}

{
    cat <<EOF
{
  "schema":           1,
  "generated_at":     "$(date -Iseconds 2>/dev/null || date +%s)",
  "engine":           "compat-engine.sh",
  "platform":         "$COMPAT_PLATFORM",
  "brand":            "$COMPAT_BRAND",
  "manufacturer":     "$COMPAT_MANUFACTURER",
  "model":            "$COMPAT_MODEL",
  "fingerprint":      "$COMPAT_FINGERPRINT",
  "soc_vendor":       "$COMPAT_SOC_VENDOR",
  "vendor_fp":        "$COMPAT_VENDOR_FP",
  "applied_rules":    [ $(join_quoted "${APPLIED_RULES[@]:-}") ],
  "skipped_rules":    [ $(join_quoted "${SKIPPED_RULES[@]:-}") ],
  "applied_actions":  $APPLIED_ACTIONS,
  "failed_actions":   $FAILED_ACTIONS,
  "runtime_env_file": "$COMPAT_RUNTIME_ENV",
  "log_file":         "$COMPAT_LOG"
}
EOF
} > "$COMPAT_STATUS"

log "Compat engine finished: ${#APPLIED_RULES[@]} rules / $APPLIED_ACTIONS actions / $FAILED_ACTIONS failed"
log "Status JSON: $COMPAT_STATUS"

exit 0

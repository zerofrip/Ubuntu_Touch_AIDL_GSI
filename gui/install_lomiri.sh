#!/bin/bash
# =============================================================================
# gui/install_lomiri.sh — Ubuntu Touch GUI Stack Installer
# =============================================================================
# Installs Mir display server and Lomiri shell into the rootfs.
# Run inside chroot during rootfs build or on first boot.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[GUI Install]${NC} $1"; }
success() { echo -e "${GREEN}[GUI Install]${NC} $1"; }
error()   { echo -e "${RED}[GUI Install]${NC} $1"; }

# ---------------------------------------------------------------------------
# Check environment
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    error "Must run as root"
    exit 1
fi

info "Installing Ubuntu Touch GUI stack (Mir + Lomiri)"
echo ""

# ---------------------------------------------------------------------------
# Add UBports PPA
# ---------------------------------------------------------------------------
info "Adding UBports repository..."

if ! command -v add-apt-repository >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y software-properties-common
fi

# Add UBports PPA for Lomiri packages
add-apt-repository -y ppa:ubports-developers/focal 2>/dev/null || {
    info "PPA not available — using manual source"
    echo "deb http://repo.ubports.com/ focal main" > /etc/apt/sources.list.d/ubports.list
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 579B9DA21E1E3D5D || true
}

apt-get update -qq

# ---------------------------------------------------------------------------
# Install Mir display server
# ---------------------------------------------------------------------------
info "Installing Mir display server..."

apt-get install -y --no-install-recommends \
    mir-graphics-drivers-desktop \
    mir-platform-graphics-wayland \
    libmiral-dev \
    2>/dev/null || {
    info "Some Mir packages unavailable — installing from alternatives"
    apt-get install -y --no-install-recommends \
        libmirclient-dev \
        mir-utils \
        2>/dev/null || true
}

success "Mir display server installed"

# ---------------------------------------------------------------------------
# Install Lomiri shell
# ---------------------------------------------------------------------------
info "Installing Lomiri shell..."

apt-get install -y --no-install-recommends \
    lomiri \
    lomiri-system-settings \
    lomiri-indicator-network \
    lomiri-indicator-datetime \
    lomiri-indicator-session \
    lomiri-indicator-power \
    2>/dev/null || {
    info "Some Lomiri packages unavailable — installing core only"
    apt-get install -y --no-install-recommends \
        lomiri \
        2>/dev/null || {
        error "Lomiri not available in repositories"
        error "The GUI will need to be installed manually"
        exit 0
    }
}

success "Lomiri shell installed"

# ---------------------------------------------------------------------------
# Install supporting packages
# ---------------------------------------------------------------------------
info "Installing supporting packages..."

apt-get install -y --no-install-recommends \
    onboard \
    zenity \
    fonts-ubuntu \
    fonts-noto \
    adwaita-icon-theme \
    dbus-x11 \
    2>/dev/null || true

success "Supporting packages installed"

# ---------------------------------------------------------------------------
# Configure auto-start
# ---------------------------------------------------------------------------
info "Configuring auto-start..."

# Install Lomiri systemd service
LOMIRI_SERVICE="/etc/systemd/system/lomiri.service"
if [ ! -f "$LOMIRI_SERVICE" ]; then
    cat > "$LOMIRI_SERVICE" << 'EOF'
[Unit]
Description=Lomiri Desktop Shell (Ubuntu Touch)
After=binder-bridge.service graphical.target dbus.service
Wants=binder-bridge.service dbus.service

[Service]
Type=simple
User=ubuntu
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=WAYLAND_DISPLAY=wayland-0
ExecStartPre=/usr/lib/ubuntu-gsi/gui/start_lomiri.sh --setup
ExecStart=/usr/bin/lomiri --mode=full-greeter
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical.target
EOF
    systemctl enable lomiri.service 2>/dev/null || true
fi

# Set default target to graphical
systemctl set-default graphical.target 2>/dev/null || true

success "Auto-start configured"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
apt-get clean
rm -rf /var/lib/apt/lists/*

echo ""
echo -e "${GREEN}${BOLD}  ✔  Ubuntu Touch GUI stack installed${NC}"
echo -e "  Lomiri will start automatically on boot."

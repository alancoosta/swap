#!/usr/bin/env bash
# ── Swap installer ──────────────────────────────────────────────────
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/alancoosta/swap/main/install.sh | bash
# ────────────────────────────────────────────────────────────────────
set -e

REPO="alancoosta/swap"
BRANCH="main"
REPO_URL="https://github.com/$REPO.git"

INSTALL_DIR="$HOME/.local/share/swap"
BIN_DIR="$HOME/.local/bin"
AUTOSTART_DIR="$HOME/.config/autostart"
CONFIG_FILE="$HOME/.claude/swap.json"
HICOLOR="$HOME/.local/share/icons/hicolor"

# ── Uninstall ─────────────────────────────────────────────────────────────
if [ "${1:-}" = "--uninstall" ]; then
    echo "==> Uninstalling Swap..."

    # Stop running instance
    TRAY_PID=$(pgrep -x swap 2>/dev/null || true)
    if [ -n "$TRAY_PID" ]; then
        kill $TRAY_PID 2>/dev/null || true
        echo "   Stopped running instance."
    fi

    rm -rf "$INSTALL_DIR"
    rm -f "$BIN_DIR/swap"
    rm -f "$AUTOSTART_DIR/swap.desktop"
    rm -f "$HICOLOR/scalable/apps/swap.svg"
    gtk-update-icon-cache -f -t "$HICOLOR" 2>/dev/null || true

    echo ""
    echo "Swap uninstalled successfully!"
    echo ""
    echo "   Config preserved at: $CONFIG_FILE"
    echo "   To remove it too:  rm $CONFIG_FILE"
    echo ""
    exit 0
fi

# ── Install / Update ──────────────────────────────────────────────────────
IS_UPDATE=false
if [ -d "$INSTALL_DIR" ] && [ -f "$BIN_DIR/swap" ]; then
    IS_UPDATE=true
    echo "==> Updating Swap..."
else
    echo "==> Installing Swap..."
fi

# ── 1. download source ────────────────────────────────────────────────────
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "==> Downloading Swap..."
if command -v git &>/dev/null; then
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMPDIR/swap" 2>/dev/null
else
    curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar xz -C "$TMPDIR"
    mv "$TMPDIR/swap-$BRANCH" "$TMPDIR/swap"
fi

SRC_DIR="$TMPDIR/swap"

# ── 2. dependencies ───────────────────────────────────────────────────────
echo "==> Checking build dependencies..."

# Rust toolchain
if ! command -v cargo &>/dev/null; then
    echo ""
    echo "ERROR: cargo (Rust toolchain) not found."
    echo "Install Rust from https://rustup.rs and re-run this script:"
    echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    exit 1
fi

# System dev libraries needed to compile the GTK / AppIndicator bindings.
MISSING_PKGS=()

command -v pkg-config &>/dev/null || MISSING_PKGS+=("pkg-config")
pkg-config --exists gtk+-3.0 2>/dev/null || MISSING_PKGS+=("libgtk-3-dev")
command -v notify-send &>/dev/null || MISSING_PKGS+=("libnotify-bin")

# Prefer the Ayatana variant (Ubuntu 22.04+), fall back to the legacy one.
if ! pkg-config --exists ayatana-appindicator3-0.1 2>/dev/null \
    && ! pkg-config --exists appindicator3-0.1 2>/dev/null; then
    if apt-cache show libayatana-appindicator3-dev >/dev/null 2>&1; then
        MISSING_PKGS+=("libayatana-appindicator3-dev")
    else
        MISSING_PKGS+=("libappindicator3-dev")
    fi
fi

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo ""
    echo "==> Installing missing system packages..."
    sudo apt-get install -y "${MISSING_PKGS[@]}" || {
        echo ""
        echo "ERROR: Could not install packages automatically."
        echo "Please run:"
        echo "  sudo apt install libgtk-3-dev libayatana-appindicator3-dev"
        echo "or, if Ayatana is unavailable:"
        echo "  sudo apt install libgtk-3-dev libappindicator3-dev"
        exit 1
    }
fi

# ── 3. build ──────────────────────────────────────────────────────────────
echo "==> Building Swap (release)..."
( cd "$SRC_DIR" && cargo build --release )

# ── 4. copy files ─────────────────────────────────────────────────────────
echo "==> Copying files to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

install -m 755 "$SRC_DIR/target/release/swap" "$BIN_DIR/swap"
mkdir -p "$INSTALL_DIR/assets"
cp "$SRC_DIR/assets/"*.svg "$INSTALL_DIR/assets/" 2>/dev/null || true
cp "$SRC_DIR/assets/"*.png "$INSTALL_DIR/assets/" 2>/dev/null || true
cp "$SRC_DIR/assets/"*.ico "$INSTALL_DIR/assets/" 2>/dev/null || true

# Install icon into hicolor theme
mkdir -p "$HICOLOR/scalable/apps"
cp "$SRC_DIR/assets/swap-icon.svg" "$HICOLOR/scalable/apps/swap.svg"
gtk-update-icon-cache -f -t "$HICOLOR" 2>/dev/null || true

# ── 5. autostart ──────────────────────────────────────────────────────────
echo "==> Setting up autostart..."
mkdir -p "$AUTOSTART_DIR"

cat > "$AUTOSTART_DIR/swap.desktop" << 'EOF'
[Desktop Entry]
Name=Swap
Comment=Switch between Claude Code settings profiles
Exec=$HOME/.local/bin/swap
Icon=swap
Terminal=false
Type=Application
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=15
EOF
sed -i "s|\$HOME|$HOME|g" "$AUTOSTART_DIR/swap.desktop"

# ── 6. seed config ────────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    echo "==> Creating starter config..."
    "$BIN_DIR/swap" --seed-only 2>/dev/null || true
fi

# ── 7. restart running instances ──────────────────────────────────────────
if [ "$IS_UPDATE" = true ]; then
    echo "==> Restarting running instance..."
    TRAY_PID=$(pgrep -x swap 2>/dev/null || true)
    if [ -n "$TRAY_PID" ]; then
        kill $TRAY_PID 2>/dev/null || true
        sleep 0.3
        nohup "$BIN_DIR/swap" >/dev/null 2>&1 &
        echo "   Tray daemon restarted."
    fi
fi

echo ""
if [ "$IS_UPDATE" = true ]; then
    echo "Swap updated successfully!"
else
    echo "Swap installed successfully!"
fi
echo ""
echo "   Start:  swap &"
echo ""
echo "   The tray will also start automatically on next login."
echo ""
echo "   TIP: On GNOME, if you don't see the tray icon, install:"
echo "   sudo apt install gnome-shell-extension-appindicator"
echo ""

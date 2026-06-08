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
echo "==> Checking dependencies..."

MISSING_PKGS=()

check_pkg() {
    python3 -c "import gi; gi.require_version('$1', '$2'); from gi.repository import $1" 2>/dev/null \
        || MISSING_PKGS+=("$3")
}

check_pkg "Gtk"  "3.0" "python3-gi"

# Check which AppIndicator variant is available
INDICATOR_PKG=""
python3 -c "import gi; gi.require_version('AyatanaAppIndicator3','0.1'); from gi.repository import AyatanaAppIndicator3" 2>/dev/null \
    && INDICATOR_PKG="ayatana" \
    || true

if [ -z "$INDICATOR_PKG" ]; then
    python3 -c "import gi; gi.require_version('AppIndicator3','0.1'); from gi.repository import AppIndicator3" 2>/dev/null \
        && INDICATOR_PKG="legacy" \
        || true
fi

if [ -z "$INDICATOR_PKG" ]; then
    MISSING_PKGS+=("gir1.2-appindicator3-0.1 or gir1.2-ayatanaappindicator3-0.1")
fi

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo ""
    echo "==> Installing missing packages..."
    INSTALL_LIST=()
    for pkg in "${MISSING_PKGS[@]}"; do
        case "$pkg" in
            python3-gi) INSTALL_LIST+=("python3-gi" "python3-gi-cairo" "gir1.2-gtk-3.0") ;;
            *appindicator*)
                if apt-cache show gir1.2-ayatanaappindicator3-0.1 >/dev/null 2>&1; then
                    INSTALL_LIST+=("gir1.2-ayatanaappindicator3-0.1")
                else
                    INSTALL_LIST+=("gir1.2-appindicator3-0.1")
                fi
                ;;
        esac
    done
    sudo apt-get install -y "${INSTALL_LIST[@]}" || {
        echo ""
        echo "ERROR: Could not install packages automatically."
        echo "Please run:"
        echo "  sudo apt install python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-appindicator3-0.1"
        echo "or on Ubuntu 22.04+:"
        echo "  sudo apt install python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1"
        exit 1
    }
fi

# ── 3. copy files ─────────────────────────────────────────────────────────
echo "==> Copying files to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

cp "$SRC_DIR/swap.py" "$INSTALL_DIR/"
mkdir -p "$INSTALL_DIR/assets"
cp "$SRC_DIR/assets/"*.svg "$INSTALL_DIR/assets/" 2>/dev/null || true
cp "$SRC_DIR/assets/"*.png "$INSTALL_DIR/assets/" 2>/dev/null || true
cp "$SRC_DIR/assets/"*.ico "$INSTALL_DIR/assets/" 2>/dev/null || true

# Install icon into hicolor theme
mkdir -p "$HICOLOR/scalable/apps"
cp "$SRC_DIR/assets/swap-icon.svg" "$HICOLOR/scalable/apps/swap.svg"
gtk-update-icon-cache -f -t "$HICOLOR" 2>/dev/null || true

# ── 4. launcher script ────────────────────────────────────────────────────
echo "==> Creating launcher command..."

cat > "$BIN_DIR/swap" << 'EOF'
#!/usr/bin/env bash
exec -a swap python3 "$HOME/.local/share/swap/swap.py" "$@"
EOF
chmod +x "$BIN_DIR/swap"

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
EOF
sed -i "s|\$HOME|$HOME|g" "$AUTOSTART_DIR/swap.desktop"

# ── 6. seed config ────────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    echo "==> Creating starter config..."
    python3 "$INSTALL_DIR/swap.py" --seed-only 2>/dev/null || true
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

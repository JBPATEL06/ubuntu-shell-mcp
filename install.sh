#!/usr/bin/env bash
# ==============================================================================
# ubuntu-shell-mcp & Dashboard Automated Installer
# 
# Installs ubuntu-shell-mcp and the Flutter companion app to ~/.local/ without
# requiring root/sudo privileges. After installation, the application runs
# completely standalone, independent of this source directory.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/share/ubuntu-shell-app"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="$HOME/.local/share/applications"

echo "=================================================="
echo "  Ubuntu Shell MCP Standalone Installer"
echo "=================================================="
echo ""

# 1. Check prerequisites
echo "[1/5] Checking prerequisites..."
if ! command -v dart &>/dev/null; then
  echo "Error: 'dart' SDK is not installed or not in PATH."
  exit 1
fi
if ! command -v flutter &>/dev/null; then
  echo "Error: 'flutter' SDK is not installed or not in PATH."
  exit 1
fi
if ! command -v zenity &>/dev/null; then
  echo "Warning: 'zenity' is not installed. You may need to run: sudo apt install zenity"
fi

# 2. Compile Server Binary
echo "[2/5] Compiling native MCP server binary..."
cd "$SCRIPT_DIR"
dart pub get
dart compile exe packages/usm_server/bin/main.dart -o packages/usm_server/ubuntu-shell-mcp

# 3. Build Flutter Application
echo "[3/5] Building Flutter Linux desktop application..."
cd "$SCRIPT_DIR/app"
flutter pub get
flutter build linux --release
cd "$SCRIPT_DIR"

# 4. Install files to ~/.local/share/ubuntu-shell-app
echo "[4/5] Installing standalone files into $INSTALL_DIR..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
mkdir -p "$BIN_DIR"
mkdir -p "$DESKTOP_DIR"

# Copy release bundle
cp -r "$SCRIPT_DIR/app/build/linux/x64/release/bundle/"* "$INSTALL_DIR/"
# Copy MCP server binary next to GUI app
cp "$SCRIPT_DIR/packages/usm_server/ubuntu-shell-mcp" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/ubuntu_shell_app"
chmod +x "$INSTALL_DIR/ubuntu-shell-mcp"

# Create symlinks in ~/.local/bin
ln -sf "$INSTALL_DIR/ubuntu-shell-mcp" "$BIN_DIR/ubuntu-shell-mcp"
ln -sf "$INSTALL_DIR/ubuntu_shell_app" "$BIN_DIR/ubuntu-shell-app"

# 5. Create Desktop Entry
echo "[5/5] Creating Ubuntu desktop shortcut..."
cat <<EOF > "$DESKTOP_DIR/ubuntu-shell-app.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Ubuntu Shell MCP
Comment=Hardened Model Context Protocol Server & Management Dashboard
Exec=$BIN_DIR/ubuntu-shell-app
Icon=utilities-terminal
Terminal=false
Categories=Utility;Development;
StartupNotify=true
EOF
chmod +x "$DESKTOP_DIR/ubuntu-shell-app.desktop"

echo ""
echo "=================================================="
echo "  ✓ Installation Complete!"
echo "=================================================="
echo ""
echo "Installed Components:"
echo "  • Standalone App: $INSTALL_DIR"
echo "  • MCP Server:     $BIN_DIR/ubuntu-shell-mcp"
echo "  • GUI Dashboard:  $BIN_DIR/ubuntu-shell-app"
echo "  • App Shortcut:   $DESKTOP_DIR/ubuntu-shell-app.desktop"
echo ""
echo "Next Steps:"
echo "  1. Launch the app by searching 'Ubuntu Shell MCP' in your Applications"
echo "     or run in terminal: ubuntu-shell-app"
echo "  2. In the app, navigate to 'Connect AI Client' and click"
echo "     'Configure Claude Desktop (1-Click)'."
echo "  3. You can now safely close, move, or delete this source repository!"
echo "=================================================="

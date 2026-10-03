#!/usr/bin/env bash
# ==============================================================================
# ubuntu-shell-mcp & Dashboard Automated Uninstaller
# ==============================================================================

set -euo pipefail

INSTALL_DIR="$HOME/.local/share/ubuntu-shell-app"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="$HOME/.local/share/applications"

echo "=================================================="
echo "  Ubuntu Shell MCP Uninstaller"
echo "=================================================="
echo ""

echo "Removing installed binaries and desktop entries..."
rm -rf "$INSTALL_DIR"
rm -f "$BIN_DIR/ubuntu-shell-mcp"
rm -f "$BIN_DIR/ubuntu-shell-app"
rm -f "$DESKTOP_DIR/ubuntu-shell-app.desktop"

echo "✓ Binaries and desktop shortcuts removed."
echo ""
echo "Note: Your audit logs and configuration under ~/.local/share/ubuntu-shell-mcp/"
echo "and ~/.config/ubuntu-shell-mcp/ were preserved."
echo "If you wish to remove them as well, run:"
echo "  rm -rf ~/.local/share/ubuntu-shell-mcp ~/.config/ubuntu-shell-mcp"
echo "=================================================="

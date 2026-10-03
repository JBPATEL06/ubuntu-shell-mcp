#!/bin/bash
# ==============================================================================
# Stripped-Environment Regression Test for ubuntu-shell-mcp
#
# PURPOSE:
# Verifies that ubuntu-shell-mcp successfully auto-discovers active GUI display
# sockets (Wayland/X11) when invoked inside an environment stripped of DISPLAY
# and WAYLAND_DISPLAY, reproducing the exact execution environment used by
# desktop launchers such as Claude Desktop:
#   env -i HOME=$HOME USER=$USER LOGNAME=$USER PATH=/usr/bin:/bin SHELL=/bin/bash
#
# HOW TO RUN:
#   1. Ensure the binary is compiled:
#        dart compile exe packages/usm_server/bin/main.dart -o packages/usm_server/ubuntu-shell-mcp
#   2. Run this script directly from the repository root:
#        ./test/integration/stripped_env.sh
#      or:
#        bash test/integration/stripped_env.sh
#
# EXIT STATUS:
#   0 - Success (or gracefully skipped if no graphical session exists on host)
#   1 - Failure (display discovery failed despite active graphical session)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BINARY="$REPO_ROOT/packages/usm_server/ubuntu-shell-mcp"

echo "=== Stripped-Environment Regression Test ==="
echo "Target binary: $BINARY"

if [ ! -f "$BINARY" ]; then
  echo "Error: Binary not found at $BINARY"
  echo "Please compile it first with:"
  echo "  dart compile exe packages/usm_server/bin/main.dart -o packages/usm_server/ubuntu-shell-mcp"
  exit 1
fi

# Detect whether a graphical session exists on this machine
UID_NUM="$(id -u)"
HAS_GRAPHICAL_SESSION=0

if [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; then
  HAS_GRAPHICAL_SESSION=1
fi

if [ "$HAS_GRAPHICAL_SESSION" -eq 0 ] && [ -d "/run/user/$UID_NUM" ]; then
  for w in "/run/user/$UID_NUM"/wayland-*; do
    if [ -e "$w" ]; then
      HAS_GRAPHICAL_SESSION=1
      break
    fi
  done
fi

if [ "$HAS_GRAPHICAL_SESSION" -eq 0 ] && [ -d "/tmp/.X11-unix" ]; then
  for x in /tmp/.X11-unix/X*; do
    if [ -e "$x" ]; then
      HAS_GRAPHICAL_SESSION=1
      break
    fi
  done
fi

if [ "$HAS_GRAPHICAL_SESSION" -eq 0 ]; then
  echo "SKIP: No active graphical session (Wayland or X11) exists on this host."
  echo "Display discovery cannot run without an active session."
  exit 0
fi

echo "Active graphical session detected on host. Executing binary in stripped environment..."

# Execute binary under strictly stripped environment mimicking Claude Desktop
OUTPUT=$(env -i \
  HOME="$HOME" \
  USER="$USER" \
  LOGNAME="$USER" \
  PATH="/usr/bin:/bin" \
  SHELL="/bin/bash" \
  "$BINARY" --check-display 2>&1 || true)

if echo "$OUTPUT" | grep -q "GUI display resolved via"; then
  RESOLVED_LINE=$(echo "$OUTPUT" | grep "GUI display resolved via" | head -n 1)
  echo "SUCCESS: Display discovery succeeded in stripped environment!"
  echo "Diagnostic output: $RESOLVED_LINE"
  exit 0
else
  echo "FAILURE: Display discovery failed in stripped environment."
  echo "Command output was:"
  echo "$OUTPUT"
  exit 1
fi

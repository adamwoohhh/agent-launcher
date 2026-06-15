#!/usr/bin/env bash
set -euo pipefail

REPO="${SCC_REPO:-adamwoohhh/safe-claude-code}"
REF="${SCC_REF:-main}"
INSTALL_DIR="${SCC_INSTALL_DIR:-$HOME/.local/bin}"
SCRIPT_URL="https://raw.githubusercontent.com/$REPO/$REF/safe-claude-code.sh"

err() { echo "❌ $*" >&2; exit 1; }
info() { echo "==> $*"; }

command -v curl >/dev/null 2>&1 || err "curl is required"
command -v bash >/dev/null 2>&1 || err "bash is required"

info "Installing from $SCRIPT_URL"
info "Target dir:    $INSTALL_DIR"

mkdir -p "$INSTALL_DIR"

TARGET="$INSTALL_DIR/agent-launch"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

curl -fsSL "$SCRIPT_URL" -o "$TMP" || err "Download failed: $SCRIPT_URL"

head -n1 "$TMP" | grep -q '^#!/usr/bin/env bash$' || err "Downloaded file doesn't look like the script"

mv "$TMP" "$TARGET"
chmod +x "$TARGET"

ln -sf agent-launch "$INSTALL_DIR/al"
rm -f "$INSTALL_DIR/safe-claude-code" "$INSTALL_DIR/scc" "$INSTALL_DIR/scc-config"

info "Installed:"
info "  $TARGET"
info "  $INSTALL_DIR/al -> agent-launch"

case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    info "$INSTALL_DIR is already in your PATH."
    ;;
  *)
    echo
    echo "⚠️  $INSTALL_DIR is NOT in your PATH."
    echo "    Add this to ~/.zshrc or ~/.bashrc:"
    echo
    echo "      export PATH=\"$INSTALL_DIR:\$PATH\""
    echo
    ;;
esac

cat <<'USAGE'

Quick start:
  # Select codex or claude, review startup check, then confirm launch
  al

Re-run this installer anytime to update.
USAGE

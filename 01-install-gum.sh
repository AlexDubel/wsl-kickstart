#!/usr/bin/env bash
# ============================================================================
# 01-install-gum.sh — bootstrap charmbracelet/gum on a fresh WSL image.
#
#   1. Verifies `gum` is on PATH (exits happily if it already is).
#   2. If missing: adds the signed Charm apt repository and installs gum.
#   3. Reloads ~/.bashrc so the current shell picks up any changes.
#
# Usage:
#   ./01-install-gum.sh          # install / verify gum
#   ./01-install-gum.sh --help   # this help
#
# Theme (override via environment; term256 numbers or hex once gum is present):
#   THEME_PRIMARY=39 THEME_SUCCESS=46 THEME_ERROR=196 \
#   THEME_INFO=39 THEME_MUTED=245 ./01-install-gum.sh
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Theme — colours for every message (override via environment variables)
# ---------------------------------------------------------------------------
THEME_PRIMARY="${THEME_PRIMARY:-212}"   # headings / banners
THEME_SUCCESS="${THEME_SUCCESS:-46}"    # success messages
THEME_ERROR="${THEME_ERROR:-196}"       # errors
THEME_INFO="${THEME_INFO:-39}"          # step / info messages
THEME_MUTED="${THEME_MUTED:-245}"       # hints / footnotes

# ---------------------------------------------------------------------------
# Output helpers — use gum when present, plain ANSI 256-colour otherwise
# (this script must also work *before* gum exists)
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

style() { # style <bold 0|1> <colour> <text...>
    local bold="$1" colour="$2"; shift 2
    if have gum; then
        gum style "--bold=$bold" --foreground "$colour" "$*"
    else
        printf '\033[%s;38;5;%sm%s\033[0m\n' "$bold" "$colour" "$*"
    fi
}

hdr()   { style 1 "$THEME_PRIMARY" "▶ $*"; }
ok()    { style 0 "$THEME_SUCCESS" "✔ $*"; }
info()  { style 0 "$THEME_INFO"    "· $*"; }
warn()  { style 0 "$THEME_ERROR"   "! $*"; }
muted() { style 0 "$THEME_MUTED"   "  $*"; }
die()   { warn "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
01-install-gum.sh — make sure charmbracelet/gum is installed.

Usage:
  ./01-install-gum.sh          install (or verify) gum
  ./01-install-gum.sh --help   show this help

Theme overrides (environment variables; term256 colour numbers or hex):
  THEME_PRIMARY  headings/banners   (default 212)
  THEME_SUCCESS  success messages   (default 46)
  THEME_ERROR    errors             (default 196)
  THEME_INFO     step/info messages (default 39)
  THEME_MUTED    hints/footnotes    (default 245)
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
    esac

    if have gum; then
        ok "gum $(gum --version 2>/dev/null || echo 'is already installed') — nothing to do."
        exit 0
    fi

    hdr "gum bootstrap"

    [[ $EUID -eq 0 ]] && die "run as your normal user (sudo is used where needed), not as root."
    sudo -v || die "sudo access is required to add the Charm apt repository."
    local dep
    for dep in curl gpg apt; do
        have "$dep" || die "missing dependency: $dep"
    done

    info "gum not found — adding the Charm apt repository…"

    info "creating /etc/apt/keyrings"
    sudo mkdir -p /etc/apt/keyrings

    info "importing Charm GPG key → /etc/apt/keyrings/charm.gpg"
    sudo rm -f /etc/apt/keyrings/charm.gpg   # idempotency: safe to re-run
    curl -fsSL https://repo.charm.sh/apt/gpg.key \
        | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg

    info "adding repository → /etc/apt/sources.list.d/charm.list"
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
        | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null

    info "running apt update && apt install gum"
    sudo apt update && sudo apt install -y gum

    have gum || die "install finished but gum is still not on PATH — open a new terminal and re-run"
    ok "gum $(gum --version) installed."

    # Reload ~/.bashrc for the current shell. Ubuntu's default ~/.bashrc
    # returns early for non-interactive shells; a non-empty PS1 makes it
    # load fully even from inside a script.
    if [[ -f "$HOME/.bashrc" ]]; then
        PS1="${PS1:-\\\$ }"
        # shellcheck disable=SC1090
        source "$HOME/.bashrc" >/dev/null 2>&1 || true
        hash -r
        ok "~/.bashrc reloaded for this shell."
        muted "fresh terminals will pick gum up automatically."
    fi

    ok "all set ✨  try: gum style --foreground 212 'hello from gum'"
}

main "$@"

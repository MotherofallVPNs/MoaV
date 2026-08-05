#!/bin/bash
set -euo pipefail

# =============================================================================
# Package a user's bundle into a distributable zip
# Usage: ./scripts/user-package.sh <username>
#
# Creates outputs/bundles/<username>-configs.zip from what the bundle already
# contains: the client guide (README.html), every config / share-link file, and
# the QR images. This script generates and renders nothing — the bundle is built
# by `moav user add` (host) / generate-user.sh (container), and README.html by
# lib/bundle-readme.sh.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

source scripts/lib/common.sh

USERNAME="${1:-}"

if [[ -z "$USERNAME" ]]; then
    echo "Usage: $0 <username>"
    echo ""
    echo "Packages user configs into a zip file with an HTML guide."
    echo "The zip will be created at: outputs/bundles/<username>-configs.zip"
    exit 1
fi

# `zip` is required and is NOT part of the install prerequisites. Check it up
# front: without this guard the failure surfaced deep in the run, and
# user-add.sh's `--package` call absorbs a non-zero exit (it runs inside an
# `if`), so a host without zip silently produced no archive while `moav user add
# --package` still reported success. Matches the guards in `moav user package`
# and `moav user base64`.
if ! command -v zip &>/dev/null; then
    log_error "zip command not found — cannot create the package archive."
    log_error "  Debian/Ubuntu: sudo apt install zip"
    log_error "  RHEL/Fedora:   sudo dnf install zip"
    log_error "  macOS:         brew install zip"
    exit 1
fi

# Check if user bundle exists
BUNDLE_DIR="outputs/bundles/$USERNAME"
if [[ ! -d "$BUNDLE_DIR" ]]; then
    log_error "User bundle not found: $BUNDLE_DIR"
    log_error "Create the user first with: moav user add $USERNAME"
    exit 1
fi

# Load environment for server info
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

log_info "========================================="
log_info "Packaging configs for user: $USERNAME"
log_info "========================================="
echo ""

# Create temp directory for packaging
TEMP_DIR=$(mktemp -d)
PACKAGE_DIR="$TEMP_DIR/$USERNAME-moav-configs"
mkdir -p "$PACKAGE_DIR"

# -----------------------------------------------------------------------------
# Copy the bundle into the package
# -----------------------------------------------------------------------------
# The bundle already holds the finished artifacts: the client guide rendered by
# render_bundle_readme (lib/bundle-readme.sh — the single source of truth for
# README.html) plus every config, share-link and QR image. Copy them; do NOT
# re-render. This script used to keep its own sed/awk copy of the template
# render, which only substituted 19 of the template's 45 placeholders and then
# OVERWROTE the correct guide — shipping users a README.html with ~26 raw
# {{PLACEHOLDER}} markers (Shadowsocks/XHTTP/AmneziaWG/Telegram/XDNS sections).

log_info "Copying bundle files..."

shopt -s nullglob
for file in "$BUNDLE_DIR"/*.html "$BUNDLE_DIR"/*.png "$BUNDLE_DIR"/*.txt \
            "$BUNDLE_DIR"/*.conf "$BUNDLE_DIR"/*.yaml "$BUNDLE_DIR"/*.json \
            "$BUNDLE_DIR"/*.pem "$BUNDLE_DIR"/*.toml "$BUNDLE_DIR"/*.gs; do
    [[ -f "$file" ]] && cp "$file" "$PACKAGE_DIR/"
done
shopt -u nullglob

# The guide is the point of the package — fail loudly rather than ship a zip
# without it (or with a stale one).
if [[ ! -s "$PACKAGE_DIR/README.html" ]]; then
    log_error "No README.html in $BUNDLE_DIR — the bundle is incomplete."
    log_error "Regenerate it with: moav regenerate-users   (or: moav user add $USERNAME)"
    rm -rf "$TEMP_DIR"
    exit 1
fi

log_info "  Bundle files copied ($(find "$PACKAGE_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ') files)"

# -----------------------------------------------------------------------------
# Create zip archive
# -----------------------------------------------------------------------------

log_info "Creating zip archive..."

OUTPUT_ZIP="outputs/bundles/${USERNAME}-configs.zip"

# Remove old zip if exists
rm -f "$OUTPUT_ZIP"

# Create zip
(cd "$TEMP_DIR" && zip -r "$SCRIPT_DIR/../$OUTPUT_ZIP" "$USERNAME-moav-configs" -x "*.bak" -x "*.tmp")

# Clean up temp directory
rm -rf "$TEMP_DIR"

# The zip bundles every client key; admin-owned, no world bits
grant_admin_rw "$OUTPUT_ZIP"

log_info "  Zip created"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

echo ""
log_info "========================================="
log_info "Package created successfully!"
log_info "========================================="
echo ""
log_info "Output: $OUTPUT_ZIP"
echo ""

# Show package contents
log_info "Package contents:"
unzip -l "$OUTPUT_ZIP" | grep -E "^\s+[0-9]+" | grep -v "files$"

echo ""
log_info "Distribute this zip file securely to the user."
log_info "The HTML guide (README.html) includes all instructions and QR codes."

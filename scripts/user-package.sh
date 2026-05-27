#!/bin/bash
set -euo pipefail

# =============================================================================
# Package user configs into a distributable zip file with HTML guide
# Usage: ./scripts/user-package.sh <username>
#
# Creates: outputs/bundles/<username>-configs.zip containing:
#   - All config files (.txt, .conf, .yaml)
#   - QR code images (generated if qrencode available)
#   - Personalized HTML guide with embedded QR codes
#
# Requirements: qrencode (optional, for QR codes)
#   - macOS: brew install qrencode
#   - Ubuntu/Debian: apt install qrencode
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
# Extract values from config files
# -----------------------------------------------------------------------------

# Server IP
SERVER_IP="${SERVER_IP:-$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")}"

# Domain
DOMAIN="${DOMAIN:-YOUR_DOMAIN}"

# Generated date
GENERATED_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Reality config
CONFIG_REALITY=""
if [[ -f "$BUNDLE_DIR/reality.txt" ]]; then
    CONFIG_REALITY=$(cat "$BUNDLE_DIR/reality.txt" | tr -d '\n')
fi

# Hysteria2 config
CONFIG_HYSTERIA2=""
if [[ -f "$BUNDLE_DIR/hysteria2.txt" ]]; then
    CONFIG_HYSTERIA2=$(cat "$BUNDLE_DIR/hysteria2.txt" | tr -d '\n')
fi

# Trojan config
CONFIG_TROJAN=""
if [[ -f "$BUNDLE_DIR/trojan.txt" ]]; then
    CONFIG_TROJAN=$(cat "$BUNDLE_DIR/trojan.txt" | tr -d '\n')
fi

# WireGuard config
CONFIG_WIREGUARD=""
if [[ -f "$BUNDLE_DIR/wireguard.conf" ]]; then
    CONFIG_WIREGUARD=$(cat "$BUNDLE_DIR/wireguard.conf")
fi

# WireGuard-wstunnel config (for censored networks)
CONFIG_WIREGUARD_WSTUNNEL=""
if [[ -f "$BUNDLE_DIR/wireguard-wstunnel.conf" ]]; then
    CONFIG_WIREGUARD_WSTUNNEL=$(cat "$BUNDLE_DIR/wireguard-wstunnel.conf")
fi

# DNS Tunnel info
DNSTT_DOMAIN="${DNSTT_SUBDOMAIN:-t}.${DOMAIN}"
DNSTT_PUBKEY=""
if [[ -f "outputs/dnstt/server.pub" ]]; then
    DNSTT_PUBKEY=$(cat "outputs/dnstt/server.pub" 2>/dev/null || echo "")
elif [[ -f "$BUNDLE_DIR/dnstt-instructions.txt" ]]; then
    # Extract from instructions file
    DNSTT_PUBKEY=$(grep -A1 "Server Public Key" "$BUNDLE_DIR/dnstt-instructions.txt" 2>/dev/null | tail -1 | tr -d '# ' || echo "")
fi

# -----------------------------------------------------------------------------
# Generate QR codes
# -----------------------------------------------------------------------------

log_info "Generating QR codes..."

# Check if qrencode is available
if ! command -v qrencode &>/dev/null; then
    log_warn "  qrencode not installed - QR codes will be skipped"
    log_warn "  Install with: brew install qrencode (macOS) or apt install qrencode (Linux)"
    QR_AVAILABLE=false
else
    QR_AVAILABLE=true
fi

generate_qr() {
    local content="$1"
    local output="$2"
    local is_file="${3:-false}"

    if [[ "$QR_AVAILABLE" != "true" ]]; then
        return 1
    fi

    if [[ "$is_file" == "true" ]]; then
        qrencode -o "$output" -s 6 -r "$content" 2>/dev/null && return 0
    else
        qrencode -o "$output" -s 6 "$content" 2>/dev/null && return 0
    fi
    return 1
}

QR_COUNT=0

# Generate QR for Reality
QR_REALITY_FILE="$PACKAGE_DIR/reality-qr.png"
if [[ -n "$CONFIG_REALITY" ]]; then
    if [[ -f "$BUNDLE_DIR/reality-qr.png" ]]; then
        cp "$BUNDLE_DIR/reality-qr.png" "$QR_REALITY_FILE"
        ((QR_COUNT++)) || true
    elif generate_qr "$CONFIG_REALITY" "$QR_REALITY_FILE"; then
        ((QR_COUNT++)) || true
    fi
fi

# Generate QR for Hysteria2
QR_HYSTERIA2_FILE="$PACKAGE_DIR/hysteria2-qr.png"
if [[ -n "$CONFIG_HYSTERIA2" ]]; then
    if [[ -f "$BUNDLE_DIR/hysteria2-qr.png" ]]; then
        cp "$BUNDLE_DIR/hysteria2-qr.png" "$QR_HYSTERIA2_FILE"
        ((QR_COUNT++)) || true
    elif generate_qr "$CONFIG_HYSTERIA2" "$QR_HYSTERIA2_FILE"; then
        ((QR_COUNT++)) || true
    fi
fi

# Generate QR for Trojan
QR_TROJAN_FILE="$PACKAGE_DIR/trojan-qr.png"
if [[ -n "$CONFIG_TROJAN" ]]; then
    if [[ -f "$BUNDLE_DIR/trojan-qr.png" ]]; then
        cp "$BUNDLE_DIR/trojan-qr.png" "$QR_TROJAN_FILE"
        ((QR_COUNT++)) || true
    elif generate_qr "$CONFIG_TROJAN" "$QR_TROJAN_FILE"; then
        ((QR_COUNT++)) || true
    fi
fi

# Generate QR for WireGuard
QR_WIREGUARD_FILE="$PACKAGE_DIR/wireguard-qr.png"
if [[ -n "$CONFIG_WIREGUARD" ]]; then
    if [[ -f "$BUNDLE_DIR/wireguard-qr.png" ]]; then
        cp "$BUNDLE_DIR/wireguard-qr.png" "$QR_WIREGUARD_FILE"
        ((QR_COUNT++)) || true
    elif generate_qr "$BUNDLE_DIR/wireguard.conf" "$QR_WIREGUARD_FILE" "true"; then
        ((QR_COUNT++)) || true
    fi
fi

# Generate QR for WireGuard-wstunnel
QR_WIREGUARD_WSTUNNEL_FILE="$PACKAGE_DIR/wireguard-wstunnel-qr.png"
if [[ -n "$CONFIG_WIREGUARD_WSTUNNEL" ]]; then
    if [[ -f "$BUNDLE_DIR/wireguard-wstunnel-qr.png" ]]; then
        cp "$BUNDLE_DIR/wireguard-wstunnel-qr.png" "$QR_WIREGUARD_WSTUNNEL_FILE"
        ((QR_COUNT++)) || true
    elif generate_qr "$BUNDLE_DIR/wireguard-wstunnel.conf" "$QR_WIREGUARD_WSTUNNEL_FILE" "true"; then
        ((QR_COUNT++)) || true
    fi
fi

if [[ $QR_COUNT -gt 0 ]]; then
    log_info "  $QR_COUNT QR code(s) generated"
else
    log_info "  No QR codes generated"
fi

# -----------------------------------------------------------------------------
# Convert QR images to base64
# -----------------------------------------------------------------------------

qr_to_base64() {
    local file="$1"
    if [[ -f "$file" ]]; then
        # Works on both macOS and Linux
        base64 < "$file" 2>/dev/null | tr -d '\n' || echo ""
    else
        # Return empty - HTML will show fallback message
        echo ""
    fi
}

QR_REALITY_B64=$(qr_to_base64 "$QR_REALITY_FILE")
QR_HYSTERIA2_B64=$(qr_to_base64 "$QR_HYSTERIA2_FILE")
QR_TROJAN_B64=$(qr_to_base64 "$QR_TROJAN_FILE")
QR_WIREGUARD_B64=$(qr_to_base64 "$QR_WIREGUARD_FILE")
QR_WIREGUARD_WSTUNNEL_B64=$(qr_to_base64 "$QR_WIREGUARD_WSTUNNEL_FILE")

# -----------------------------------------------------------------------------
# Generate HTML guide from template
# -----------------------------------------------------------------------------

log_info "Generating HTML guide..."

TEMPLATE_FILE="docs/client-guide-template.html"
OUTPUT_HTML="$PACKAGE_DIR/README.html"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    log_error "Template not found: $TEMPLATE_FILE"
    exit 1
fi

# Read template and replace placeholders
cp "$TEMPLATE_FILE" "$OUTPUT_HTML"

# Simple replacements using sed
sed -i.bak "s|{{USERNAME}}|$USERNAME|g" "$OUTPUT_HTML"
sed -i.bak "s|{{SERVER_IP}}|$SERVER_IP|g" "$OUTPUT_HTML"
sed -i.bak "s|{{DOMAIN}}|$DOMAIN|g" "$OUTPUT_HTML"
sed -i.bak "s|{{GENERATED_DATE}}|$GENERATED_DATE|g" "$OUTPUT_HTML"
sed -i.bak "s|{{DNSTT_DOMAIN}}|$DNSTT_DOMAIN|g" "$OUTPUT_HTML"
sed -i.bak "s|{{DNSTT_PUBKEY}}|$DNSTT_PUBKEY|g" "$OUTPUT_HTML"

# Remove demo notice placeholders (not a demo user from package)
sed -i.bak "s|{{DEMO_NOTICE_EN}}||g" "$OUTPUT_HTML"
sed -i.bak "s|{{DEMO_NOTICE_FA}}||g" "$OUTPUT_HTML"

# QR codes (base64)
sed -i.bak "s|{{QR_REALITY}}|$QR_REALITY_B64|g" "$OUTPUT_HTML"
sed -i.bak "s|{{QR_HYSTERIA2}}|$QR_HYSTERIA2_B64|g" "$OUTPUT_HTML"
sed -i.bak "s|{{QR_TROJAN}}|$QR_TROJAN_B64|g" "$OUTPUT_HTML"
sed -i.bak "s|{{QR_WIREGUARD}}|$QR_WIREGUARD_B64|g" "$OUTPUT_HTML"
sed -i.bak "s|{{QR_WIREGUARD_WSTUNNEL}}|$QR_WIREGUARD_WSTUNNEL_B64|g" "$OUTPUT_HTML"

# Config values (need special handling due to special characters like @ and &)
# Escape & for awk replacement (& is special in gsub replacement)
escape_for_awk() {
    echo "$1" | sed 's/&/\\&/g'
}

if [[ -n "$CONFIG_REALITY" ]]; then
    ESCAPED=$(escape_for_awk "$CONFIG_REALITY")
    awk -v replacement="$ESCAPED" '{gsub(/\{\{CONFIG_REALITY\}\}/, replacement)}1' "$OUTPUT_HTML" > "$OUTPUT_HTML.new" && mv -f "$OUTPUT_HTML.new" "$OUTPUT_HTML"
else
    sed -i.bak "s|{{CONFIG_REALITY}}|No Reality config available|g" "$OUTPUT_HTML"
fi

if [[ -n "$CONFIG_HYSTERIA2" ]]; then
    ESCAPED=$(escape_for_awk "$CONFIG_HYSTERIA2")
    awk -v replacement="$ESCAPED" '{gsub(/\{\{CONFIG_HYSTERIA2\}\}/, replacement)}1' "$OUTPUT_HTML" > "$OUTPUT_HTML.new" && mv -f "$OUTPUT_HTML.new" "$OUTPUT_HTML"
else
    sed -i.bak "s|{{CONFIG_HYSTERIA2}}|No Hysteria2 config available|g" "$OUTPUT_HTML"
fi

if [[ -n "$CONFIG_TROJAN" ]]; then
    ESCAPED=$(escape_for_awk "$CONFIG_TROJAN")
    awk -v replacement="$ESCAPED" '{gsub(/\{\{CONFIG_TROJAN\}\}/, replacement)}1' "$OUTPUT_HTML" > "$OUTPUT_HTML.new" && mv -f "$OUTPUT_HTML.new" "$OUTPUT_HTML"
else
    sed -i.bak "s|{{CONFIG_TROJAN}}|No Trojan config available|g" "$OUTPUT_HTML"
fi

# WireGuard config is multiline - handle with awk
if [[ -n "$CONFIG_WIREGUARD" ]]; then
    # Escape & and convert newlines
    ESCAPED=$(echo "$CONFIG_WIREGUARD" | sed 's/&/\\&/g' | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')
    awk -v replacement="$ESCAPED" 'BEGIN{gsub(/\\n/,"\n",replacement)} {gsub(/\{\{CONFIG_WIREGUARD\}\}/, replacement)}1' "$OUTPUT_HTML" > "$OUTPUT_HTML.new" && mv -f "$OUTPUT_HTML.new" "$OUTPUT_HTML"
else
    sed -i.bak "s|{{CONFIG_WIREGUARD}}|No WireGuard config available|g" "$OUTPUT_HTML"
fi

# WireGuard-wstunnel config is multiline - handle with awk
if [[ -n "$CONFIG_WIREGUARD_WSTUNNEL" ]]; then
    # Escape & and convert newlines
    ESCAPED=$(echo "$CONFIG_WIREGUARD_WSTUNNEL" | sed 's/&/\\&/g' | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')
    awk -v replacement="$ESCAPED" 'BEGIN{gsub(/\\n/,"\n",replacement)} {gsub(/\{\{CONFIG_WIREGUARD_WSTUNNEL\}\}/, replacement)}1' "$OUTPUT_HTML" > "$OUTPUT_HTML.new" && mv -f "$OUTPUT_HTML.new" "$OUTPUT_HTML"
else
    sed -i.bak "s|{{CONFIG_WIREGUARD_WSTUNNEL}}|No WireGuard-wstunnel config available|g" "$OUTPUT_HTML"
fi

# Clean up backup files
rm -f "$OUTPUT_HTML.bak"

log_info "  HTML guide generated"

# -----------------------------------------------------------------------------
# Copy config files to package directory
# -----------------------------------------------------------------------------

log_info "Copying config files..."

# Copy all relevant files
for file in "$BUNDLE_DIR"/*.txt "$BUNDLE_DIR"/*.conf "$BUNDLE_DIR"/*.yaml "$BUNDLE_DIR"/*.json; do
    if [[ -f "$file" ]]; then
        cp "$file" "$PACKAGE_DIR/"
    fi
done

log_info "  Config files copied"

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

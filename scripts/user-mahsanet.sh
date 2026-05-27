#!/bin/bash
set -euo pipefail

# =============================================================================
# Build a MahsaNG-ready import package for an existing user.
#
# MahsaNG (github.com/GFW-knocker/MahsaNG) is a V2RayNG fork used by 2M+ people
# in Iran. It imports servers via (a) a subscription URL — base64 of a newline
# list of vless:///trojan:///ss:///... URIs, (b) a single URI, or (c) a QR code.
#
# This script collects the MahsaNG-compatible (standard V2Ray) URIs already
# generated in the user's bundle, prints them, builds a base64 subscription
# body, writes both to the bundle, and shows a scannable QR per config.
#
# Usage: ./scripts/user-mahsanet.sh <username> [--no-qr]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

source scripts/lib/common.sh

USERNAME="${1:-}"
SHOW_QR=true
for arg in "$@"; do
    case "$arg" in
        --no-qr) SHOW_QR=false ;;
    esac
done

if [[ -z "$USERNAME" || "$USERNAME" == --* ]]; then
    echo "Usage: $0 <username> [--no-qr]"
    echo ""
    echo "Builds a MahsaNG import package (subscription URL + URIs + QR codes)"
    echo "from the user's existing bundle in outputs/bundles/<username>/."
    exit 1
fi

BUNDLE_DIR="outputs/bundles/$USERNAME"
if [[ ! -d "$BUNDLE_DIR" ]]; then
    log_error "User bundle not found: $BUNDLE_DIR"
    log_error "Create the user first with: moav user add $USERNAME"
    exit 1
fi

# MahsaNG-compatible config files, ordered by reliability under Iran's
# censorship (most reliable first). Each entry: "file|label".
# Only standard V2Ray URI schemes (vless/trojan/ss/hysteria2) are listed —
# WireGuard/AmneziaWG/TrustTunnel/dnstt/Slipstream/MasterDNS/Telegram are NOT
# importable as MahsaNG subscription entries and are intentionally excluded.
MAHSANG_FILES=(
    "reality.txt|Reality (VLESS) — most reliable, no domain needed"
    "cdn-vless.txt|CDN (VLESS+WS) — works when the server IP is blocked"
    "xhttp-vless.txt|XHTTP (VLESS+XHTTP+Reality) — HTTP-camouflaged"
    "trojan.txt|Trojan (TLS) — needs a domain"
    "shadowsocks.txt|Shadowsocks-2022 — lightweight"
    "hysteria2.txt|Hysteria2 (QUIC/UDP) — fast but UDP is often blocked in Iran"
    "reality-ipv6.txt|Reality (VLESS) over IPv6"
    "trojan-ipv6.txt|Trojan over IPv6"
    "shadowsocks-ipv6.txt|Shadowsocks-2022 over IPv6"
    "hysteria2-ipv6.txt|Hysteria2 over IPv6"
)

URIS=()
LABELS=()
for entry in "${MAHSANG_FILES[@]}"; do
    file="${entry%%|*}"
    label="${entry##*|}"
    path="$BUNDLE_DIR/$file"
    [[ -f "$path" ]] || continue
    uri="$(tr -d '\r\n' < "$path")"
    [[ -n "$uri" ]] || continue
    case "$uri" in
        vless://*|trojan://*|ss://*|hysteria2://*|vmess://*) ;;
        *) continue ;;
    esac
    URIS+=("$uri")
    LABELS+=("$label")
done

echo ""
echo "=========================================="
echo "  MahsaNG Import — user: $USERNAME"
echo "=========================================="
echo ""

if [[ ${#URIS[@]} -eq 0 ]]; then
    log_error "No MahsaNG-compatible configs found in $BUNDLE_DIR"
    echo ""
    echo "MahsaNG imports standard V2Ray URIs (vless/trojan/ss/hysteria2)."
    echo "Enable at least one of: Reality, CDN, XHTTP, Trojan, Shadowsocks,"
    echo "Hysteria2 — then regenerate the bundle (moav user add / moav"
    echo "regenerate-users) and run this again."
    exit 1
fi

echo "Found ${#URIS[@]} MahsaNG-compatible config(s)."
echo ""
echo "------------------------------------------"
echo "  Individual URIs (Method B: paste one)"
echo "------------------------------------------"
echo "In MahsaNG: tap + → \"Import config from clipboard\" (or paste in the"
echo "manual add screen). Reality/CDN are the best choices for Iran."
echo ""
i=1
for idx in "${!URIS[@]}"; do
    echo "[$i] ${LABELS[$idx]}"
    echo "${URIS[$idx]}"
    echo ""
    i=$((i + 1))
done

# Build the V2Ray subscription body: base64 of the newline-joined URI list.
# MahsaNG/V2RayNG accept standard base64 (newline-stripped).
URI_LIST=""
for u in "${URIS[@]}"; do
    URI_LIST+="$u"$'\n'
done
SUB_B64="$(printf '%s' "$URI_LIST" | base64 | tr -d '\n')"

URIS_FILE="$BUNDLE_DIR/mahsanet-uris.txt"
SUB_FILE="$BUNDLE_DIR/mahsanet-sub.txt"
printf '%s' "$URI_LIST" > "$URIS_FILE"
printf '%s\n' "$SUB_B64" > "$SUB_FILE"

echo "------------------------------------------"
echo "  Subscription (Method A: one import for all)"
echo "------------------------------------------"
echo "Base64 subscription body (the standard V2Ray subscription format):"
echo ""
echo "$SUB_B64"
echo ""
echo "Use it one of these ways:"
echo "  • Subscription URL — host the file below at any HTTPS URL the phone"
echo "    can reach (or download this user's bundle from the MoaV admin"
echo "    dashboard), then in MahsaNG: Subscriptions → + → paste that URL."
echo "  • Some MahsaNG builds also accept the base64 text above pasted"
echo "    directly when adding a subscription."
echo ""
echo "Saved to the user bundle:"
echo "  $URIS_FILE   (plain URI list — one per line)"
echo "  $SUB_FILE    (base64 subscription body — host this as the sub URL)"
echo ""

if [[ "$SHOW_QR" == "true" ]]; then
    if command -v qrencode >/dev/null 2>&1; then
        echo "------------------------------------------"
        echo "  QR codes (Method C: scan in MahsaNG)"
        echo "------------------------------------------"
        echo "MahsaNG: tap + → \"Scan QR code\". One QR per config:"
        echo ""
        i=1
        for idx in "${!URIS[@]}"; do
            echo "[$i] ${LABELS[$idx]}"
            qrencode -t ANSIUTF8 "${URIS[$idx]}" 2>/dev/null || \
                echo "  (could not render QR for this config)"
            echo ""
            i=$((i + 1))
        done
        echo "PNG QR images for each config are also in $BUNDLE_DIR/*-qr.png"
    else
        log_warn "qrencode not installed — skipping terminal QR codes"
        log_warn "  Install: apt install qrencode (Linux) / brew install qrencode (macOS)"
        echo "  PNG QR images for each config are already in $BUNDLE_DIR/*-qr.png"
    fi
    echo ""
fi

echo "=========================================="
echo "  MahsaNG v16 — additional protocols"
echo "=========================================="
echo ""
echo "MahsaNG v16 ships two extra protocols that are configured separately"
echo "(not via subscription URI). Check your bundle for their setup files:"
echo ""

MASTERDNS_FILE="$BUNDLE_DIR/masterdns-instructions.txt"
if [[ -f "$MASTERDNS_FILE" ]]; then
    echo "✓ MasterDNS (fastest DNS tunnel, MahsaNG v16 native tab)"
    echo "  Setup: $MASTERDNS_FILE"
    echo "  → In MahsaNG: MasterDNS tab → enter domain + key from that file"
    echo ""
else
    echo "○ MasterDNS — not in this bundle (enable with ENABLE_MASTERDNS=true)"
    echo ""
fi

GOOSERELAY_FILE="$BUNDLE_DIR/gooserelay-instructions.txt"
if [[ -f "$GOOSERELAY_FILE" ]]; then
    echo "✓ GooseRelay (SOCKS5 via Google Apps Script, MahsaNG v16 tab)"
    echo "  Setup: $GOOSERELAY_FILE"
    echo "  → Deploy the Apps Script forwarder per that file, then"
    echo "    In MahsaNG: GooseRelay tab → paste client_config.json"
    echo ""
else
    echo "○ GooseRelay — not in this bundle (enable with ENABLE_GOOSERELAY=true)"
    echo ""
fi

echo "See docs/mahsanet.md for full import guide."
echo "=========================================="

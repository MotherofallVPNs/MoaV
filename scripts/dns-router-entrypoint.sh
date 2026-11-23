#!/bin/bash
set -euo pipefail

# =============================================================================
# DNS Router Entrypoint
# Routes DNS queries to dnstt, MasterDNS, and/or XDNS backends by domain
# suffix. All tunnels can run simultaneously on port 53. Slipstream is
# deprecated and no longer routed (ENABLE_SLIPSTREAM is ignored here).
# =============================================================================

echo "================================================"
echo "  MoaV DNS Router"
echo "================================================"

# Validate at least one backend is enabled
ENABLE_DNSTT="${ENABLE_DNSTT:-true}"
ENABLE_SLIPSTREAM="${ENABLE_SLIPSTREAM:-false}"
ENABLE_MASTERDNS="${ENABLE_MASTERDNS:-true}"
ENABLE_XDNS="${ENABLE_XDNS:-true}"

if [[ "$ENABLE_SLIPSTREAM" == "true" ]]; then
    echo "[WARN] ENABLE_SLIPSTREAM=true is ignored: Slipstream is deprecated and no longer routed."
    echo "       Move clients to MasterDNS or dnstt, then set ENABLE_SLIPSTREAM=false."
fi

if [[ "$ENABLE_DNSTT" != "true" && "$ENABLE_MASTERDNS" != "true" && "$ENABLE_XDNS" != "true" ]]; then
    echo "[ERROR] All DNS tunnel backends are disabled. Nothing to route."
    exit 1
fi

echo "[dns-router] Configuration:"
echo "  ENABLE_DNSTT=${ENABLE_DNSTT}"
echo "  ENABLE_MASTERDNS=${ENABLE_MASTERDNS}"
echo "  ENABLE_XDNS=${ENABLE_XDNS}"

if [[ "$ENABLE_DNSTT" == "true" ]]; then
    echo "  DNSTT_DOMAIN=${DNSTT_DOMAIN:-<not set>}"
    echo "  DNSTT_BACKEND=${DNSTT_BACKEND:-dnstt:5353}"
fi

if [[ "$ENABLE_MASTERDNS" == "true" ]]; then
    echo "  MASTERDNS_DOMAIN=${MASTERDNS_DOMAIN:-<not set>}"
    echo "  MASTERDNS_BACKEND=${MASTERDNS_BACKEND:-masterdns:5355}"
fi

if [[ "$ENABLE_XDNS" == "true" ]]; then
    echo "  XDNS_DOMAIN=${XDNS_DOMAIN:-<not set>}"
    echo "  XDNS_BACKEND=${XDNS_BACKEND:-xray:5355}"
fi

echo "  DNS_LISTEN=${DNS_LISTEN:-:5353}"
echo "================================================"

# Wait briefly for backends to be available
sleep 2

exec dns-router

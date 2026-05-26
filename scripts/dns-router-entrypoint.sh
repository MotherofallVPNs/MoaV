#!/bin/bash
set -euo pipefail

# =============================================================================
# DNS Router Entrypoint
# Routes DNS queries to dnstt and/or Slipstream backends by domain suffix.
# =============================================================================

echo "================================================"
echo "  MoaV DNS Router"
echo "================================================"

# Validate at least one backend is enabled
ENABLE_DNSTT="${ENABLE_DNSTT:-true}"
ENABLE_SLIPSTREAM="${ENABLE_SLIPSTREAM:-true}"
ENABLE_MASTERDNS="${ENABLE_MASTERDNS:-true}"

if [[ "$ENABLE_DNSTT" != "true" && "$ENABLE_SLIPSTREAM" != "true" && "$ENABLE_MASTERDNS" != "true" ]]; then
    echo "[ERROR] None of ENABLE_DNSTT / ENABLE_SLIPSTREAM / ENABLE_MASTERDNS is true. Nothing to route."
    exit 1
fi

echo "[dns-router] Configuration:"
echo "  ENABLE_DNSTT=${ENABLE_DNSTT}"
echo "  ENABLE_SLIPSTREAM=${ENABLE_SLIPSTREAM}"
echo "  ENABLE_MASTERDNS=${ENABLE_MASTERDNS}"

if [[ "$ENABLE_DNSTT" == "true" ]]; then
    echo "  DNSTT_DOMAIN=${DNSTT_DOMAIN:-<not set>}"
    echo "  DNSTT_BACKEND=${DNSTT_BACKEND:-dnstt:5353}"
fi

if [[ "$ENABLE_SLIPSTREAM" == "true" ]]; then
    echo "  SLIPSTREAM_DOMAIN=${SLIPSTREAM_DOMAIN:-<not set>}"
    echo "  SLIPSTREAM_BACKEND=${SLIPSTREAM_BACKEND:-slipstream:5354}"
fi

if [[ "$ENABLE_MASTERDNS" == "true" ]]; then
    echo "  MASTERDNS_DOMAIN=${MASTERDNS_DOMAIN:-<not set>}"
    echo "  MASTERDNS_BACKEND=${MASTERDNS_BACKEND:-masterdns:5355}"
fi

echo "  DNS_LISTEN=${DNS_LISTEN:-:5353}"
echo "================================================"

# Wait briefly for backends to be available
sleep 2

exec dns-router

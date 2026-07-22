#!/bin/bash
# lib/bundle-readme.sh — render a user's client-guide README.html from the
# template, and write subscription.txt. Single source for both provisioning
# paths (host `moav user add` → user-add.sh, container bootstrap/regenerate →
# generate-user.sh), which previously carried ~290 near-identical lines each and
# drifted (the SS/XHTTP placeholder gap, sed -i vs sed -i.bak).
#
# All placeholder substitution runs in ONE Python pass — no sed (so no BSD/GNU
# `-i` flavor split), and multiline configs / passwords with shell-special chars
# are handled natively. subscription.txt is written UNCONDITIONALLY so the bundle
# always has it (empty when there are no V2Ray-compatible links).
#
# render_bundle_readme <username> <output_dir> <template_file> [context]
#   context: "host" (moav user add) | "container" (bootstrap/regenerate; default)
#            — only affects the MasterDNS/GooseRelay absent-fallback text, since
#            the host path can't generate those (server-shared key in the volume).
#
# Reads config/QR files from <output_dir> and these env vars (callers set them,
# and pre-resolve the two whose SOURCE differs by context):
#   SERVER_IP DOMAIN PORT_SS DNSTT_SUBDOMAIN SLIPSTREAM_SUBDOMAIN CDN_DOMAIN
#   DNSTT_PUBKEY  (host: outputs/dnstt/server.pub · container: state keys)
#   USER_PASSWORD (host: trusttunnel.json/credentials · container: already set)
#   IS_DEMO_USER + ENABLE_* (container demo user only)

# Resolve the sibling Python renderer at source time (BASH_SOURCE is reliable
# here; bootstrap.sh / user-add.sh source this under bash).
_BUNDLE_README_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

render_bundle_readme() {
    local username="$1" output_dir="$2" template_file="$3" context="${4:-container}"

    [[ -f "$template_file" ]] || { log_info "  - README.html skipped (template not found)"; return 0; }

    local wstunnel_cmd generated_date
    wstunnel_cmd="$(wstunnel_client_cmd)"
    generated_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    RB_USERNAME="$username" \
    RB_OUTPUT_DIR="$output_dir" \
    RB_TEMPLATE="$template_file" \
    RB_OUTPUT_HTML="$output_dir/README.html" \
    RB_CONTEXT="$context" \
    RB_SERVER_IP="${SERVER_IP:-YOUR_SERVER_IP}" \
    RB_DOMAIN="${DOMAIN:-YOUR_DOMAIN}" \
    RB_PORT_SS="${PORT_SS:-8388}" \
    RB_WSTUNNEL_CMD="$wstunnel_cmd" \
    RB_GENERATED_DATE="$generated_date" \
    RB_DNSTT_DOMAIN="${DNSTT_SUBDOMAIN:-t}.${DOMAIN:-}" \
    RB_DNSTT_PUBKEY="${DNSTT_PUBKEY:-}" \
    RB_SLIPSTREAM_DOMAIN="${SLIPSTREAM_SUBDOMAIN:-s}.${DOMAIN:-}" \
    RB_CDN_DOMAIN="${CDN_DOMAIN:-}" \
    RB_USER_PASSWORD="${USER_PASSWORD:-}" \
    RB_IS_DEMO_USER="${IS_DEMO_USER:-false}" \
    RB_ENABLE_WIREGUARD="${ENABLE_WIREGUARD:-true}" \
    RB_ENABLE_DNSTT="${ENABLE_DNSTT:-true}" \
    RB_ENABLE_TROJAN="${ENABLE_TROJAN:-true}" \
    RB_ENABLE_ANYTLS="${ENABLE_ANYTLS:-false}" \
    RB_ENABLE_HYSTERIA2="${ENABLE_HYSTERIA2:-true}" \
    RB_ENABLE_REALITY="${ENABLE_REALITY:-true}" \
    python3 "${BUNDLE_README_PY:-$_BUNDLE_README_DIR/bundle_readme.py}" || {
        log_info "  - README.html generation failed"; return 1; }

    log_info "  - README.html generated"
}

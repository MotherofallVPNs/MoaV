#!/bin/bash
# lib/moav-bundle.sh — emit a compact moav:// bundle URL from a user's ENABLED
# proxy protocols. The compact form factors shared credentials (the UUID rides
# in the userinfo; pw / reality pbk+sid / ss+obfs secrets / default SNI go in
# shared query params) out of the N per-protocol URIs into one URL that
# moav-client's ParseMoaVBundle expands back into endpoints. Grammar +
# round-trip contract: docs/MOAV_BUNDLE.md and the moav-client repo.
#
# Reads the same environment the singbox_/xray_ share-link builders use
# (USER_UUID, USER_PASSWORD, REALITY_*, DOMAIN, CDN_*, HYSTERIA2_OBFS_PASSWORD,
# SS_*, PORT_*, ENABLE_*) plus moav_name_prefix. Definitions only.

# Percent-encode a value (RFC3986 unreserved kept). Applied to every shared
# query value AND every p= record sub-value; moav-client url-decodes the whole
# record before the structural comma/`=` split, so encoding sub-values is safe
# and the structural separators (which we never encode) survive.
_moav_urlencode() {
    local s="$1" out="" c i
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

# moav_bundle_link <label> <host> — print the moav:// URL, or nothing when no
# proxy protocol is enabled / the user has no UUID. <host> is the default
# connection host (SERVER_IP); CDN overrides it per-record via host=.
moav_bundle_link() {
    local label="$1" host="$2"
    [[ -n "${USER_UUID:-}" ]] || return 0
    local shared=() precords=()

    # Shared credentials (the UUID is the userinfo, so it is not repeated here).
    [[ -n "${USER_PASSWORD:-}" ]]      && shared+=("pw=$(_moav_urlencode "$USER_PASSWORD")")
    [[ -n "${REALITY_PUBLIC_KEY:-}" ]] && shared+=("pbk=$(_moav_urlencode "$REALITY_PUBLIC_KEY")")
    [[ -n "${REALITY_SHORT_ID:-}" ]]   && shared+=("sid=$(_moav_urlencode "$REALITY_SHORT_ID")")
    [[ -n "${DOMAIN:-}" ]]             && shared+=("sni_default=$(_moav_urlencode "$DOMAIN")")
    shared+=("fp=random")

    # Per-protocol records, gated by the same ENABLE_* flags + ports as the
    # per-protocol .txt builders, so the moav:// bundle matches the legacy URIs.
    if [[ "${ENABLE_REALITY:-true}" == "true" ]]; then
        precords+=("p=reality,443,sni=$(_moav_urlencode "${REALITY_TARGET_HOST:-}"),flow=xtls-rprx-vision")
    fi
    if [[ "${ENABLE_XHTTP:-true}" == "true" ]]; then
        local _xt="${XHTTP_REALITY_TARGET:-${REALITY_TARGET:-dl.google.com:443}}"
        precords+=("p=vless-xhttp,${PORT_XHTTP:-2096},sni=$(_moav_urlencode "${_xt%%:*}"),fp=chrome")
    fi
    if [[ "${ENABLE_CDN:-false}" == "true" && -n "${CDN_ADDRESS:-}" ]]; then
        local _cdn="vless-httpupgrade"
        [[ "${CDN_TRANSPORT:-httpupgrade}" == "ws" ]] && _cdn="vless-ws"
        precords+=("p=${_cdn},443,host=$(_moav_urlencode "$CDN_ADDRESS"),path=$(_moav_urlencode "${CDN_WS_PATH:-/ws}"),sni=$(_moav_urlencode "${CDN_SNI:-}"),alpn=http/1.1")
    fi
    if [[ "${ENABLE_TROJAN:-true}" == "true" ]]; then
        precords+=("p=trojan,8443")
    fi
    if [[ "${ENABLE_ANYTLS:-false}" == "true" ]]; then
        precords+=("p=anytls,${PORT_ANYTLS:-8445}")
    fi
    if [[ "${ENABLE_HYSTERIA2:-true}" == "true" ]]; then
        [[ -n "${HYSTERIA2_OBFS_PASSWORD:-}" ]] && shared+=("obfs_pw=$(_moav_urlencode "$HYSTERIA2_OBFS_PASSWORD")")
        precords+=("p=hy2,443,obfs=salamander")
    fi
    if [[ "${ENABLE_SS:-false}" == "true" && -n "${SS_SERVER_PSK_LOCAL:-}" && -n "${SS_USER_PSK:-}" ]]; then
        shared+=("ss_method=$(_moav_urlencode "${SS_METHOD_LOCAL:-2022-blake3-aes-128-gcm}")")
        shared+=("ss_pw=$(_moav_urlencode "${SS_SERVER_PSK_LOCAL}:${SS_USER_PSK}")")
        precords+=("p=ss,${SS_PORT:-8388}")
    fi

    (( ${#precords[@]} )) || return 0

    local all=("${shared[@]}" "${precords[@]}") query
    query=$(IFS='&'; printf '%s' "${all[*]}")
    printf 'moav://%s@%s?%s#%s%s\n' "$USER_UUID" "$host" "$query" "$(moav_name_prefix)" "$label"
}

#!/bin/bash
# sing-box specific functions

# singbox_add_user <config> <username> <uuid> <password> <ss_psk>
# (Snell is shared-key, not per-user, so there is no snell arg here.)
# Canonical sing-box server-config mutation — the single source of truth for
# inserting a user into the proxy inbounds (used by the host `user add` path and
# the bootstrap/regenerate reconcile). Each insert is INDEPENDENTLY idempotent:
# UUID inbounds (reality, vless-ws) dedup by uuid, password inbounds (trojan,
# anytls, hysteria2, shadowsocks) dedup by name. Do NOT gate the block on the
# UUID — SS/Trojan/AnyTLS/Hysteria2 entries carry only a password, so a
# "uuid already present" guard would skip repairing them once Reality re-added
# the uuid (the SS "invalid request" orphan bug). Shadowsocks is added only when
# <ss_psk> is non-empty; the addbyname map is a no-op when the inbound is absent.
# Writes in place via cat-overwrite (preserving the file's inode/mode/owner, so a
# sudo'd CLI vs admin-container uid mismatch can't lose write access) and only
# when the config actually changed. Returns 0 if the config changed, 1 if
# unchanged or on jq failure.
singbox_add_user() {
    local sb="$1" n="$2" id="$3" p="$4" ss="$5" tmp
    [[ -f "$sb" ]] || return 1
    tmp=$(mktemp)
    if jq --arg n "$n" --arg id "$id" --arg p "$p" --arg ss "$ss" '
            def addbyuuid($tag; $e):
              .inbounds |= map(if .tag==$tag and ((any(.users[]?; .uuid==$e.uuid)) | not)
                               then .users += [$e] else . end);
            def addbyname($tag; $e):
              .inbounds |= map(if .tag==$tag and ((any(.users[]?; .name==$e.name)) | not)
                               then .users += [$e] else . end);
            addbyuuid("vless-reality-in"; {name:$n, uuid:$id, flow:"xtls-rprx-vision"})
            | addbyname("trojan-tls-in"; {name:$n, password:$p})
            | addbyname("anytls-in";     {name:$n, password:$p})
            | addbyname("hysteria2-in";  {name:$n, password:$p})
            | addbyuuid("vless-ws-in";   {name:$n, uuid:$id})
            | (if $ss != "" then addbyname("shadowsocks-in"; {name:$n, password:$ss}) else . end)
        ' "$sb" > "$tmp" 2>/dev/null && jq empty "$tmp" 2>/dev/null; then
        if ! cmp -s "$tmp" "$sb"; then cat "$tmp" > "$sb"; rm -f "$tmp"; return 0; fi
    fi
    rm -f "$tmp"
    return 1
}


# =============================================================================
# Share-link builders — pure functions of the caller's environment.
# Both the host add-user path (singbox-user-add.sh) and the bundle generator
# (generate-user.sh) emit byte-identical share links; these are the single
# source of truth. Each reads USER_UUID / USER_PASSWORD and the relevant
# protocol keys from the environment, and takes (label, host) so one builder
# serves IPv4 and IPv6 — host is "1.2.3.4" or "[2001:db8::1]", label is e.g.
# "alice" or "alice-IPv6".
# =============================================================================

singbox_reality_link() {
    local label="$1" host="$2"
    echo "vless://${USER_UUID}@${host}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_TARGET_HOST}&fp=random&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#$(moav_name_prefix)Reality-${label}"
}

singbox_trojan_link() {
    local label="$1" host="$2"
    echo "trojan://${USER_PASSWORD}@${host}:8443?security=tls&sni=${DOMAIN}&type=tcp#$(moav_name_prefix)Trojan-${label}"
}

singbox_anytls_link() {
    local label="$1" host="$2"
    echo "anytls://${USER_PASSWORD}@${host}:${PORT_ANYTLS:-8445}?sni=${DOMAIN}&insecure=0#$(moav_name_prefix)AnyTLS-${label}"
}

singbox_hysteria2_link() {
    local label="$1" host="$2"
    echo "hysteria2://${USER_PASSWORD}@${host}:443?sni=${DOMAIN}&obfs=salamander&obfs-password=${HYSTERIA2_OBFS_PASSWORD}#$(moav_name_prefix)Hysteria2-${label}"
}

# CDN routes through a fronting address (CDN_ADDRESS), not the server IP, so it
# has no IPv6 variant — only the label varies.
singbox_cdn_link() {
    local label="$1"
    echo "vless://${USER_UUID}@${CDN_ADDRESS}:443?security=tls&type=${CDN_TRANSPORT}&path=${CDN_WS_PATH}&sni=${CDN_SNI}&host=${CDN_DOMAIN}&fp=random&alpn=http/1.1#$(moav_name_prefix)CDN-${label}"
}

# Shadowsocks-2022 SIP002 userinfo: BASE64URL_NOPAD(method:server_psk:user_psk).
singbox_ss_userinfo() {
    local method="$1" server_psk="$2" user_psk="$3"
    printf '%s' "${method}:${server_psk}:${user_psk}" | base64 | tr -d '\n=' | tr '/+' '_-'
}

# Shadowsocks-2022 ss:// share link. userinfo from singbox_ss_userinfo; port and
# host are passed so one builder serves IPv4 and IPv6.
singbox_ss_link() {
    local label="$1" host="$2" userinfo="$3" port="$4"
    echo "ss://${userinfo}@${host}:${port}#$(moav_name_prefix)Shadowsocks-${label}"
}

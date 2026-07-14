#!/bin/bash
# lib/sync.sh — reconcile the server proxy configs with the user state.
#
# The sing-box and xray configs are regenerated from templates on every
# bootstrap (envsubst), which wipes the per-user entries that `moav user add`
# inserts incrementally. `sync_server_users` re-inserts EVERY user from state
# into those configs, idempotently, reusing each user's STORED credentials — so
# an update/re-bootstrap can never orphan a user, and already-distributed
# bundles keep working (no fresh UUIDs). Sourced by bootstrap.sh; also driven by
# `moav regenerate-users`.

# sync_server_users [sing-box-config] [xray-config] [state-users-dir]
# Returns the number of users newly re-inserted into the sing-box config.
sync_server_users() {
    local sb="${1:-/configs/sing-box/config.json}"
    local xr="${2:-/configs/xray/config.json}"
    local users_dir="${3:-${STATE_DIR:-/state}/users}"
    [[ -f "$sb" ]] || return 0
    [[ -d "$users_dir" ]] || return 0

    local d u uuid pass ss tmp added=0
    for d in "$users_dir"/*/; do
        [[ -d "$d" ]] || continue
        u=$(basename "$d")
        [[ -f "${d}credentials.env" ]] || continue
        uuid=$(grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "${d}credentials.env" | head -1)
        pass=$(sed -n 's/^USER_PASSWORD=//p' "${d}credentials.env" | head -1)
        ss=$(sed -n 's/^SS_USER_PSK=//p' "${d}shadowsocks.env" 2>/dev/null | head -1)
        [[ -n "$uuid" ]] || continue

        # sing-box: reality / trojan / anytls / hysteria2 / cdn(vless-ws) / ss.
        # Skip if this user's UUID/name is already present anywhere in the config.
        if ! grep -q "$uuid" "$sb"; then
            tmp=$(mktemp)
            jq --arg n "$u" --arg id "$uuid" '.inbounds|=map(if .tag=="vless-reality-in" then .users+=[{"name":$n,"uuid":$id,"flow":"xtls-rprx-vision"}] else . end)' "$sb" \
             | jq --arg n "$u" --arg p "$pass" '.inbounds|=map(if .tag=="trojan-tls-in" then .users+=[{"name":$n,"password":$p}] else . end)' \
             | jq --arg n "$u" --arg p "$pass" '.inbounds|=map(if .tag=="anytls-in" then .users+=[{"name":$n,"password":$p}] else . end)' \
             | jq --arg n "$u" --arg p "$pass" '.inbounds|=map(if .tag=="hysteria2-in" then .users+=[{"name":$n,"password":$p}] else . end)' \
             | jq --arg n "$u" --arg id "$uuid" '.inbounds|=map(if .tag=="vless-ws-in" then .users+=[{"name":$n,"uuid":$id}] else . end)' > "$tmp"
            if [[ -n "$ss" ]]; then
                jq --arg n "$u" --arg p "$ss" '.inbounds|=map(if .tag=="shadowsocks-in" then .users+=[{"name":$n,"password":$p}] else . end)' "$tmp" > "${tmp}.2" \
                    && mv -f "${tmp}.2" "$tmp"
            fi
            if jq empty "$tmp" 2>/dev/null; then cat "$tmp" > "$sb"; added=$((added+1)); fi
            rm -f "$tmp" "${tmp}.2"
        fi

        # xray (XHTTP): append to whichever field the running config uses
        # (older configs use settings.clients, newer settings.users).
        if [[ -f "$xr" ]] && ! grep -q "$uuid" "$xr"; then
            tmp=$(mktemp)
            if jq --arg id "$uuid" --arg e "${u}@moav" '
                    (.inbounds[] | select(.protocol=="vless" and (.tag // "" | startswith("vless-"))) | .settings) |=
                      (if has("clients") then .clients += [{"id":$id,"email":$e,"flow":""}]
                       else .users += [{"id":$id,"email":$e,"flow":""}] end)
                ' "$xr" > "$tmp" 2>/dev/null && jq empty "$tmp" 2>/dev/null; then
                cat "$tmp" > "$xr"
            fi
            rm -f "$tmp"
        fi
    done

    [[ "$added" -gt 0 ]] && log_info "Reconciled $added user(s) into the server proxy configs"
    return 0
}

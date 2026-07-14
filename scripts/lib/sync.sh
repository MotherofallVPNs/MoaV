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

        # sing-box: add this user to every enabled inbound they belong to, each
        # insert INDEPENDENTLY idempotent. Do NOT gate the block on the UUID:
        # SS/Trojan/AnyTLS/Hysteria2 entries carry only a password (no UUID), so
        # a "UUID already present" guard would skip repairing them the moment
        # Reality re-added the UUID — leaving a user in the Reality inbound but
        # missing from the password inbounds (the SS "invalid request" bug).
        # Dedup UUID inbounds by uuid, password inbounds by name.
        tmp=$(mktemp)
        if jq --arg n "$u" --arg id "$uuid" --arg p "$pass" --arg ss "$ss" '
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
            if ! cmp -s "$tmp" "$sb"; then cat "$tmp" > "$sb"; added=$((added+1)); fi
        fi
        rm -f "$tmp"

        # xray (XHTTP): add to every vless inbound, idempotent by id, into
        # whichever field the running config uses (older: settings.clients,
        # newer: settings.users).
        if [[ -f "$xr" ]]; then
            tmp=$(mktemp)
            if jq --arg id "$uuid" --arg e "${u}@moav" '
                    (.inbounds[] | select(.protocol=="vless" and (.tag // "" | startswith("vless-"))) | .settings) |=
                      (if has("clients")
                       then (if (any(.clients[]?; .id==$id) | not) then .clients += [{"id":$id,"email":$e,"flow":""}] else . end)
                       else (if (any(.users[]?;   .id==$id) | not) then .users   += [{"id":$id,"email":$e,"flow":""}] else . end) end)
                ' "$xr" > "$tmp" 2>/dev/null && jq empty "$tmp" 2>/dev/null; then
                if ! cmp -s "$tmp" "$xr"; then cat "$tmp" > "$xr"; fi
            fi
            rm -f "$tmp"
        fi
    done

    [[ "$added" -gt 0 ]] && log_info "Reconciled $added user(s) into the server proxy configs"
    return 0
}

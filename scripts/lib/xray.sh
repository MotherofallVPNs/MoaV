#!/bin/bash
# lib/xray.sh — canonical Xray (XHTTP/XDNS) server-config mutation + client
# bundle generation. Single source of truth shared by the host `moav user add`
# path (singbox-user-add.sh) and the container bundle generator
# (generate-user.sh), which previously carried near-identical copies that had
# drifted (the host XDNS block lagged the container's XDNS_METHOD + uuid fallback
# and used differently-formatted JSON).
#
# Server mutation: inserts a user's VLESS client entry into every vless-* inbound,
# idempotently by id, into whichever field the running config uses — Xray v26.5.9
# renamed `settings.clients` -> `settings.users` (kept `clients` as an alias), so
# the bootstrap template writes `users` while a legacy config may carry `clients`.
# Extend whichever is present rather than forcing one — matching the reconcile,
# which is authoritative for the post-bootstrap config.

# xray_add_user <config> <uuid> <username>
# Writes in place via cat-overwrite (preserving inode/mode/owner) only when the
# config changed. Returns 0 if the config changed, 1 if unchanged or on jq failure.
xray_add_user() {
    local xr="$1" id="$2" n="$3" tmp
    [[ -f "$xr" ]] || return 1
    tmp=$(mktemp)
    if jq --arg id "$id" --arg e "${n}@moav" '
            (.inbounds[] | select(.protocol=="vless" and (.tag // "" | startswith("vless-"))) | .settings) |=
              (if has("clients")
               then (if (any(.clients[]?; .id==$id) | not) then .clients += [{"id":$id,"email":$e,"flow":""}] else . end)
               else (if (any(.users[]?;   .id==$id) | not) then .users   += [{"id":$id,"email":$e,"flow":""}] else . end) end)
        ' "$xr" > "$tmp" 2>/dev/null && jq empty "$tmp" 2>/dev/null; then
        if ! cmp -s "$tmp" "$xr"; then cat "$tmp" > "$xr"; rm -f "$tmp"; return 0; fi
    fi
    rm -f "$tmp"
    return 1
}

# =============================================================================
# Client bundle writers — XHTTP + XDNS. Each reads USER_UUID / SERVER_IP /
# REALITY_* and the XHTTP/XDNS_* knobs from the environment; the label
# (username) and, for XDNS, the resolved uuid are passed as args (the caller
# owns any uuid.env fallback). Callers keep their own enable/skip guards.
# =============================================================================

# xray_xhttp_link <label> — VLESS+XHTTP+Reality share link.
xray_xhttp_link() {
    local label="$1"
    local target="${XHTTP_REALITY_TARGET:-${REALITY_TARGET:-dl.google.com:443}}"
    local host="${target%%:*}"
    local port="${PORT_XHTTP:-2096}"
    echo "vless://${USER_UUID}@${SERVER_IP}:${port}?type=xhttp&security=reality&sni=${host}&fp=chrome&headers=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&encryption=none#MoaV-XHTTP-${label}"
}

# xray_write_xhttp_bundle <output_dir> <label> — writes xhttp-vless.txt (the
# share link) + its QR. The human-readable setup guide lives in README.html, so
# no xhttp.txt is emitted.
xray_write_xhttp_bundle() {
    local out="$1" label="$2"
    local link; link="$(xray_xhttp_link "$label")"

    echo "$link" > "$out/xhttp-vless.txt"

    if command -v qrencode &>/dev/null; then
        qrencode -o "$out/xhttp-qr.png" -s 6 -m 2 "$link" 2>/dev/null || true
    fi
}

# xray_xdns_finalmask <mode> — emit the finalmask "settings" JSON. mode=dns uses
# the public resolver CSV (XDNS_RESOLVERS); mode=direct targets the server XDNS
# port (SERVER_IP:PORT_XDNS). Each resolver is "domain[:method]+udp://ip:port";
# XDNS_METHOD=txt (default) is expressed by omitting the suffix (aaaa needs Xray
# >= v26.6.1). Reads XDNS_DOMAIN-equivalents from the caller's locals via args.
xray_xdns_finalmask() {
    local mode="$1" domain="$2" resolvers_csv="$3" method="$4" direct_target="$5"
    if [[ "$mode" == "direct" ]]; then
        XDNS_DOMAIN="$domain" XDNS_DIRECT_TARGET="$direct_target" XDNS_METHOD="$method" python3 -c '
import os, json
domain = os.environ["XDNS_DOMAIN"]
target = os.environ["XDNS_DIRECT_TARGET"]
method = os.environ.get("XDNS_METHOD", "txt").strip().lower()
suffix = "" if method in ("", "txt") else ":" + method
# Direct mode: send xdns-encoded queries straight to the server XDNS port
# (host PORT_XDNS -> xray:5355), with no public recursive resolver in between.
print(json.dumps({"resolvers": [domain + suffix + "+udp://" + target]}))
'
    else
        XDNS_DOMAIN="$domain" XDNS_RESOLVERS_CSV="$resolvers_csv" XDNS_METHOD="$method" python3 -c '
import os, json
domain = os.environ["XDNS_DOMAIN"]
csv = os.environ.get("XDNS_RESOLVERS_CSV", "").strip()
method = os.environ.get("XDNS_METHOD", "txt").strip().lower()
suffix = "" if method in ("", "txt") else ":" + method
ips = [x.strip() for x in csv.split(",") if x.strip()] if csv else []
if not ips:
    ips = ["1.1.1.1"]
# Xray v26.x finalmask: the client side uses "resolvers", each formatted as
# "domain[:method]+udp://server:port". The old singular "domain" field was
# removed; "domains" is server-side only.
resolvers = [domain + suffix + "+udp://" + (ip if ":" in ip else ip + ":53") for ip in ips]
print(json.dumps({"resolvers": resolvers}))
'
    fi
}

# xray_write_xdns_bundle <output_dir> <label> <uuid> — xdns-config.json (via
# public resolver) + xdns-direct-config.json (direct to the server XDNS port).
# The setup guide (client, resolver tips, MTU tuning) lives in README.html.
# Honors XDNS_SUBDOMAIN / XDNS_MTU / XDNS_RESOLVERS / XDNS_METHOD + PORT_XDNS.
xray_write_xdns_bundle() {
    local out="$1" label="$2" uuid="$3"
    local domain="${XDNS_SUBDOMAIN:-x}.${DOMAIN}"
    local mtu="${XDNS_MTU:-35}"
    local resolvers_csv="${XDNS_RESOLVERS:-1.1.1.1,8.8.8.8}"
    local method="${XDNS_METHOD:-txt}"
    local port="${PORT_XDNS:-5356}"
    local fm fmd
    fm=$(xray_xdns_finalmask dns    "$domain" "$resolvers_csv" "$method" "")
    fmd=$(xray_xdns_finalmask direct "$domain" "$resolvers_csv" "$method" "${SERVER_IP}:${port}")

    cat > "$out/xdns-config.json" <<XDNSEOF
{
  "remarks": "MoaV-XDNS-${label} (via DNS)",
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": 7891, "protocol": "socks", "settings": {"auth": "noauth", "udp": true}}],
  "outbounds": [
    {"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": "8.8.8.8", "port": 53, "users": [{"id": "$uuid", "encryption": "none"}]}]}, "streamSettings": {"network": "kcp", "kcpSettings": {"mtu": $mtu, "tti": 100, "uplinkCapacity": 0, "downlinkCapacity": 0, "congestion": true}, "finalmask": {"udp": [{"type": "xdns", "settings": ${fm}}]}}},
    {"tag": "direct", "protocol": "freedom"}
  ],
  "routing": {"rules": [{"type": "field", "ip": ["::/0"], "outboundTag": "direct"}]}
}
XDNSEOF

    cat > "$out/xdns-direct-config.json" <<XDNSEOF2
{
  "remarks": "MoaV-XDNS-${label} (direct)",
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": 7891, "protocol": "socks", "settings": {"auth": "noauth", "udp": true}}],
  "outbounds": [
    {"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": "${SERVER_IP}", "port": ${port}, "users": [{"id": "$uuid", "encryption": "none"}]}]}, "streamSettings": {"network": "kcp", "kcpSettings": {"mtu": $mtu, "tti": 100, "uplinkCapacity": 0, "downlinkCapacity": 0, "congestion": true}, "finalmask": {"udp": [{"type": "xdns", "settings": ${fmd}}]}}},
    {"tag": "direct", "protocol": "freedom"}
  ],
  "routing": {"rules": [{"type": "field", "ip": ["::/0"], "outboundTag": "direct"}]}
}
XDNSEOF2
}

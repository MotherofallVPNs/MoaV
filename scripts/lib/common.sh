#!/bin/bash
# Common utility functions

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Generate a random password
generate_password() {
    local length="${1:-24}"
    pwgen -s "$length" 1
}

# Generate UUID
generate_uuid() {
    sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Create directory if it doesn't exist
ensure_dir() {
    mkdir -p "$1"
}

# Build the wstunnel client command for WireGuard-over-WebSocket bundles.
# wss:// when a domain (hence a TLS cert) is configured, else plain ws://.
# The per-install path secret (state/keys/wstunnel-path.secret, shared with the
# server) becomes an HTTP-upgrade path prefix so scanners can't complete the
# upgrade blind. Reads DOMAIN/SERVER_IP from the caller's environment.
wstunnel_client_cmd() {
    local state_dir="${1:-${STATE_DIR:-./state}}"
    local secret="" pathopt="" url
    [[ -f "$state_dir/keys/wstunnel-path.secret" ]] && \
        secret=$(cat "$state_dir/keys/wstunnel-path.secret" 2>/dev/null)
    [[ -n "$secret" ]] && pathopt="--http-upgrade-path-prefix $secret "
    if [[ -n "${DOMAIN:-}" && "$DOMAIN" != "YOUR_DOMAIN" ]]; then
        url="wss://${DOMAIN}:8080"
    else
        url="ws://${SERVER_IP:-YOUR_SERVER_IP}:8080"
    fi
    echo "wstunnel client -L udp://127.0.0.1:51820:moav-wireguard:51820 ${pathopt}${url}"
}

# -----------------------------------------------------------------------------
# net_next_free_octet <config_file> <subnet_prefix> [extra_used_octet ...]
# Next free host octet (2..254) in a /24 for a wg/awg peer. Scans <config_file>
# for "AllowedIPs = <prefix>.N" and merges any extra octets (e.g. scraped from a
# live `wg/awg show <if> allowed-ips` on the host). Picks max-used + 1 so it is
# collision-safe across revoked-user gaps. Echoes the octet, or returns 1 (full).
# -----------------------------------------------------------------------------
net_next_free_octet() {
    local config_file="$1"; local prefix="$2"; shift 2
    local used="$*"
    local esc="${prefix//./\\.}"
    if [[ -f "$config_file" ]]; then
        used+=" $(grep "AllowedIPs = ${esc}\." "$config_file" 2>/dev/null \
            | sed "s|.*${esc}\.\([0-9]*\).*|\1|" | tr '\n' ' ')"
    fi
    local next=2 o
    for o in $used; do
        [[ "$o" =~ ^[0-9]+$ ]] || continue
        (( o >= next )) && next=$((o + 1))
    done
    (( next > 254 )) && return 1
    printf '%s\n' "$next"
}

# True if `ip` (e.g. 10.66.66.5) is on an AllowedIPs line belonging to a peer
# other than `user_id`. A stored client IP is only safe to reuse when no other
# peer already claims it; duplicates come from the old peer-count+1 allocator
# (which reused freed octets), a state restore, or a hand-edited conf.
net_ip_claimed_by_other() {
    local config_file="$1" ip="$2" user_id="$3"
    [[ -f "$config_file" ]] || return 1
    awk -v ip="$ip" -v me="$user_id" '
        /^\[Peer\]/    { peer = "" }
        /^# /          { if (peer == "") peer = substr($0, 3) }
        $1 == "AllowedIPs" && index($0, ip "/32") && peer != me { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$config_file"
}

# docker compose with a hard deadline, for host scripts that touch running
# containers. -k: if `docker compose` ignores the SIGTERM at the deadline (e.g.
# it's stuck in `exec` against a wedged container — the AmneziaWG hot-reload
# hang, #220), SIGKILL it 5s later so provisioning can never block
# indefinitely. (No global stdin redirect here — callers like
# `echo KEY | ... awg pubkey` rely on the piped stdin.)
compose_timeout() {
    # Never hand a TTY to a container exec. `docker exec -i` / `docker compose
    # exec` ATTACH stdin, and when stdin is the operator's terminal the exec
    # blocks reading it until the timeout kills it: measured 25s and EMPTY
    # output for `wg show wg0 public-key` from an interactive shell, vs 220ms
    # and the right answer with stdin closed.
    #
    # This is why `moav user add` failed from an interactive terminal but
    # always passed in scripts, CI and the dashboard (none of which have a
    # TTY): every container call in the add path — wg/awg keygen, the server
    # public-key read, the sing-box and wg/awg hot reloads — silently timed out.
    # `-t 0` is safe to branch on: if stdin is a terminal, no caller can be
    # piping data in (the `echo KEY | … pubkey` callers have a pipe on stdin).
    if command -v timeout >/dev/null 2>&1; then
        if [ -t 0 ]; then
            timeout -k 5 "${COMPOSE_TIMEOUT:-20}" docker compose "$@" < /dev/null
        else
            timeout -k 5 "${COMPOSE_TIMEOUT:-20}" docker compose "$@"
        fi
    else
        if [ -t 0 ]; then
            docker compose "$@" < /dev/null
        else
            docker compose "$@"
        fi
    fi
}

# svc_running / svc_exec — the same two operations by CONTAINER NAME instead of
# `docker compose <service>`.
#
# `docker compose` has to load docker-compose.yml and interpolate .env. Inside
# the admin container that fails: .env is root 0600 and the app runs as uid 2000.
# So every `compose ps <svc> --status running` check answered "not running" for
# containers that were plainly up, and the dashboard silently skipped WireGuard
# and never hot-applied new peers. Container names are fixed (`container_name:
# moav-<service>`), and plain `docker exec` works from the host AND through the
# admin container's docker-proxy — verified live on both.
#
# Same hard deadline as compose_timeout: a wedged container must never hang
# provisioning (#220).
svc_running() {
    local t=()
    command -v timeout >/dev/null 2>&1 && t=(timeout -k 5 "${COMPOSE_TIMEOUT:-20}")
    "${t[@]}" docker ps --filter "name=^/moav-${1}$" --filter status=running -q 2>/dev/null | grep -q .
}

# moav_server_label — short human label for THIS server, used in every config
# name so a user importing bundles from several MoaV servers can tell them
# apart in the VPN app list. DOMAIN's first label (yorkschool.xyz ->
# yorkschool), else SERVER_IP, else "moav".
moav_server_label() {
    local d="${DOMAIN:-}" ip="${SERVER_IP:-}"
    if [[ -n "$d" ]]; then printf '%s' "${d%%.*}"
    elif [[ -n "$ip" ]]; then printf '%s' "$ip"
    fi   # neither: empty, so names stay "MoaV-Reality-alice" / "moav-wg.conf"
}

# moav_name_prefix — "MoaV-<server>-" for share-link fragments and config
# remarks. Emits "MoaV-" when there is no label, so a name can never come out
# as "MoaV--Reality-alice".
moav_name_prefix() {
    local l; l=$(moav_server_label)
    if [[ -n "$l" ]]; then printf 'MoaV-%s-' "$l"; else printf 'MoaV-'; fi
}

# moav_wg_basename <wg|awg|wgws> — basename (no .conf) for a WireGuard-family
# config. WireGuard clients take the tunnel name from the FILENAME, and Linux
# `wg-quick` turns that basename into a network interface, which the kernel
# caps at 15 characters (verified: 15 accepted, 16 rejected). "moav-" + label +
# "-wgws" is the longest form, so the label gets 5 characters.
moav_wg_basename() {
    local sfx="$1" lbl
    lbl=$(moav_server_label | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-5)
    if [[ -n "$lbl" ]]; then printf 'moav-%s-%s' "$lbl" "$sfx"; else printf 'moav-%s' "$sfx"; fi
}

# svc_restart <service> — restart by container name. `docker compose restart`
# needs the compose file + .env interpolation, which the admin container cannot
# do; a skipped restart is silent and total: sing-box runs from a COPY of the
# config made at container start, so a user added without a restart is
# "unknown UUID" on every protocol until something else restarts it.
svc_restart() {
    local t=()
    command -v timeout >/dev/null 2>&1 && t=(timeout -k 5 "${SVC_RESTART_TIMEOUT:-60}")
    "${t[@]}" docker restart "moav-${1}" >/dev/null 2>&1
}

# svc_exec <service> <cmd...> — run a command in that container (stdin passes
# through, so `echo KEY | svc_exec wireguard wg pubkey` works).
svc_exec() {
    local svc="$1"; shift
    local t=()
    command -v timeout >/dev/null 2>&1 && t=(timeout -k 5 "${COMPOSE_TIMEOUT:-20}")
    # `< /dev/null` when stdin is a terminal — see compose_timeout: `-i` against
    # a TTY blocks the exec until the timeout kills it. Piped callers keep their
    # stdin (a pipe is not a terminal).
    if [ -t 0 ]; then
        "${t[@]}" docker exec -i "moav-${svc}" "$@" < /dev/null
    else
        "${t[@]}" docker exec -i "moav-${svc}" "$@"
    fi
}

# The admin container's fixed uid/gid (Dockerfile.admin: adduser -u 2000).
# Bundles and user state must be writable by the non-root admin app AND by the
# root-run provisioning paths; the old answer was chmod 777 / a+rwX, which left
# client private keys readable and writable by every local account.
ADMIN_UID=2000
ADMIN_GID=2000

# Make paths admin-owned with no world bits. Root callers (bootstrap container,
# host scripts under sudo) get the full chown; the admin app itself already
# writes as uid 2000, so its chown failure is harmless and the chmod still
# strips world access from what it owns.
grant_admin_rw() {
    local p
    for p in "$@"; do
        [[ -e "$p" ]] || continue
        chown -R "$ADMIN_UID:$ADMIN_GID" "$p" 2>/dev/null || true
        chmod -R ug+rwX,o-rwx "$p" 2>/dev/null || true
    done
}

# Secret material under state/keys must not be world-readable.
#
# Files created with `(umask 077 && ...)` came out 0600 correctly, but everything
# written via `cat > … <<EOF` or `echo … >` inherited umask 022 and landed 0644 —
# world-readable. On a live server that left REALITY_PRIVATE_KEY (reality.env),
# the Clash API secret and Hysteria2 obfs password (clash-api.env), the
# Shadowsocks PSK, the MasterDNS/GooseRelay keys and the wstunnel path secret all
# at 0644, while the raw *.key files beside them were correctly 0600.
#
# Idempotent: safe to call on every bootstrap, and it repairs existing installs.
# Public counterparts (*.pub, certs) stay 644 — other parties must read those.
#
# OWNERSHIP is normalized to root, not just the mode: live installs carry keys
# owned by whatever uid the old per-container flows wrote them as (a real
# server had uid-999 files from the v1 dnstt image), and a cap_drop-ALL
# container without DAC_OVERRIDE cannot read a 0600 file it does not own even
# as in-container root. The earlier claim that "every state-volume container
# runs as root" was wrong twice over: root there does not bypass modes, and
# dnstt/masterdns/slipstream run their daemons as USER moav (uid ~100). Those
# three read their own key directly, so their key files stay world-readable
# INSIDE the volume (644) — the volume boundary is the actual control, as it
# always was — while everything else goes 0600 root.
secure_state_keys() {
    local keys_dir="${1:-$STATE_DIR/keys}"
    [[ -d "$keys_dir" ]] || return 0
    chown 0:0 "$keys_dir" 2>/dev/null || true
    local f base fixed=0
    for f in "$keys_dir"/*; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        chown 0:0 "$f" 2>/dev/null || true
        case "$base" in
            *.pub|*.pub.hex|*-cert.pem|*.crt|*.csr)
                chmod 644 "$f" 2>/dev/null || true   # public by design
                continue ;;
            dnstt-server.key.hex|masterdns-encrypt.key|slipstream-key.pem)
                chmod 644 "$f" 2>/dev/null || true   # non-root daemon reads it
                continue ;;
        esac
        # clash-api.env is no longer an exception: the root admin entrypoint now
        # reads it and hands the secret to the non-root app via env, so 0600 is
        # safe. Requires an admin image built from this revision or later.
        # Only touch what is actually loose, so the log stays meaningful.
        #
        # `find -perm /077` is GNU-only: BSD/macOS find rejects it, the test
        # yields nothing, and this function then silently chmods NOTHING. In
        # production it runs on Linux so it worked, but a helper that no-ops on
        # a whole platform -- and a test that fails only there -- teaches people
        # to ignore red output. Read the mode directly instead, GNU form first
        # then BSD.
        local mode
        mode=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || echo "")
        # Pad to 3 digits so 640 and 40 do not compare alike.
        while [[ -n "$mode" && ${#mode} -lt 3 ]]; do mode="0$mode"; done
        # Loose = any group or other bit set.
        if [[ -n "$mode" && "${mode:1}" != "00" ]]; then
            chmod 600 "$f" 2>/dev/null && fixed=$((fixed + 1))
        fi
    done
    [[ $fixed -gt 0 ]] && log_info "Secured $fixed key file(s) in $keys_dir (0600)"
    return 0
}

# Read a value from a .env-style file — handles duplicates (last wins), inline
# comments, and quotes.
#   val=$(get_env_val "ENABLE_XHTTP" "$env_file" "true")
#
# DELIBERATE DUPLICATE of the definition in moav.sh. The host CLI (lib/) and the
# provisioning tree (scripts/lib/, mounted into containers as /app/lib) are
# separate source trees — the container never sees moav.sh, and the CLI should
# not pull in 15 protocol generators just to read a variable. The bodies are held
# byte-identical by tests/env-resolution-test.sh, so the two cannot drift; that
# check is what makes the duplication safe rather than a second implementation.
#
# Note `cut -d'=' -f2-`, not -f2: values legitimately contain '=' (base64
# padding), and cutting at the first one silently truncates credentials.
get_env_val() {
    local key="$1" file="$2" default="${3:-}"
    local val
    val=$(grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d'=' -f2- | sed 's/#.*//' | tr -d '"' | tr -d "'" | xargs) || true
    echo "${val:-$default}"
}

# creds_valid <uuid> <password> — 0 iff both universal user credentials are
# well-formed (UUID + non-empty password). Guards against a malformed or
# partially-written credentials.env silently producing broken bundles.
creds_valid() {
    local uuid="${1:-}" password="${2:-}"
    [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 1
    [[ -n "$password" ]] || return 1
    return 0
}

# Donate mode: restrict a user to the protocols in DONATE_ONLY_PROTOCOLS.
# Reference, including how to add a protocol: docs/devdocs/DONATE-MODE.md
#
# Call this AFTER sourcing .env, in every script that generates per-user configs.
# It used to live only in user-add.sh, un-exported, and each sub-script then
# re-sourced .env — so the overrides never reached singbox-user-add.sh or
# wg-user-add.sh, and donated users got the operator's full protocol set.
apply_donate_mode() {
    local list=" ${DONATE_ONLY_PROTOCOLS:-} "
    [[ -n "${DONATE_ONLY_PROTOCOLS:-}" ]] || return 0

    # Not donatable: each needs a client-side daemon, a tunnel device or a DNS
    # delegation, which a recipient pasting a share link does not have.
    export ENABLE_WIREGUARD=false ENABLE_AMNEZIAWG=false ENABLE_TRUSTTUNNEL=false \
           ENABLE_GOOSERELAY=false ENABLE_DNSTT=false ENABLE_SLIPSTREAM=false \
           ENABLE_MASTERDNS=false ENABLE_XDNS=false

    _dm() { [[ "$list" == *" $1 "* ]]; }
    _dm reality     && export ENABLE_REALITY=true   || export ENABLE_REALITY=false
    _dm trojan      && export ENABLE_TROJAN=true    || export ENABLE_TROJAN=false
    _dm anytls      && export ENABLE_ANYTLS=true    || export ENABLE_ANYTLS=false
    _dm hysteria2   && export ENABLE_HYSTERIA2=true || export ENABLE_HYSTERIA2=false
    _dm shadowsocks && export ENABLE_SS=true        || export ENABLE_SS=false
    _dm telegram    && export ENABLE_TELEMT=true    || export ENABLE_TELEMT=false
    _dm xhttp       && export ENABLE_XHTTP=true     || export ENABLE_XHTTP=false
    unset -f _dm
}

# True when donate mode is off, or when $1 is in the donated list. For protocols
# with no ENABLE_ flag to switch (CDN keys off CDN_SUBDOMAIN, and clearing that
# does not stick because the generator re-reads .env when it is empty).
donate_allows() {
    [[ -z "${DONATE_ONLY_PROTOCOLS:-}" ]] && return 0
    [[ " ${DONATE_ONLY_PROTOCOLS} " == *" $1 "* ]]
}

# Is the Cloudflare-fronted CDN inbound in use?
#
# ENABLE_CDN is the flag, but .env.example ships it UNSET (commented), so the
# rule below governs: CDN is on when CDN_SUBDOMAIN/CDN_DOMAIN is set. A CDN link
# only works once the subdomain is proxied through Cloudflare, so an unconfigured
# server stays off (no config that cannot connect) while a configured one needs
# no second toggle. An explicit true/false still wins. Leaving the flag unset
# also means `moav update` never appends it onto an upgrading server, which is
# how a pre-flag server (and any server that never set it) keeps its CDN.
cdn_enabled() {
    local flag="${ENABLE_CDN:-}"
    [[ -z "$flag" && -f .env ]] && flag="$(get_env_val "ENABLE_CDN" ".env" "")"
    if [[ -n "$flag" ]]; then
        [[ "$flag" == "true" ]]
        return
    fi
    local sub="${CDN_SUBDOMAIN:-}"
    [[ -z "$sub" && -f .env ]] && sub="$(get_env_val "CDN_SUBDOMAIN" ".env" "")"
    [[ -n "$sub" || -n "${CDN_DOMAIN:-}" ]]
}

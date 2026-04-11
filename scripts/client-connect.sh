#!/bin/bash
# =============================================================================
# MoaV Client - Connect Mode
# Connects to MoaV server and exposes local SOCKS5/HTTP proxy
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration (from environment, set by entrypoint)
CONFIG_DIR="${CONFIG_DIR:-/config}"
PROTOCOL="${PROTOCOL:-auto}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
HTTP_PORT="${HTTP_PORT:-8080}"
TEST_URL="${TEST_URL:-https://www.google.com/generate_204}"
TEST_TIMEOUT="${TEST_TIMEOUT:-10}"

# Protocol priority for auto mode
# Note: psiphon excluded - requires embedded server list, not supported in client mode
PROTOCOL_PRIORITY=(reality hysteria2 trojan xhttp trusttunnel wireguard amneziawg tor dnstt slipstream)

# State
CURRENT_PID=""
CURRENT_PROTOCOL=""
EXIT_IP=""

# =============================================================================
# Logging
# =============================================================================

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { [[ "${VERBOSE:-false}" == "true" ]] && echo -e "${CYAN}[DEBUG]${NC} $1" || true; }

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
    log_info "Shutting down..."
    [[ -n "$CURRENT_PID" ]] && kill "$CURRENT_PID" 2>/dev/null || true
    rm -rf /tmp/moav-client-*
    exit 0
}
trap cleanup SIGTERM SIGINT

# =============================================================================
# Protocol Connection Functions
# =============================================================================

# Portable URL parameter extraction (no grep -P)
extract_param() {
    local uri="$1"
    local param="$2"
    echo "$uri" | sed -n "s/.*[?&]${param}=\([^&#]*\).*/\1/p" | head -1
}

# Extract value before @ in URI
extract_auth() {
    local uri="$1"
    local protocol="$2"
    echo "$uri" | sed -n "s|${protocol}://\([^@]*\)@.*|\1|p" | head -1
}

# Extract host from URI (between @ and :port or ?)
# Handles both IPv4 (server:port) and IPv6 ([addr]:port)
extract_host() {
    local uri="$1"
    # Check for IPv6 (brackets after @)
    if echo "$uri" | grep -q '@\['; then
        # IPv6: extract [address] including brackets, then remove brackets for sing-box
        echo "$uri" | sed -n 's|.*@\(\[[^]]*\]\):.*|\1|p' | head -1 | tr -d '[]'
    else
        # IPv4: extract until colon
        echo "$uri" | sed -n 's|.*@\([^:]*\):.*|\1|p' | head -1
    fi
}

# Extract port from URI
# Handles both IPv4 (server:port) and IPv6 ([addr]:port)
extract_port() {
    local uri="$1"
    # Check for IPv6 (brackets) - port comes after ]:
    if echo "$uri" | grep -q '@\['; then
        echo "$uri" | sed -n 's|.*\]:\([0-9]*\)[?#].*|\1|p' | head -1
    else
        # IPv4 - port comes after host:
        echo "$uri" | sed -n 's|.*:\([0-9]*\)[?#].*|\1|p' | head -1
    fi
}

# Generate sing-box client config for proxy protocols
generate_singbox_config() {
    local protocol="$1"
    local output_file="$2"
    local config_file=""

    # Find config file (prefer IPv4 over IPv6, .txt over .json)
    case "$protocol" in
        reality)
            # Prefer non-IPv6 configs first
            for f in "$CONFIG_DIR"/reality.txt "$CONFIG_DIR"/reality.json; do
                [[ -f "$f" ]] && config_file="$f" && break
            done
            # Fall back to any reality config (including ipv6)
            if [[ -z "$config_file" ]]; then
                for f in "$CONFIG_DIR"/reality*.txt "$CONFIG_DIR"/reality*.json; do
                    [[ -f "$f" ]] && config_file="$f" && break
                done
            fi
            ;;
        trojan)
            for f in "$CONFIG_DIR"/trojan.txt "$CONFIG_DIR"/trojan.json; do
                [[ -f "$f" ]] && config_file="$f" && break
            done
            if [[ -z "$config_file" ]]; then
                for f in "$CONFIG_DIR"/trojan*.txt "$CONFIG_DIR"/trojan*.json; do
                    [[ -f "$f" ]] && config_file="$f" && break
                done
            fi
            ;;
        hysteria2)
            for f in "$CONFIG_DIR"/hysteria2.txt "$CONFIG_DIR"/hysteria2.yaml "$CONFIG_DIR"/hysteria2.yml; do
                [[ -f "$f" ]] && config_file="$f" && break
            done
            if [[ -z "$config_file" ]]; then
                for f in "$CONFIG_DIR"/hysteria2*.txt "$CONFIG_DIR"/hysteria2*.yaml "$CONFIG_DIR"/hysteria2*.yml; do
                    [[ -f "$f" ]] && config_file="$f" && break
                done
            fi
            ;;
        wireguard)
            for f in "$CONFIG_DIR"/wireguard.conf "$CONFIG_DIR"/wg.conf; do
                [[ -f "$f" ]] && config_file="$f" && break
            done
            if [[ -z "$config_file" ]]; then
                for f in "$CONFIG_DIR"/wireguard*.conf "$CONFIG_DIR"/wg*.conf; do
                    [[ -f "$f" ]] && config_file="$f" && break
                done
            fi
            ;;
    esac

    if [[ -z "$config_file" ]]; then
        return 1
    fi

    log_debug "Generating config from: $config_file"

    # Base config with inbounds
    local inbounds='[
        {"type": "socks", "tag": "socks-in", "listen": "0.0.0.0", "listen_port": '"$SOCKS_PORT"'},
        {"type": "http", "tag": "http-in", "listen": "0.0.0.0", "listen_port": '"$HTTP_PORT"'}
    ]'

    # Parse and generate outbound based on protocol and file type
    case "$protocol" in
        reality)
            if [[ "$config_file" == *.txt ]]; then
                local uri=$(cat "$config_file" | tr -d '\n\r')
                local uuid=$(extract_auth "$uri" "vless")
                local server=$(extract_host "$uri")
                local port=$(extract_port "$uri")
                local sni=$(extract_param "$uri" "sni")
                local pbk=$(extract_param "$uri" "pbk")
                local sid=$(extract_param "$uri" "sid")
                local fp=$(extract_param "$uri" "fp")

                [[ -z "$fp" ]] && fp="chrome"

                # Ensure port is numeric
                port=$(echo "$port" | tr -cd '0-9')
                [[ -z "$port" ]] && port="443"

                # Validate required fields
                if [[ -z "$server" ]] || [[ -z "$uuid" ]] || [[ -z "$sni" ]] || [[ -z "$pbk" ]]; then
                    log_error "Failed to parse Reality URI (missing required fields)"
                    log_debug "server='$server' uuid='${uuid:0:8}...' sni='$sni' pbk='${pbk:0:10}...'"
                    return 1
                fi

                log_debug "Reality config: server=$server port=$port sni=$sni"

                cat > "$output_file" << EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": $inbounds,
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "$server",
      "server_port": $port,
      "uuid": "$uuid",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$sni",
        "utls": {"enabled": true, "fingerprint": "$fp"},
        "reality": {
          "enabled": true,
          "public_key": "$pbk",
          "short_id": "$sid"
        }
      }
    }
  ],
  "route": {"final": "proxy"}
}
EOF
            else
                jq --argjson inbounds "$inbounds" '. + {"inbounds": $inbounds, "log": {"level": "info", "timestamp": true}, "route": {"final": "proxy"}}' "$config_file" > "$output_file"
            fi
            ;;

        trojan)
            if [[ "$config_file" == *.txt ]]; then
                local uri=$(cat "$config_file" | tr -d '\n\r')
                local password=$(extract_auth "$uri" "trojan")
                local server=$(extract_host "$uri")
                local port=$(extract_port "$uri")
                local sni=$(extract_param "$uri" "sni")

                [[ -z "$sni" ]] && sni="$server"

                # Ensure port is numeric
                port=$(echo "$port" | tr -cd '0-9')
                [[ -z "$port" ]] && port="8443"

                # Validate required fields
                if [[ -z "$server" ]] || [[ -z "$password" ]]; then
                    log_error "Failed to parse Trojan URI (missing required fields)"
                    log_debug "server='$server' password='${password:0:8}...'"
                    return 1
                fi

                log_debug "Trojan config: server=$server port=$port sni=$sni"

                cat > "$output_file" << EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": $inbounds,
  "outbounds": [
    {
      "type": "trojan",
      "tag": "proxy",
      "server": "$server",
      "server_port": $port,
      "password": "$password",
      "tls": {
        "enabled": true,
        "server_name": "$sni"
      }
    }
  ],
  "route": {"final": "proxy"}
}
EOF
            else
                jq --argjson inbounds "$inbounds" '. + {"inbounds": $inbounds, "log": {"level": "info", "timestamp": true}, "route": {"final": "proxy"}}' "$config_file" > "$output_file"
            fi
            ;;

        hysteria2)
            local server="" auth="" sni="" obfs_type="" obfs_password=""

            if [[ "$config_file" == *.txt ]]; then
                local uri=$(cat "$config_file" | tr -d '\n\r')
                auth=$(extract_auth "$uri" "hysteria2")
                server=$(echo "$uri" | sed -n 's|.*@\([^?#]*\).*|\1|p' | head -1)
                sni=$(extract_param "$uri" "sni")
                obfs_type=$(extract_param "$uri" "obfs")
                obfs_password=$(extract_param "$uri" "obfs-password")
            elif [[ "$config_file" == *.yaml ]] || [[ "$config_file" == *.yml ]]; then
                server=$(grep -E "^server:" "$config_file" | sed 's/server:[[:space:]]*//' | tr -d '"' | head -1)
                auth=$(grep -E "^auth:" "$config_file" | sed 's/auth:[[:space:]]*//' | tr -d '"' | head -1)
                sni=$(grep -E "^[[:space:]]*sni:" "$config_file" | sed 's/.*sni:[[:space:]]*//' | tr -d '"' | head -1)
                obfs_type=$(grep -E "^[[:space:]]*type:" "$config_file" | head -1 | sed 's/.*type:[[:space:]]*//' | tr -d '"')
                obfs_password=$(grep -E "^[[:space:]]*password:" "$config_file" | head -2 | tail -1 | sed 's/.*password:[[:space:]]*//' | tr -d '"')
            fi

            # Parse host:port - handle both IPv4 and IPv6
            local host="" port=""
            if echo "$server" | grep -q '^\['; then
                # IPv6: [addr]:port format
                host=$(echo "$server" | sed 's/^\[\([^]]*\)\].*/\1/')
                port=$(echo "$server" | sed -n 's/.*\]:\([0-9]*\).*/\1/p')
                [[ -z "$port" ]] && port="443"
            elif echo "$server" | grep -q ':'; then
                # IPv4: host:port format
                host="${server%:*}"
                port="${server##*:}"
            else
                host="$server"
                port="443"
            fi

            # Ensure port is numeric
            port=$(echo "$port" | tr -cd '0-9')
            [[ -z "$port" ]] && port="443"
            [[ -z "$sni" ]] && sni="$host"

            # Validate required fields
            if [[ -z "$host" ]] || [[ -z "$auth" ]]; then
                log_error "Failed to parse Hysteria2 config (missing required fields)"
                log_debug "host='$host' auth='${auth:0:8}...'"
                return 1
            fi

            log_debug "Hysteria2 config: host=$host port=$port sni=$sni"

            # Build obfs config if present
            local obfs_config=""
            if [[ -n "$obfs_type" ]] && [[ -n "$obfs_password" ]]; then
                obfs_config=",
      \"obfs\": {
        \"type\": \"$obfs_type\",
        \"password\": \"$obfs_password\"
      }"
            fi

            cat > "$output_file" << EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": $inbounds,
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "proxy",
      "server": "$host",
      "server_port": $port,
      "password": "$auth"$obfs_config,
      "tls": {
        "enabled": true,
        "server_name": "$sni"
      }
    }
  ],
  "route": {"final": "proxy"}
}
EOF
            ;;

        wireguard)
            # Extract WireGuard config values (case-insensitive, match first = only)
            local private_key=$(grep -i "PrivateKey" "$config_file" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \t\r')
            local endpoint=$(grep -i "Endpoint" "$config_file" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \t\r')
            local peer_public_key=$(grep -i "PublicKey" "$config_file" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \t\r')
            local address=$(grep -i "Address" "$config_file" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \t\r' | cut -d',' -f1)

            # Parse endpoint - handle both IPv4 and IPv6
            local server="" port=""
            if echo "$endpoint" | grep -q '^\['; then
                # IPv6: [addr]:port format
                server=$(echo "$endpoint" | sed 's/^\[\([^]]*\)\].*/\1/')
                port=$(echo "$endpoint" | sed -n 's/.*\]:\([0-9]*\).*/\1/p')
            else
                # IPv4: host:port format
                server="${endpoint%:*}"
                port="${endpoint##*:}"
            fi

            # Ensure port is numeric
            port=$(echo "$port" | tr -cd '0-9')
            [[ -z "$port" ]] && port="51820"

            # Validate required fields
            if [[ -z "$server" ]] || [[ -z "$private_key" ]] || [[ -z "$peer_public_key" ]]; then
                log_error "Failed to parse WireGuard config (missing required fields)"
                log_debug "server='$server' private_key='${private_key:0:10}...' peer_public_key='${peer_public_key:0:10}...'"
                return 1
            fi

            log_debug "WireGuard config: server=$server port=$port"

            cat > "$output_file" << EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": $inbounds,
  "outbounds": [
    {
      "type": "wireguard",
      "tag": "proxy",
      "server": "$server",
      "server_port": $port,
      "local_address": ["$address"],
      "private_key": "$private_key",
      "peer_public_key": "$peer_public_key",
      "mtu": 1280
    }
  ],
  "route": {"final": "proxy"}
}
EOF
            ;;
    esac

    return 0
}

# Connect using sing-box (Reality, Trojan, Hysteria2)
connect_singbox() {
    local protocol="$1"
    local config_file="/tmp/moav-client-$protocol.json"

    if ! generate_singbox_config "$protocol" "$config_file"; then
        log_error "Failed to generate config for $protocol"
        return 1
    fi

    log_info "Starting sing-box with $protocol..."
    sing-box run -c "$config_file" &
    CURRENT_PID=$!
    CURRENT_PROTOCOL="$protocol"

    sleep 2

    if ! kill -0 $CURRENT_PID 2>/dev/null; then
        log_error "sing-box failed to start"
        return 1
    fi

    # Test connection
    sleep 1
    if curl -sf --socks5 127.0.0.1:$SOCKS_PORT --max-time "$TEST_TIMEOUT" "$TEST_URL" >/dev/null 2>&1; then
        # Get exit IP for display
        EXIT_IP=$(curl -sf --socks5 127.0.0.1:$SOCKS_PORT --max-time "$TEST_TIMEOUT" https://api.ipify.org 2>/dev/null || \
                  curl -sf --socks5 127.0.0.1:$SOCKS_PORT --max-time "$TEST_TIMEOUT" https://ifconfig.me 2>/dev/null || echo "")
        return 0
    else
        log_warn "Connection test failed for $protocol"
        kill $CURRENT_PID 2>/dev/null || true
        CURRENT_PID=""
        return 1
    fi
}

# Connect using WireGuard via sing-box
connect_wireguard() {
    local config_file="/tmp/moav-client-wireguard.json"

    if ! generate_singbox_config "wireguard" "$config_file"; then
        log_error "Failed to generate config for wireguard"
        return 1
    fi

    log_info "Starting sing-box with WireGuard..."
    sing-box run -c "$config_file" &
    CURRENT_PID=$!
    CURRENT_PROTOCOL="wireguard"

    sleep 3

    if ! kill -0 $CURRENT_PID 2>/dev/null; then
        log_error "sing-box failed to start WireGuard tunnel"
        return 1
    fi

    # Test connection
    if curl -sf --socks5 127.0.0.1:$SOCKS_PORT --max-time "$TEST_TIMEOUT" "$TEST_URL" >/dev/null 2>&1; then
        EXIT_IP=$(curl -sf --socks5 127.0.0.1:$SOCKS_PORT --max-time "$TEST_TIMEOUT" https://api.ipify.org 2>/dev/null || \
                  curl -sf --socks5 127.0.0.1:$SOCKS_PORT --max-time "$TEST_TIMEOUT" https://ifconfig.me 2>/dev/null || echo "")
        return 0
    else
        log_warn "Connection test failed for wireguard"
        kill $CURRENT_PID 2>/dev/null || true
        CURRENT_PID=""
        return 1
    fi
}

# Connect using XHTTP (VLESS+XHTTP+Reality via Xray-core)
connect_xhttp() {
    local config_file=""

    # Find XHTTP config
    for f in "$CONFIG_DIR"/xhttp-vless.txt "$CONFIG_DIR"/xhttp.txt; do
        if [[ -f "$f" ]] && grep -q "^vless://" "$f" 2>/dev/null; then
            config_file="$f"
            break
        fi
    done

    if [[ -z "$config_file" ]]; then
        log_error "No XHTTP config found"
        return 1
    fi

    if ! command -v xray &>/dev/null; then
        log_error "Xray-core not installed (rebuild client image to add XHTTP support)"
        return 1
    fi

    # Parse VLESS URI
    local uri=$(cat "$config_file" | head -1 | tr -d '\n\r')
    local uuid=$(extract_auth "$uri" "vless")
    local server=$(extract_host "$uri")
    local port=$(extract_port "$uri")
    local sni=$(extract_param "$uri" "sni")
    local pbk=$(extract_param "$uri" "pbk")
    local sid=$(extract_param "$uri" "sid")
    local fp=$(extract_param "$uri" "fp")

    [[ -z "$fp" ]] && fp="chrome"
    [[ -z "$port" ]] && port="2096"
    port=$(echo "$port" | tr -cd '0-9')
    [[ -z "$port" ]] && port="2096"

    if [[ -z "$server" ]] || [[ -z "$uuid" ]] || [[ -z "$sni" ]] || [[ -z "$pbk" ]]; then
        log_error "Failed to parse XHTTP URI"
        return 1
    fi

    # Generate Xray config
    local xray_config="/tmp/moav-client-xhttp.json"
    cat > "$xray_config" << EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": {"udp": true}
    },
    {
      "listen": "0.0.0.0",
      "port": $HTTP_PORT,
      "protocol": "http"
    }
  ],
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "$server",
        "port": $port,
        "users": [{"id": "$uuid", "encryption": "none", "flow": ""}]
      }]
    },
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "realitySettings": {
        "serverName": "$sni",
        "fingerprint": "$fp",
        "publicKey": "$pbk",
        "shortId": "$sid"
      }
    }
  }]
}
EOF

    log_info "Starting Xray with XHTTP..."
    xray run -c "$xray_config" &
    CURRENT_PID=$!
    CURRENT_PROTOCOL="xhttp"

    sleep 3

    if ! kill -0 $CURRENT_PID 2>/dev/null; then
        log_error "Xray failed to start"
        return 1
    fi

    # Test connection
    if curl -sf --socks5 127.0.0.1:$SOCKS_PORT --max-time "$TEST_TIMEOUT" "$TEST_URL" >/dev/null 2>&1; then
        EXIT_IP=$(curl -sf --socks5 127.0.0.1:$SOCKS_PORT --max-time "$TEST_TIMEOUT" https://api.ipify.org 2>/dev/null || \
                  curl -sf --socks5 127.0.0.1:$SOCKS_PORT --max-time "$TEST_TIMEOUT" https://ifconfig.me 2>/dev/null || echo "")
        return 0
    else
        log_warn "Connection test failed for xhttp"
        kill $CURRENT_PID 2>/dev/null || true
        CURRENT_PID=""
        return 1
    fi
}

# Connect using AmneziaWG (full VPN via awg-quick)
# Note: AmneziaWG is a full VPN (TUN-based), not a proxy
# It routes all container traffic through the VPN tunnel
connect_amneziawg() {
    local config_file=""

    for f in "$CONFIG_DIR"/amneziawg.conf; do
        [[ -f "$f" ]] && config_file="$f" && break
    done

    if [[ -z "$config_file" ]]; then
        log_error "No AmneziaWG config found (looking for amneziawg.conf in $CONFIG_DIR)"
        return 1
    fi

    if ! command -v awg-quick >/dev/null 2>&1; then
        log_error "awg-quick not available"
        log_info "AmneziaWG tools not installed in this container"
        return 1
    fi

    # Check for TUN device
    if [[ ! -e /dev/net/tun ]]; then
        log_error "/dev/net/tun not available - container needs NET_ADMIN capability"
        return 1
    fi

    log_info "Starting AmneziaWG VPN..."
    log_info "Note: AmneziaWG is a full VPN - all container traffic will be tunneled"

    # Bring up the AmneziaWG interface
    if ! awg-quick up "$config_file" 2>&1; then
        log_error "awg-quick up failed"
        return 1
    fi

    CURRENT_PROTOCOL="amneziawg"

    # Wait for interface to come up
    sleep 5

    # Test connection directly (traffic goes through TUN, not via SOCKS5)
    if curl -sf --max-time "$TEST_TIMEOUT" "$TEST_URL" >/dev/null 2>&1; then
        EXIT_IP=$(curl -sf --max-time "$TEST_TIMEOUT" https://api.ipify.org 2>/dev/null || \
                  curl -sf --max-time "$TEST_TIMEOUT" https://ifconfig.me 2>/dev/null || echo "")
        log_success "AmneziaWG VPN connected (exit IP: ${EXIT_IP:-unknown})"
        return 0
    else
        log_warn "Connection test failed for AmneziaWG"
        awg-quick down "$config_file" 2>/dev/null || true
        CURRENT_PROTOCOL=""
        return 1
    fi
}

# Connect using dnstt
connect_dnstt() {
    local config_file=""

    for f in "$CONFIG_DIR"/dnstt*.txt "$CONFIG_DIR"/*dnstt*; do
        [[ -f "$f" ]] && config_file="$f" && break
    done

    if [[ -z "$config_file" ]]; then
        log_error "No dnstt config found"
        return 1
    fi

    # Extract domain - look for t.domain.com pattern (portable)
    local domain=$(grep -oE 't\.[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "$config_file" | head -1)

    # Extract pubkey - look for hex string (64 chars) in the config
    local pubkey=""
    pubkey=$(grep -oE '[0-9a-fA-F]{64}' "$config_file" | head -1)

    # Check for server.pub in bundle (hex format)
    [[ -z "$pubkey" ]] && [[ -f "$CONFIG_DIR/server.pub" ]] && pubkey=$(cat "$CONFIG_DIR/server.pub" | tr -d '\n\r ')

    # Check for server.pub in default dnstt outputs location
    [[ -z "$pubkey" ]] && [[ -f "/outputs/dnstt/server.pub" ]] && pubkey=$(cat "/outputs/dnstt/server.pub" | tr -d '\n\r ')

    # Check configs directory
    [[ -z "$pubkey" ]] && [[ -f "/configs/dnstt/server.pub" ]] && pubkey=$(cat "/configs/dnstt/server.pub" | tr -d '\n\r ')

    if [[ -z "$domain" ]] || [[ -z "$pubkey" ]]; then
        log_error "Could not extract dnstt domain or pubkey"
        log_debug "domain=$domain pubkey=${pubkey:0:20}..."
        return 1
    fi

    log_info "Starting dnstt client for $domain..."
    log_info "Note: DNS tunneling is slow - please be patient"

    # dnstt-client creates a TCP tunnel to the server's upstream (sing-box SOCKS proxy)
    # So the local port acts as a SOCKS5 proxy
    dnstt-client -doh https://1.1.1.1/dns-query -pubkey "$pubkey" "$domain" 127.0.0.1:$SOCKS_PORT &
    CURRENT_PID=$!
    CURRENT_PROTOCOL="dnstt"

    # DNS tunneling takes longer to establish
    sleep 5

    if ! kill -0 $CURRENT_PID 2>/dev/null; then
        log_error "dnstt-client failed to start"
        return 1
    fi

    # Test connectivity (with longer timeout for DNS tunnel)
    log_info "Testing tunnel connectivity..."
    if curl -sf --socks5 127.0.0.1:$SOCKS_PORT --max-time 30 "$TEST_URL" >/dev/null 2>&1; then
        log_success "dnstt tunnel established and working"
        return 0
    else
        log_warn "Tunnel established but connectivity test timed out"
        log_info "DNS tunneling is slow - connection may still work"
        return 0
    fi
}

# Connect using Slipstream (QUIC-over-DNS tunnel)
connect_slipstream() {
    local instructions_file=""

    for f in "$CONFIG_DIR"/slipstream*.txt "$CONFIG_DIR"/*slipstream*; do
        [[ -f "$f" ]] && instructions_file="$f" && break
    done

    if [[ -z "$instructions_file" ]]; then
        log_error "No Slipstream config found"
        return 1
    fi

    if ! command -v slipstream-client >/dev/null 2>&1; then
        log_error "slipstream-client not available"
        return 1
    fi

    # Extract domain from instructions (e.g., s.example.com)
    local domain=$(grep -oE 's\.[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "$instructions_file" | head -1)

    if [[ -z "$domain" ]]; then
        log_error "Could not extract Slipstream domain from instructions"
        return 1
    fi

    # Find cert file
    local cert_file=""
    for f in "$CONFIG_DIR"/slipstream-cert.pem "/slipstream/cert.pem"; do
        [[ -f "$f" ]] && cert_file="$f" && break
    done

    if [[ -z "$cert_file" ]]; then
        log_error "Slipstream certificate not found"
        return 1
    fi

    log_info "Starting Slipstream client for $domain..."
    log_info "Note: DNS tunneling may be slow - using resolver mode (stealthier)"

    # slipstream-client is a TCP tunnel: local TCP port → DNS tunnel → server's sing-box:1080 (SOCKS5)
    slipstream-client --domain "$domain" --cert "$cert_file" --resolver 1.1.1.1:53 --tcp-listen-host 127.0.0.1 --tcp-listen-port $SOCKS_PORT &
    CURRENT_PID=$!
    CURRENT_PROTOCOL="slipstream"

    # DNS tunneling takes a moment to establish
    sleep 5

    if ! kill -0 $CURRENT_PID 2>/dev/null; then
        log_error "slipstream-client failed to start"
        return 1
    fi

    # Test connectivity (with longer timeout for DNS tunnel)
    log_info "Testing tunnel connectivity..."
    if curl -sf --socks5 127.0.0.1:$SOCKS_PORT --max-time 30 "$TEST_URL" >/dev/null 2>&1; then
        log_success "Slipstream tunnel established and working"
        return 0
    else
        log_warn "Tunnel established but connectivity test timed out"
        log_info "DNS tunneling is slow - connection may still work"
        return 0
    fi
}

# Connect using TrustTunnel
# Note: TrustTunnel is a full VPN (TUN-based), not a proxy
# It routes all container traffic through the VPN tunnel
connect_trusttunnel() {
    local config_file=""

    # Look for TOML config first (full config), then fall back to JSON/txt
    for f in "$CONFIG_DIR"/trusttunnel.toml "$CONFIG_DIR"/trusttunnel.json "$CONFIG_DIR"/trusttunnel.txt; do
        [[ -f "$f" ]] && config_file="$f" && break
    done

    if [[ -z "$config_file" ]]; then
        log_error "No TrustTunnel config found"
        return 1
    fi

    if ! command -v trusttunnel_client >/dev/null 2>&1; then
        log_error "trusttunnel_client not available"
        log_info "TrustTunnel CLI client not installed in this container"
        return 1
    fi

    # If we have a TOML config, use it directly
    if [[ "$config_file" == *.toml ]]; then
        log_info "Starting TrustTunnel VPN client..."
        log_info "Note: TrustTunnel is a full VPN - all container traffic will be tunneled"

        # Run TrustTunnel client in background
        trusttunnel_client --config "$config_file" > /var/log/moav/trusttunnel.log 2>&1 &
        CURRENT_PID=$!
        CURRENT_PROTOCOL="trusttunnel"

        # Wait for TUN interface to come up
        sleep 8

        if ! kill -0 $CURRENT_PID 2>/dev/null; then
            log_error "trusttunnel_client failed to start"
            [[ -f /var/log/moav/trusttunnel.log ]] && tail -5 /var/log/moav/trusttunnel.log
            return 1
        fi

        # Test connection directly (traffic goes through TUN)
        if curl -sf --max-time "$TEST_TIMEOUT" "$TEST_URL" >/dev/null 2>&1; then
            EXIT_IP=$(curl -sf --max-time "$TEST_TIMEOUT" https://api.ipify.org 2>/dev/null || \
                      curl -sf --max-time "$TEST_TIMEOUT" https://ifconfig.me 2>/dev/null || echo "")
            log_success "TrustTunnel VPN connected (exit IP: ${EXIT_IP:-unknown})"
            return 0
        else
            log_warn "Connection test failed for TrustTunnel"
            kill $CURRENT_PID 2>/dev/null || true
            CURRENT_PID=""
            return 1
        fi
    fi

    # Fall back to parsing JSON/txt for manual info
    local endpoint="" username="" password="" server_ip=""

    if [[ "$config_file" == *.json ]]; then
        # Support both old and new field names
        endpoint=$(jq -r '.ip_address // .endpoint // empty' "$config_file" 2>/dev/null || true)
        server_ip=$(jq -r '.domain // .server_ip // empty' "$config_file" 2>/dev/null || true)
        username=$(jq -r '.username // empty' "$config_file" 2>/dev/null || true)
        password=$(jq -r '.password // empty' "$config_file" 2>/dev/null || true)
    else
        # Support both old and new field names in txt files
        endpoint=$(grep -iE "^(IP Address|Endpoint):" "$config_file" | sed 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' | head -1 || true)
        server_ip=$(grep -iE "^(Domain|Server IP):" "$config_file" | sed 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' | head -1 || true)
        username=$(grep -i "^Username:" "$config_file" | sed 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' | head -1 || true)
        password=$(grep -i "^Password:" "$config_file" | sed 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' | head -1 || true)
    fi

    if [[ -z "$endpoint" ]] || [[ -z "$username" ]] || [[ -z "$password" ]]; then
        log_error "Could not parse TrustTunnel config (missing endpoint/username/password)"
        return 1
    fi

    # Generate a temporary TOML config
    local temp_config="/tmp/trusttunnel-temp.toml"
    local hostname="${endpoint%:*}"
    local port="${endpoint#*:}"
    [[ -z "$server_ip" ]] && server_ip="$hostname"

    cat > "$temp_config" <<EOF
loglevel = "info"
vpn_mode = "general"
killswitch_enabled = false
post_quantum_group_enabled = true

[endpoint]
hostname = "$hostname"
dns_upstreams = ["tls://1.1.1.1"]
addresses = ["$server_ip:$port"]
has_ipv6 = false
username = "$username"
password = "$password"
upstream_protocol = "http2"
upstream_fallback_protocol = "http3"

[listener.tun]
included_routes = ["0.0.0.0/0"]
excluded_routes = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
mtu_size = 1280
EOF

    log_info "Starting TrustTunnel VPN client..."
    trusttunnel_client --config "$temp_config" > /var/log/moav/trusttunnel.log 2>&1 &
    CURRENT_PID=$!
    CURRENT_PROTOCOL="trusttunnel"

    sleep 8

    if ! kill -0 $CURRENT_PID 2>/dev/null; then
        log_error "trusttunnel_client failed to start"
        [[ -f /var/log/moav/trusttunnel.log ]] && tail -5 /var/log/moav/trusttunnel.log
        rm -f "$temp_config"
        return 1
    fi

    if curl -sf --max-time "$TEST_TIMEOUT" "$TEST_URL" >/dev/null 2>&1; then
        EXIT_IP=$(curl -sf --max-time "$TEST_TIMEOUT" https://api.ipify.org 2>/dev/null || echo "")
        log_success "TrustTunnel VPN connected (exit IP: ${EXIT_IP:-unknown})"
        return 0
    else
        log_warn "Connection test failed for TrustTunnel"
        kill $CURRENT_PID 2>/dev/null || true
        CURRENT_PID=""
        rm -f "$temp_config"
        return 1
    fi
}

# Connect using Psiphon (standalone, doesn't need MoaV server)
# NOTE: Not implemented - Psiphon tunnel-core requires embedded server lists
# that are not publicly available. Use the official Psiphon apps instead:
# - Android: https://play.google.com/store/apps/details?id=com.psiphon3
# - iOS: https://apps.apple.com/app/psiphon/id1276263909
# - Windows: https://psiphon.ca/en/download.html
connect_psiphon() {
    log_warn "Psiphon client mode not implemented"
    log_info "Psiphon requires embedded server lists not available for CLI usage"
    log_info "Use the official Psiphon apps for your platform instead:"
    log_info "  - Android/iOS: Search 'Psiphon' in app store"
    log_info "  - Windows: https://psiphon.ca/en/download.html"
    return 1
}

# Connect using Tor with Snowflake
connect_tor() {
    log_info "Starting Tor with Snowflake bridge..."
    log_info "Note: Tor connects to its own network, not your MoaV server"

    if ! command -v snowflake-client >/dev/null 2>&1; then
        log_error "snowflake-client not available"
        return 1
    fi

    # Create torrc with Snowflake (simplified config to stay under 510 byte limit)
    local torrc="/tmp/moav-torrc"
    cat > "$torrc" << EOF
SocksPort 0.0.0.0:$SOCKS_PORT
DataDirectory /tmp/tor-data
UseBridges 1
ClientTransportPlugin snowflake exec /usr/local/bin/snowflake-client
Bridge snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72 fingerprint=2B280B23E1107BB62ABFC40DDCC8824814F80A72 url=https://snowflake-broker.torproject.net.global.prod.fastly.net/ front=cdn.sstatic.net ice=stun:stun.l.google.com:19302
EOF

    mkdir -p /tmp/tor-data
    chmod 700 /tmp/tor-data

    tor -f "$torrc" &
    CURRENT_PID=$!
    CURRENT_PROTOCOL="tor"

    log_info "Waiting for Tor to bootstrap (this may take a while)..."
    sleep 10

    if ! kill -0 $CURRENT_PID 2>/dev/null; then
        log_error "Tor failed to start"
        return 1
    fi

    # Wait for bootstrap
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
        if curl -sf --socks5 127.0.0.1:$SOCKS_PORT --max-time 5 "$TEST_URL" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        ((attempts++))
    done

    log_warn "Tor may still be bootstrapping..."
    return 0
}

# =============================================================================
# Auto Mode - Try protocols in order
# =============================================================================

connect_auto() {
    log_info "Auto mode: trying protocols in priority order..."

    for protocol in "${PROTOCOL_PRIORITY[@]}"; do
        log_info "Trying $protocol..."

        case "$protocol" in
            reality|trojan|hysteria2)
                if connect_singbox "$protocol"; then
                    log_success "Connected via $protocol"
                    return 0
                fi
                ;;
            wireguard)
                if connect_wireguard; then
                    log_success "Connected via WireGuard"
                    return 0
                fi
                ;;
            amneziawg)
                if connect_amneziawg; then
                    log_success "Connected via AmneziaWG"
                    return 0
                fi
                ;;
            xhttp)
                if connect_xhttp; then
                    log_success "Connected via XHTTP"
                    return 0
                fi
                ;;
            trusttunnel)
                if connect_trusttunnel; then
                    log_success "Connected via TrustTunnel"
                    return 0
                fi
                ;;
            psiphon)
                if connect_psiphon; then
                    log_success "Connected via Psiphon"
                    return 0
                fi
                ;;
            tor)
                if connect_tor; then
                    log_success "Connected via Tor/Snowflake"
                    return 0
                fi
                ;;
            dnstt)
                if connect_dnstt; then
                    log_success "Connected via dnstt"
                    return 0
                fi
                ;;
            slipstream)
                if connect_slipstream; then
                    log_success "Connected via Slipstream"
                    return 0
                fi
                ;;
        esac

        log_warn "$protocol failed, trying next..."
    done

    log_error "All protocols failed!"
    return 1
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  MoaV Client - Connect Mode"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  Config:     $CONFIG_DIR"
    echo "  Protocol:   $PROTOCOL"
    echo "  SOCKS5:     0.0.0.0:$SOCKS_PORT"
    echo "  HTTP:       0.0.0.0:$HTTP_PORT"
    echo ""
    echo "───────────────────────────────────────────────────────────────"
    echo ""

    local connected=false

    case "$PROTOCOL" in
        auto)
            connect_auto && connected=true
            ;;
        reality|trojan|hysteria2)
            connect_singbox "$PROTOCOL" && connected=true
            ;;
        wireguard)
            connect_wireguard && connected=true
            ;;
        amneziawg)
            connect_amneziawg && connected=true
            ;;
        xhttp)
            connect_xhttp && connected=true
            ;;
        trusttunnel)
            connect_trusttunnel && connected=true
            ;;
        psiphon)
            connect_psiphon && connected=true
            ;;
        tor)
            connect_tor && connected=true
            ;;
        dnstt)
            connect_dnstt && connected=true
            ;;
        slipstream)
            connect_slipstream && connected=true
            ;;
        *)
            log_error "Unknown protocol: $PROTOCOL"
            exit 1
            ;;
    esac

    if [[ "$connected" != "true" ]]; then
        log_error "Failed to establish connection"
        exit 1
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}Connected!${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  Protocol:   $CURRENT_PROTOCOL"
    if [[ -n "${EXIT_IP:-}" ]]; then
        echo -e "  Exit IP:    ${CYAN}$EXIT_IP${NC}"
    fi
    echo "  SOCKS5:     localhost:$SOCKS_PORT"
    echo "  HTTP:       localhost:$HTTP_PORT"
    echo ""
    echo "  Configure your browser/apps to use one of these proxies."
    echo "  Press Ctrl+C to disconnect."
    echo ""
    echo "───────────────────────────────────────────────────────────────"

    # Keep running
    wait $CURRENT_PID
}

main

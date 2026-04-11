#!/bin/bash
# =============================================================================
# MoaV Client - Test Mode
# Tests connectivity to all services for a given user bundle
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test configuration
TEST_URL="${TEST_URL:-https://www.google.com/generate_204}"
TEST_TIMEOUT="${TEST_TIMEOUT:-10}"
TEMP_DIR="/tmp/moav-test-$$"

# Results storage
declare -A RESULTS
declare -A DETAILS

# =============================================================================
# Logging
# =============================================================================

log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_debug() { [[ "${VERBOSE:-false}" == "true" ]] && echo -e "${CYAN}[DEBUG]${NC} $1" >&2 || true; }

# =============================================================================
# Utility Functions
# =============================================================================

cleanup() {
    log_debug "Cleaning up..."
    jobs -p | xargs -r kill 2>/dev/null || true
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

setup() {
    mkdir -p "$TEMP_DIR"
}

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

# =============================================================================
# Test Functions
# =============================================================================

# Test Reality (VLESS) protocol
test_reality() {
    log_info "Testing Reality (VLESS)..."

    local config_file=""
    local result="skip"
    local detail=""
    local is_ipv6=false

    # Find Reality config - prefer IPv4 over IPv6
    # First try non-ipv6 configs
    for f in "$CONFIG_DIR"/reality.txt "$CONFIG_DIR"/reality.json; do
        [[ -f "$f" ]] && config_file="$f" && break
    done
    # Fall back to any reality config (including ipv6)
    if [[ -z "$config_file" ]]; then
        for f in "$CONFIG_DIR"/reality*.txt "$CONFIG_DIR"/reality*.json; do
            [[ -f "$f" ]] && config_file="$f" && break
        done
    fi
    # Check if this is an IPv6 config
    [[ "$config_file" == *ipv6* ]] && is_ipv6=true

    if [[ -z "$config_file" ]]; then
        detail="No Reality config found in bundle"
        log_warn "$detail"
        log_debug "Searched in: $CONFIG_DIR for reality*.txt, reality*.json"
        log_debug "Available files: $(ls -1 "$CONFIG_DIR" 2>/dev/null | tr '\n' ' ')"
        RESULTS[reality]="skip"
        DETAILS[reality]="$detail"
        return
    fi

    log_debug "Using config: $config_file"
    log_debug "Config content: $(cat "$config_file" | head -1 | cut -c1-80)..."

    local client_config="$TEMP_DIR/reality-client.json"

    if [[ "$config_file" == *.txt ]]; then
        local uri=$(cat "$config_file" | tr -d '\n\r')

        # Parse VLESS URI using portable methods
        local uuid=$(extract_auth "$uri" "vless")
        local server=$(extract_host "$uri")
        local port=$(extract_port "$uri")
        local sni=$(extract_param "$uri" "sni")
        local pbk=$(extract_param "$uri" "pbk")
        local sid=$(extract_param "$uri" "sid")
        local fp=$(extract_param "$uri" "fp")

        [[ -z "$fp" ]] && fp="chrome"
        [[ -z "$port" ]] && port="443"

        # Ensure port is numeric
        port=$(echo "$port" | tr -cd '0-9')
        [[ -z "$port" ]] && port="443"

        log_debug "Parsed: server=$server port=$port uuid=$uuid sni=$sni"
        log_debug "Reality params: pbk=$pbk sid=$sid fp=$fp"

        # Validate required fields
        if [[ -z "$server" ]] || [[ -z "$uuid" ]] || [[ -z "$sni" ]] || [[ -z "$pbk" ]]; then
            detail="Failed to parse Reality URI (missing required fields). Run with -v for details."
            log_error "$detail"
            log_error "server='$server' uuid='${uuid:0:8}...' sni='$sni' pbk='${pbk:0:10}...'"
            RESULTS[reality]="fail"
            DETAILS[reality]="$detail"
            return
        fi

        # Generate sing-box 1.12+ compatible config
        cat > "$client_config" << EOF
{
  "log": {"level": "error"},
  "inbounds": [
    {"type": "socks", "listen": "127.0.0.1", "listen_port": 10800}
  ],
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
  "route": {
    "final": "proxy"
  }
}
EOF
    else
        # JSON config - wrap with inbounds
        jq '. + {
          "log": {"level": "error"},
          "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": 10800}],
          "route": {"final": "proxy"}
        }' "$config_file" > "$client_config" 2>/dev/null || {
            detail="Failed to parse JSON config"
            log_error "$detail"
            RESULTS[reality]="fail"
            DETAILS[reality]="$detail"
            return
        }
    fi

    log_debug "Generated config: $(cat "$client_config")"

    # Validate JSON before running
    if ! jq empty "$client_config" 2>/dev/null; then
        detail="Generated invalid JSON config"
        log_error "$detail"
        log_debug "Config content: $(cat "$client_config")"
        RESULTS[reality]="fail"
        DETAILS[reality]="$detail"
        return
    fi

    # Start sing-box and capture errors
    local error_log="$TEMP_DIR/reality-error.log"
    sing-box run -c "$client_config" 2>"$error_log" &
    local pid=$!
    sleep 3

    if ! kill -0 $pid 2>/dev/null; then
        detail="sing-box failed to start"
        if [[ -s "$error_log" ]]; then
            local error_msg=$(tail -5 "$error_log" 2>/dev/null | tr '\n' ' ' || true)
            detail="sing-box error: $error_msg"
        fi
        log_error "$detail"
        log_debug "Generated config was: $(cat "$client_config" 2>/dev/null | tr '\n' ' ')"
        RESULTS[reality]="fail"
        DETAILS[reality]="$detail"
        return
    fi

    log_debug "sing-box started successfully (PID: $pid)"

    # Test connection
    log_debug "Testing connectivity via SOCKS5 on port 10800..."
    if curl -sf --socks5 127.0.0.1:10800 --max-time "$TEST_TIMEOUT" "$TEST_URL" >/dev/null 2>&1; then
        # Verify we can access the internet and get exit IP
        local exit_ip=""
        exit_ip=$(curl -sf --socks5 127.0.0.1:10800 --max-time "$TEST_TIMEOUT" https://api.ipify.org 2>/dev/null || \
                  curl -sf --socks5 127.0.0.1:10800 --max-time "$TEST_TIMEOUT" https://ifconfig.me 2>/dev/null || true)
        if [[ -n "$exit_ip" ]]; then
            log_success "Reality connection successful (exit IP: $exit_ip)"
            RESULTS[reality]="pass"
            DETAILS[reality]="Connected via VLESS/Reality, exit IP: $exit_ip"
        else
            log_success "Reality connection successful"
            RESULTS[reality]="pass"
            DETAILS[reality]="Connected via VLESS/Reality"
        fi
    else
        detail="Connection test failed"
        # Check for sing-box errors during operation
        if [[ -s "$error_log" ]]; then
            local error_msg=$(grep -i "error\|fail\|unreachable\|timeout\|refused" "$error_log" 2>/dev/null | tail -3 | tr '\n' ' ' || true)
            [[ -n "$error_msg" ]] && detail="$error_msg"
        fi
        log_debug "Full error log: $(cat "$error_log" 2>/dev/null | tail -10 | tr '\n' ' ')"
        log_debug "Server: $server:$port, SNI: $sni"
        # If IPv6 config and network unreachable, warn instead of fail
        if [[ "$is_ipv6" == "true" ]] && echo "$detail" | grep -qi "unreachable\|network"; then
            log_warn "IPv6 config - $detail"
            RESULTS[reality]="warn"
            DETAILS[reality]="IPv6 network may not be available: $detail"
        else
            log_error "$detail"
            RESULTS[reality]="fail"
            DETAILS[reality]="$detail"
        fi
    fi

    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
}

# Test Trojan protocol
test_trojan() {
    log_info "Testing Trojan..."

    local config_file=""
    local detail=""
    local is_ipv6=false

    # Find Trojan config - prefer IPv4 over IPv6
    for f in "$CONFIG_DIR"/trojan.txt "$CONFIG_DIR"/trojan.json; do
        [[ -f "$f" ]] && config_file="$f" && break
    done
    if [[ -z "$config_file" ]]; then
        for f in "$CONFIG_DIR"/trojan*.txt "$CONFIG_DIR"/trojan*.json; do
            [[ -f "$f" ]] && config_file="$f" && break
        done
    fi
    [[ "$config_file" == *ipv6* ]] && is_ipv6=true

    if [[ -z "$config_file" ]]; then
        detail="No Trojan config found in bundle"
        log_warn "$detail"
        log_debug "Searched in: $CONFIG_DIR for trojan*.txt, trojan*.json"
        RESULTS[trojan]="skip"
        DETAILS[trojan]="$detail"
        return
    fi

    log_debug "Using config: $config_file"
    log_debug "Config content: $(cat "$config_file" | head -1 | cut -c1-80)..."

    local client_config="$TEMP_DIR/trojan-client.json"

    if [[ "$config_file" == *.txt ]]; then
        local uri=$(cat "$config_file" | tr -d '\n\r')

        local password=$(extract_auth "$uri" "trojan")
        local server=$(extract_host "$uri")
        local port=$(extract_port "$uri")
        local sni=$(extract_param "$uri" "sni")

        [[ -z "$sni" ]] && sni="$server"
        [[ -z "$port" ]] && port="8443"

        # Ensure port is numeric
        port=$(echo "$port" | tr -cd '0-9')
        [[ -z "$port" ]] && port="8443"

        log_debug "Parsed: server=$server port=$port sni=$sni"

        # Validate required fields
        if [[ -z "$server" ]] || [[ -z "$password" ]]; then
            detail="Failed to parse Trojan URI (missing required fields). Run with -v for details."
            log_error "$detail"
            log_error "server='$server' password='${password:0:8}...'"
            RESULTS[trojan]="fail"
            DETAILS[trojan]="$detail"
            return
        fi

        cat > "$client_config" << EOF
{
  "log": {"level": "error"},
  "inbounds": [
    {"type": "socks", "listen": "127.0.0.1", "listen_port": 10801}
  ],
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
  "route": {
    "final": "proxy"
  }
}
EOF
    else
        jq '. + {
          "log": {"level": "error"},
          "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": 10801}],
          "route": {"final": "proxy"}
        }' "$config_file" > "$client_config" 2>/dev/null || {
            detail="Failed to parse JSON config"
            log_error "$detail"
            RESULTS[trojan]="fail"
            DETAILS[trojan]="$detail"
            return
        }
    fi

    # Validate JSON before running
    if ! jq empty "$client_config" 2>/dev/null; then
        detail="Generated invalid JSON config"
        log_error "$detail"
        RESULTS[trojan]="fail"
        DETAILS[trojan]="$detail"
        return
    fi

    # Start sing-box and capture errors
    local error_log="$TEMP_DIR/trojan-error.log"
    sing-box run -c "$client_config" 2>"$error_log" &
    local pid=$!
    sleep 3

    if ! kill -0 $pid 2>/dev/null; then
        detail="sing-box failed to start"
        if [[ -s "$error_log" ]]; then
            local error_msg=$(tail -5 "$error_log" 2>/dev/null | tr '\n' ' ' || true)
            detail="sing-box error: $error_msg"
        fi
        log_error "$detail"
        log_debug "Generated config was: $(cat "$client_config" 2>/dev/null | tr '\n' ' ')"
        RESULTS[trojan]="fail"
        DETAILS[trojan]="$detail"
        return
    fi

    log_debug "sing-box started successfully (PID: $pid)"
    log_debug "Testing connectivity via SOCKS5 on port 10801..."

    if curl -sf --socks5 127.0.0.1:10801 --max-time "$TEST_TIMEOUT" "$TEST_URL" >/dev/null 2>&1; then
        # Verify we can access the internet and get exit IP
        local exit_ip=""
        exit_ip=$(curl -sf --socks5 127.0.0.1:10801 --max-time "$TEST_TIMEOUT" https://api.ipify.org 2>/dev/null || \
                  curl -sf --socks5 127.0.0.1:10801 --max-time "$TEST_TIMEOUT" https://ifconfig.me 2>/dev/null || true)
        if [[ -n "$exit_ip" ]]; then
            log_success "Trojan connection successful (exit IP: $exit_ip)"
            RESULTS[trojan]="pass"
            DETAILS[trojan]="Connected via Trojan, exit IP: $exit_ip"
        else
            log_success "Trojan connection successful"
            RESULTS[trojan]="pass"
            DETAILS[trojan]="Connected via Trojan"
        fi
    else
        detail="Connection test failed"
        # Check for sing-box errors during operation
        if [[ -s "$error_log" ]]; then
            local error_msg=$(grep -i "error\|fail\|unreachable\|timeout\|refused" "$error_log" 2>/dev/null | tail -3 | tr '\n' ' ' || true)
            [[ -n "$error_msg" ]] && detail="$error_msg"
        fi
        log_debug "Full error log: $(cat "$error_log" 2>/dev/null | tail -10 | tr '\n' ' ')"
        log_debug "Server: $server:$port, SNI: $sni"
        # If IPv6 config and network unreachable, warn instead of fail
        if [[ "$is_ipv6" == "true" ]] && echo "$detail" | grep -qi "unreachable\|network"; then
            log_warn "IPv6 config - $detail"
            RESULTS[trojan]="warn"
            DETAILS[trojan]="IPv6 network may not be available: $detail"
        else
            log_error "$detail"
            RESULTS[trojan]="fail"
            DETAILS[trojan]="$detail"
        fi
    fi

    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
}

# Test Hysteria2 protocol
test_hysteria2() {
    log_info "Testing Hysteria2..."

    local config_file=""
    local detail=""
    local is_ipv6=false

    # Find Hysteria2 config - prefer IPv4 over IPv6
    for f in "$CONFIG_DIR"/hysteria2.txt "$CONFIG_DIR"/hysteria2.yaml "$CONFIG_DIR"/hysteria2.yml; do
        [[ -f "$f" ]] && config_file="$f" && break
    done
    if [[ -z "$config_file" ]]; then
        for f in "$CONFIG_DIR"/hysteria2*.txt "$CONFIG_DIR"/hysteria2*.yaml "$CONFIG_DIR"/hysteria2*.yml; do
            [[ -f "$f" ]] && config_file="$f" && break
        done
    fi
    [[ "$config_file" == *ipv6* ]] && is_ipv6=true

    if [[ -z "$config_file" ]]; then
        detail="No Hysteria2 config found in bundle"
        log_warn "$detail"
        log_debug "Searched in: $CONFIG_DIR for hysteria2*.txt, hysteria2*.yaml"
        RESULTS[hysteria2]="skip"
        DETAILS[hysteria2]="$detail"
        return
    fi

    log_debug "Using config: $config_file"
    log_debug "Config content: $(cat "$config_file" | head -3 | tr '\n' ' ')"

    local client_config="$TEMP_DIR/hysteria2-client.json"
    local server="" auth="" sni="" host="" port="" obfs_type="" obfs_password=""

    if [[ "$config_file" == *.txt ]]; then
        local uri=$(cat "$config_file" | tr -d '\n\r')
        auth=$(extract_auth "$uri" "hysteria2")
        # For hysteria2, server might include port
        server=$(echo "$uri" | sed -n 's|.*@\([^?#]*\).*|\1|p' | head -1)
        sni=$(extract_param "$uri" "sni")
        obfs_type=$(extract_param "$uri" "obfs")
        obfs_password=$(extract_param "$uri" "obfs-password")
    elif [[ "$config_file" == *.yaml ]] || [[ "$config_file" == *.yml ]]; then
        server=$(grep -E "^server:" "$config_file" | sed 's/server:[[:space:]]*//' | tr -d '"' | head -1)
        auth=$(grep -E "^auth:" "$config_file" | sed 's/auth:[[:space:]]*//' | tr -d '"' | head -1)
        sni=$(grep -E "^[[:space:]]*sni:" "$config_file" | sed 's/.*sni:[[:space:]]*//' | tr -d '"' | head -1)
        obfs_type=$(grep -E "^[[:space:]]*type:" "$config_file" | head -1 | sed 's/.*type:[[:space:]]*//' | tr -d '"' || true)
        obfs_password=$(grep -E "^[[:space:]]*password:" "$config_file" | head -2 | tail -1 | sed 's/.*password:[[:space:]]*//' | tr -d '"' || true)
    fi

    # Parse host:port - handle both IPv4 and IPv6
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

    # For sni, use host without brackets
    [[ -z "$sni" ]] && sni="$host"

    log_debug "Parsed: host=$host port=$port auth=$auth sni=$sni"

    if [[ -z "$host" ]] || [[ -z "$auth" ]]; then
        detail="Could not parse Hysteria2 config. Run with -v for details."
        log_error "$detail"
        RESULTS[hysteria2]="fail"
        DETAILS[hysteria2]="$detail"
        return
    fi

    # Build obfs config if present
    local obfs_config=""
    if [[ -n "$obfs_type" ]] && [[ -n "$obfs_password" ]]; then
        obfs_config=",
      \"obfs\": {
        \"type\": \"$obfs_type\",
        \"password\": \"$obfs_password\"
      }"
        log_debug "Using obfuscation: type=$obfs_type"
    fi

    cat > "$client_config" << EOF
{
  "log": {"level": "error"},
  "inbounds": [
    {"type": "socks", "listen": "127.0.0.1", "listen_port": 10802}
  ],
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
  "route": {
    "final": "proxy"
  }
}
EOF

    log_debug "Generated config: $(cat "$client_config")"

    # Validate JSON before running
    if ! jq empty "$client_config" 2>/dev/null; then
        detail="Generated invalid JSON config"
        log_error "$detail"
        RESULTS[hysteria2]="fail"
        DETAILS[hysteria2]="$detail"
        return
    fi

    # Start sing-box and capture errors
    local error_log="$TEMP_DIR/hysteria2-error.log"
    sing-box run -c "$client_config" 2>"$error_log" &
    local pid=$!
    sleep 3

    if ! kill -0 $pid 2>/dev/null; then
        detail="sing-box failed to start"
        if [[ -s "$error_log" ]]; then
            local error_msg=$(tail -5 "$error_log" 2>/dev/null | tr '\n' ' ' || true)
            detail="sing-box error: $error_msg"
        fi
        log_error "$detail"
        log_debug "Generated config was: $(cat "$client_config" 2>/dev/null | tr '\n' ' ')"
        RESULTS[hysteria2]="fail"
        DETAILS[hysteria2]="$detail"
        return
    fi

    log_debug "sing-box started successfully (PID: $pid)"
    log_debug "Testing connectivity via SOCKS5 on port 10802..."

    if curl -sf --socks5 127.0.0.1:10802 --max-time "$TEST_TIMEOUT" "$TEST_URL" >/dev/null 2>&1; then
        # Verify we can access the internet and get exit IP
        local exit_ip=""
        exit_ip=$(curl -sf --socks5 127.0.0.1:10802 --max-time "$TEST_TIMEOUT" https://api.ipify.org 2>/dev/null || \
                  curl -sf --socks5 127.0.0.1:10802 --max-time "$TEST_TIMEOUT" https://ifconfig.me 2>/dev/null || true)
        if [[ -n "$exit_ip" ]]; then
            log_success "Hysteria2 connection successful (exit IP: $exit_ip)"
            RESULTS[hysteria2]="pass"
            DETAILS[hysteria2]="Connected via Hysteria2, exit IP: $exit_ip"
        else
            log_success "Hysteria2 connection successful"
            RESULTS[hysteria2]="pass"
            DETAILS[hysteria2]="Connected via Hysteria2"
        fi
    else
        detail="Connection test failed"
        # Check for sing-box errors during operation
        if [[ -s "$error_log" ]]; then
            local error_msg=$(grep -i "error\|fail\|unreachable\|timeout\|refused" "$error_log" 2>/dev/null | tail -3 | tr '\n' ' ' || true)
            [[ -n "$error_msg" ]] && detail="$error_msg"
        fi
        log_debug "Full error log: $(cat "$error_log" 2>/dev/null | tail -10 | tr '\n' ' ')"
        log_debug "Server: $host:$port, SNI: $sni"
        # If IPv6 config and network unreachable, warn instead of fail
        if [[ "$is_ipv6" == "true" ]] && echo "$detail" | grep -qi "unreachable\|network"; then
            log_warn "IPv6 config - $detail"
            RESULTS[hysteria2]="warn"
            DETAILS[hysteria2]="IPv6 network may not be available: $detail"
        else
            log_error "$detail"
            RESULTS[hysteria2]="fail"
            DETAILS[hysteria2]="$detail"
        fi
    fi

    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
}

# Test WireGuard (config validation + endpoint reachability)
test_wireguard() {
    log_info "Testing WireGuard (config validation)..."

    local config_file=""
    local detail=""
    local is_ipv6=false

    # Find WireGuard config - prefer IPv4 over IPv6
    for f in "$CONFIG_DIR"/wireguard.conf "$CONFIG_DIR"/wg.conf; do
        [[ -f "$f" ]] && config_file="$f" && break
    done
    if [[ -z "$config_file" ]]; then
        for f in "$CONFIG_DIR"/wireguard*.conf "$CONFIG_DIR"/wg*.conf; do
            [[ -f "$f" ]] && config_file="$f" && break
        done
    fi
    [[ "$config_file" == *ipv6* ]] && is_ipv6=true

    if [[ -z "$config_file" ]]; then
        detail="No WireGuard config found in bundle"
        log_warn "$detail"
        RESULTS[wireguard]="skip"
        DETAILS[wireguard]="$detail"
        return
    fi

    log_debug "Using config: $config_file"

    # Validate config structure
    if ! grep -q "\[Interface\]" "$config_file" || ! grep -q "\[Peer\]" "$config_file"; then
        detail="Invalid WireGuard config format"
        log_error "$detail"
        RESULTS[wireguard]="fail"
        DETAILS[wireguard]="$detail"
        return
    fi

    # Extract values using portable grep/sed (case-insensitive, match first = only)
    local private_key=$(grep -i "PrivateKey" "$config_file" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \t\r')
    local endpoint=$(grep -i "Endpoint" "$config_file" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \t\r')
    local peer_public_key=$(grep -i "PublicKey" "$config_file" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \t\r')
    local address=$(grep -i "Address" "$config_file" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \t\r' | cut -d',' -f1)

    log_debug "Extracted: private_key=${private_key:0:10}... endpoint=$endpoint pubkey=${peer_public_key:0:10}... address=$address"

    if [[ -z "$private_key" ]] || [[ -z "$endpoint" ]] || [[ -z "$peer_public_key" ]]; then
        detail="Missing required fields in WireGuard config"
        log_error "$detail"
        RESULTS[wireguard]="fail"
        DETAILS[wireguard]="$detail"
        return
    fi

    # Validate key formats (base64, 44 chars with padding)
    if [[ ${#private_key} -lt 40 ]] || [[ ${#peer_public_key} -lt 40 ]]; then
        detail="Invalid key format in WireGuard config"
        log_error "$detail"
        RESULTS[wireguard]="fail"
        DETAILS[wireguard]="$detail"
        return
    fi

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

    log_debug "Parsed: server=$server port=$port"

    # Test endpoint reachability (UDP is hard to test, try TCP or just DNS resolve)
    # For IPv6, ping6 or ping -6 might be needed
    local ping_result=false
    if echo "$server" | grep -q ':'; then
        # IPv6 address
        ping -6 -c 1 -W 2 "$server" >/dev/null 2>&1 && ping_result=true
    else
        # IPv4 or hostname
        host "$server" >/dev/null 2>&1 && ping_result=true
        ping -c 1 -W 2 "$server" >/dev/null 2>&1 && ping_result=true
    fi

    if [[ "$ping_result" == "true" ]]; then
        log_success "WireGuard config valid, endpoint reachable: $endpoint"
        RESULTS[wireguard]="pass"
        DETAILS[wireguard]="Config valid, endpoint $server reachable"
    else
        # Can't reach server, but config is valid
        log_warn "WireGuard config valid, but endpoint not reachable: $endpoint"
        RESULTS[wireguard]="warn"
        # For IPv6, note that it might be a network issue
        if [[ "$is_ipv6" == "true" ]] || echo "$server" | grep -q ':'; then
            DETAILS[wireguard]="Config valid, IPv6 endpoint not reachable (IPv6 may not be available)"
        else
            DETAILS[wireguard]="Config valid, endpoint $server not reachable (may be blocked)"
        fi
    fi
}

# Test AmneziaWG (AmneziaWireGuard - obfuscated WireGuard)
# Note: AmneziaWG uses TUN interface (full VPN), not SOCKS proxy
test_amneziawg() {
    log_info "Testing AmneziaWG (config validation)..."

    local config_file=""
    local detail=""

    # Find AmneziaWG config
    for f in "$CONFIG_DIR"/amneziawg.conf; do
        [[ -f "$f" ]] && config_file="$f" && break
    done
    if [[ -z "$config_file" ]]; then
        for f in "$CONFIG_DIR"/amneziawg*.conf; do
            [[ -f "$f" ]] && config_file="$f" && break
        done
    fi

    if [[ -z "$config_file" ]]; then
        detail="No AmneziaWG config found in bundle"
        log_warn "$detail"
        RESULTS[amneziawg]="skip"
        DETAILS[amneziawg]="$detail"
        return
    fi

    log_debug "Using config: $config_file"

    # Validate config structure (similar to WireGuard format)
    if ! grep -q "\[Interface\]" "$config_file" || ! grep -q "\[Peer\]" "$config_file"; then
        detail="Invalid AmneziaWG config format"
        log_error "$detail"
        RESULTS[amneziawg]="fail"
        DETAILS[amneziawg]="$detail"
        return
    fi

    # Extract endpoint info for reachability test
    local endpoint=$(grep -i "Endpoint" "$config_file" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \t\r')

    if [[ -z "$endpoint" ]]; then
        detail="No Endpoint found in AmneziaWG config"
        log_error "$detail"
        RESULTS[amneziawg]="fail"
        DETAILS[amneziawg]="$detail"
        return
    fi

    # Parse endpoint - handle both IPv4 and IPv6
    local server_ip="" port=""
    if echo "$endpoint" | grep -q '^\['; then
        # IPv6: [addr]:port format
        server_ip=$(echo "$endpoint" | sed 's/^\[\([^]]*\)\].*/\1/')
        port=$(echo "$endpoint" | sed -n 's/.*\]:\([0-9]*\).*/\1/p')
    else
        # IPv4: host:port format
        server_ip="${endpoint%:*}"
        port="${endpoint##*:}"
    fi

    [[ -z "$port" ]] && port="51820"
    log_debug "Parsed: server_ip=$server_ip port=$port"

    # Check if awg-quick or awg binary exists
    local can_full_test=true
    if ! command -v awg-quick >/dev/null 2>&1 && ! command -v awg >/dev/null 2>&1; then
        log_debug "awg-quick / awg not available"
        can_full_test=false
    elif [[ ! -c /dev/net/tun ]]; then
        log_debug "TUN device not available (/dev/net/tun not found or not a character device)"
        can_full_test=false
    fi

    if [[ "$can_full_test" != "true" ]]; then
        log_debug "Full VPN test not possible, testing endpoint reachability..."

        # AmneziaWG uses UDP, test reachability via nc or ping
        local reachable=false
        if nc -z -w 3 -u "$server_ip" "$port" 2>/dev/null; then
            reachable=true
        else
            # Fall back to ping to check basic host reachability
            if echo "$server_ip" | grep -q ':'; then
                ping -6 -c 1 -W 2 "$server_ip" >/dev/null 2>&1 && reachable=true
            else
                host "$server_ip" >/dev/null 2>&1 && reachable=true
                ping -c 1 -W 2 "$server_ip" >/dev/null 2>&1 && reachable=true
            fi
        fi

        if [[ "$reachable" == "true" ]]; then
            log_success "AmneziaWG config valid, endpoint reachable: $endpoint"
            RESULTS[amneziawg]="pass"
            DETAILS[amneziawg]="Config valid, endpoint ${server_ip}:${port} reachable (awg-quick not available for full VPN test)"
        else
            log_warn "AmneziaWG config valid, but endpoint not reachable: $endpoint"
            RESULTS[amneziawg]="warn"
            DETAILS[amneziawg]="Config valid, endpoint ${server_ip}:${port} not reachable (may be blocked)"
        fi
        return
    fi

    # Full test with awg-quick
    log_debug "Starting AmneziaWG tunnel with awg-quick..."
    local error_log="$TEMP_DIR/amneziawg-error.log"
    local test_config="$TEMP_DIR/amneziawg-test.conf"
    cp "$config_file" "$test_config"

    awg-quick up "$test_config" 2>"$error_log"
    local awg_exit=$?

    if [[ $awg_exit -ne 0 ]]; then
        detail="awg-quick failed to bring up interface"
        if [[ -s "$error_log" ]]; then
            local error_msg=$(tail -5 "$error_log" 2>/dev/null | tr '\n' ' ' || true)
            detail="AmneziaWG error: $error_msg"
        fi
        log_error "$detail"
        RESULTS[amneziawg]="fail"
        DETAILS[amneziawg]="$detail"
        rm -f "$test_config"
        return
    fi

    log_debug "AmneziaWG interface up, testing connectivity..."

    # Test connectivity directly (traffic goes through TUN interface)
    if curl -sf --max-time "$TEST_TIMEOUT" "$TEST_URL" >/dev/null 2>&1; then
        local exit_ip=""
        exit_ip=$(curl -sf --max-time "$TEST_TIMEOUT" https://api.ipify.org 2>/dev/null || \
                  curl -sf --max-time "$TEST_TIMEOUT" https://ifconfig.me 2>/dev/null || true)
        if [[ -n "$exit_ip" ]]; then
            log_success "AmneziaWG VPN connection successful (exit IP: $exit_ip)"
            RESULTS[amneziawg]="pass"
            DETAILS[amneziawg]="Connected via AmneziaWG VPN, exit IP: $exit_ip"
        else
            log_success "AmneziaWG VPN connection successful"
            RESULTS[amneziawg]="pass"
            DETAILS[amneziawg]="Connected via AmneziaWG VPN"
        fi
    else
        detail="VPN connection test failed"
        if [[ -s "$error_log" ]]; then
            local error_msg=$(grep -i "error\|fail\|unreachable\|timeout\|refused" "$error_log" 2>/dev/null | tail -3 | tr '\n' ' ' || true)
            [[ -n "$error_msg" ]] && detail="$error_msg"
        fi
        log_error "$detail"
        RESULTS[amneziawg]="fail"
        DETAILS[amneziawg]="$detail"
    fi

    awg-quick down "$test_config" 2>/dev/null || true
    rm -f "$test_config"
}

# Test dnstt (DNS tunnel)
test_dnstt() {
    log_info "Testing dnstt (DNS tunnel)..."

    local config_file=""
    local detail=""

    # Find dnstt config file - handle glob expansion safely
    # shellcheck disable=SC2044
    for f in "$CONFIG_DIR"/dnstt*.txt "$CONFIG_DIR"/*dnstt* "$CONFIG_DIR"/dnstt-instructions.txt; do
        if [[ -f "$f" ]]; then
            config_file="$f"
            break
        fi
    done

    if [[ -z "$config_file" ]]; then
        detail="No dnstt config found in bundle"
        log_warn "$detail"
        RESULTS[dnstt]="skip"
        DETAILS[dnstt]="$detail"
        return
    fi

    log_debug "Using config: $config_file"

    # Extract domain - look for t.domain.com pattern
    # Note: grep returns non-zero if no match, so we use || true to avoid pipefail exit
    local domain=$(grep -oE 't\.[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "$config_file" 2>/dev/null | head -1 || true)

    # Extract pubkey - look for hex string (64 chars) in the config
    local pubkey=""

    # First try to find hex pubkey in the instructions file
    pubkey=$(grep -oE '[0-9a-fA-F]{64}' "$config_file" 2>/dev/null | head -1 || true)

    # Check for server.pub file in bundle (hex format)
    if [[ -z "$pubkey" ]] && [[ -f "$CONFIG_DIR/server.pub" ]]; then
        pubkey=$(cat "$CONFIG_DIR/server.pub" | tr -d '\n\r ')
        log_debug "Found pubkey in bundle: server.pub"
    fi

    # Check for server.pub in default dnstt outputs location
    if [[ -z "$pubkey" ]] && [[ -f "/outputs/dnstt/server.pub" ]]; then
        pubkey=$(cat "/outputs/dnstt/server.pub" | tr -d '\n\r ')
        log_debug "Found pubkey in /outputs/dnstt/server.pub"
    fi

    # Check configs directory
    if [[ -z "$pubkey" ]] && [[ -f "/configs/dnstt/server.pub" ]]; then
        pubkey=$(cat "/configs/dnstt/server.pub" | tr -d '\n\r ')
        log_debug "Found pubkey in /configs/dnstt/server.pub"
    fi

    if [[ -z "$domain" ]]; then
        detail="Could not extract tunnel domain from config"
        log_error "$detail"
        RESULTS[dnstt]="fail"
        DETAILS[dnstt]="$detail"
        return
    fi

    log_debug "Parsed: domain=$domain pubkey=${pubkey:0:20}..."

    if [[ -z "$pubkey" ]]; then
        detail="Could not extract public key (check outputs/dnstt/server.pub)"
        log_warn "$detail"
        RESULTS[dnstt]="warn"
        DETAILS[dnstt]="Domain: $domain, but missing pubkey for full test"
        return
    fi

    # Check if dnstt-client is available
    if ! command -v dnstt-client >/dev/null 2>&1; then
        RESULTS[dnstt]="warn"
        DETAILS[dnstt]="dnstt-client not available, config looks valid for $domain"
        return
    fi

    log_debug "Starting dnstt-client tunnel..."
    local error_log="$TEMP_DIR/dnstt-error.log"

    # Start dnstt-client with DoH resolver
    # dnstt-client creates a raw TCP tunnel, not SOCKS
    # We connect to it and the server forwards to sing-box SOCKS proxy
    dnstt-client -doh https://1.1.1.1/dns-query -pubkey "$pubkey" "$domain" 127.0.0.1:10803 2>"$error_log" &
    local pid=$!

    # Give it time to establish the tunnel
    sleep 5

    if ! kill -0 $pid 2>/dev/null; then
        detail="dnstt-client failed to start"
        if [[ -s "$error_log" ]]; then
            local error_msg
            error_msg=$(tail -3 "$error_log" 2>/dev/null | tr '\n' ' ' || true)
            [[ -n "$error_msg" ]] && detail="dnstt error: $error_msg"
        fi
        log_error "$detail"
        RESULTS[dnstt]="fail"
        DETAILS[dnstt]="$detail"
        return
    fi

    log_debug "dnstt-client running (PID $pid), testing connectivity..."

    # dnstt tunnels raw TCP to the server's upstream (sing-box SOCKS proxy)
    # So we can use the local dnstt port as a SOCKS5 proxy
    local test_success=false

    # Test 1: Basic connectivity through the tunnel
    if curl -sf --socks5 127.0.0.1:10803 --max-time "$TEST_TIMEOUT" "$TEST_URL" >/dev/null 2>&1; then
        log_debug "Basic connectivity test passed"
        test_success=true
    else
        log_debug "Basic connectivity test failed, trying extended timeout..."
        # DNS tunneling is slow, try with longer timeout
        if curl -sf --socks5 127.0.0.1:10803 --max-time 30 "$TEST_URL" >/dev/null 2>&1; then
            log_debug "Extended timeout test passed"
            test_success=true
        fi
    fi

    if [[ "$test_success" == "true" ]]; then
        # Test 2: Verify public IP (optional but recommended)
        local tunnel_ip=""
        tunnel_ip=$(curl -sf --socks5 127.0.0.1:10803 --max-time 30 https://api.ipify.org 2>/dev/null || true)
        [[ -z "$tunnel_ip" ]] && tunnel_ip=$(curl -sf --socks5 127.0.0.1:10803 --max-time 30 https://ifconfig.me 2>/dev/null || true)

        if [[ -n "$tunnel_ip" ]]; then
            log_success "dnstt tunnel working, exit IP: $tunnel_ip"
            RESULTS[dnstt]="pass"
            DETAILS[dnstt]="DNS tunnel to $domain working (exit IP: $tunnel_ip)"
        else
            log_success "dnstt tunnel established to $domain"
            RESULTS[dnstt]="pass"
            DETAILS[dnstt]="DNS tunnel to $domain working"
        fi
    else
        detail="Tunnel established but connectivity test failed (DNS tunneling is slow)"
        if [[ -s "$error_log" ]]; then
            local error_msg
            error_msg=$(tail -3 "$error_log" 2>/dev/null | tr '\n' ' ' || true)
            [[ -n "$error_msg" ]] && detail="$detail - $error_msg"
        fi
        log_warn "$detail"
        RESULTS[dnstt]="warn"
        DETAILS[dnstt]="$detail"
    fi

    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
}

# Test Slipstream (QUIC-over-DNS tunnel)
test_slipstream() {
    log_info "Testing Slipstream (DNS tunnel)..."

    local config_file=""
    local detail=""

    # Find slipstream instructions file
    for f in "$CONFIG_DIR"/slipstream*.txt "$CONFIG_DIR"/*slipstream*; do
        if [[ -f "$f" ]]; then
            config_file="$f"
            break
        fi
    done

    if [[ -z "$config_file" ]]; then
        detail="No Slipstream config found in bundle"
        log_warn "$detail"
        RESULTS[slipstream]="skip"
        DETAILS[slipstream]="$detail"
        return
    fi

    log_debug "Using config: $config_file"

    # Extract domain (e.g., s.example.com)
    local domain=$(grep -oE 's\.[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "$config_file" 2>/dev/null | head -1 || true)

    if [[ -z "$domain" ]]; then
        detail="Could not extract Slipstream tunnel domain from config"
        log_error "$detail"
        RESULTS[slipstream]="fail"
        DETAILS[slipstream]="$detail"
        return
    fi

    # Find cert file
    local cert_file=""
    for f in "$CONFIG_DIR"/slipstream-cert.pem "/slipstream/cert.pem"; do
        [[ -f "$f" ]] && cert_file="$f" && break
    done

    if [[ -z "$cert_file" ]]; then
        detail="Slipstream certificate not found"
        log_warn "$detail"
        RESULTS[slipstream]="warn"
        DETAILS[slipstream]="Domain: $domain, but missing cert for full test"
        return
    fi

    # Check if slipstream-client is available
    if ! command -v slipstream-client >/dev/null 2>&1; then
        RESULTS[slipstream]="warn"
        DETAILS[slipstream]="slipstream-client not available, config looks valid for $domain"
        return
    fi

    log_debug "Starting slipstream-client tunnel..."
    local error_log="$TEMP_DIR/slipstream-error.log"

    # Start slipstream-client in resolver mode
    # slipstream-client is a TCP tunnel: local TCP port → DNS tunnel → server's sing-box:1080 (SOCKS5)
    slipstream-client --domain "$domain" --cert "$cert_file" --resolver 1.1.1.1:53 --tcp-listen-host 127.0.0.1 --tcp-listen-port 10804 2>"$error_log" &
    local pid=$!

    # Give it time to establish the tunnel
    sleep 5

    if ! kill -0 $pid 2>/dev/null; then
        detail="slipstream-client failed to start"
        if [[ -s "$error_log" ]]; then
            local error_msg
            error_msg=$(tail -3 "$error_log" 2>/dev/null | tr '\n' ' ' || true)
            [[ -n "$error_msg" ]] && detail="slipstream error: $error_msg"
        fi
        log_error "$detail"
        RESULTS[slipstream]="fail"
        DETAILS[slipstream]="$detail"
        return
    fi

    log_debug "slipstream-client running (PID $pid), testing connectivity..."

    local test_success=false

    # Test connectivity through the tunnel
    if curl -sf --socks5 127.0.0.1:10804 --max-time "$TEST_TIMEOUT" "$TEST_URL" >/dev/null 2>&1; then
        log_debug "Basic connectivity test passed"
        test_success=true
    else
        log_debug "Basic connectivity test failed, trying extended timeout..."
        if curl -sf --socks5 127.0.0.1:10804 --max-time 30 "$TEST_URL" >/dev/null 2>&1; then
            log_debug "Extended timeout test passed"
            test_success=true
        fi
    fi

    if [[ "$test_success" == "true" ]]; then
        local tunnel_ip=""
        tunnel_ip=$(curl -sf --socks5 127.0.0.1:10804 --max-time 30 https://api.ipify.org 2>/dev/null || true)
        [[ -z "$tunnel_ip" ]] && tunnel_ip=$(curl -sf --socks5 127.0.0.1:10804 --max-time 30 https://ifconfig.me 2>/dev/null || true)

        if [[ -n "$tunnel_ip" ]]; then
            log_success "Slipstream tunnel working, exit IP: $tunnel_ip"
            RESULTS[slipstream]="pass"
            DETAILS[slipstream]="DNS tunnel to $domain working (exit IP: $tunnel_ip)"
        else
            log_success "Slipstream tunnel established to $domain"
            RESULTS[slipstream]="pass"
            DETAILS[slipstream]="DNS tunnel to $domain working"
        fi
    else
        detail="Tunnel established but connectivity test failed (DNS tunneling is slow)"
        if [[ -s "$error_log" ]]; then
            local error_msg
            error_msg=$(tail -3 "$error_log" 2>/dev/null | tr '\n' ' ' || true)
            [[ -n "$error_msg" ]] && detail="$detail - $error_msg"
        fi
        log_warn "$detail"
        RESULTS[slipstream]="warn"
        DETAILS[slipstream]="$detail"
    fi

    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
}

# Test TrustTunnel
# Note: TrustTunnel CLI uses TUN interface (full VPN), not SOCKS proxy
test_trusttunnel() {
    log_info "Testing TrustTunnel..."

    local config_file=""
    local detail=""

    # Find TrustTunnel config - prefer TOML for full test
    for f in "$CONFIG_DIR"/trusttunnel.toml "$CONFIG_DIR"/trusttunnel.json "$CONFIG_DIR"/trusttunnel.txt; do
        [[ -f "$f" ]] && config_file="$f" && break
    done

    if [[ -z "$config_file" ]]; then
        detail="No TrustTunnel config found in bundle"
        log_warn "$detail"
        RESULTS[trusttunnel]="skip"
        DETAILS[trusttunnel]="$detail"
        return
    fi

    log_debug "Using config: $config_file"

    # Parse config to get endpoint info for reachability test
    local endpoint="" username="" password="" server_ip="" host="" port=""

    if [[ "$config_file" == *.toml ]]; then
        # Parse TOML config
        host=$(grep -E '^hostname\s*=' "$config_file" | head -1 | sed 's/.*=\s*"\([^"]*\)".*/\1/' || true)
        server_ip=$(grep -E '^addresses\s*=' "$config_file" | head -1 | sed 's/.*\["\([^"]*\)".*/\1/' | cut -d: -f1 || true)
        port=$(grep -E '^addresses\s*=' "$config_file" | head -1 | sed 's/.*:\([0-9]*\)".*/\1/' || true)
        username=$(grep -E '^username\s*=' "$config_file" | head -1 | sed 's/.*=\s*"\([^"]*\)".*/\1/' || true)
        password=$(grep -E '^password\s*=' "$config_file" | head -1 | sed 's/.*=\s*"\([^"]*\)".*/\1/' || true)
        endpoint="${host}:${port:-4443}"
    elif [[ "$config_file" == *.json ]]; then
        # Support both old and new field names
        endpoint=$(jq -r '.ip_address // .endpoint // empty' "$config_file" 2>/dev/null || true)
        server_ip=$(jq -r '.domain // .server_ip // empty' "$config_file" 2>/dev/null || true)
        username=$(jq -r '.username // empty' "$config_file" 2>/dev/null || true)
        password=$(jq -r '.password // empty' "$config_file" 2>/dev/null || true)
        host="${endpoint%:*}"
        port="${endpoint##*:}"
    else
        # Support both old and new field names in txt files
        endpoint=$(grep -iE "^(IP Address|Endpoint):" "$config_file" | sed 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' | head -1 || true)
        server_ip=$(grep -iE "^(Domain|Server IP):" "$config_file" | sed 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' | head -1 || true)
        username=$(grep -i "^Username:" "$config_file" | sed 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' | head -1 || true)
        password=$(grep -i "^Password:" "$config_file" | sed 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' | head -1 || true)
        host="${endpoint%:*}"
        port="${endpoint##*:}"
    fi

    [[ -z "$port" ]] && port="4443"
    [[ -z "$host" ]] && host="$server_ip"
    [[ -z "$server_ip" ]] && server_ip="$host"

    log_debug "Parsed: host=$host port=$port username=$username"

    if [[ -z "$host" ]] || [[ -z "$username" ]] || [[ -z "$password" ]]; then
        detail="Could not parse TrustTunnel config (missing endpoint/username/password)"
        log_error "$detail"
        RESULTS[trusttunnel]="fail"
        DETAILS[trusttunnel]="$detail"
        return
    fi

    # Check if trusttunnel_client is available and TUN device is accessible
    local can_full_test=true
    if ! command -v trusttunnel_client >/dev/null 2>&1; then
        log_debug "trusttunnel_client not available"
        can_full_test=false
    elif [[ ! -c /dev/net/tun ]]; then
        log_debug "TUN device not available (/dev/net/tun not found or not a character device)"
        can_full_test=false
    fi

    if [[ "$can_full_test" != "true" ]]; then
        log_debug "Full VPN test not possible, testing endpoint reachability..."

        # Test endpoint reachability via TCP
        if nc -z -w 3 "$server_ip" "$port" 2>/dev/null || curl -sf --max-time 3 "https://${host}:${port}" -o /dev/null 2>/dev/null; then
            log_success "TrustTunnel config valid, endpoint reachable: ${host}:${port}"
            RESULTS[trusttunnel]="pass"
            DETAILS[trusttunnel]="Config valid, endpoint ${server_ip}:${port} reachable (TUN not available for full VPN test)"
        else
            log_warn "TrustTunnel config valid, endpoint may not be reachable: ${host}:${port}"
            RESULTS[trusttunnel]="warn"
            DETAILS[trusttunnel]="Config valid, endpoint ${server_ip}:${port} not reachable (may be blocked)"
        fi
        return
    fi

    # Full test with trusttunnel_client
    local error_log="$TEMP_DIR/trusttunnel-error.log"
    local test_config="$TEMP_DIR/trusttunnel-test.toml"

    # Use TOML config if available, otherwise generate one
    if [[ "$config_file" == *.toml ]]; then
        cp "$config_file" "$test_config"
    else
        # Generate temporary TOML config for testing
        cat > "$test_config" <<EOF
loglevel = "info"
vpn_mode = "general"
killswitch_enabled = false
post_quantum_group_enabled = true

[endpoint]
hostname = "$host"
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
    fi

    log_debug "Starting trusttunnel_client with config..."
    # TrustTunnel client creates TUN interface (full VPN)
    trusttunnel_client --config "$test_config" >"$error_log" 2>&1 &
    local pid=$!
    sleep 8

    if ! kill -0 $pid 2>/dev/null; then
        # Check if it's a TUN/listener creation failure
        if grep -qi "Failed to create listener\|tun\|permission" "$error_log" 2>/dev/null; then
            log_debug "TUN interface creation failed, falling back to endpoint reachability test..."
            rm -f "$test_config"

            # Fall back to endpoint reachability test
            if nc -z -w 3 "$server_ip" "$port" 2>/dev/null || curl -sf --max-time 3 "https://${host}:${port}" -o /dev/null 2>/dev/null; then
                log_success "TrustTunnel config valid, endpoint reachable: ${host}:${port}"
                RESULTS[trusttunnel]="pass"
                DETAILS[trusttunnel]="Config valid, endpoint ${server_ip}:${port} reachable (TUN unavailable for full VPN test)"
            else
                log_warn "TrustTunnel config valid, endpoint may not be reachable: ${host}:${port}"
                RESULTS[trusttunnel]="warn"
                DETAILS[trusttunnel]="Config valid, endpoint ${server_ip}:${port} not reachable (may be blocked)"
            fi
            return
        fi

        detail="trusttunnel_client failed to start"
        if [[ -s "$error_log" ]]; then
            local error_msg=$(tail -5 "$error_log" 2>/dev/null | tr '\n' ' ' || true)
            detail="TrustTunnel error: $error_msg"
        fi
        log_error "$detail"
        RESULTS[trusttunnel]="fail"
        DETAILS[trusttunnel]="$detail"
        rm -f "$test_config"
        return
    fi

    log_debug "trusttunnel_client running (PID $pid), testing connectivity..."

    # Test connectivity directly (traffic goes through TUN interface)
    if curl -sf --max-time "$TEST_TIMEOUT" "$TEST_URL" >/dev/null 2>&1; then
        local exit_ip=""
        exit_ip=$(curl -sf --max-time "$TEST_TIMEOUT" https://api.ipify.org 2>/dev/null || \
                  curl -sf --max-time "$TEST_TIMEOUT" https://ifconfig.me 2>/dev/null || true)
        if [[ -n "$exit_ip" ]]; then
            log_success "TrustTunnel VPN connection successful (exit IP: $exit_ip)"
            RESULTS[trusttunnel]="pass"
            DETAILS[trusttunnel]="Connected via TrustTunnel VPN, exit IP: $exit_ip"
        else
            log_success "TrustTunnel VPN connection successful"
            RESULTS[trusttunnel]="pass"
            DETAILS[trusttunnel]="Connected via TrustTunnel VPN"
        fi
    else
        detail="VPN connection test failed"
        if [[ -s "$error_log" ]]; then
            local error_msg=$(grep -i "error\|fail\|unreachable\|timeout\|refused" "$error_log" 2>/dev/null | tail -3 | tr '\n' ' ' || true)
            [[ -n "$error_msg" ]] && detail="$error_msg"
        fi
        log_error "$detail"
        RESULTS[trusttunnel]="fail"
        DETAILS[trusttunnel]="$detail"
    fi

    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    rm -f "$test_config"
}

# Test XHTTP (VLESS+XHTTP+Reality via Xray-core)
test_xhttp() {
    log_info "Testing XHTTP (VLESS+XHTTP+Reality)..."

    local config_file=""
    local detail=""

    # Find XHTTP config
    for f in "$CONFIG_DIR"/xhttp-vless.txt "$CONFIG_DIR"/xhttp.txt; do
        if [[ -f "$f" ]] && grep -q "^vless://" "$f" 2>/dev/null; then
            config_file="$f"
            break
        fi
    done

    if [[ -z "$config_file" ]]; then
        detail="No XHTTP config found in bundle"
        log_warn "$detail"
        RESULTS[xhttp]="skip"
        DETAILS[xhttp]="$detail"
        return
    fi

    # Check if xray binary is available
    if ! command -v xray &>/dev/null; then
        detail="Xray-core not installed (rebuild client image to add XHTTP support)"
        log_warn "$detail"
        RESULTS[xhttp]="skip"
        DETAILS[xhttp]="$detail"
        return
    fi

    log_debug "Using config: $config_file"

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

    log_debug "Parsed: server=$server port=$port uuid=$uuid sni=$sni"

    if [[ -z "$server" ]] || [[ -z "$uuid" ]] || [[ -z "$sni" ]] || [[ -z "$pbk" ]]; then
        detail="Failed to parse XHTTP URI (missing required fields)"
        log_error "$detail"
        RESULTS[xhttp]="fail"
        DETAILS[xhttp]="$detail"
        return
    fi

    # Generate Xray-core config (different format from sing-box)
    local client_config="$TEMP_DIR/xhttp-client.json"
    cat > "$client_config" << EOF
{
  "log": {"loglevel": "error"},
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": 10806,
    "protocol": "socks",
    "settings": {"udp": true}
  }],
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

    log_debug "Generated Xray config: $(cat "$client_config")"

    if ! jq empty "$client_config" 2>/dev/null; then
        detail="Generated invalid JSON config"
        log_error "$detail"
        RESULTS[xhttp]="fail"
        DETAILS[xhttp]="$detail"
        return
    fi

    # Start Xray and test
    local error_log="$TEMP_DIR/xhttp-error.log"
    xray run -c "$client_config" 2>"$error_log" &
    local pid=$!
    sleep 3

    if ! kill -0 $pid 2>/dev/null; then
        detail="Xray failed to start"
        if [[ -s "$error_log" ]]; then
            local error_msg=$(tail -5 "$error_log" 2>/dev/null | tr '\n' ' ' || true)
            detail="Xray error: $error_msg"
        fi
        log_error "$detail"
        RESULTS[xhttp]="fail"
        DETAILS[xhttp]="$detail"
        return
    fi

    log_debug "Xray started successfully (PID: $pid)"

    # Test connection via SOCKS5
    log_debug "Testing connectivity via SOCKS5 on port 10806..."
    if curl -sf --socks5 127.0.0.1:10806 --max-time "$TEST_TIMEOUT" "$TEST_URL" >/dev/null 2>&1; then
        local exit_ip=""
        exit_ip=$(curl -sf --socks5 127.0.0.1:10806 --max-time "$TEST_TIMEOUT" https://api.ipify.org 2>/dev/null || \
                  curl -sf --socks5 127.0.0.1:10806 --max-time "$TEST_TIMEOUT" https://ifconfig.me 2>/dev/null || true)
        if [[ -n "$exit_ip" ]]; then
            log_success "XHTTP connection successful (exit IP: $exit_ip)"
            RESULTS[xhttp]="pass"
            DETAILS[xhttp]="Connected via VLESS/XHTTP/Reality (Xray-core), exit IP: $exit_ip"
        else
            log_success "XHTTP connection successful"
            RESULTS[xhttp]="pass"
            DETAILS[xhttp]="Connected via VLESS/XHTTP/Reality (Xray-core)"
        fi
    else
        detail="Connection test failed"
        if [[ -s "$error_log" ]]; then
            local error_msg=$(grep -i "error\|fail\|unreachable\|timeout\|refused" "$error_log" 2>/dev/null | tail -3 | tr '\n' ' ' || true)
            [[ -n "$error_msg" ]] && detail="$error_msg"
        fi
        log_error "$detail"
        RESULTS[xhttp]="fail"
        DETAILS[xhttp]="$detail"
    fi

    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
}

test_telemt() {
    log_info "Testing Telegram MTProxy (telemt)..."

    local config_file=""
    local detail=""

    # Find telemt proxy link
    for f in "$CONFIG_DIR"/telegram-proxy-link.txt; do
        [[ -f "$f" ]] && config_file="$f" && break
    done

    if [[ -z "$config_file" ]]; then
        detail="No telemt config found in bundle"
        log_warn "$detail"
        RESULTS[telemt]="skip"
        DETAILS[telemt]="$detail"
        return
    fi

    log_debug "Using config: $config_file"

    # Parse tg://proxy link to extract server and port
    local tg_link
    tg_link=$(cat "$config_file" | tr -d '\n\r')
    log_debug "tg:// link: ${tg_link:0:60}..."

    local server port
    server=$(echo "$tg_link" | sed -n 's/.*server=\([^&]*\).*/\1/p' || true)
    port=$(echo "$tg_link" | sed -n 's/.*port=\([^&]*\).*/\1/p' || true)

    if [[ -z "$server" ]] || [[ -z "$port" ]]; then
        detail="Failed to parse telemt proxy link"
        log_error "$detail"
        RESULTS[telemt]="fail"
        DETAILS[telemt]="$detail"
        return
    fi

    log_debug "Parsed: server=$server port=$port"

    # TCP connectivity test (cannot test MTProxy protocol without Telegram client)
    log_info "  Testing TCP connectivity to $server:$port..."
    if nc -z -w 5 "$server" "$port" 2>/dev/null; then
        detail="Port $port reachable — use Telegram app to verify proxy"
        log_info "  $detail"
        RESULTS[telemt]="pass"
        DETAILS[telemt]="$detail"
    else
        detail="TCP connection to $server:$port failed (port may be blocked or service not running)"
        log_error "  $detail"
        RESULTS[telemt]="fail"
        DETAILS[telemt]="$detail"
    fi
}

# =============================================================================
# Output Functions
# =============================================================================

output_json() {
    local overall_status="pass"
    local pass_count=0
    local fail_count=0
    local skip_count=0
    local warn_count=0

    for protocol in "${!RESULTS[@]}"; do
        case "${RESULTS[$protocol]}" in
            pass) ((pass_count++)) ;;
            fail) ((fail_count++)); overall_status="fail" ;;
            skip) ((skip_count++)) ;;
            warn) ((warn_count++)); [[ "$overall_status" == "pass" ]] && overall_status="warn" ;;
        esac
    done

    cat << EOF
{
  "timestamp": "$(date -Iseconds 2>/dev/null || date)",
  "config_dir": "$CONFIG_DIR",
  "overall_status": "$overall_status",
  "summary": {
    "pass": $pass_count,
    "fail": $fail_count,
    "warn": $warn_count,
    "skip": $skip_count
  },
  "tests": {
EOF

    local first=true
    for protocol in reality trojan hysteria2 wireguard amneziawg dnstt slipstream trusttunnel telemt; do
        if [[ -n "${RESULTS[$protocol]:-}" ]]; then
            [[ "$first" != "true" ]] && echo ","
            first=false
            cat << EOF
    "$protocol": {
      "status": "${RESULTS[$protocol]}",
      "detail": "${DETAILS[$protocol]:-}"
    }
EOF
        fi
    done

    cat << EOF

  }
}
EOF
}

output_human() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  MoaV Connection Test Results"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  Config: $CONFIG_DIR"
    echo "  Time:   $(date)"
    echo ""
    echo "───────────────────────────────────────────────────────────────"

    for protocol in reality trojan hysteria2 wireguard amneziawg dnstt slipstream trusttunnel telemt; do
        if [[ -n "${RESULTS[$protocol]:-}" ]]; then
            local status="${RESULTS[$protocol]}"
            local detail="${DETAILS[$protocol]:-}"
            local icon=""
            local color=""

            case "$status" in
                pass) icon="✓"; color="$GREEN" ;;
                fail) icon="✗"; color="$RED" ;;
                warn) icon="⚠"; color="$YELLOW" ;;
                skip) icon="○"; color="$CYAN" ;;
            esac

            printf "  ${color}${icon}${NC} %-12s %s\n" "$protocol" "$detail"
        fi
    done

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
}

# =============================================================================
# Main
# =============================================================================

main() {
    setup

    log_info "Starting connectivity tests..."
    log_info "Config directory: $CONFIG_DIR"
    echo ""

    # Run all tests
    test_reality
    test_trojan
    test_hysteria2
    test_xhttp
    test_wireguard
    test_amneziawg
    test_dnstt
    test_slipstream
    test_trusttunnel
    test_telemt

    # Output results
    if [[ "${JSON_OUTPUT:-false}" == "true" ]]; then
        output_json
    else
        output_human
    fi
}

main

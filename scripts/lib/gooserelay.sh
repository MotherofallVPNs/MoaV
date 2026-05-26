#!/bin/bash
# GooseRelay exit-server configuration functions (MahsaNG v16 component)
#
# GooseRelay (github.com/kianmhz/GooseRelayVPN) tunnels raw TCP through a
# user-deployed Google Apps Script web app to this VPS exit server, end-to-end
# AES-256-GCM encrypted and domain-fronted via google.com. Interoperable with
# the GooseRelay client in MahsaNG v16 (GooseRelay v1.7.1).
#
# Server egress is routed through sing-box's mixed inbound (sing-box:1080) for
# parity with the rest of the MoaV stack.

GOOSERELAY_CONFIG_DIR="/configs/gooserelay"

generate_gooserelay_config() {
    log_info "Setting up GooseRelay configuration..."

    ensure_dir "$GOOSERELAY_CONFIG_DIR"
    ensure_dir "$STATE_DIR/keys"

    local key_file="$STATE_DIR/keys/gooserelay-tunnel.key"

    # tunnel_key = openssl rand -hex 32 (64-char hex, AES-256). Stable across
    # re-bootstraps; the exact same value must be set in the client config.
    if [[ ! -s "$key_file" ]] || [[ $(tr -d '\n\r ' < "$key_file" | wc -c | tr -d ' ') -ne 64 ]]; then
        log_info "Generating GooseRelay tunnel key (64-char hex / AES-256)"
        # No chmod: follow the repo convention (dnstt/Slipstream state keys) so
        # the unprivileged `moav` user in the service container can read it.
        openssl rand -hex 32 | tr -d '\n' > "$key_file"
    fi

    if [[ ! -s "$key_file" ]]; then
        log_error "GooseRelay tunnel key file is empty or missing"
        return 1
    fi

    local tunnel_key
    tunnel_key=$(tr -d '\n\r ' < "$key_file")

    # Route outbound through sing-box's mixed SOCKS inbound so GooseRelay
    # egress matches dnstt/Slipstream/MasterDNS.
    cat > "$GOOSERELAY_CONFIG_DIR/server_config.json" <<EOF
{
  "server_host": "0.0.0.0",
  "server_port": 8443,
  "tunnel_key": "${tunnel_key}",
  "upstream_proxy": "socks5://sing-box:1080",
  "debug_timing": false
}
EOF

    ensure_dir "/outputs/gooserelay"
    echo "$tunnel_key" > "/outputs/gooserelay/tunnel_key.txt"

    log_info "GooseRelay configuration created (server :8443 /tunnel)"
}

# Generate GooseRelay client instructions for a user
gooserelay_generate_client_instructions() {
    local user_id="$1"
    local output_dir="$2"

    local key_file="$STATE_DIR/keys/gooserelay-tunnel.key"
    local tunnel_key="KEY_NOT_GENERATED"
    [[ -s "$key_file" ]] && tunnel_key=$(tr -d '\n\r ' < "$key_file")

    local srv_ip="${SERVER_IP:-YOUR_SERVER_IP}"
    local goose_port="${PORT_GOOSE:-8444}"

    cat > "$output_dir/gooserelay-instructions.txt" <<EOF
# GooseRelay Instructions
# =======================
# SOCKS5 over a Google Apps Script web app -> this VPS exit server.
# To the network you only ever appear to talk TLS to google.com.
# End-to-end AES-256-GCM; Google never sees plaintext or the key.
# Interoperable with the GooseRelay client in MahsaNG v16 (GooseRelay v1.7.1).
#
# Project: https://github.com/kianmhz/GooseRelayVPN
# Bundled in: MahsaNG (https://github.com/GFW-knocker/MahsaNG)

# Shared tunnel key (keep SECRET — anyone with it can use your VPS as you):
$tunnel_key

# This server's exit endpoint (add to the RELAY_URLS array in your Apps Script):
http://$srv_ip:$goose_port/tunnel

# -------------------------
# One-time setup (done on YOUR machine + YOUR Google account)
# -------------------------
# 1. Get the client + Apps Script from:
#    https://github.com/kianmhz/GooseRelayVPN/releases  (tag v1.7.1)
#
# 2. Deploy the Apps Script forwarder:
#    - Open https://script.google.com  ->  New project
#    - Paste the contents of apps_script/Code.gs from the repo
#    - Set the RELAY_URLS array near the top to this server's endpoint
#      (v1.7.x uses an array, not a single RELAY_URL):
#        const RELAY_URLS = [
#          'http://$srv_ip:$goose_port/tunnel',
#        ];
#    - Deploy -> New deployment -> type "Web app"
#        Execute as: Me
#        Who has access: Anyone
#    - Copy the Deployment ID it shows.
#    - (Re-deploy as a NEW deployment every time you edit Code.gs.)
#
# 3. Fill in client_config.json:
#      {
#        "socks_host": "127.0.0.1",
#        "socks_port": 1080,
#        "google_host": "216.239.38.120",
#        "sni": ["www.google.com", "mail.google.com", "accounts.google.com"],
#        "script_keys": [ { "id": "YOUR_DEPLOYMENT_ID", "account": "acct-a" } ],
#        "tunnel_key": "$tunnel_key"
#      }
#
# 4. Run the client, then point your apps at SOCKS5 127.0.0.1:1080.
#    A pre-flight check confirms the relay is healthy and the key matches.

# -------------------------
# Notes:
# -------------------------
# - Apps Script quota is ~20,000 calls/day PER Google account. Deploy under
#   several accounts and list all Deployment IDs in script_keys for capacity.
# - Real-time apps (Telegram/X) drain the quota fast due to constant polling.
# - Traffic exits through the MoaV server (your IP appears as the server IP).
# - All deployments forwarding here must use this exact tunnel_key.
EOF

    log_info "Generated GooseRelay instructions for $user_id"
}

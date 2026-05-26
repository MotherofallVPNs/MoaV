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
    local endpoint="http://$srv_ip:$goose_port/tunnel"

    # Ready-to-paste Apps Script: the vendored v1.7.1 Code.gs with RELAY_URLS
    # already pointed at this server (no hand-editing of the array).
    local gs_template="$GOOSERELAY_CONFIG_DIR/Code.gs.template"
    local have_gs=false
    if [[ -f "$gs_template" ]]; then
        sed "s|__GOOSE_RELAY_ENDPOINT__|$endpoint|g" "$gs_template" > "$output_dir/gooserelay-AppsScript.gs"
        have_gs=true
    fi

    # Ready-to-use client config (matches GooseRelay v1.7.1's schema). Everything
    # is pre-filled except the Apps Script Deployment ID, which only exists after
    # the user deploys the script in their own Google account.
    cat > "$output_dir/gooserelay-client_config.json" <<EOF
{
  "debug_timing": false,
  "socks_host": "127.0.0.1",
  "socks_port": 1080,
  "google_host": "216.239.38.120",
  "sni": ["www.google.com", "mail.google.com", "accounts.google.com"],
  "script_keys": [
    {"id": "REPLACE_WITH_YOUR_APPS_SCRIPT_DEPLOYMENT_ID", "account": "acct-a"}
  ],
  "tunnel_key": "$tunnel_key",
  "coalesce_step_ms": 0,
  "idle_slots_per_bucket": 2
}
EOF

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

# This bundle ships TWO ready-made files so you don't hand-edit anything:
#   gooserelay-AppsScript.gs       -> paste into script.google.com; the
#                                     RELAY_URLS array already points here
#   gooserelay-client_config.json  -> ready for the GooseRelay / MahsaNG v16
#                                     client; only the Deployment ID is blank

# Shared tunnel key (already in the config; keep SECRET — anyone with it can
# use your VPS as you):
$tunnel_key

# This server's exit endpoint (already wired into gooserelay-AppsScript.gs):
$endpoint

# -------------------------
# Setup (one-time, in YOUR Google account)
# -------------------------
# 1. Open https://script.google.com  ->  New project
# 2. Paste the WHOLE contents of  gooserelay-AppsScript.gs  (no edits needed)
# 3. Deploy -> New deployment -> type "Web app"
#       Execute as: Me
#       Who has access: Anyone
#    Copy the Deployment ID it shows.
#    (Re-deploy as a NEW deployment whenever you change the script.)
# 4. In gooserelay-client_config.json, replace
#    REPLACE_WITH_YOUR_APPS_SCRIPT_DEPLOYMENT_ID with that Deployment ID.
# 5. Load gooserelay-client_config.json into the GooseRelay client (or the
#    MahsaNG v16 GooseRelay tab), then point apps at SOCKS5 127.0.0.1:1080.
#    A pre-flight check confirms the relay is healthy and the key matches.

# -------------------------
# Notes:
# -------------------------
# - Apps Script quota is ~20,000 calls/day PER Google account. Deploy under
#   several accounts and add each Deployment ID to "script_keys" for capacity.
# - Real-time apps (Telegram/X) drain the quota fast due to constant polling.
# - Traffic exits through the MoaV server (your IP appears as the server IP).
# - All deployments forwarding here must use this exact tunnel_key.
EOF

    if [[ "$have_gs" == true ]]; then
        log_info "Generated GooseRelay bundle (AppsScript.gs + client_config.json) for $user_id"
    else
        log_info "GooseRelay Code.gs.template not found; emitted client_config.json + instructions only for $user_id"
    fi
}

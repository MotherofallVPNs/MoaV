#!/bin/bash
# Slipstream QUIC-over-DNS tunnel configuration functions
# DEPRECATED (2026-11-23): off by default and not routed by dns-router;
# kept one release for migration, removed in a later release.

SLIPSTREAM_CONFIG_DIR="/configs/slipstream"

generate_slipstream_config() {
    log_info "Setting up Slipstream configuration..."

    ensure_dir "$SLIPSTREAM_CONFIG_DIR"
    ensure_dir "$STATE_DIR/keys"

    local cert_file="$STATE_DIR/keys/slipstream-cert.pem"
    local key_file="$STATE_DIR/keys/slipstream-key.pem"

    # Generate ECDSA P-256 self-signed cert if not exists
    if [[ ! -f "$cert_file" ]] || [[ ! -f "$key_file" ]]; then
        log_info "Generating Slipstream ECDSA P-256 certificate..."

        # Generate private key
        if ! openssl ecparam -genkey -name prime256v1 -noout -out "$key_file" 2>&1; then
            log_error "Failed to generate Slipstream private key"
            return 1
        fi

        # Generate self-signed certificate (10-year validity)
        if ! openssl req -new -x509 -key "$key_file" -out "$cert_file" \
            -days 3650 -subj "/CN=slipstream" 2>&1; then
            log_error "Failed to generate Slipstream certificate"
            return 1
        fi

        log_info "Slipstream certificate generated (valid for 10 years)"
    else
        log_info "Slipstream certificate already exists, skipping generation"
    fi

    # Verify cert/key are valid
    if [[ ! -s "$cert_file" ]]; then
        log_error "Slipstream certificate file is empty or missing"
        return 1
    fi
    if [[ ! -s "$key_file" ]]; then
        log_error "Slipstream key file is empty or missing"
        return 1
    fi

    # Copy cert to configs and outputs for distribution
    cp "$cert_file" "$SLIPSTREAM_CONFIG_DIR/cert.pem"
    ensure_dir "/outputs/slipstream"
    cp "$cert_file" "/outputs/slipstream/cert.pem"

    log_info "Slipstream configuration created"
    log_info "Certificate: $cert_file"
}

# Generate Slipstream client instructions for a user
slipstream_generate_client_instructions() {
    local user_id="$1"
    local output_dir="$2"

    local slipstream_domain="${SLIPSTREAM_SUBDOMAIN:-s}.${DOMAIN}"

    # Copy cert to user bundle
    if [[ -f "$STATE_DIR/keys/slipstream-cert.pem" ]]; then
        cp "$STATE_DIR/keys/slipstream-cert.pem" "$output_dir/slipstream-cert.pem"
    fi

    # Canonical client config (carries the tunnel domain — the human setup guide
    # lives in README.html). The client tools + connectivity test read the domain
    # from here; keep it the first slipstream-named file so it wins the glob.
    cat > "$output_dir/slipstream-client.conf" <<EOF
# Slipstream client config. Setup guide: README.html.
# DEPRECATED: Slipstream is being removed from MoaV; use MasterDNS or dnstt.
# Run (Linux): slipstream-client --domain $slipstream_domain --cert slipstream-cert.pem --resolver 1.1.1.1:53 --tcp-listen-host 127.0.0.1 --tcp-listen-port 1080
domain = $slipstream_domain
EOF

    log_info "Generated Slipstream client config for $user_id"
}

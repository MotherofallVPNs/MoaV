#!/bin/bash
# lib/donate.sh — config donation: MahsaNet (share individual proxy configs to
# the MahsaNet pool) plus the Conduit/Snowflake donation setup and status views.
#
# Self-contained: the MahsaNet API endpoint and the donations ledger path are
# defined here, and nothing outside calls into it except the `moav donate`
# dispatch. Sourced by moav.sh after lib/common.sh.
#
# Definitions only — nothing here runs at source time.

MAHSANET_API_URL="https://www.mahsaserver.com/backend/api/v1/config/"
MAHSANET_DONATIONS_FILE="outputs/mahsanet-donations.json"

mahsanet_api_call() {
    local method="$1"
    local endpoint="${2:-}"
    local data="${3:-}"
    local api_key="$4"
    local url="${MAHSANET_API_URL}${endpoint}"

    local curl_args=(
        -s -w "\n%{http_code}"
        -X "$method"
        -H "Authorization: Token $api_key"
        -H "Content-Type: application/json"
    )
    [[ -n "$data" ]] && curl_args+=(-d "$data")
    curl_args+=("$url")

    curl "${curl_args[@]}"
}

mahsanet_validate_key() {
    local api_key="$1"
    local response
    response=$(mahsanet_api_call "GET" "?limit=1" "" "$api_key")
    local http_code
    http_code=$(echo "$response" | tail -1)
    if [[ "$http_code" == "200" ]]; then
        return 0
    elif [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
        error "Invalid API key (HTTP $http_code)"
        return 1
    else
        error "MahsaNet API error (HTTP $http_code)"
        return 1
    fi
}

mahsanet_validate_link() {
    local link="$1"
    local protocol="$2"

    # Check non-empty
    if [[ -z "$link" ]]; then
        return 1
    fi

    # Telegram links have different structure
    if [[ "$protocol" == "telegram" ]]; then
        [[ "$link" == tg://proxy* ]] || return 1
        [[ "$link" == *"server="* ]] || return 1
        [[ "$link" == *"secret="* ]] || return 1
        return 0
    fi

    # Check length
    if [[ ${#link} -lt 50 ]]; then
        return 1
    fi

    # Check URI structure (has @ and #)
    if [[ "$link" != *"@"* ]] || [[ "$link" != *"#"* ]]; then
        return 1
    fi

    # Check protocol prefix
    case "$protocol" in
        reality|cdn|xhttp)
            [[ "$link" == vless://* ]] || return 1
            ;;
        hysteria2)
            [[ "$link" == hysteria2://* ]] || return 1
            ;;
        trojan)
            [[ "$link" == trojan://* ]] || return 1
            ;;
        *)
            return 1
            ;;
    esac

    return 0
}

mahsanet_protocol_to_file() {
    local protocol="$1"
    case "$protocol" in
        reality)   echo "reality.txt" ;;
        hysteria2) echo "hysteria2.txt" ;;
        trojan)    echo "trojan.txt" ;;
        cdn)       echo "cdn-vless.txt" ;;
        xhttp)     echo "xhttp-vless.txt" ;;
        telegram)  echo "telegram-proxy-link.txt" ;;
        *)         echo "" ;;
    esac
}

mahsanet_load_donations() {
    if [[ -f "$MAHSANET_DONATIONS_FILE" ]]; then
        cat "$MAHSANET_DONATIONS_FILE"
    else
        echo '{"configs":[]}'
    fi
}

mahsanet_save_donation() {
    local config_id="$1"
    local user="$2"
    local protocol="$3"

    local donations
    donations=$(mahsanet_load_donations)

    # Append new entry
    donations=$(echo "$donations" | jq \
        --arg id "$config_id" \
        --arg user "$user" \
        --arg protocol "$protocol" \
        --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.configs += [{"id": $id, "user": $user, "protocol": $protocol, "donated_at": $date}]')

    mkdir -p "$(dirname "$MAHSANET_DONATIONS_FILE")"
    echo "$donations" > "$MAHSANET_DONATIONS_FILE"
}

cmd_donate_mahsanet_setup() {
    echo ""
    info "MahsaNet API Key Setup"
    echo ""
    echo "  To get an API key:"
    echo "  1. Register at https://www.mahsaserver.com/"
    echo "  2. Verify your email"
    echo "  3. Fill out the verified donor form"
    echo "  4. Go to https://www.mahsaserver.com/user/api"
    echo "  5. Generate an API key"
    echo ""
    printf "  API Key: "
    read -r api_key

    if [[ -z "$api_key" ]]; then
        error "No API key provided"
        return 1
    fi

    info "Validating API key..."
    if ! mahsanet_validate_key "$api_key"; then
        return 1
    fi
    success "API key is valid!"

    # Save to .env
    if [[ ! -f ".env" ]]; then
        error ".env file not found. Run 'moav setup' first."
        return 1
    fi

    if grep -q "^MAHSANET_API_KEY=" .env 2>/dev/null; then
        sed -i "s|^MAHSANET_API_KEY=.*|MAHSANET_API_KEY=$api_key|" .env
    else
        echo "MAHSANET_API_KEY=$api_key" >> .env
    fi
    success "API key saved to .env"

    # Recreate admin if running to pick up new key (restart won't read .env changes)
    if docker ps --filter "name=moav-admin" --filter "status=running" -q 2>/dev/null | grep -q .; then
        info "Recreating admin container to pick up API key..."
        docker compose --profile admin up -d admin 2>/dev/null || true
    fi
}

cmd_donate_mahsanet_list() {
    local api_key="$1"
    info "Fetching donated configs from MahsaNet..."
    echo ""

    local response
    response=$(mahsanet_api_call "GET" "?limit=100" "" "$api_key")
    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        error "Failed to fetch configs (HTTP $http_code)"
        return 1
    fi

    local count
    count=$(echo "$body" | jq -r '.count // 0')

    if [[ "$count" == "0" ]]; then
        info "No configs donated yet."
        return 0
    fi

    printf "  %3s  %-38s %-10s %6s  %4s\n" "#" "URL" "Status" "Health" "Used"
    echo "  $(printf '%.0s─' {1..74})"

    local i=1
    echo "$body" | jq -r '.results[] | [
        (.url[:34] + (if (.url | length) > 34 then ".." else "" end)),
        (if .is_active then "active" else "inactive" end),
        (if .health_status_percent == null then "—" elif (.health_status_percent | type) == "number" then (.health_status_percent | tostring) + "%" elif (.health_status_percent | type) == "string" then .health_status_percent + "%" else "—" end),
        (.num_consumed // 0 | tostring)
    ] | @tsv' 2>/dev/null | while IFS=$'\t' read -r url status health used; do
        printf "  %3s  %-38s %-10s %6s  %4s\n" "$i" "$url" "$status" "$health" "$used"
        i=$((i + 1))
    done

    echo ""
    info "Total: $count config(s)"
    echo -e "  ${DIM}To delete specific configs: moav donate delete${NC}"
}

cmd_donate_mahsanet_delete() {
    local api_key="$1"

    # Get all configs
    local response
    response=$(mahsanet_api_call "GET" "?limit=100" "" "$api_key")
    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        error "Failed to fetch configs (HTTP $http_code)"
        return 1
    fi

    local count
    count=$(echo "$body" | jq -r '.count // 0')

    if [[ "$count" == "0" ]]; then
        info "No configs to delete."
        return 0
    fi

    # Show numbered list
    echo ""
    printf "  %3s  %-48s %-10s\n" "#" "URL" "Status"
    echo "  $(printf '%.0s─' {1..68})"

    local i=1
    echo "$body" | jq -r '.results[] | [
        (.url[:44] + (if (.url | length) > 44 then ".." else "" end)),
        (if .is_active then "active" else "inactive" end)
    ] | @tsv' 2>/dev/null | while IFS=$'\t' read -r url status; do
        printf "  %3s  %-48s %-10s\n" "$i" "$url" "$status"
        i=$((i + 1))
    done
    echo ""

    echo -n "  Enter numbers to delete (e.g. 1 3 5, or 'all'): "
    read -r selection

    if [[ -z "$selection" ]]; then
        info "Cancelled."
        return 0
    fi

    # Build list of ids to delete
    local ids_json
    ids_json=$(echo "$body" | jq -r '[.results[] | (.id // .hash)]')

    local to_delete=()
    if [[ "$selection" == "all" ]]; then
        while IFS= read -r id; do
            to_delete+=("$id")
        done < <(echo "$ids_json" | jq -r '.[]')
    else
        for num in $selection; do
            local idx=$((num - 1))
            local id
            id=$(echo "$ids_json" | jq -r ".[$idx] // empty")
            if [[ -n "$id" ]]; then
                to_delete+=("$id")
            else
                warn "Invalid number: $num"
            fi
        done
    fi

    if [[ ${#to_delete[@]} -eq 0 ]]; then
        info "Nothing to delete."
        return 0
    fi

    warn "Will delete ${#to_delete[@]} config(s) from MahsaNet."
    if ! confirm "Are you sure?" "n"; then
        info "Cancelled."
        return 0
    fi

    local removed=0
    local failed=0
    for id in "${to_delete[@]}"; do
        local del_response
        del_response=$(mahsanet_api_call "DELETE" "${id}/" "" "$api_key")
        local del_code
        del_code=$(echo "$del_response" | tail -1)
        if [[ "$del_code" == "204" || "$del_code" == "200" ]]; then
            removed=$((removed + 1))
        else
            failed=$((failed + 1))
            warn "Failed to remove config $id (HTTP $del_code)"
        fi
    done

    echo ""
    success "Removed $removed config(s) from MahsaNet"
    [[ $failed -gt 0 ]] && warn "$failed config(s) failed to remove"
}

cmd_donate_mahsanet_status() {
    local api_key="$1"
    info "Fetching donation status..."

    local response
    response=$(mahsanet_api_call "GET" "?limit=1" "" "$api_key")
    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        error "Failed to fetch status (HTTP $http_code)"
        return 1
    fi

    local total
    total=$(echo "$body" | jq -r '.count // 0')

    # Get active count
    local active_response
    active_response=$(mahsanet_api_call "GET" "?limit=1&is_active=true" "" "$api_key")
    local active_body
    active_body=$(echo "$active_response" | sed '$d')
    local active
    active=$(echo "$active_body" | jq -r '.count // 0')
    local inactive=$((total - active))

    echo ""
    echo -e "  ${WHITE}MahsaNet Donation Status${NC}"
    echo -e "  Total configs:   ${CYAN}$total${NC}"
    echo -e "  Active:          ${GREEN}$active${NC}"
    echo -e "  Inactive:        ${YELLOW}$inactive${NC}"
    echo ""
}

cmd_donate_mahsanet_remove() {
    local api_key="$1"

    # Get all configs
    local response
    response=$(mahsanet_api_call "GET" "?limit=100" "" "$api_key")
    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        error "Failed to fetch configs (HTTP $http_code)"
        return 1
    fi

    local count
    count=$(echo "$body" | jq -r '.count // 0')

    if [[ "$count" == "0" ]]; then
        info "No configs to remove."
        return 0
    fi

    warn "This will remove all $count donated config(s) from MahsaNet."
    if ! confirm "Are you sure?" "n"; then
        info "Cancelled."
        return 0
    fi

    local ids
    ids=$(echo "$body" | jq -r '.results[] | (.id // .hash)')
    local removed=0
    local failed=0

    for id in $ids; do
        local del_response
        del_response=$(mahsanet_api_call "DELETE" "${id}/" "" "$api_key")
        local del_code
        del_code=$(echo "$del_response" | tail -1)
        if [[ "$del_code" == "204" || "$del_code" == "200" ]]; then
            removed=$((removed + 1))
        else
            failed=$((failed + 1))
            warn "Failed to remove config $id (HTTP $del_code)"
        fi
    done

    # Clear local tracking
    if [[ -f "$MAHSANET_DONATIONS_FILE" ]]; then
        echo '{"configs":[]}' > "$MAHSANET_DONATIONS_FILE"
    fi

    echo ""
    success "Removed $removed config(s) from MahsaNet"
    [[ $failed -gt 0 ]] && warn "$failed config(s) failed to remove"
}

_get_donate_api_key() {
    local api_key=""
    if [[ -f ".env" ]]; then
        api_key=$(get_env_val "MAHSANET_API_KEY" ".env")
    fi
    if [[ -z "$api_key" ]]; then
        error "No donation service configured"
        echo ""
        echo "  Run: moav donate setup"
        return 1
    fi
    echo "$api_key"
}

cmd_donate_mahsanet_donate() {
    local api_key="$1"

    info "Validating API key..."
    if ! mahsanet_validate_key "$api_key"; then
        return 1
    fi
    success "API key valid"
    echo ""

    # Read protocols
    local protocols="reality hysteria2"
    if [[ -f ".env" ]]; then
        local env_protocols
        env_protocols=$(grep -E "^MAHSANET_PROTOCOLS=" .env 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
        [[ -n "$env_protocols" ]] && protocols="$env_protocols"
    fi

    # Read pool
    local pool="mahsa"
    if [[ -f ".env" ]]; then
        local env_pool
        env_pool=$(grep -E "^MAHSANET_POOL=" .env 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
        [[ -n "$env_pool" ]] && pool="$env_pool"
    fi

    echo -e "  ${WHITE}Protocols:${NC} $protocols"
    echo -e "  ${WHITE}Pool:${NC} $pool"
    echo ""

    # Ask for user count and prefix
    printf "  Number of users to create for donation (default: 1): "
    read -r user_count
    user_count="${user_count:-1}"

    if ! [[ "$user_count" =~ ^[0-9]+$ ]] || [[ "$user_count" -lt 1 ]] || [[ "$user_count" -gt 50 ]]; then
        error "Invalid count. Must be 1-50."
        return 1
    fi

    printf "  Username prefix (default: mahsa): "
    read -r user_prefix
    user_prefix="${user_prefix:-mahsa}"

    if [[ ! "$user_prefix" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        error "Invalid prefix. Use only letters, numbers, underscores, and hyphens."
        return 1
    fi

    echo ""
    info "Will create $user_count user(s) with prefix '$user_prefix' and donate $protocols configs"
    if ! confirm "Proceed?" "y"; then
        info "Cancelled."
        return 0
    fi

    # Generate users (with DONATE_ONLY_PROTOCOLS to skip WireGuard/AmneziaWG/etc.)
    echo ""
    info "Generating $user_count donation user(s) (lightweight — only donated protocols)..."
    export DONATE_ONLY_PROTOCOLS="$protocols"
    local add_output
    if [[ "$user_count" -eq 1 ]]; then
        # Single user mode - use prefix as the username directly
        if [[ -x "./scripts/user-add.sh" ]]; then
            add_output=$(./scripts/user-add.sh "${user_prefix}01" 2>&1) || true
        else
            error "user-add.sh not found"
            return 1
        fi
    else
        if [[ -x "./scripts/user-add.sh" ]]; then
            add_output=$(./scripts/user-add.sh --batch "$user_count" --prefix "$user_prefix" 2>&1) || true
        else
            error "user-add.sh not found"
            return 1
        fi
    fi
    unset DONATE_ONLY_PROTOCOLS

    # Find the generated user directories
    local generated_users=()
    local i
    for i in $(seq -w 1 "$user_count"); do
        # Pad to 2 digits
        local padded
        padded=$(printf "%02d" "$((10#$i))")
        local username="${user_prefix}${padded}"
        if [[ -d "outputs/bundles/$username" ]]; then
            generated_users+=("$username")
        fi
    done

    if [[ ${#generated_users[@]} -eq 0 ]]; then
        error "No users were generated. Check the output above for errors."
        echo "$add_output" | tail -5
        return 1
    fi

    success "Generated ${#generated_users[@]} user(s)"
    echo ""

    # Donate configs
    info "Donating configs to MahsaNet..."
    local donated=0
    local skipped=0
    local failed=0

    for username in "${generated_users[@]}"; do
        local bundle_dir="outputs/bundles/$username"

        for protocol in $protocols; do
            local link_file
            link_file=$(mahsanet_protocol_to_file "$protocol")

            if [[ -z "$link_file" ]]; then
                warn "Unknown protocol: $protocol (skipping)"
                skipped=$((skipped + 1))
                continue
            fi

            local filepath="$bundle_dir/$link_file"
            if [[ ! -f "$filepath" ]]; then
                warn "$username: $protocol config not found ($link_file) — skipping"
                skipped=$((skipped + 1))
                continue
            fi

            local link
            link=$(head -1 "$filepath" | tr -d '[:space:]')

            if ! mahsanet_validate_link "$link" "$protocol"; then
                warn "$username: $protocol link failed sanity check — skipping"
                echo "    link preview: ${link:0:80}..."
                skipped=$((skipped + 1))
                continue
            fi

            # Telegram configs go to the "telegram" pool, others use configured pool
            local config_pool="$pool"
            if [[ "$protocol" == "telegram" ]]; then
                config_pool="telegram"
            fi

            echo -e "  ${WHITE}→${NC} $username/$protocol: submitting to '$config_pool' pool..."

            # POST to MahsaNet API
            local json_data
            json_data=$(jq -n \
                --arg url "$link" \
                --arg pool "$config_pool" \
                '{"url": $url, "ads_url": "https://t.me/VahidOnline", "pool": $pool, "use_mux": false, "use_fragment": false}')

            local response
            response=$(mahsanet_api_call "POST" "" "$json_data" "$api_key")
            local http_code
            http_code=$(echo "$response" | tail -1)
            local body
            body=$(echo "$response" | sed '$d')

            if [[ "$http_code" == "201" ]]; then
                local config_id
                config_id=$(echo "$body" | jq -r '.hash // .id // "unknown"')
                mahsanet_save_donation "$config_id" "$username" "$protocol"
                donated=$((donated + 1))
                echo -e "  ${GREEN}✓${NC} $username/$protocol → donated (id: $config_id)"
            elif [[ "$http_code" == "429" ]]; then
                # Rate limited — extract wait time and retry
                local wait_secs
                wait_secs=$(echo "$body" | grep -oP 'in \K[0-9]+' 2>/dev/null || echo "30")
                echo -e "  ${YELLOW}⏳${NC} Rate limited — waiting ${wait_secs}s..."
                sleep "$((wait_secs + 2))"
                # Retry
                response=$(mahsanet_api_call "POST" "" "$json_data" "$api_key")
                http_code=$(echo "$response" | tail -1)
                body=$(echo "$response" | sed '$d')
                if [[ "$http_code" == "201" ]]; then
                    local config_id
                    config_id=$(echo "$body" | jq -r '.hash // .id // "unknown"')
                    mahsanet_save_donation "$config_id" "$username" "$protocol"
                    donated=$((donated + 1))
                    echo -e "  ${GREEN}✓${NC} $username/$protocol → donated (id: $config_id)"
                else
                    failed=$((failed + 1))
                    echo -e "  ${RED}✗${NC} $username/$protocol → failed after retry ($http_code)"
                fi
            else
                failed=$((failed + 1))
                local err_msg
                err_msg=$(echo "$body" | jq -r '.detail // .url // .non_field_errors // "unknown error"' 2>/dev/null || echo "HTTP $http_code")
                echo -e "  ${RED}✗${NC} $username/$protocol → failed ($http_code): $err_msg"
            fi
        done
    done

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${WHITE}Donation Summary${NC}"
    echo -e "  Users created: ${CYAN}${#generated_users[@]}${NC}"
    echo -e "  Configs donated: ${GREEN}$donated${NC}"
    [[ $skipped -gt 0 ]] && echo -e "  Skipped: ${YELLOW}$skipped${NC}"
    [[ $failed -gt 0 ]] && echo -e "  Failed: ${RED}$failed${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
}

_format_bytes_sh() {
    local bytes="${1:-0}"
    if [[ "$bytes" == "0" ]] || [[ -z "$bytes" ]]; then echo "0 B"; return; fi
    # Use awk for portable float arithmetic
    echo "$bytes" | awk '{
        b=$1; units[0]="B"; units[1]="KB"; units[2]="MB"; units[3]="GB"; units[4]="TB"
        for(i=0; i<4 && b>=1024; i++) b/=1024
        printf "%.1f %s", b, units[i]
    }'
}

_query_conduit_metrics() {
    local metrics
    metrics=$(docker exec moav-conduit curl -sf http://127.0.0.1:9090/metrics 2>/dev/null) || \
    metrics=$(docker exec moav-conduit wget -qO- http://127.0.0.1:9090/metrics 2>/dev/null) || return 1
    local connected
    connected=$(echo "$metrics" | grep "^conduit_connected_clients " | awk '{print $2}' | cut -d. -f1)
    local up_bytes
    up_bytes=$(echo "$metrics" | grep "^conduit_bytes_uploaded " | awk '{print $2}' | cut -d. -f1)
    local down_bytes
    down_bytes=$(echo "$metrics" | grep "^conduit_bytes_downloaded " | awk '{print $2}' | cut -d. -f1)
    echo "${connected:-0} ${up_bytes:-0} ${down_bytes:-0}"
}

_query_snowflake_metrics() {
    local metrics
    metrics=$(docker exec moav-snowflake-exporter wget -qO- http://127.0.0.1:8080/metrics 2>/dev/null) || \
    metrics=$(docker exec moav-snowflake-exporter curl -sf http://127.0.0.1:8080/metrics 2>/dev/null) || return 1
    local served
    served=$(echo "$metrics" | grep "^served_people " | awk '{print $2}' | cut -d. -f1)
    local up_gb
    up_gb=$(echo "$metrics" | grep "^upload_gb " | awk '{print $2}')
    local down_gb
    down_gb=$(echo "$metrics" | grep "^download_gb " | awk '{print $2}')
    echo "${served:-0} ${up_gb:-0} ${down_gb:-0}"
}

_show_donation_services() {
    local env_file="$SCRIPT_DIR/.env"

    # MahsaNet
    local mahsa_key=""
    [[ -f "$env_file" ]] && mahsa_key=$(get_env_val "MAHSANET_API_KEY" "$env_file" "")
    if [[ -n "$mahsa_key" ]]; then
        echo -e "    ${GREEN}✓${NC} MahsaNet    API key configured"
    else
        echo -e "    ${DIM}○${NC} MahsaNet    ${DIM}not configured${NC}"
    fi

    # Conduit
    local conduit_enabled
    conduit_enabled=$(get_env_val "ENABLE_CONDUIT" "$env_file" "true")
    local conduit_bw
    conduit_bw=$(get_env_val "CONDUIT_BANDWIDTH" "$env_file" "100")
    local conduit_clients
    conduit_clients=$(get_env_val "CONDUIT_MAX_COMMON_CLIENTS" "$env_file" "200")
    if [[ "$conduit_enabled" == "true" ]]; then
        local conduit_running=""
        docker compose ps psiphon-conduit --status running 2>/dev/null | tail -n +2 | grep -q . && conduit_running="yes"
        if [[ -n "$conduit_running" ]]; then
            echo -e "    ${GREEN}✓${NC} Conduit     Running — ${conduit_bw} Mbps, ${conduit_clients} max clients"
        else
            echo -e "    ${YELLOW}○${NC} Conduit     Enabled but not running"
        fi
    else
        echo -e "    ${DIM}○${NC} Conduit     ${DIM}disabled${NC}"
    fi

    # Snowflake
    local snow_enabled
    snow_enabled=$(get_env_val "ENABLE_SNOWFLAKE" "$env_file" "true")
    local snow_bw
    snow_bw=$(get_env_val "SNOWFLAKE_BANDWIDTH" "$env_file" "5")
    local snow_cap
    snow_cap=$(get_env_val "SNOWFLAKE_CAPACITY" "$env_file" "50")
    if [[ "$snow_enabled" == "true" ]]; then
        local snow_running=""
        docker compose ps snowflake --status running 2>/dev/null | tail -n +2 | grep -q . && snow_running="yes"
        if [[ -n "$snow_running" ]]; then
            echo -e "    ${GREEN}✓${NC} Snowflake   Running — ${snow_bw} Mbps, ${snow_cap} capacity"
        else
            echo -e "    ${YELLOW}○${NC} Snowflake   Enabled but not running"
        fi
    else
        echo -e "    ${DIM}○${NC} Snowflake   ${DIM}disabled${NC}"
    fi
}

cmd_donate_conduit_setup() {
    local env_file="$SCRIPT_DIR/.env"
    print_section "Psiphon Conduit Configuration"
    echo ""
    echo "  Donate bandwidth to Psiphon's relay network (millions of users worldwide)."
    echo ""

    local current_bw
    current_bw=$(get_env_val "CONDUIT_BANDWIDTH" "$env_file" "100")
    local current_clients
    current_clients=$(get_env_val "CONDUIT_MAX_COMMON_CLIENTS" "$env_file" "200")

    echo -e "  Current: ${WHITE}${current_bw} Mbps${NC}, ${WHITE}${current_clients}${NC} max clients"
    echo ""

    printf "  Bandwidth limit in Mbps (current: $current_bw): "
    read -r new_bw
    new_bw="${new_bw:-$current_bw}"

    printf "  Max concurrent clients (current: $current_clients): "
    read -r new_clients
    new_clients="${new_clients:-$current_clients}"

    # Update .env
    if grep -q "^CONDUIT_BANDWIDTH=" "$env_file" 2>/dev/null; then
        sed -i "s/^CONDUIT_BANDWIDTH=.*/CONDUIT_BANDWIDTH=$new_bw/" "$env_file"
    else
        echo "CONDUIT_BANDWIDTH=$new_bw" >> "$env_file"
    fi
    if grep -q "^CONDUIT_MAX_COMMON_CLIENTS=" "$env_file" 2>/dev/null; then
        sed -i "s/^CONDUIT_MAX_COMMON_CLIENTS=.*/CONDUIT_MAX_COMMON_CLIENTS=$new_clients/" "$env_file"
    else
        echo "CONDUIT_MAX_COMMON_CLIENTS=$new_clients" >> "$env_file"
    fi

    success "Updated: ${new_bw} Mbps, ${new_clients} max clients"

    # Restart to apply
    if confirm "Restart Conduit to apply changes?" "y"; then
        docker compose up -d psiphon-conduit 2>/dev/null
        success "Conduit restarted"
    else
        echo -e "  ${DIM}Run: docker compose up -d psiphon-conduit${NC}"
    fi
}

cmd_donate_snowflake_setup() {
    local env_file="$SCRIPT_DIR/.env"
    print_section "Tor Snowflake Configuration"
    echo ""
    echo "  Donate bandwidth to the Tor network as a Snowflake proxy."
    echo ""

    local current_bw
    current_bw=$(get_env_val "SNOWFLAKE_BANDWIDTH" "$env_file" "5")
    local current_cap
    current_cap=$(get_env_val "SNOWFLAKE_CAPACITY" "$env_file" "50")

    echo -e "  Current: ${WHITE}${current_bw} Mbps${NC}, ${WHITE}${current_cap}${NC} capacity"
    echo ""

    printf "  Bandwidth limit in Mbps (current: $current_bw): "
    read -r new_bw
    new_bw="${new_bw:-$current_bw}"

    printf "  Max concurrent clients (current: $current_cap): "
    read -r new_cap
    new_cap="${new_cap:-$current_cap}"

    # Update .env
    if grep -q "^SNOWFLAKE_BANDWIDTH=" "$env_file" 2>/dev/null; then
        sed -i "s/^SNOWFLAKE_BANDWIDTH=.*/SNOWFLAKE_BANDWIDTH=$new_bw/" "$env_file"
    else
        echo "SNOWFLAKE_BANDWIDTH=$new_bw" >> "$env_file"
    fi
    if grep -q "^SNOWFLAKE_CAPACITY=" "$env_file" 2>/dev/null; then
        sed -i "s/^SNOWFLAKE_CAPACITY=.*/SNOWFLAKE_CAPACITY=$new_cap/" "$env_file"
    else
        echo "SNOWFLAKE_CAPACITY=$new_cap" >> "$env_file"
    fi

    success "Updated: ${new_bw} Mbps, ${new_cap} capacity"

    # Restart to apply
    if confirm "Restart Snowflake to apply changes?" "y"; then
        docker compose up -d snowflake 2>/dev/null
        success "Snowflake restarted"
    else
        echo -e "  ${DIM}Run: docker compose up -d snowflake${NC}"
    fi
}

cmd_donate_conduit_info() {
    echo ""
    echo "  Psiphon Conduit generates a unique keypair when it first starts."
    echo "  The Ryve deep link below lets you claim this Conduit in the Ryve app"
    echo "  to monitor it and manage it from your phone."
    echo ""
    if [[ -x "$SCRIPT_DIR/scripts/conduit-info.sh" ]]; then
        "$SCRIPT_DIR/scripts/conduit-info.sh"
    else
        error "conduit-info.sh not found"
    fi
}

cmd_donate_status() {
    local env_file="$SCRIPT_DIR/.env"
    print_section "Donation Status"
    echo ""

    # MahsaNet
    local mahsa_key=""
    [[ -f "$env_file" ]] && mahsa_key=$(get_env_val "MAHSANET_API_KEY" "$env_file" "")
    echo -e "  ${WHITE}MahsaNet${NC}"
    if [[ -n "$mahsa_key" ]]; then
        cmd_donate_mahsanet_status "$mahsa_key" 2>/dev/null || echo -e "    ${YELLOW}○${NC} Could not fetch stats"
    else
        echo -e "    ${DIM}○ Not configured — run: moav donate setup${NC}"
    fi
    echo ""

    # Conduit
    local conduit_enabled
    conduit_enabled=$(get_env_val "ENABLE_CONDUIT" "$env_file" "true")
    local conduit_bw
    conduit_bw=$(get_env_val "CONDUIT_BANDWIDTH" "$env_file" "100")
    local conduit_clients
    conduit_clients=$(get_env_val "CONDUIT_MAX_COMMON_CLIENTS" "$env_file" "200")
    echo -e "  ${WHITE}Psiphon Conduit${NC}"
    if [[ "$conduit_enabled" == "true" ]]; then
        local conduit_running=""
        docker compose ps psiphon-conduit --status running 2>/dev/null | tail -n +2 | grep -q . && conduit_running="yes"
        if [[ -n "$conduit_running" ]]; then
            echo -e "    ${GREEN}✓${NC} Running — ${conduit_bw} Mbps, ${conduit_clients} max clients"
            local cm
            cm=$(_query_conduit_metrics 2>/dev/null)
            if [[ -n "$cm" ]]; then
                local c_conn c_up c_down
                c_conn=$(echo "$cm" | awk '{print $1}')
                c_up=$(echo "$cm" | awk '{print $2}')
                c_down=$(echo "$cm" | awk '{print $3}')
                echo -e "    Connected: ${CYAN}${c_conn}${NC} clients | Bandwidth: $(_format_bytes_sh "$c_up") ↑ / $(_format_bytes_sh "$c_down") ↓"
            fi
            echo -e "    ${DIM}Ryve link: moav donate info${NC}"
        else
            echo -e "    ${YELLOW}○${NC} Enabled but not running — start with: moav start conduit"
        fi
    else
        echo -e "    ${DIM}○ Disabled — enable in .env: ENABLE_CONDUIT=true${NC}"
    fi
    echo ""

    # Snowflake
    local snow_enabled
    snow_enabled=$(get_env_val "ENABLE_SNOWFLAKE" "$env_file" "true")
    local snow_bw
    snow_bw=$(get_env_val "SNOWFLAKE_BANDWIDTH" "$env_file" "5")
    local snow_cap
    snow_cap=$(get_env_val "SNOWFLAKE_CAPACITY" "$env_file" "50")
    echo -e "  ${WHITE}Tor Snowflake${NC}"
    if [[ "$snow_enabled" == "true" ]]; then
        local snow_running=""
        docker compose ps snowflake --status running 2>/dev/null | tail -n +2 | grep -q . && snow_running="yes"
        if [[ -n "$snow_running" ]]; then
            echo -e "    ${GREEN}✓${NC} Running — ${snow_bw} Mbps, ${snow_cap} capacity"
            local sm
            sm=$(_query_snowflake_metrics 2>/dev/null)
            if [[ -n "$sm" ]]; then
                local s_served s_up s_down
                s_served=$(echo "$sm" | awk '{print $1}')
                s_up=$(echo "$sm" | awk '{print $2}')
                s_down=$(echo "$sm" | awk '{print $3}')
                echo -e "    Served: ${CYAN}${s_served}${NC} people | Bandwidth: ${s_up} GB ↑ / ${s_down} GB ↓"
            else
                echo -e "    ${DIM}Stats unavailable — enable monitoring: moav start monitoring${NC}"
            fi
        else
            echo -e "    ${YELLOW}○${NC} Enabled but not running — start with: moav start snowflake"
        fi
    else
        echo -e "    ${DIM}○ Disabled — enable in .env: ENABLE_SNOWFLAKE=true${NC}"
    fi
}

cmd_donate() {
    local action="${1:-}"
    shift 1 2>/dev/null || shift $#

    case "$action" in
        setup|--setup)
            print_section "Donation Services Setup"
            echo ""
            echo "  1. MahsaNet     Configure API key for Mahsa VPN config donation"
            echo "  2. Conduit      Configure Psiphon bandwidth donation"
            echo "  3. Snowflake    Configure Tor bandwidth donation"
            echo ""
            printf "  Select service [1-3]: "
            read -r svc_choice
            case "$svc_choice" in
                1) cmd_donate_mahsanet_setup ;;
                2) cmd_donate_conduit_setup ;;
                3) cmd_donate_snowflake_setup ;;
                *) error "Invalid selection" ;;
            esac
            ;;
        list|--list)
            local key; key=$(_get_donate_api_key) || return 1
            cmd_donate_mahsanet_list "$key"
            ;;
        status|--status)
            cmd_donate_status
            ;;
        delete|--delete)
            local key; key=$(_get_donate_api_key) || return 1
            cmd_donate_mahsanet_delete "$key"
            ;;
        remove|--remove)
            local key; key=$(_get_donate_api_key) || return 1
            cmd_donate_mahsanet_remove "$key"
            ;;
        info|--info)
            cmd_donate_conduit_info
            ;;
        help|--help|-h)
            echo "Usage: moav donate [command]"
            echo ""
            echo "Donate VPN configs and bandwidth to help people bypass censorship."
            echo ""
            echo "Commands:"
            echo "  (none)     Interactive donation wizard"
            echo "  setup      Configure donation services (MahsaNet, Conduit, Snowflake)"
            echo "  status     Show all donation services status and stats"
            echo "  list       List donated MahsaNet configs"
            echo "  delete     Select and delete specific MahsaNet configs"
            echo "  remove     Remove all donated MahsaNet configs"
            echo "  info       Show Conduit Ryve deep link and QR code"
            echo "  help       Show this help"
            echo ""
            echo "Services:"
            echo "  MahsaNet     mahsaserver.com — Donate VPN configs to MahsaNet VPN (2M+ users)"
            echo "  Conduit      conduit.psiphon.ca — Donate bandwidth to Psiphon (millions of users)"
            echo "  Snowflake    snowflake.torproject.org — Donate bandwidth to Tor network"
            echo ""
            echo "Configuration (.env):"
            echo "  MAHSANET_API_KEY              API token from mahsaserver.com/user/api"
            echo "  CONDUIT_BANDWIDTH             Psiphon bandwidth limit in Mbps (default: 100)"
            echo "  CONDUIT_MAX_COMMON_CLIENTS    Max concurrent Conduit clients (default: 200)"
            echo "  SNOWFLAKE_BANDWIDTH           Tor bandwidth limit in Mbps (default: 5)"
            echo "  SNOWFLAKE_CAPACITY            Max concurrent Snowflake clients (default: 50)"
            ;;
        *)
            # Wizard flow
            print_section "Donate VPN Configs & Bandwidth"
            echo ""
            echo "  Services:"
            _show_donation_services
            echo ""

            echo "  Actions:"
            echo "    1. Donate VPN configs to MahsaNet"
            echo "    2. View donation status & stats"
            echo "    3. Configure donation services"
            echo "    4. View Conduit Ryve link"
            echo ""
            printf "  Select [1-4]: "
            read -r donate_choice

            case "$donate_choice" in
                1)
                    local api_key=""
                    [[ -f ".env" ]] && api_key=$(get_env_val "MAHSANET_API_KEY" ".env")
                    if [[ -z "$api_key" ]]; then
                        error "MahsaNet API key not configured"
                        echo -e "  Run ${CYAN}moav donate setup${NC} to configure."
                        return 1
                    fi
                    echo ""
                    cmd_donate_mahsanet_donate "$api_key"
                    ;;
                2) echo ""; cmd_donate_status ;;
                3) echo ""; cmd_donate setup ;;
                4) cmd_donate_conduit_info ;;
                *) info "Cancelled." ;;
            esac
            ;;
    esac
}

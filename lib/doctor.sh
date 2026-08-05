#!/bin/bash
# lib/doctor.sh — the diagnostic suite: every `doctor_check_*`, the DOCTOR_CHECKS
# registry that names them, and `moav doctor` itself.
#
# Checks are dispatched dynamically as "doctor_check_${check_name}" from the
# registry, so they are never called by literal name — worth knowing before
# concluding one is dead code.
#
# Sourced AFTER lib/nettune.sh and lib/peers.sh: doctor_check_net calls nt_*,
# and doctor_check_peers lives in lib/peers.sh.
#
# Definitions only — nothing here runs at source time.

doctor_check_net() {
    local rc=0
    nt_status || rc=$?
    # rc=2 → bundle not applied or kernel unsupported. Skip extended checks.
    [[ "$rc" -eq 2 ]] && return 2

    local pass=true
    [[ "$rc" -eq 1 ]] && pass=false
    nt_check_pmtu  || pass=false
    nt_check_drops || pass=false
    # CGNAT returns 2 (unknown — no route or RFC1918 without SERVER_IP), don't fail on that
    local cgnat=0; nt_check_cgnat || cgnat=$?
    [[ "$cgnat" -eq 1 ]] && pass=false
    nt_check_mtu   # informational only

    $pass && return 0 || return 1
}

doctor_is_enabled() {
    local value
    value=$(printf "%s" "${1:-}" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        true|1|yes|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

doctor_check_docker() {
    local pass=true

    # Docker daemon
    if command -v docker &>/dev/null; then
        local docker_ver
        docker_ver=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        if docker info &>/dev/null; then
            echo -e "    ${GREEN}✓${NC} Docker ${docker_ver} — running"
        else
            echo -e "    ${RED}✗${NC} Docker ${docker_ver} — daemon not running"
            echo -e "      ${DIM}Run: sudo systemctl start docker${NC}"
            pass=false
        fi
    else
        echo -e "    ${RED}✗${NC} Docker not installed"
        echo -e "      ${DIM}Install: curl -fsSL https://get.docker.com | sh${NC}"
        pass=false
    fi

    # Docker Compose
    if docker compose version &>/dev/null; then
        local compose_ver
        compose_ver=$(docker compose version --short 2>/dev/null)
        echo -e "    ${GREEN}✓${NC} Docker Compose ${compose_ver}"
    else
        echo -e "    ${RED}✗${NC} Docker Compose not found"
        pass=false
    fi

    # Docker disk usage (brief)
    local docker_usage
    docker_usage=$(docker system df --format '{{.Type}}\t{{.Size}}' 2>/dev/null)
    if [[ -n "$docker_usage" ]]; then
        local images_size containers_size volumes_size
        images_size=$(echo "$docker_usage" | grep "Images" | awk '{print $2}')
        volumes_size=$(echo "$docker_usage" | grep "Volumes" | awk '{print $2}')
        echo -e "    ${DIM}Docker disk: images=${images_size:-?}, volumes=${volumes_size:-?}${NC}"
    fi

    $pass && return 0 || return 1
}

doctor_check_memory() {
    local env_file="$SCRIPT_DIR/.env"

    # Get total and available memory in MB
    local total_mb available_mb
    total_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)
    available_mb=$(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)

    if [[ -z "$total_mb" ]]; then
        echo -e "    ${YELLOW}○${NC} Could not read /proc/meminfo"
        return 2
    fi

    local total_gb
    total_gb=$(awk "BEGIN {printf \"%.1f\", $total_mb/1024}")
    local avail_gb
    avail_gb=$(awk "BEGIN {printf \"%.1f\", $available_mb/1024}")
    local used_pct
    used_pct=$(awk "BEGIN {printf \"%.0f\", ($total_mb-$available_mb)/$total_mb*100}")

    echo -e "    RAM: ${WHITE}${total_gb} GB${NC} total, ${available_mb} MB available (${used_pct}% used)"

    # Surface swap status on low-RAM hosts — missing swap is the usual reason
    # image builds get OOM-killed on a small VPS.
    local swap_mb
    swap_mb=$(awk '/SwapTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    if [[ "$total_mb" -le 2560 ]] && [[ "${swap_mb:-0}" -eq 0 ]]; then
        echo -e "    ${YELLOW}○${NC} No swap configured — image builds may be OOM-killed on low RAM"
        echo -e "      ${DIM}Add 2 GB swap: fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile${NC}"
        echo -e "      ${DIM}…and persist: echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab${NC}"
        echo -e "      ${DIM}Or build with limited parallelism: MOAV_BUILD_PARALLEL=1 moav build${NC}"
    fi

    # Check monitoring enabled
    local monitoring_enabled
    monitoring_enabled=$(get_env_val "ENABLE_MONITORING" "$env_file" "false")

    if [[ "$total_mb" -lt 1024 ]]; then
        echo -e "    ${RED}✗${NC} Less than 1 GB RAM — MoaV may be unstable"
        echo -e "      ${DIM}Upgrade to at least 1 GB (2 GB with monitoring)${NC}"
        return 1
    elif [[ "$total_mb" -lt 2048 ]] && [[ "$monitoring_enabled" == "true" ]]; then
        echo -e "    ${YELLOW}○${NC} Less than 2 GB with monitoring enabled — may cause hangs"
        echo -e "      ${DIM}Upgrade to 2 GB+ or disable monitoring: ENABLE_MONITORING=false${NC}"
        return 1
    elif [[ "$available_mb" -lt 256 ]]; then
        echo -e "    ${RED}✗${NC} Very low available memory (${available_mb} MB)"
        echo -e "      ${DIM}Check for memory leaks: docker stats --no-stream${NC}"
        return 1
    else
        echo -e "    ${GREEN}✓${NC} Memory OK"
        return 0
    fi
}

doctor_check_disk() {
    # Check root filesystem
    local disk_info
    disk_info=$(df -h / 2>/dev/null | tail -1)

    if [[ -z "$disk_info" ]]; then
        echo -e "    ${YELLOW}○${NC} Could not check disk space"
        return 2
    fi

    local total used avail pct
    total=$(echo "$disk_info" | awk '{print $2}')
    used=$(echo "$disk_info" | awk '{print $3}')
    avail=$(echo "$disk_info" | awk '{print $4}')
    pct=$(echo "$disk_info" | awk '{print $5}' | tr -d '%')

    echo -e "    Disk: ${WHITE}${total}${NC} total, ${avail} available (${pct}% used)"

    # Check /var/lib/docker separately if on different partition
    local docker_dir="/var/lib/docker"
    if [[ -d "$docker_dir" ]]; then
        local docker_disk
        docker_disk=$(df -h "$docker_dir" 2>/dev/null | tail -1)
        local docker_avail docker_pct
        docker_avail=$(echo "$docker_disk" | awk '{print $4}')
        docker_pct=$(echo "$docker_disk" | awk '{print $5}' | tr -d '%')
        # Only show if different from root
        local root_dev docker_dev
        root_dev=$(df / 2>/dev/null | tail -1 | awk '{print $1}')
        docker_dev=$(df "$docker_dir" 2>/dev/null | tail -1 | awk '{print $1}')
        if [[ "$root_dev" != "$docker_dev" ]]; then
            echo -e "    Docker: ${docker_avail} available (${docker_pct}% used)"
        fi
    fi

    # Thresholds
    local avail_mb
    avail_mb=$(df -m / 2>/dev/null | tail -1 | awk '{print $4}')

    if [[ "${avail_mb:-0}" -lt 1024 ]]; then
        echo -e "    ${RED}✗${NC} Less than 1 GB free disk space"
        echo -e "      ${DIM}Clean up: docker system prune -a --volumes${NC}"
        echo -e "      ${DIM}Find large files: apt install ncdu && ncdu /${NC}"
        return 1
    elif [[ "${avail_mb:-0}" -lt 2048 ]]; then
        echo -e "    ${YELLOW}○${NC} Less than 2 GB free — may run low with monitoring/logs"
        echo -e "      ${DIM}Check usage: ncdu / or docker system df -v${NC}"
        return 1
    else
        echo -e "    ${GREEN}✓${NC} Disk space OK"
        return 0
    fi
}

# Inspect container json-file logs and offer to truncate ones above a threshold.
# Pre-1.7.6 containers (and any container created before the x-logging anchor was
# applied) keep growing under Docker's unbounded default. Truncating in place
# zeros the file without disrupting the running service — Docker keeps writing
# to the same FD and the kernel reclaims the disk pages immediately.
doctor_check_logs() {
    local docker_dir="/var/lib/docker/containers"
    local sudo_prefix=""
    [[ $EUID -ne 0 ]] && sudo_prefix="sudo"

    if [[ ! -d "$docker_dir" ]]; then
        echo -e "    ${YELLOW}○${NC} ${docker_dir} not found (skipping log-size check)"
        return 2
    fi
    if ! $sudo_prefix test -r "$docker_dir" 2>/dev/null; then
        echo -e "    ${YELLOW}○${NC} Cannot read ${docker_dir} (need root)"
        return 2
    fi

    local threshold_mb=100
    # find -size +100M matches files strictly larger than 100 MB
    local oversized
    oversized=$($sudo_prefix find "$docker_dir" -maxdepth 2 -name '*-json.log' -size "+${threshold_mb}M" -printf '%s\t%p\n' 2>/dev/null | sort -rn)

    if [[ -z "$oversized" ]]; then
        echo -e "    ${GREEN}✓${NC} Container logs under ${threshold_mb} MB threshold"
        return 0
    fi

    # Build container ID → name map for nicer output
    declare -A name_map
    local map_line cid cname
    while IFS= read -r map_line; do
        cid=$(echo "$map_line" | awk '{print $1}')
        cname=$(echo "$map_line" | awk '{print $2}')
        [[ -n "$cid" ]] && name_map["$cid"]="$cname"
    done < <(docker ps -a --no-trunc --format '{{.ID}} {{.Names}}' 2>/dev/null || true)

    echo -e "    ${YELLOW}○${NC} Container logs over ${threshold_mb} MB (likely pre-rotation containers):"
    local count=0 total_bytes=0 size path id name size_mb
    while IFS=$'\t' read -r size path; do
        [[ -z "$size" ]] && continue
        ((count++)) || true
        total_bytes=$((total_bytes + size))
        id=$(basename "$(dirname "$path")")
        name="${name_map[$id]:-${id:0:12}}"
        size_mb=$((size / 1024 / 1024))
        echo -e "      ${DIM}${size_mb} MB  ${name}${NC}"
    done <<< "$oversized"

    local total_mb=$((total_bytes / 1024 / 1024))
    echo -e "    ${YELLOW}Total:${NC} ${total_mb} MB across ${count} log file(s)"

    # Only prompt when interactive (skip in cron / CI / piped doctor runs)
    if [[ ! -t 0 ]]; then
        echo -e "      ${DIM}Run interactively to truncate, or:${NC}"
        echo -e "      ${DIM}sudo truncate -s 0 /var/lib/docker/containers/*/*-json.log${NC}"
        return 1
    fi

    local confirm
    read -r -p "    Truncate these log files now? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "      ${DIM}Skipped. Manual: sudo truncate -s 0 /var/lib/docker/containers/*/*-json.log${NC}"
        return 1
    fi

    local truncated=0 failed=0
    while IFS=$'\t' read -r size path; do
        [[ -z "$path" ]] && continue
        if $sudo_prefix truncate -s 0 "$path" 2>/dev/null; then
            ((truncated++)) || true
        else
            ((failed++)) || true
        fi
    done <<< "$oversized"

    if [[ "$failed" -gt 0 ]]; then
        echo -e "    ${YELLOW}○${NC} Truncated ${truncated}/${count} log file(s); ${failed} failed (permission denied?)"
        return 1
    fi
    echo -e "    ${GREEN}✓${NC} Truncated ${truncated} log file(s) (~${total_mb} MB freed)"
    echo -e "      ${DIM}Tip: existing containers keep their old logging policy until recreated.${NC}"
    echo -e "      ${DIM}Run 'docker compose up -d --force-recreate' to apply the 10m × 3 rotation.${NC}"
    return 0
}

doctor_lookup_a_records() {
    local host="$1"

    if command -v dig >/dev/null 2>&1; then
        dig +short A "$host" 2>/dev/null | awk '/^[0-9]+\./ { print $1 }' | sort -u
        return 0
    fi

    if command -v getent >/dev/null 2>&1; then
        getent ahostsv4 "$host" 2>/dev/null | awk '{ print $1 }' | sort -u
        return 0
    fi

    if command -v host >/dev/null 2>&1; then
        host "$host" 2>/dev/null | awk '/ has address / { print $NF }' | sort -u
        return 0
    fi

    if command -v nslookup >/dev/null 2>&1; then
        nslookup "$host" 2>/dev/null | awk '
            /^Name: / { name_seen=1; next }
            name_seen && /^Address: / {
                gsub(/#.*/, "", $2)
                print $2
            }
        ' | awk '/^[0-9]+\./ { print $1 }' | sort -u
        return 0
    fi

    return 127
}

doctor_lookup_ns_records() {
    local host="$1"
    # Extract parent zone (e.g., t.bitchat.center -> bitchat.center)
    local parent_zone="${host#*.}"

    if command -v dig >/dev/null 2>&1; then
        # First try: query authoritative NS of parent zone
        # Subdomain NS delegation appears in AUTHORITY section, not ANSWER
        local auth_ns
        auth_ns=$(dig +short NS "$parent_zone" 2>/dev/null | head -1)
        if [[ -n "$auth_ns" ]]; then
            local result
            # Parse AUTHORITY section for NS records
            result=$(dig NS "$host" "@${auth_ns}" 2>/dev/null | awk '/^;; AUTHORITY SECTION:/,/^$/ { if ($4 == "NS") print $5 }' | sed 's/\.$//' | sed '/^$/d' | sort -u)
            if [[ -n "$result" ]]; then
                echo "$result"
                return 0
            fi
        fi
        # Fallback: try +short (works for zones where NS is in ANSWER section)
        dig +short NS "$host" 2>/dev/null | sed 's/\.$//' | sed '/^$/d' | sort -u
        return 0
    fi

    if command -v host >/dev/null 2>&1; then
        host -t NS "$host" 2>/dev/null | awk '/ name server / { print $NF }' | sed 's/\.$//' | sort -u
        return 0
    fi

    if command -v nslookup >/dev/null 2>&1; then
        nslookup -type=NS "$host" 2>/dev/null | awk -F' = ' '/nameserver = / { print $2 }' | sed 's/\.$//' | sort -u
        return 0
    fi

    return 127
}

doctor_lines_to_csv() {
    awk '
        NF {
            if (count++) {
                printf ", "
            }
            printf "%s", $0
        }
        END {
            if (count) {
                printf "\n"
            }
        }
    '
}

doctor_domainless_protocols() {
    local env_file="$1"
    local protocols=()

    if doctor_is_enabled "$(get_env_val "ENABLE_REALITY" "$env_file" "true")"; then
        protocols+=("Reality")
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_XHTTP" "$env_file" "true")"; then
        protocols+=("XHTTP")
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_WIREGUARD" "$env_file" "true")"; then
        protocols+=("WireGuard")
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_AMNEZIAWG" "$env_file" "true")"; then
        protocols+=("AmneziaWG")
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_TELEMT" "$env_file" "true")"; then
        protocols+=("Telegram MTProxy")
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_SS" "$env_file" "false")"; then
        protocols+=("Shadowsocks-2022")
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_ADMIN_UI" "$env_file" "true")"; then
        protocols+=("Admin Dashboard")
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_CONDUIT" "$env_file" "true")"; then
        protocols+=("Conduit")
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_SNOWFLAKE" "$env_file" "true")"; then
        protocols+=("Snowflake")
    fi

    if [[ ${#protocols[@]} -gt 0 ]]; then
        printf "%s\n" "${protocols[@]}" | doctor_lines_to_csv
    fi
}

doctor_check_a_record() {
    local label="$1"
    local host="$2"
    local expected_ip="$3"
    local remediation="$4"
    local resolved_ips=""

    if ! resolved_ips=$(doctor_lookup_a_records "$host"); then
        error "${label}: unable to query DNS for ${host}"
        echo "  Install 'dig', 'host', or 'nslookup', then rerun 'moav doctor dns'."
        return 1
    fi

    if [[ -z "$resolved_ips" ]]; then
        error "${label}: ${host} does not resolve"
        echo "  Fix: ${remediation}"
        return 1
    fi

    if printf "%s\n" "$resolved_ips" | grep -Fxq "$expected_ip"; then
        success "${label}: ${host} points to ${expected_ip}"
        return 0
    fi

    error "${label}: ${host} does not point to ${expected_ip}"
    echo "  Found: $(printf "%s\n" "$resolved_ips" | doctor_lines_to_csv)"
    echo "  Fix: ${remediation}"
    return 1
}

doctor_check_ns_record() {
    local label="$1"
    local host="$2"
    local expected_ns="$3"
    local remediation="$4"
    local resolved_ns=""

    if ! resolved_ns=$(doctor_lookup_ns_records "$host"); then
        error "${label}: unable to query NS records for ${host}"
        echo "  Install 'dig', 'host', or 'nslookup', then rerun 'moav doctor dns'."
        return 1
    fi

    if [[ -z "$resolved_ns" ]]; then
        error "${label}: ${host} has no NS delegation"
        echo "  Fix: ${remediation}"
        return 1
    fi

    if printf "%s\n" "$resolved_ns" | grep -Fxiq "$expected_ns"; then
        success "${label}: ${host} delegates to ${expected_ns}"
        return 0
    fi

    error "${label}: ${host} does not delegate to ${expected_ns}"
    echo "  Found: $(printf "%s\n" "$resolved_ns" | doctor_lines_to_csv)"
    echo "  Fix: ${remediation}"
    return 1
}

doctor_check_resolves() {
    local label="$1"
    local host="$2"
    local remediation="$3"
    local resolved_ips=""

    if ! resolved_ips=$(doctor_lookup_a_records "$host"); then
        error "${label}: unable to query DNS for ${host}"
        echo "  Install 'dig', 'host', or 'nslookup', then rerun 'moav doctor dns'."
        return 1
    fi

    if [[ -z "$resolved_ips" ]]; then
        error "${label}: ${host} does not resolve"
        echo "  Fix: ${remediation}"
        return 1
    fi

    success "${label}: ${host} resolves ($(printf "%s\n" "$resolved_ips" | doctor_lines_to_csv))"
    return 0
}

doctor_check_dns() {
    local env_file=".env"
    local failures=0
    local domain=""
    local server_ip=""
    local dnstt_enabled=false
    local slipstream_enabled=false
    local cdn_subdomain=""
    local cdn_domain=""
    local cdn_host=""

    if [[ ! -f "$env_file" ]]; then
        error ".env file not found"
        echo "  Run 'moav check' or copy '.env.example' to '.env' first."
        return 1
    fi

    domain=$(get_env_val "DOMAIN" "$env_file" "")
    if [[ -z "$domain" ]]; then
        warn "DOMAIN is empty; skipping DNS diagnostics (domainless mode)."
        local domainless_protocols=""
        domainless_protocols=$(doctor_domainless_protocols "$env_file")
        if [[ -n "$domainless_protocols" ]]; then
            echo "  Domainless-capable protocols enabled: ${domainless_protocols}"
        else
            echo "  No domainless-capable protocols are enabled in .env."
        fi
        return 2
    fi

    server_ip=$(get_env_val "SERVER_IP" "$env_file" "")
    if [[ -z "$server_ip" ]]; then
        server_ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)
        if [[ -n "$server_ip" ]]; then
            warn "SERVER_IP is empty in .env; using detected public IP for comparison: ${server_ip}"
        else
            error "SERVER_IP is empty and public IP detection failed"
            echo "  Set SERVER_IP in .env so A records can be verified."
            failures=$((failures + 1))
        fi
    else
        info "Expected server IP: ${server_ip}"
    fi

    if [[ -n "$server_ip" ]]; then
        if ! doctor_check_a_record "Main A record" "$domain" "$server_ip" "set A @ -> ${server_ip} (DNS only)"; then
            failures=$((failures + 1))
        fi
    fi

    if doctor_is_enabled "$(get_env_val "ENABLE_DNSTT" "$env_file" "true")"; then
        dnstt_enabled=true
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_SLIPSTREAM" "$env_file" "true")"; then
        slipstream_enabled=true
    fi

    local xdns_pre_enabled=""
    xdns_pre_enabled=$(get_env_val "ENABLE_XDNS" "$env_file" "true")

    local masterdns_pre_enabled=""
    masterdns_pre_enabled=$(get_env_val "ENABLE_MASTERDNS" "$env_file" "true")

    if [[ "$dnstt_enabled" == "true" || "$slipstream_enabled" == "true" || "$masterdns_pre_enabled" == "true" || "$xdns_pre_enabled" == "true" ]]; then
        local dns_host="dns.${domain}"
        if [[ -n "$server_ip" ]]; then
            if ! doctor_check_a_record "DNS nameserver A record" "$dns_host" "$server_ip" "set A dns -> ${server_ip} (DNS only)"; then
                failures=$((failures + 1))
            fi
        else
            warn "Skipping dns.${domain} A record comparison until SERVER_IP is configured."
        fi

        if [[ "$dnstt_enabled" == "true" ]]; then
            local dnstt_subdomain=""
            dnstt_subdomain=$(get_env_val "DNSTT_SUBDOMAIN" "$env_file" "t")
            if ! doctor_check_ns_record "dnstt NS record" "${dnstt_subdomain}.${domain}" "$dns_host" "set NS ${dnstt_subdomain} -> ${dns_host}"; then
                failures=$((failures + 1))
            fi
        fi

        if [[ "$slipstream_enabled" == "true" ]]; then
            local slipstream_subdomain=""
            slipstream_subdomain=$(get_env_val "SLIPSTREAM_SUBDOMAIN" "$env_file" "s")
            if ! doctor_check_ns_record "Slipstream NS record" "${slipstream_subdomain}.${domain}" "$dns_host" "set NS ${slipstream_subdomain} -> ${dns_host}"; then
                failures=$((failures + 1))
            fi
        fi

        local masterdns_enabled=""
        masterdns_enabled=$(get_env_val "ENABLE_MASTERDNS" "$env_file" "true")
        if [[ "$masterdns_enabled" == "true" ]]; then
            local masterdns_subdomain masterdns_public_sub
            masterdns_subdomain=$(get_env_val "MASTERDNS_SUBDOMAIN" "$env_file" "m")
            masterdns_public_sub=$(get_env_val "MASTERDNS_PUBLIC_SUBDOMAIN" "$env_file" "")
            if ! doctor_check_ns_record "MasterDNS NS record" "${masterdns_subdomain}.${domain}" "$dns_host" "set NS ${masterdns_subdomain} -> ${dns_host}"; then
                failures=$((failures + 1))
            fi
            # dns-router still serves the base subdomain and pre-existing bundles use it,
            # so when a public alias is set both delegations must exist
            if [[ -n "$masterdns_public_sub" && "$masterdns_public_sub" != "$masterdns_subdomain" ]]; then
                if ! doctor_check_ns_record "MasterDNS public NS record" "${masterdns_public_sub}.${domain}" "$dns_host" "set NS ${masterdns_public_sub} -> ${dns_host}"; then
                    failures=$((failures + 1))
                fi
            fi
        fi

        local xdns_enabled=""
        xdns_enabled=$(get_env_val "ENABLE_XDNS" "$env_file" "true")
        if [[ "$xdns_enabled" == "true" ]]; then
            local xdns_subdomain=""
            xdns_subdomain=$(get_env_val "XDNS_SUBDOMAIN" "$env_file" "x")
            if ! doctor_check_ns_record "XDNS NS record" "${xdns_subdomain}.${domain}" "$dns_host" "set NS ${xdns_subdomain} -> ${dns_host}"; then
                failures=$((failures + 1))
            fi
        fi
    else
        info "DNS tunnel checks skipped: dnstt, Slipstream, MasterDNS, and XDNS are all disabled."
    fi

    cdn_subdomain=$(get_env_val "CDN_SUBDOMAIN" "$env_file" "")
    cdn_domain=$(get_env_val "CDN_DOMAIN" "$env_file" "")
    if [[ -n "$cdn_subdomain" ]]; then
        cdn_host="${cdn_subdomain}.${domain}"
    elif [[ -n "$cdn_domain" ]]; then
        cdn_host="$cdn_domain"
    fi

    if [[ -n "$cdn_host" ]]; then
        if ! doctor_check_resolves "CDN endpoint" "$cdn_host" "create or fix the CDN DNS entry for ${cdn_host}"; then
            failures=$((failures + 1))
        fi
    else
        info "CDN check skipped: CDN_SUBDOMAIN/CDN_DOMAIN is not configured."
    fi

    if [[ $failures -gt 0 ]]; then
        echo ""
        echo "See https://moav.sh/docs/DNS for record templates and provider-specific examples."
        # Generate zone file for easy import
        local zone_file
        zone_file=$(generate_dns_zone_file 2>/dev/null)
        if [[ -n "$zone_file" ]] && [[ -f "$zone_file" ]]; then
            echo ""
            success "DNS zone file saved to: $zone_file"
            echo -e "  ${DIM}Import into Cloudflare: DNS > Records > Import and Upload${NC}"
            echo ""
            if confirm "Show zone file contents?" "y"; then
                echo ""
                cat "$zone_file"
                echo ""
            fi
        fi
        return 1
    fi

    # Generate zone file even on success (for reference)
    generate_dns_zone_file >/dev/null 2>&1

    return 0
}

doctor_check_services() {
    local env_file="$SCRIPT_DIR/.env"
    local pass=true

    # Map of ENABLE_* vars to service names
    local -A service_map=(
        ["ENABLE_REALITY"]="sing-box"
        ["ENABLE_SS"]="sing-box"
        ["ENABLE_XHTTP"]="xray"
        ["ENABLE_WIREGUARD"]="wireguard"
        ["ENABLE_AMNEZIAWG"]="amneziawg"
        ["ENABLE_TELEMT"]="telemt"
        ["ENABLE_DNSTT"]="dnstt"
        ["ENABLE_SLIPSTREAM"]="slipstream"
        ["ENABLE_TRUSTTUNNEL"]="trusttunnel"
        ["ENABLE_CONDUIT"]="psiphon-conduit"
        ["ENABLE_SNOWFLAKE"]="snowflake"
    )

    local running_services
    running_services=$(docker compose ps --services --filter "status=running" 2>/dev/null || echo "")
    local restarting_services
    restarting_services=$(docker compose ps --services --filter "status=restarting" 2>/dev/null || echo "")

    for enable_var in "${!service_map[@]}"; do
        local svc="${service_map[$enable_var]}"
        local enabled
        enabled=$(get_env_val "$enable_var" "$env_file" "true")

        if [[ "$enabled" == "true" ]]; then
            if echo "$restarting_services" | grep -qw "$svc"; then
                echo -e "    ${RED}✗${NC} $svc — enabled but crash-looping (restarting)"
                echo -e "      ${DIM}Check logs: moav logs $svc${NC}"
                pass=false
            elif echo "$running_services" | grep -qw "$svc"; then
                echo -e "    ${GREEN}✓${NC} $svc — running"
            else
                echo -e "    ${YELLOW}○${NC} $svc — enabled but not running"
                echo -e "      ${DIM}Start with: moav start${NC}"
                pass=false
            fi
        fi
    done

    $pass && return 0 || return 1
}

doctor_check_config() {
    local pass=true
    local env_file="$SCRIPT_DIR/.env"

    # Check bootstrap has been run
    local bootstrapped=false
    docker run --rm -v moav_moav_state:/state alpine test -f /state/.bootstrapped 2>/dev/null && bootstrapped=true

    if [[ "$bootstrapped" != "true" ]]; then
        echo -e "    ${RED}✗${NC} Bootstrap has not been run"
        echo -e "      ${DIM}Run: moav bootstrap${NC}"
        return 1
    fi
    echo -e "    ${GREEN}✓${NC} Bootstrap completed"

    # Check config files for enabled services
    local -A config_files=(
        ["ENABLE_REALITY"]="configs/sing-box/config.json"
        ["ENABLE_XHTTP"]="configs/xray/config.json"
        ["ENABLE_WIREGUARD"]="configs/wireguard/wg0.conf"
        ["ENABLE_AMNEZIAWG"]="configs/amneziawg/awg0.conf"
        ["ENABLE_TELEMT"]="configs/telemt/config.toml"
    )

    for enable_var in "${!config_files[@]}"; do
        local enabled
        enabled=$(get_env_val "$enable_var" "$env_file" "true")
        local config="${config_files[$enable_var]}"
        local svc_name="${config%%/*}"
        svc_name="${svc_name#configs/}"

        if [[ "$enabled" == "true" ]]; then
            if [[ -f "$SCRIPT_DIR/$config" ]]; then
                echo -e "    ${GREEN}✓${NC} $config exists"
            else
                echo -e "    ${RED}✗${NC} $config missing"
                echo -e "      ${DIM}Run: moav bootstrap${NC}"
                pass=false
            fi
        fi
    done

    # Check state keys
    local keys_exist=false
    docker run --rm -v moav_moav_state:/state alpine test -d /state/keys 2>/dev/null && keys_exist=true
    if [[ "$keys_exist" == "true" ]]; then
        echo -e "    ${GREEN}✓${NC} State keys directory exists"
    else
        echo -e "    ${RED}✗${NC} State keys missing"
        echo -e "      ${DIM}Run: moav bootstrap${NC}"
        pass=false
    fi

    # Per-service state key checks: ENABLE_X=true but keys missing = service will crash-loop
    # Each entry: "ENABLE_VAR:service_name:key_path1,key_path2,..."
    local state_key_specs=(
        "ENABLE_DNSTT:dnstt:/state/keys/dnstt-server.key.hex,/state/keys/dnstt-server.pub.hex"
        "ENABLE_SLIPSTREAM:slipstream:/state/keys/slipstream-cert.pem,/state/keys/slipstream-key.pem"
        "ENABLE_WIREGUARD:wireguard:/state/keys/wg-server.key,/state/keys/wg-server.pub"
        "ENABLE_AMNEZIAWG:amneziawg:/state/keys/awg-server.key,/state/keys/awg-server.pub"
    )
    for spec in "${state_key_specs[@]}"; do
        local var="${spec%%:*}"
        local rest="${spec#*:}"
        local svc="${rest%%:*}"
        local paths="${rest#*:}"
        local default="true"
        [[ "$var" == "ENABLE_XDNS" ]] && default="true"
        local enabled
        enabled=$(get_env_val "$var" "$env_file" "$default")
        [[ "$enabled" != "true" ]] && continue

        local missing=""
        IFS=',' read -ra path_list <<< "$paths"
        for p in "${path_list[@]}"; do
            if ! docker run --rm -v moav_moav_state:/state alpine test -f "$p" 2>/dev/null; then
                missing+="${p##*/} "
            fi
        done
        if [[ -n "$missing" ]]; then
            echo -e "    ${RED}✗${NC} $svc enabled but missing key(s): ${missing% }"
            echo -e "      ${DIM}Run: moav bootstrap   (regenerates missing keys idempotently)${NC}"
            pass=false
        else
            echo -e "    ${GREEN}✓${NC} $svc keys present"
        fi
    done

    $pass && return 0 || return 1
}

doctor_check_ports() {
    local env_file="$SCRIPT_DIR/.env"
    local pass=true

    # Service -> port mappings
    local -A port_map=(
        ["sing-box"]="$(get_env_val 'PORT_REALITY' "$env_file" '443')"
        ["xray"]="$(get_env_val 'PORT_XHTTP' "$env_file" '2096')"
        ["wireguard"]="$(get_env_val 'PORT_WIREGUARD' "$env_file" '51820')"
        ["amneziawg"]="$(get_env_val 'PORT_AMNEZIAWG' "$env_file" '51821')"
        ["telemt"]="$(get_env_val 'PORT_TELEMT' "$env_file" '993')"
        ["trusttunnel"]="$(get_env_val 'PORT_TRUSTTUNNEL' "$env_file" '4443')"
        ["admin"]="$(get_env_val 'PORT_ADMIN' "$env_file" '9443')"
        ["grafana"]="$(get_env_val 'PORT_GRAFANA' "$env_file" '9444')"
    )

    # Check port 53 availability for any enabled DNS tunnel
    local dnstt_enabled slip_enabled xdns_enabled masterdns_enabled
    dnstt_enabled=$(get_env_val "ENABLE_DNSTT" "$env_file" "true")
    slip_enabled=$(get_env_val "ENABLE_SLIPSTREAM" "$env_file" "true")
    masterdns_enabled=$(get_env_val "ENABLE_MASTERDNS" "$env_file" "true")
    xdns_enabled=$(get_env_val "ENABLE_XDNS" "$env_file" "true")

    if [[ "$dnstt_enabled" == "true" || "$slip_enabled" == "true" || "$masterdns_enabled" == "true" || "$xdns_enabled" == "true" ]]; then
        if port53_conflict_detected; then
            if systemctl is-active systemd-resolved &>/dev/null; then
                echo -e "    ${RED}✗${NC} Port 53 in use by systemd-resolved (DNS tunnels need it)"
                echo -e "      ${DIM}Run: moav setup-dns${NC}"
                pass=false
            else
                echo -e "    ${YELLOW}○${NC} Port 53 in use — DNS tunnels may fail to bind"
            fi
        elif ss -ulnp 2>/dev/null | grep -q ':53 ' || netstat -ulnp 2>/dev/null | grep -q ':53 '; then
            echo -e "    ${GREEN}✓${NC} Port 53 bound by MoaV dns-router"
        else
            echo -e "    ${GREEN}✓${NC} Port 53 available for DNS tunnels"
        fi
    fi

    # Check key service ports
    for svc in "${!port_map[@]}"; do
        local port="${port_map[$svc]}"
        if ss -tlnp 2>/dev/null | grep -q ":${port} " || ss -ulnp 2>/dev/null | grep -q ":${port} "; then
            echo -e "    ${GREEN}✓${NC} Port $port ($svc) — listening"
        else
            echo -e "    ${DIM}○${NC} Port $port ($svc) — not listening"
        fi
    done

    $pass && return 0 || return 1
}

doctor_check_conflicts() {
    local pass=true
    local enabled running
    enabled=$(dns_tunnels_enabled)
    running=$(dns_tunnels_running)

    # 1) Report enabled tunnels (all can coexist via dns-router)
    if [[ -n "$enabled" ]]; then
        echo -e "    ${GREEN}✓${NC} DNS tunnel(s) enabled: $enabled"
    else
        echo -e "    ${DIM}○${NC} No DNS tunnel enabled"
    fi

    # 2) Config vs runtime drift: a disabled tunnel has containers running
    for t in $running; do
        if ! echo " $enabled " | grep -q " $t "; then
            local svcs
            svcs=$(dns_tunnel_field "$t" services)
            echo -e "    ${YELLOW}!${NC} $t is running but disabled in .env"
            echo -e "      ${DIM}Stop: docker compose stop $svcs${NC}"
            pass=false
        fi
    done

    # 4) dns-router crash loop — port 53 taken by another process, or misconfigured backend
    local restarting
    restarting=$(docker compose ps --services --filter "status=restarting" 2>/dev/null || echo "")
    if echo "$restarting" | grep -qw "dns-router"; then
        echo -e "    ${RED}✗${NC} dns-router is crash-looping"
        echo -e "      ${DIM}Check: port 53 may be taken by another process, or a *_DOMAIN env var is unset${NC}"
        echo -e "      ${DIM}Fix: moav doctor env — then docker compose logs dns-router${NC}"
        pass=false
    fi

    $pass && return 0 || return 1
}

# Reality dest reachability (#115). Uses the container's resolver (matches what
# Reality sees at handshake); falls back to host resolver when container down.
doctor_check_reality() {
    local env_file="$SCRIPT_DIR/.env"
    local enable_reality enable_xhttp
    enable_reality=$(get_env_val "ENABLE_REALITY" "$env_file" "true")
    enable_xhttp=$(get_env_val "ENABLE_XHTTP" "$env_file" "true")

    if [[ "$enable_reality" != "true" && "$enable_xhttp" != "true" ]]; then
        echo -e "    ${DIM}○${NC} Reality and XHTTP-Reality both disabled — skipping"
        return 2
    fi

    local pass=true
    _doctor_reality_tcp_probe() {
        local container="$1" host="$2" port="$3"
        docker compose exec -T "$container" sh -s -- "$host" "$port" <<'EOF'
host="$1"
port="$2"

if command -v nc >/dev/null 2>&1 && nc -z -w 5 "$host" "$port" >/dev/null 2>&1; then
    exit 0
fi

if command -v curl >/dev/null 2>&1 && curl -k -IsS --connect-timeout 5 --max-time 8 "https://$host:$port/" >/dev/null 2>&1; then
    exit 0
fi

if command -v bash >/dev/null 2>&1 && timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1; then
    exit 0
fi

exit 1
EOF
    }

    _doctor_reality_one() {
        local label="$1" container="$2" key="$3" default_target="$4"
        local host_port host port resolver_label resolves=false container_running=false
        host_port=$(get_env_val "$key" "$env_file" "$default_target")
        host="${host_port%%:*}"
        port="${host_port##*:}"
        [[ "$port" == "$host_port" ]] && port=443  # no `:port` in value

        if docker compose ps --status running --services 2>/dev/null | grep -qw "$container"; then
            container_running=true
            resolver_label="container $container"
            if docker compose exec -T "$container" getent hosts "$host" >/dev/null 2>&1; then
                resolves=true
            fi
        else
            resolver_label="host (container $container not running)"
            reality_target_resolves "$host" && resolves=true
        fi

        if [[ "$resolves" != "true" ]]; then
            echo -e "    ${RED}✗${NC} $label: $host does NOT resolve ($resolver_label)"
            echo -e "      ${DIM}NXDOMAIN — Reality fallback fails, inbound RSTs every TLS hello (issue #115).${NC}"
            echo -e "      ${DIM}Fix: set $key in .env to a resolvable host. See: moav doctor reality --help${NC}"
            pass=false
            return
        fi

        if [[ "$container_running" == "true" ]]; then
            if _doctor_reality_tcp_probe "$container" "$host" "$port"; then
                echo -e "    ${GREEN}✓${NC} $label: $host:$port resolves and reachable from $container"
            else
                echo -e "    ${YELLOW}!${NC} $label: $host resolves but TCP $port unreachable from $container"
                echo -e "      ${DIM}Reality fallback will hang or RST. Check container egress / VPS firewall.${NC}"
                pass=false
            fi
        else
            echo -e "    ${GREEN}✓${NC} $label: $host resolves ($resolver_label, TCP probe skipped)"
        fi
    }

    [[ "$enable_reality" == "true" ]] && _doctor_reality_one "VLESS Reality (:443)" "sing-box" "REALITY_TARGET" "www.cloudflare.com:443"
    [[ "$enable_xhttp"    == "true" ]] && _doctor_reality_one "XHTTP-Reality (:2096)" "xray" "XHTTP_REALITY_TARGET" "www.cloudflare.com:443"

    # state<->config short_id desync guard (E4-4). The short_id lives in state;
    # if a render read an empty .env-injected value instead, config.json ships
    # an empty short_id and EVERY Reality client is rejected with no error
    # anywhere (PR #152 class). Compare the rendered config against state.
    if [[ "$enable_reality" == "true" ]]; then
        local rcfg="$SCRIPT_DIR/configs/sing-box/config.json" state_sid=""
        state_sid=$(docker run --rm -v moav_moav_state:/state alpine sh -c \
            'grep "^REALITY_SHORT_ID=" /state/keys/reality.env 2>/dev/null | cut -d= -f2-' 2>/dev/null | tr -d '\r\n ')
        if [[ -n "$state_sid" && -f "$rcfg" ]]; then
            if grep -qF -- "$state_sid" "$rcfg"; then
                echo -e "    ${GREEN}✓${NC} Reality short_id in config.json matches state"
            else
                echo -e "    ${RED}✗${NC} Reality short_id from state is ABSENT in config.json"
                echo -e "      ${DIM}config↔state desync — every Reality client is rejected (issue class of PR #152).${NC}"
                echo -e "      ${DIM}Fix: moav bootstrap (re-renders sing-box from state).${NC}"
                pass=false
            fi
        fi
    fi

    unset -f _doctor_reality_tcp_probe
    unset -f _doctor_reality_one
    $pass && return 0 || return 1
}

doctor_check_env() {
    local env_file="$SCRIPT_DIR/.env"
    local example_file="$SCRIPT_DIR/.env.example"
    local pass=true

    if [[ ! -f "$env_file" ]]; then
        echo -e "    ${RED}✗${NC} .env file not found"
        echo -e "      ${DIM}Run: cp .env.example .env${NC}"
        return 1
    fi

    if [[ ! -f "$example_file" ]]; then
        echo -e "    ${YELLOW}○${NC} .env.example not found — skipping comparison"
        return 2
    fi

    # Extract variable names from .env.example (skip comments and empty lines)
    local missing=0
    local total=0
    local critical_missing=()

    # Critical variables that should always be set
    local critical_vars=("ADMIN_PASSWORD" "DOMAIN" "SERVER_IP")

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue
        [[ ! "$line" =~ = ]] && continue

        local var_name="${line%%=*}"
        var_name=$(echo "$var_name" | xargs)  # trim whitespace
        [[ -z "$var_name" ]] && continue

        total=$((total + 1))

        if ! grep -q "^${var_name}=" "$env_file" 2>/dev/null; then
            missing=$((missing + 1))
            # Check if critical
            for cv in "${critical_vars[@]}"; do
                if [[ "$var_name" == "$cv" ]]; then
                    critical_missing+=("$var_name")
                fi
            done
        fi
    done < "$example_file"

    if [[ ${#critical_missing[@]} -gt 0 ]]; then
        for cv in "${critical_missing[@]}"; do
            echo -e "    ${RED}✗${NC} Missing critical variable: $cv"
        done
        pass=false
    fi

    if [[ $missing -gt 0 ]]; then
        echo -e "    ${YELLOW}○${NC} $missing of $total variables from .env.example not in .env"
        echo -e "      ${DIM}New variables use defaults. Review with: diff <(grep -o '^[A-Z_]*=' .env.example | sort) <(grep -o '^[A-Z_]*=' .env | sort)${NC}"
    else
        echo -e "    ${GREEN}✓${NC} All $total variables from .env.example present in .env"
    fi

    $pass && return 0 || return 1
}

doctor_check_updates() {
    local current_version
    current_version=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")

    echo -e "    Current version: ${WHITE}v${current_version}${NC}"

    # Check latest version from GitHub
    local latest
    latest=$(curl -sf --max-time 5 "https://api.github.com/repos/MotherofallVPNs/moav/releases/latest" 2>/dev/null | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4 | sed 's/^v//')

    if [[ -z "$latest" ]]; then
        echo -e "    ${YELLOW}○${NC} Could not check for updates (no internet or GitHub unreachable)"
        return 2
    fi

    if [[ "$current_version" == "$latest" ]]; then
        echo -e "    ${GREEN}✓${NC} Up to date (v${latest})"
        return 0
    elif version_gt "$latest" "$current_version"; then
        echo -e "    ${YELLOW}○${NC} Update available: v${latest} (current: v${current_version})"
        echo -e "      ${DIM}Run: moav update${NC}"
        return 1
    else
        # Running ahead of the latest published release — e.g. a dev/pre-release
        # build, or the latest GitHub release tag lags the shipped VERSION.
        echo -e "    ${GREEN}✓${NC} Running v${current_version} (ahead of latest release v${latest})"
        return 0
    fi
}

# Registry of diagnostic checks: "<name>:<description>" -> doctor_check_<name>.
# Lives with cmd_doctor (it was briefly carried along by the nettune extraction).
DOCTOR_CHECKS=(
    "docker:Check Docker and prerequisites"
    "memory:Check available RAM"
    "disk:Check available disk space"
    "logs:Check container log file sizes (offers to truncate oversized)"
    "dns:Check DNS records for enabled protocols"
    "services:Check running services vs enabled config"
    "config:Check config files and keys from bootstrap"
    "ports:Check required ports are available"
    "conflicts:Check for conflicting services (e.g. DNS tunnels on port 53)"
    "reality:Check Reality fallback targets resolve and are reachable"
    "net:Check BBR/sysctl tuning + packet drops + PMTU + CGNAT + MTU"
    "peers:Check for duplicate WireGuard/AmneziaWG peer addresses (--fix repairs)"
    "env:Compare .env with .env.example for missing vars"
    "updates:Check for MoaV updates"
)

cmd_doctor() {
    local requested_check="${1:-}"
    # `moav doctor peers --fix [--yes]` — the only check that can repair what
    # it finds. Deliberately not a blanket `doctor --fix`: the repair rotates
    # peer addresses and keys, which invalidates those users' existing bundles.
    if [[ "$requested_check" == "peers" ]] && [[ "${2:-}" == "--fix" ]]; then
        print_section "Repair duplicate peer addresses"
        peers_report || true
        peers_repair "${3:-}"
        return $?
    fi
    local selected_checks=()
    local check_spec=""
    local check_name=""
    local check_desc=""
    local found=false
    local passed=0
    local failed=0
    local skipped=0
    local rc=0

    case "$requested_check" in
        help|--help|-h)
            echo "Usage: moav doctor [check]"
            echo ""
            echo "Run MoaV diagnostic checks."
            echo ""
            echo "Checks:"
            for check_spec in "${DOCTOR_CHECKS[@]}"; do
                check_name="${check_spec%%:*}"
                check_desc="${check_spec#*:}"
                printf "  %-12s %s\n" "$check_name" "$check_desc"
            done
            echo ""
            echo "Examples:"
            echo "  moav doctor"
            echo "  moav doctor dns"
            return 0
            ;;
    esac

    for check_spec in "${DOCTOR_CHECKS[@]}"; do
        check_name="${check_spec%%:*}"
        if [[ -z "$requested_check" || "$requested_check" == "all" || "$requested_check" == "$check_name" ]]; then
            selected_checks+=("$check_spec")
        fi
        if [[ -n "$requested_check" && "$requested_check" == "$check_name" ]]; then
            found=true
        fi
    done

    if [[ -n "$requested_check" && "$requested_check" != "all" && "$found" != "true" ]]; then
        error "Unknown doctor check: ${requested_check}"
        echo ""
        cmd_doctor --help
        return 1
    fi

    print_section "MoaV Doctor"
    info "Running ${#selected_checks[@]} diagnostic check(s)..."

    for check_spec in "${selected_checks[@]}"; do
        check_name="${check_spec%%:*}"
        check_desc="${check_spec#*:}"

        echo ""
        echo -e "${WHITE}${check_name}${NC} - ${check_desc}"

        if "doctor_check_${check_name}"; then
            passed=$((passed + 1))
        else
            rc=$?
            case "$rc" in
                2)
                    skipped=$((skipped + 1))
                    ;;
                *)
                    failed=$((failed + 1))
                    ;;
            esac
        fi
    done

    echo ""
    print_section "Doctor Summary"
    success "${passed} check(s) passed"
    if [[ $skipped -gt 0 ]]; then
        warn "${skipped} check(s) skipped"
    fi
    if [[ $failed -gt 0 ]]; then
        error "${failed} check(s) failed"
        return 1
    fi

    success "Doctor completed without failures."
}

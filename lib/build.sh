#!/bin/bash
# lib/build.sh — building the container images: the compose build wrapper,
# `moav build` (including `--local`, which builds the monitoring images from
# source instead of pulling them), the local-build info banner, and the
# interactive build-services picker.
#
# Sourced by moav.sh after lib/common.sh.
#
# Definitions only — nothing here runs at source time.

build_services() {
    print_section "Build Services"

    # Get all available services from compose
    local all_services
    all_services=$(docker compose --profile all config --services 2>/dev/null | sort)

    echo "Build options:"
    echo ""
    echo -e "  ${WHITE}a)${NC} Build all services"
    echo -e "  ${WHITE}n)${NC} Build all (no cache)"

    if [[ -n "$all_services" ]]; then
        echo ""
        echo "Build specific service:"
        local i=1
        local services_array=()
        while IFS= read -r svc; do
            [[ -z "$svc" ]] && continue
            services_array+=("$svc")
            echo -e "  ${WHITE}$i)${NC} $svc"
            ((i++))
        done <<< "$all_services"
    fi

    echo ""
    echo -e "  ${WHITE}0)${NC} Cancel"
    echo ""

    prompt "Choice: "
    read -r choice < /dev/tty 2>/dev/null || choice=""

    case $choice in
        a|A)
            echo ""
            info "Building all services..."
            compose_build --profile all build
            success "Build complete!"
            ;;
        n|N)
            echo ""
            info "Building all services (no cache)..."
            compose_build --profile all build --no-cache
            success "Build complete!"
            ;;
        0|"")
            return 0
            ;;
        [1-9]*)
            local idx=$((choice - 1))
            if [[ $idx -ge 0 && $idx -lt ${#services_array[@]} ]]; then
                local service="${services_array[$idx]}"
                echo ""
                info "Building $service..."
                compose_build build "$service"
                success "$service built!"
            else
                warn "Invalid choice"
            fi
            ;;
        *)
            warn "Invalid choice"
            ;;
    esac
}

compose_build() {
    local total_mb limit
    total_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)

    if [[ -n "${MOAV_BUILD_PARALLEL:-}" ]]; then
        limit="$MOAV_BUILD_PARALLEL"
    elif [[ "$total_mb" -gt 0 && "$total_mb" -le 3072 ]]; then
        limit=1          # <=3GB: serial — one heavy Go compile at a time
    elif [[ "$total_mb" -gt 0 && "$total_mb" -le 6144 ]]; then
        limit=2          # 3-6GB: two at a time
    else
        limit=0          # >6GB or unknown: leave Docker defaults (bake/parallel)
    fi

    if [[ "$limit" =~ ^[0-9]+$ ]] && [[ "$limit" -ge 1 ]]; then
        # COMPOSE_BAKE=false selects the classic builder that honors
        # COMPOSE_PARALLEL_LIMIT; the bake builder ignores it and parallelizes.
        info "Build concurrency limited to ${limit} (RAM ${total_mb}MB; set MOAV_BUILD_PARALLEL=N to override)" >&2
        COMPOSE_BAKE=false COMPOSE_PARALLEL_LIMIT="$limit" docker compose "$@"
    else
        docker compose "$@"
    fi
}

cmd_build() {
    local no_cache=""
    local build_local=""
    local services_args=()

    # Parse arguments
    for arg in "$@"; do
        case "$arg" in
            --no-cache) no_cache="--no-cache" ;;
            --local) build_local="true" ;;
            *) services_args+=("$arg") ;;
        esac
    done

    # Check if .env exists
    if [[ ! -f ".env" ]]; then
        echo ""
        warn "No .env file found. Build may fail or show warnings about missing variables."
        echo ""
        echo "  You have two options:"
        echo -e "    1. Run ${CYAN}moav bootstrap${NC} first to set up configuration"
        echo "    2. Copy .env.example to .env and configure manually"
        echo ""
        if ! confirm "Continue building anyway?" "n"; then
            echo ""
            info "Run 'moav bootstrap' or 'cp .env.example .env' first"
            return 0
        fi
        echo ""
    fi

    # Handle --local: build images locally from Dockerfiles
    if [[ "$build_local" == "true" ]]; then
        build_local_images "$no_cache" "${services_args[@]}"
        return $?
    fi

    if [[ ${#services_args[@]} -eq 0 ]] || [[ "${services_args[0]}" == "all" ]]; then
        info "Building all services${no_cache:+ (no cache)}..."
        # Go services compile from source and download modules from proxy.golang.org.
        # Building them in parallel with 10+ other images saturates the network,
        # causing TLS handshake timeouts on module downloads.
        # Fix: build Go services sequentially first, then everything else in parallel.
        local go_services="amneziawg dnstt dns-router snowflake"
        local buildable_services remaining_services

        # Get only services that have build: configs (excludes image-only services)
        buildable_services=$(docker compose --profile all config --format json 2>/dev/null \
            | jq -r '.services | to_entries[] | select(.value.build != null) | .key' 2>/dev/null) \
            || buildable_services=$(docker compose --profile all config --services 2>/dev/null)

        # Phase 1: Build Go-compilation services one at a time
        info "Phase 1/2: Building Go services (sequential)..."
        for svc in $go_services; do
            if echo "$buildable_services" | grep -q "^${svc}$"; then
                info "  Building ${svc}..."
                compose_build --profile all build $no_cache "$svc"
            fi
        done

        # Phase 2: Build remaining buildable services in parallel
        remaining_services=$(echo "$buildable_services" | grep -vE "^($(echo $go_services | tr ' ' '|'))$" | tr '\n' ' ')
        info "Phase 2/2: Building remaining services ($(echo $remaining_services | wc -w | tr -d ' ') services)..."
        compose_build --profile all build $no_cache $remaining_services
        success "All services built!"
    else
        # Resolve all arguments: each can be a profile name or a service name
        local profiles="proxy wireguard amneziawg dnstunnel trusttunnel admin conduit snowflake monitoring"
        local matched_profiles=()
        local remaining_args=()

        for arg in "${services_args[@]}"; do
            local resolved_arg
            resolved_arg=$(resolve_profile "$arg")
            local is_profile=""
            for p in $profiles; do
                if [[ "$resolved_arg" == "$p" ]]; then
                    matched_profiles+=("$p")
                    is_profile="true"
                    break
                fi
            done
            if [[ -z "$is_profile" ]]; then
                remaining_args+=("$arg")
            fi
        done

        # Build matched profiles
        for profile in "${matched_profiles[@]}"; do
            info "Building $profile profile${no_cache:+ (no cache)}..."
            compose_build --profile "$profile" build $no_cache
            success "Profile $profile built!"
        done

        # Build remaining services (non-profile args)
        if [[ ${#remaining_args[@]} -gt 0 ]]; then
            local services
            services=$(resolve_services "${remaining_args[@]}")
            # Remove empty values and trim whitespace
            services=$(echo "$services" | xargs)
            if [[ -n "$services" ]]; then
                # Check if any services are image-only (need --local build)
                local compose_services=()
                local local_services=()
                for svc in $services; do
                    if _local_build_info "$svc" >/dev/null 2>&1; then
                        local_services+=("$svc")
                    else
                        compose_services+=("$svc")
                    fi
                done
                # Build compose services normally
                if [[ ${#compose_services[@]} -gt 0 ]]; then
                    info "Building: ${compose_services[*]}${no_cache:+ (no cache)}"
                    compose_build --profile all build $no_cache "${compose_services[@]}"
                    success "Build complete!"
                fi
                # Auto-redirect image-only services to local build
                if [[ ${#local_services[@]} -gt 0 ]]; then
                    info "Building locally: ${local_services[*]} (image-only services)"
                    build_local_images "$no_cache" "${local_services[@]}"
                fi
            fi
        fi

        # Nothing matched at all
        if [[ ${#matched_profiles[@]} -eq 0 && ${#remaining_args[@]} -eq 0 ]]; then
            info "No buildable services specified"
            return 0
        fi
    fi

    prune_build_cache
}

# Bound the BuildKit cache after a build. On the bitchat upgrade it had grown to
# ~4 GB (the bulk of a "disk 81% full" scare) while images and logs were fine —
# every `moav build` layers more cache and nothing evicted it.
#
# CRITICAL: this must NOT wipe the cache — that is what makes the *next* build
# fast (base layers, Go/Rust module downloads, compile output). We only cap it:
# keep the most-recently-used ~4 GB and evict the older overflow. So a normal
# rebuild keeps its warm cache; only unbounded accumulation is trimmed.
# Cache only, never images (they back the running stack and any rollback).
MOAV_BUILD_CACHE_KEEP="${MOAV_BUILD_CACHE_KEEP:-}"

# Sized to hold the whole stack's layers: MoaV's in-use images total ~1.9 GB on a
# full install and their cache is the same order, so 4 GB keeps every rebuild
# warm. It only shrinks when the disk is genuinely tight -- never more than half
# of the space the cache could occupy -- so a small VPS gives ground instead of
# filling up. Measured case: 24 GB box at 82%, 4.3 GB free plus 4.0 GB cache, so
# the cap stays 4 GB; the same box with 1 GB free would drop to 2.5 GB.
default_cache_keep() {
    local free_mb cache_mb keep
    free_mb=$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')
    [[ "$free_mb" =~ ^[0-9]+$ ]] || { echo 4096; return; }
    # Count the existing cache as available: it is what we are about to reclaim,
    # so without it the cap would ratchet down every run.
    cache_mb=$(docker system df 2>/dev/null | awk '/^Build Cache/ {
        v = $(NF-1); u = $(NF-1);
        sub(/[A-Za-z]+$/, "", v);
        if (u ~ /GB/) printf "%d", v * 1024; else if (u ~ /MB/) printf "%d", v; else print 0 }')
    [[ "$cache_mb" =~ ^[0-9]+$ ]] || cache_mb=0
    keep=$(( (free_mb + cache_mb) / 2 ))
    (( keep > 4096 )) && keep=4096
    (( keep < 1024 )) && keep=1024
    echo "$keep"
}

prune_build_cache() {
    command -v docker >/dev/null 2>&1 || return 0
    [[ -n "$MOAV_BUILD_CACHE_KEEP" ]] || MOAV_BUILD_CACHE_KEEP="$(default_cache_keep)MB"
    # --keep-storage caps retained cache (Docker 18.09+; a deprecation alias for
    # --reserved-space on 27+, still honored). Fall back to an age filter on the
    # rare daemon that rejects it, still preserving recent layers.
    if docker builder prune -f --keep-storage "$MOAV_BUILD_CACHE_KEEP" >/dev/null 2>&1; then
        info "Capped build cache at ~${MOAV_BUILD_CACHE_KEEP} (least-recently-used layers evicted first)"
    elif docker builder prune -f --filter until=336h >/dev/null 2>&1; then
        info "Pruned build cache older than 14 days (recent layers kept)"
    fi
}

# Map of services that can be built locally
# Format: "dockerfile|image_tag|image_env_var|version_env_var|version_arg|description"
ALL_LOCAL_BUILD_SERVICES="cadvisor clash-exporter prometheus grafana node-exporter nginx certbot"

_local_build_info() {
    case "$1" in
        cadvisor)       echo "dockerfiles/Dockerfile.cadvisor|moav-cadvisor:local|IMAGE_CADVISOR|CADVISOR_VERSION|CADVISOR_VERSION|cAdvisor container metrics (gcr.io)" ;;
        clash-exporter) echo "dockerfiles/Dockerfile.clash-exporter|moav-clash-exporter:local|IMAGE_CLASH_EXPORTER|CLASH_EXPORTER_VERSION|CLASH_EXPORTER_VERSION|Clash API exporter (ghcr.io)" ;;
        prometheus)     echo "dockerfiles/Dockerfile.prometheus|moav-prometheus:local|IMAGE_PROMETHEUS|PROMETHEUS_VERSION|PROMETHEUS_VERSION|Prometheus time-series DB" ;;
        grafana)        echo "dockerfiles/Dockerfile.grafana|moav-grafana:local|IMAGE_GRAFANA|GRAFANA_VERSION|GRAFANA_VERSION|Grafana dashboards" ;;
        node-exporter)  echo "dockerfiles/Dockerfile.node-exporter|moav-node-exporter:local|IMAGE_NODE_EXPORTER|NODE_EXPORTER_VERSION|NODE_EXPORTER_VERSION|Node system metrics" ;;
        nginx)          echo "dockerfiles/Dockerfile.nginx|moav-nginx:local|IMAGE_NGINX||NGINX_VERSION|Nginx web server" ;;
        certbot)        echo "dockerfiles/Dockerfile.certbot|moav-certbot:local|IMAGE_CERTBOT||CERTBOT_VERSION|Let's Encrypt client" ;;
        *) return 1 ;;
    esac
}

# Default services to build with --local (commonly blocked registries)
DEFAULT_LOCAL_BUILDS="cadvisor clash-exporter"

# Build images locally for regions with blocked registries
build_local_images() {
    local no_cache="${1:-}"
    shift
    local services_to_build=("$@")
    local env_file=".env"
    local built_count=0

    print_section "Building Local Images"
    echo ""
    echo "This builds images from source for regions where container registries are blocked."
    echo ""

    # If no services specified, use defaults (commonly blocked)
    if [[ ${#services_to_build[@]} -eq 0 ]]; then
        read -ra services_to_build <<< "$DEFAULT_LOCAL_BUILDS"
        echo "Building default images (gcr.io/ghcr.io - commonly blocked):"
        for svc in "${services_to_build[@]}"; do
            echo "  - $svc"
        done
    elif [[ "${services_to_build[0]}" == "all" ]]; then
        # First, build all services that use docker-compose build
        echo "Step 1: Building all docker-compose services..."
        echo ""
        if compose_build --profile all build $no_cache; then
            success "Docker-compose services built!"
        else
            error "Failed to build some docker-compose services"
        fi
        echo ""

        # Then build external images
        echo "Step 2: Building external images locally..."
        read -ra services_to_build <<< "$ALL_LOCAL_BUILD_SERVICES"
        echo "Images to build:"
        for svc in "${services_to_build[@]}"; do
            echo "  - $svc"
        done
    else
        echo "Building specified images:"
        for svc in "${services_to_build[@]}"; do
            echo "  - $svc"
        done
    fi
    echo ""

    # Build each service
    for service in "${services_to_build[@]}"; do
        local build_info
        build_info=$(_local_build_info "$service" 2>/dev/null) || true

        if [[ -z "$build_info" ]]; then
            warn "Unknown service for local build: $service"
            echo "Available services: $ALL_LOCAL_BUILD_SERVICES"
            continue
        fi

        # Parse build info (dockerfile|image_tag|image_env_var|version_env_var|version_arg|description)
        IFS='|' read -r dockerfile image_tag image_env_var version_env_var version_arg description <<< "$build_info"

        # Check Dockerfile exists
        if [[ ! -f "$dockerfile" ]]; then
            error "Dockerfile not found: $dockerfile"
            continue
        fi

        # Get version from .env if available
        local version_value=""
        local build_args=""
        if [[ -n "$version_env_var" ]] && [[ -f "$env_file" ]]; then
            version_value=$(get_env_val "$version_env_var" "$env_file")
            if [[ -n "$version_value" ]] && [[ -n "$version_arg" ]]; then
                build_args="--build-arg ${version_arg}=${version_value}"
            fi
        fi

        info "Building $service ($description)${version_value:+ v$version_value}..."
        if docker build $no_cache $build_args -f "$dockerfile" -t "$image_tag" .; then
            success "$service built: $image_tag"
            built_count=$((built_count + 1))

            # Update .env to use local image
            if [[ -f "$env_file" ]] && [[ -n "$image_env_var" ]]; then
                update_env_var "$env_file" "$image_env_var" "$image_tag"
            fi
        else
            error "Failed to build $service"
        fi
        echo ""
    done

    if [[ $built_count -eq 0 ]]; then
        error "No images were built successfully"
        return 1
    fi

    success "$built_count local image(s) built successfully!"
    echo ""
    echo "Your .env has been updated to use the local images."
    echo "Run 'moav start' to use them."
    echo ""
    echo "To see all available images for local build:"
    echo "  moav build --local --list"
}

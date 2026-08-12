#!/bin/bash
# lib/update.sh — `moav update`: pull the new revision, then work out what the
# operator actually has to do about it. Component-version comparison, detecting
# config templates that changed under a live deployment, detecting sources that
# need a rebuild, the post-update apply steps, new-variable detection against
# .env.example, and the dnstt→DNS-tunnel state migration that older installs
# still need on the way through.
#
# Sourced by moav.sh after lib/common.sh; `moav update` and the dispatcher's
# migrate-dns-state entry both land here.
#
# Definitions only — nothing here runs at source time.

cmd_update() {
    local target_branch=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--branch)
                if [[ $# -lt 2 ]]; then
                    error "-b/--branch requires a branch name"
                    return 1
                fi
                target_branch="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: moav update [-b BRANCH]"
                echo ""
                echo "Update MoaV to the latest version"
                echo ""
                echo "Options:"
                echo "  -b, --branch BRANCH   Switch to and pull specified branch"
                echo "                        Examples: main, dev, paqet"
                echo ""
                echo "Examples:"
                echo "  moav update              # Update current branch"
                echo "  moav update -b main      # Switch to main and update"
                echo "  moav update -b dev       # Switch to dev branch"
                return 0
                ;;
            *)
                error "Unknown option: $1"
                echo "Use 'moav update --help' for usage"
                return 1
                ;;
        esac
    done

    echo ""
    info "Updating MoaV..."
    echo ""

    # Get the installation directory
    local install_dir="$SCRIPT_DIR"

    # Check if it's a git repository
    if [[ ! -d "$install_dir/.git" ]]; then
        error "Not a git repository: $install_dir"
        echo "  Cannot update - MoaV was not installed via git clone"
        return 1
    fi

    echo -e "  Install directory: ${CYAN}$install_dir${NC}"
    echo ""

    # Show current version/commit
    local current_commit
    current_commit=$(git -C "$install_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    echo -e "  Current commit: ${YELLOW}$current_commit${NC}"

    # Check current branch
    local current_branch
    current_branch=$(git -C "$install_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    echo -e "  Current branch: ${CYAN}$current_branch${NC}"

    # Show target branch if switching
    if [[ -n "$target_branch" ]]; then
        echo -e "  Target branch: ${GREEN}$target_branch${NC}"
    fi

    # Warn if not on main branch (and not switching)
    if [[ -z "$target_branch" && "$current_branch" != "main" && "$current_branch" != "master" ]]; then
        echo ""
        echo -e "  ${YELLOW}⚠ Warning:${NC} You are on branch '${YELLOW}$current_branch${NC}' (not main)"
        echo -e "    This may be a development or feature branch."
        echo -e "    To switch to stable: ${WHITE}moav update -b main${NC}"
    fi
    echo ""

    # Check for local changes that would block git pull
    local changes
    changes=$(git -C "$install_dir" status --porcelain 2>/dev/null)

    if [[ -n "$changes" ]]; then
        echo -e "${YELLOW}⚠ Local changes detected:${NC}"
        echo ""
        # Show modified files (limit to 10 for readability)
        echo "$changes" | head -10 | while read -r line; do
            echo -e "    ${CYAN}$line${NC}"
        done
        local change_count
        change_count=$(echo "$changes" | wc -l | tr -d ' ')
        if [[ "$change_count" -gt 10 ]]; then
            echo -e "    ${DIM}... and $((change_count - 10)) more files${NC}"
        fi
        echo ""
        echo "These changes will conflict with the update."
        echo ""
        echo "Options:"
        echo -e "  ${WHITE}1)${NC} Stash changes (save temporarily, can restore later)"
        echo -e "  ${WHITE}2)${NC} Discard changes (reset to clean state - ${RED}LOSES YOUR CHANGES${NC})"
        echo -e "  ${WHITE}3)${NC} Abort (handle manually)"
        echo ""
        read -rp "Choice [1/2/3]: " choice

        case "$choice" in
            1|"")
                info "Stashing local changes..."
                local stash_msg="moav-update-$(date +%Y%m%d-%H%M%S)"
                if git -C "$install_dir" stash push -m "$stash_msg" --include-untracked; then
                    success "Changes stashed"
                    echo ""
                    echo -e "${CYAN}To restore your changes later:${NC}"
                    echo -e "  ${WHITE}cd $install_dir && git stash pop${NC}"
                    echo ""
                    echo -e "${DIM}Or view stashed changes: git stash list${NC}"
                    echo ""
                else
                    error "Failed to stash changes"
                    echo "  Try manually: cd $install_dir && git stash"
                    return 1
                fi
                ;;
            2)
                echo ""
                echo -e "${RED}WARNING: This will permanently discard all local changes!${NC}"
                read -rp "Are you sure? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    info "Discarding local changes..."
                    git -C "$install_dir" checkout -- . 2>/dev/null
                    git -C "$install_dir" clean -fd 2>/dev/null
                    success "Local changes discarded"
                    echo ""
                else
                    info "Aborted"
                    return 0
                fi
                ;;
            3|*)
                info "Aborted. Handle changes manually:"
                echo ""
                echo -e "  ${WHITE}cd $install_dir${NC}"
                echo -e "  ${WHITE}git status${NC}           # View changes"
                echo -e "  ${WHITE}git stash${NC}            # Save changes temporarily"
                echo -e "  ${WHITE}git checkout -- .${NC}    # Discard changes"
                echo -e "  ${WHITE}moav update${NC}          # Try again"
                echo ""
                return 0
                ;;
        esac
    fi

    # Fetch latest from remote
    info "Fetching from remote..."
    if ! git -C "$install_dir" fetch --all --prune 2>/dev/null; then
        warn "Failed to fetch, continuing with local data..."
    fi

    # Switch branch if requested
    if [[ -n "$target_branch" && "$target_branch" != "$current_branch" ]]; then
        info "Switching to branch: $target_branch"

        # Check if branch exists (locally or on remote)
        if ! git -C "$install_dir" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null && \
           ! git -C "$install_dir" show-ref --verify --quiet "refs/remotes/origin/$target_branch" 2>/dev/null; then
            error "Branch '$target_branch' does not exist"
            echo ""
            echo "Available branches:"
            git -C "$install_dir" branch -a | sed 's/^/  /' | head -15
            return 1
        fi

        # Checkout the branch
        if ! git -C "$install_dir" checkout "$target_branch" 2>/dev/null; then
            error "Failed to checkout branch '$target_branch'"
            return 1
        fi
        success "Switched to branch: $target_branch"
        current_branch="$target_branch"
    fi

    # Pull latest changes
    info "Pulling latest changes..."
    if git -C "$install_dir" pull origin "$current_branch" 2>/dev/null || git -C "$install_dir" pull; then
        echo ""
        local new_commit
        new_commit=$(git -C "$install_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        local new_branch
        new_branch=$(git -C "$install_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

        if [[ "$current_commit" == "$new_commit" ]]; then
            success "Already up to date (branch: $new_branch)"
        else
            success "Updated: $current_commit → $new_commit (branch: $new_branch)"

            # Re-exec with new code for post-update checks. The running script is
            # the old version; the new code is on disk. Pass the pre-pull commit so
            # the new code can diff it for config-template changes (re-bootstrap).
            exec "$SCRIPT_DIR/moav.sh" _post-update "$current_commit"
        fi

        # Post-update checks (reached on "already up to date"; the updated path
        # re-execs into _post-update above and never returns here). No pull
        # happened, so there are no config-template changes to diff.
        check_component_versions
        migrate_dns_tunnel_state
        check_env_additions
        print_post_update_apply_steps
    else
        error "Failed to update. Check your network connection or git status."
        echo ""
        echo "Troubleshooting:"
        echo "  - Check network: ping github.com"
        echo "  - View git status: cd $install_dir && git status"
        echo "  - See docs: https://moav.sh/docs/TROUBLESHOOTING#git-update-issues"
        return 1
    fi
}

# Check if component versions in .env are outdated compared to .env.example.
check_component_versions() {
    local env_file="$SCRIPT_DIR/.env"
    local example_file="$SCRIPT_DIR/.env.example"

    # Skip if .env doesn't exist
    [[ ! -f "$env_file" ]] && return 0
    [[ ! -f "$example_file" ]] && return 0

    # List of version variables to check
    local version_vars=(
        "SINGBOX_VERSION"
        "WSTUNNEL_VERSION"
        "CONDUIT_VERSION"
        "SNOWFLAKE_VERSION"
        "TRUSTTUNNEL_VERSION"
        "TRUSTTUNNEL_CLIENT_VERSION"
        "SLIPSTREAM_VERSION"
        "TELEMT_VERSION"
        "XRAY_VERSION"
        "DNSTT_VERSION"
        "MASTERDNS_VERSION"
        "GOOSERELAY_VERSION"
    )

    local updates_available=()
    local services_to_rebuild=()

    for var in "${version_vars[@]}"; do
        local current_val example_val
        current_val=$(get_env_val "$var" "$env_file")
        example_val=$(get_env_val "$var" "$example_file")

        # Skip if either is empty
        [[ -z "$current_val" || -z "$example_val" ]] && continue

        # Check if versions differ
        if [[ "$current_val" != "$example_val" ]]; then
            updates_available+=("$var:$current_val:$example_val")

            # Map version var to service name for rebuild command
            case "$var" in
                SINGBOX_VERSION) services_to_rebuild+=("sing-box") ;;
                WSTUNNEL_VERSION) services_to_rebuild+=("wstunnel") ;;
                CONDUIT_VERSION) services_to_rebuild+=("psiphon-conduit") ;;
                SNOWFLAKE_VERSION) services_to_rebuild+=("snowflake") ;;
                TRUSTTUNNEL_VERSION|TRUSTTUNNEL_CLIENT_VERSION)
                    # Only add trusttunnel once
                    if [[ ! " ${services_to_rebuild[*]} " =~ " trusttunnel " ]]; then
                        services_to_rebuild+=("trusttunnel")
                    fi
                    ;;
                SLIPSTREAM_VERSION) services_to_rebuild+=("slipstream") ;;
                TELEMT_VERSION) services_to_rebuild+=("telemt") ;;
                XRAY_VERSION) services_to_rebuild+=("xray") ;;
                DNSTT_VERSION) services_to_rebuild+=("dnstt") ;;
                MASTERDNS_VERSION) services_to_rebuild+=("masterdns") ;;
                GOOSERELAY_VERSION) services_to_rebuild+=("gooserelay") ;;
            esac
        fi
    done

    # No updates available
    [[ ${#updates_available[@]} -eq 0 ]] && return 0

    echo ""
    info "Component updates available:"
    echo ""

    for update in "${updates_available[@]}"; do
        local var current new
        var=$(echo "$update" | cut -d: -f1)
        current=$(echo "$update" | cut -d: -f2)
        new=$(echo "$update" | cut -d: -f3)
        printf "  %-28s %s → ${GREEN}%s${NC}\n" "$var:" "$current" "$new"
    done

    echo ""
    # Defaults to yes: these are the versions this release was tested against,
    # so staying on the old pin is the unusual choice. Matches the [Y/n] on the
    # equivalent question in check_env_additions.
    read -r -p "Update component versions in .env? [Y/n] " update_versions

    if [[ ! "$update_versions" =~ ^[Nn]$ ]]; then
        for update in "${updates_available[@]}"; do
            local var new
            var=$(echo "$update" | cut -d: -f1)
            new=$(echo "$update" | cut -d: -f3)

            # Update the version in .env
            if grep -q "^${var}=" "$env_file"; then
                sed -i "s/^${var}=.*/${var}=${new}/" "$env_file"
            else
                # Add if not present
                echo "${var}=${new}" >> "$env_file"
            fi
        done

        success "Component versions updated in .env"

        # Record which services need rebuilding. The ordered apply sequence is
        # composed and printed once by print_post_update_apply_steps (so a
        # rebuild + a config-template re-bootstrap are shown as one flow).
        if [[ ${#services_to_rebuild[@]} -gt 0 ]]; then
            POST_UPDATE_REBUILD_SERVICES="${services_to_rebuild[*]}"
        fi
    else
        echo ""
        echo "Versions not updated. To update later, compare:"
        echo "  .env.example (new versions) vs .env (your versions)"
    fi
}

# After a self-update pull, detect changes to server config *templates*
# (configs/**/*.template). The configs already generated on disk won't reflect
# a template change until they're regenerated via bootstrap, so flag it. Most
# such changes are picked up cleanly on the next bootstrap (which is idempotent
# and preserves keys/users); some are backward-compatible and need no action at
# all (e.g. the v1.7.8 Xray clients→users rename, where Xray still accepts the
# old key). Records the changed templates for print_post_update_apply_steps.
check_config_template_changes() {
    local old_commit="${1:-}"
    [[ -z "$old_commit" ]] && return 0
    [[ -d "$SCRIPT_DIR/.git" ]] || return 0

    local diff
    diff=$(git -C "$SCRIPT_DIR" diff --name-only "$old_commit" HEAD 2>/dev/null || true)

    local changed
    changed=$(echo "$diff" | grep -E '\.template$' || true)
    [[ -n "$changed" ]] && POST_UPDATE_BOOTSTRAP_TEMPLATES="$changed"

    # The user-bundle guide is regenerated by `moav regenerate-users` (no
    # re-bootstrap needed). Flag changes to its template or renderer so an
    # update that, e.g., started hiding disabled-protocol sections (#73) tells
    # the operator to refresh existing bundles.
    if echo "$diff" | grep -qE 'templates/client-guide-template\.html|scripts/lib/bundle_readme\.py|scripts/lib/bundle-readme\.sh'; then
        POST_UPDATE_REGEN_BUNDLES=1
    fi
    return 0
}

# After a self-update pulls new code, queue source-built services whose *baked*
# build inputs changed in the pull. check_component_versions only catches
# version-pin bumps in .env; services built from source (the Go binaries, the
# COPY'd entrypoints, dns-router/) have no version pin, so a code change there
# would ship in git but never reach a running container until a manual rebuild
# — exactly how a dns-router source change left old routers running pre-1.8.0.
#
# Only inputs COPY'd into the image count. Scripts bind-mounted at runtime
# (bootstrap.sh, generate-user.sh, lib/, grafana-entrypoint.sh) take effect on
# the next run, so they must NOT trigger a (pointless, on a 1GB VPS slow) build.
check_source_rebuilds() {
    local old_commit="${1:-}"
    [[ -z "$old_commit" ]] && return 0
    [[ -d "$SCRIPT_DIR/.git" ]] || return 0

    local changed
    changed=$(git -C "$SCRIPT_DIR" diff --name-only "$old_commit" HEAD 2>/dev/null) || return 0
    [[ -z "$changed" ]] && return 0

    # Operator-facing services built from source. Monitoring/infra images
    # (exporters, grafana, prometheus, the bootstrap image) are intentionally
    # excluded — low impact, and their entrypoints are bind-mounted anyway.
    local valid=" dns-router dnstt slipstream gooserelay masterdns sing-box xray telemt trusttunnel wireguard amneziawg wstunnel snowflake psiphon-conduit client admin "

    local queued="" f svc
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        svc=""
        case "$f" in
            dns-router/*)                   svc="dns-router" ;;
            admin/*)                        svc="admin" ;;
            scripts/conduit-entrypoint.sh)  svc="psiphon-conduit" ;;   # name mismatch
            dockerfiles/Dockerfile.psiphon) svc="psiphon-conduit" ;;   # name mismatch
            scripts/client-*.sh)            svc="client" ;;
            scripts/*-entrypoint.sh)        svc="${f#scripts/}"; svc="${svc%-entrypoint.sh}" ;;
            dockerfiles/Dockerfile.*)       svc="${f#dockerfiles/Dockerfile.}" ;;
        esac
        [[ -z "$svc" ]] && continue
        # Drop anything not in the allowlist: bind-mounted entrypoints (grafana),
        # monitoring exporters, infra images, unknown name mappings.
        [[ "$valid" == *" $svc "* ]] || continue
        [[ " $queued " == *" $svc "* ]] || queued="${queued:+$queued }$svc"
    done <<< "$changed"

    [[ -z "$queued" ]] && return 0

    # Merge with version-pin rebuilds (check_component_versions), de-duped.
    local merged="${POST_UPDATE_REBUILD_SERVICES:-}"
    for svc in $queued; do
        [[ " $merged " == *" $svc "* ]] || merged="${merged:+$merged }$svc"
    done
    POST_UPDATE_REBUILD_SERVICES="$merged"
}

# Compose a single ordered "how to apply this update" summary from what the
# post-update checks found: component rebuilds (POST_UPDATE_REBUILD_SERVICES)
# and/or stale server configs (POST_UPDATE_BOOTSTRAP_TEMPLATES). Print-only by
# design — never auto-rebuilds or restarts a running server (a build-all would
# OOM low-RAM VPSes, and restarting a live circumvention node is the operator's
# call). Fixes two non-obvious gotchas: (1) `moav build` doesn't recreate
# containers and `moav restart` reuses the old image — you need `moav start`
# (up -d); (2) a config-template change needs a re-bootstrap, not just a build.
print_post_update_apply_steps() {
    local rebuild="${POST_UPDATE_REBUILD_SERVICES:-}"
    local templates="${POST_UPDATE_BOOTSTRAP_TEMPLATES:-}"
    local regen_bundles="${POST_UPDATE_REGEN_BUNDLES:-}"

    [[ -z "$rebuild" && -z "$templates" && -z "$regen_bundles" ]] && return 0

    echo ""
    if [[ -n "$templates" ]]; then
        warn "This update changed server config templates:"
        while IFS= read -r f; do
            [[ -n "$f" ]] && echo -e "    ${CYAN}$f${NC}"
        done <<< "$templates"
        echo ""
        echo "The generated configs on disk may not reflect this change until they"
        echo "are regenerated. Re-bootstrap to pick it up — bootstrap is idempotent"
        echo "and preserves your keys and user UUIDs."
        echo ""
    fi

    local n=1
    echo -e "${WHITE}Apply this update in order:${NC}"
    echo ""
    if [[ -n "$rebuild" ]]; then
        echo -e "  ${WHITE}${n}.${NC} moav build ${rebuild}   ${DIM}# build new images (add --no-cache only to force a clean rebuild)${NC}"
        n=$((n+1))
    fi
    if [[ -n "$templates" ]]; then
        echo -e "  ${WHITE}${n}.${NC} moav bootstrap                  ${DIM}# regenerate server configs (keeps keys + users)${NC}"
        n=$((n+1))
        echo -e "  ${WHITE}${n}.${NC} moav regenerate-users           ${DIM}# refresh user bundles${NC}"
        n=$((n+1))
    elif [[ -n "$regen_bundles" ]]; then
        # Bundle guide/renderer changed but server configs did not — only the
        # user bundles need refreshing (no re-bootstrap).
        echo -e "  ${WHITE}${n}.${NC} moav regenerate-users           ${DIM}# refresh user bundles (guide layout changed)${NC}"
        n=$((n+1))
    fi
    echo -e "  ${WHITE}${n}.${NC} moav start                      ${DIM}# recreate containers on the new images${NC}"
    echo ""
    echo -e "${DIM}Note: 'moav restart' reuses the old image — use 'moav start' (docker compose up -d) to pick up rebuilt images.${NC}"
}

# Check for new variables in .env.example that are missing from .env
# Preserve DNS tunnel state before check_env_additions.
#
# v1.7.5 flipped DNS tunnel defaults (ENABLE_DNSTT/SLIPSTREAM: false→true, ENABLE_XDNS: true→false).
# v1.7.9+ re-enabled XDNS by default (ENABLE_XDNS: false→true) — all 4 tunnels now default on.
# If a pre-1.7.5 user's .env is missing any of these vars (sparse config), check_env_additions
# would append the new defaults, putting their .env in a state that conflicts with their currently
# running tunnel. This migration writes explicit values first — derived from what's actually
# running — so check_env_additions sees all three vars present and skips them.
migrate_dns_tunnel_state() {
    local env_file="$SCRIPT_DIR/.env"
    [[ ! -f "$env_file" ]] && return 0

    local has_xdns has_dnstt has_slip
    grep -q '^ENABLE_XDNS='       "$env_file" && has_xdns=true  || has_xdns=false
    grep -q '^ENABLE_DNSTT='      "$env_file" && has_dnstt=true || has_dnstt=false
    grep -q '^ENABLE_SLIPSTREAM=' "$env_file" && has_slip=true  || has_slip=false

    # All three present = user already has explicit config. Leave alone.
    if $has_xdns && $has_dnstt && $has_slip; then
        return 0
    fi

    info "Preserving DNS tunnel state (.env missing some DNS tunnel vars; v1.7.5 default flip detected)..."

    # Detect current tunnel state from running containers (authoritative over .env)
    local running
    running=$(docker compose ps --services --filter "status=running" 2>/dev/null || echo "")
    local xdns_active=false dnstt_active=false slip_active=false

    # xray serves both XHTTP and XDNS. XDNS is only "active" if enable flag is true
    # (or flag is missing, which in pre-1.7.5 defaulted to true).
    if echo "$running" | grep -qw xray; then
        if $has_xdns; then
            local cur
            cur=$(get_env_val "ENABLE_XDNS" "$env_file" "true")
            [[ "$cur" == "true" ]] && xdns_active=true
        else
            # Missing from .env — pre-1.7.5 default was true
            xdns_active=true
        fi
    fi
    echo "$running" | grep -qw dnstt      && dnstt_active=true
    echo "$running" | grep -qw slipstream && slip_active=true

    # Nothing detected running → fall back to pre-1.7.5 defaults (XDNS on, others off)
    if ! $xdns_active && ! $dnstt_active && ! $slip_active; then
        xdns_active=true
    fi

    local v
    if ! $has_xdns; then
        $xdns_active && v=true || v=false
        update_env_var "$env_file" "ENABLE_XDNS" "$v"
    fi
    if ! $has_dnstt; then
        $dnstt_active && v=true || v=false
        update_env_var "$env_file" "ENABLE_DNSTT" "$v"
    fi
    if ! $has_slip; then
        $slip_active && v=true || v=false
        update_env_var "$env_file" "ENABLE_SLIPSTREAM" "$v"
    fi

    # Pin port assignments if missing. All tunnels now go through dns-router on PORT_DNS=53.
    # PORT_XDNS is xray's secondary host port (not port 53 — dns-router owns that).
    if ! grep -q '^PORT_XDNS=' "$env_file"; then
        update_env_var "$env_file" "PORT_XDNS" "5356"
    fi
    if ! grep -q '^PORT_DNS=' "$env_file"; then
        { $dnstt_active || $slip_active || $xdns_active; } && v=53 || v=5353
        update_env_var "$env_file" "PORT_DNS" "$v"
    fi

    echo "  Preserved: ENABLE_XDNS=$xdns_active, ENABLE_DNSTT=$dnstt_active, ENABLE_SLIPSTREAM=$slip_active"
}

check_env_additions() {
    local env_file="$SCRIPT_DIR/.env"
    local example_file="$SCRIPT_DIR/.env.example"

    [[ ! -f "$env_file" ]] && return 0
    [[ ! -f "$example_file" ]] && return 0

    # Build list of missing variables (in .env.example but not in .env)
    # Use temp files to avoid set -e issues with pipelines and process substitution
    local tmp_env tmp_example tmp_missing
    tmp_env=$(mktemp)
    tmp_example=$(mktemp)
    tmp_missing=$(mktemp)
    trap "rm -f '$tmp_env' '$tmp_example' '$tmp_missing'" RETURN

    # Extract variable names from both files
    grep '^[A-Z_]' "$env_file" | sed 's/=.*//' | sort -u > "$tmp_env" 2>/dev/null || true
    grep '^[A-Z_]' "$example_file" | sed 's/=.*//' | sort -u > "$tmp_example" 2>/dev/null || true

    # Bail if either file had no variables
    [[ ! -s "$tmp_env" || ! -s "$tmp_example" ]] && return 0

    # Find missing variables
    comm -23 "$tmp_example" "$tmp_env" > "$tmp_missing" 2>/dev/null || true

    local missing_count
    missing_count=$(wc -l < "$tmp_missing" | tr -d ' ')
    [[ "$missing_count" -eq 0 ]] && return 0

    # Build display list and append block
    local display_lines=""
    local append_block=""

    while IFS= read -r var; do
        [[ -z "$var" ]] && continue

        # Get the value line from .env.example
        local value_line
        value_line=$(grep "^${var}=" "$example_file" | head -1) || true
        [[ -z "$value_line" ]] && continue

        # Get preceding comment lines (walk backwards)
        local line_num comments=""
        line_num=$(grep -n "^${var}=" "$example_file" | head -1 | cut -d: -f1) || true

        if [[ -n "$line_num" ]]; then
            local prev=$((line_num - 1))
            while [[ $prev -gt 0 ]]; do
                local prev_line
                prev_line=$(sed -n "${prev}p" "$example_file") || true
                if [[ "$prev_line" =~ ^#[^!] ]]; then
                    comments="${prev_line}"$'\n'"${comments}"
                    prev=$((prev - 1))
                else
                    break
                fi
            done
        fi

        # A new opt-in flag must not switch off a feature the server is already
        # running. ENABLE_CDN's absence means "on if CDN_SUBDOMAIN is set" (see
        # cdn_enabled), so appending the example's `false` would leave a working
        # CDN alive until the next bootstrap and then silently drop the inbound.
        if [[ "$var" == "ENABLE_CDN" ]]; then
            if [[ -n "$(get_env_val "CDN_SUBDOMAIN" "$env_file" "")" \
               || -n "$(get_env_val "CDN_DOMAIN"    "$env_file" "")" ]]; then
                value_line="ENABLE_CDN=true"
            fi
        fi

        # Display: variable name with its default value
        local default_val
        default_val=$(echo "$value_line" | cut -d'=' -f2-)
        if [[ -z "$default_val" ]]; then
            display_lines+="  ${var}  ${DIM}(empty default)${NC}"$'\n'
        else
            display_lines+="  ${var}=${default_val}"$'\n'
        fi

        # Build the block to append (comments + variable line)
        if [[ -n "$comments" ]]; then
            append_block+="${comments}"
        fi
        append_block+="${value_line}"$'\n'

    done < "$tmp_missing"

    [[ -z "$append_block" ]] && return 0

    echo ""
    info "New configuration options available ($missing_count):"
    echo ""
    echo -e "$display_lines"

    read -r -p "Add these to your .env with default values? [Y/n] " add_vars

    if [[ ! "$add_vars" =~ ^[Nn]$ ]]; then
        {
            echo ""
            echo "# ── Added by moav update ($(date +%Y-%m-%d)) ──"
            echo -n "$append_block"
        } >> "$env_file"

        success "Added $missing_count new variable(s) to .env"
        echo ""
        echo -e "Review with: ${WHITE}cat .env${NC}"
    else
        echo ""
        echo "Skipped. To add later, compare .env.example vs .env"
    fi
}

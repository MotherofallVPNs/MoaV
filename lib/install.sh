#!/bin/bash
# lib/install.sh — making `moav` available as a command: the /usr/local/bin
# symlink, shell completions (install + removal), and `moav uninstall` (stop and
# remove containers, optionally images and data).
#
# NOTE: the symlink is why moav.sh keeps its own $0/BASH_SOURCE resolution in the
# entrypoint — a lib's BASH_SOURCE points at the lib, not the invoked script.
#
# Sourced by moav.sh after lib/common.sh.
#
# Definitions only — nothing here runs at source time.

INSTALL_PATH="/usr/local/bin/moav"

is_installed() {
    [[ -L "$INSTALL_PATH" ]] && [[ "$(readlink "$INSTALL_PATH")" == "$SCRIPT_DIR/moav.sh" ]]
}

install_completions() {
    local comp_src="$SCRIPT_DIR/completions/moav.bash"
    if [[ ! -f "$comp_src" ]]; then
        return 0
    fi

    local installed=false

    # System-wide bash completions
    if [[ -d "/etc/bash_completion.d" ]]; then
        if [[ -w "/etc/bash_completion.d" ]]; then
            cp "$comp_src" "/etc/bash_completion.d/moav"
        else
            sudo cp "$comp_src" "/etc/bash_completion.d/moav" 2>/dev/null || true
        fi
        installed=true
    fi

    # User-level bash completions (fallback)
    if [[ "$installed" != "true" ]]; then
        local user_comp_dir="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"
        mkdir -p "$user_comp_dir" 2>/dev/null
        cp "$comp_src" "$user_comp_dir/moav" 2>/dev/null || true
        installed=true
    fi

    # Zsh completions (if zsh is available)
    if command -v zsh &>/dev/null; then
        # Try common zsh completion directories
        for zsh_dir in "/usr/local/share/zsh/site-functions" "/usr/share/zsh/site-functions"; do
            if [[ -d "$zsh_dir" ]]; then
                if [[ -w "$zsh_dir" ]]; then
                    cp "$comp_src" "$zsh_dir/_moav"
                else
                    sudo cp "$comp_src" "$zsh_dir/_moav" 2>/dev/null || true
                fi
                break
            fi
        done
    fi

    # Also add to .bashrc/.zshrc as fallback (in case bash-completion package isn't installed)
    local shell_rc=""
    if [[ -n "${BASH_VERSION:-}" ]]; then
        shell_rc="$HOME/.bashrc"
    elif [[ -n "${ZSH_VERSION:-}" ]]; then
        shell_rc="$HOME/.zshrc"
    fi
    if [[ -n "$shell_rc" && -f "$shell_rc" ]]; then
        local source_line="[[ -f \"$comp_src\" ]] && source \"$comp_src\"  # moav completions"
        if ! grep -q "moav completions" "$shell_rc" 2>/dev/null; then
            echo "" >> "$shell_rc"
            echo "$source_line" >> "$shell_rc"
        fi
    fi

    # Source now for the current shell
    source "$comp_src" 2>/dev/null || true

    if [[ "$installed" == "true" ]]; then
        success "Shell completions installed (available in this and future sessions)"
    fi
}

uninstall_completions() {
    local paths=(
        "/etc/bash_completion.d/moav"
        "${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions/moav"
        "/usr/local/share/zsh/site-functions/_moav"
        "/usr/share/zsh/site-functions/_moav"
    )
    for p in "${paths[@]}"; do
        if [[ -f "$p" ]]; then
            if [[ -w "$p" ]] || [[ -w "$(dirname "$p")" ]]; then
                rm -f "$p"
            else
                sudo rm -f "$p" 2>/dev/null || true
            fi
        fi
    done
}

do_install() {
    local script_path="$SCRIPT_DIR/moav.sh"

    echo ""
    info "Installing moav to $INSTALL_PATH"

    # Check if already installed correctly
    if is_installed; then
        success "Already installed at $INSTALL_PATH"
        install_completions
        return 0
    fi

    # Check if something else exists at install path
    if [[ -e "$INSTALL_PATH" ]]; then
        warn "File already exists at $INSTALL_PATH"
        if [[ -L "$INSTALL_PATH" ]]; then
            local current_target
            current_target=$(readlink "$INSTALL_PATH")
            echo "  Current symlink points to: $current_target"
        fi
        if ! confirm "Replace it?"; then
            warn "Installation cancelled"
            return 1
        fi
    fi

    # Need sudo for /usr/local/bin
    if [[ -w "$(dirname "$INSTALL_PATH")" ]]; then
        ln -sf "$script_path" "$INSTALL_PATH"
    else
        info "Requires sudo to create symlink in /usr/local/bin"
        sudo ln -sf "$script_path" "$INSTALL_PATH"
    fi

    if is_installed; then
        success "Installed! You can now run 'moav' from anywhere"

        # Install shell completions
        install_completions

        echo ""
        echo "  Examples:"
        echo "    moav              # Interactive menu"
        echo "    moav start        # Start all services"
        echo "    moav logs conduit # View conduit logs"
    else
        error "Installation failed"
        return 1
    fi
}

do_uninstall() {
    local wipe=false assume_yes=false remove_imgs=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --wipe)
                wipe=true
                shift
                ;;
            --yes|-y)
                assume_yes=true
                shift
                ;;
            --remove-images)
                remove_imgs=true
                shift
                ;;
            *)
                error "Unknown option: $1"
                echo "Usage: moav uninstall [--wipe] [--yes|-y] [--remove-images]"
                return 1
                ;;
        esac
    done

    echo ""
    if [[ "$wipe" == "true" ]]; then
        warn "This will COMPLETELY REMOVE MoaV including:"
        echo "  - All Docker containers and volumes"
        echo "  - All configuration files (.env, configs/)"
        echo "  - All generated keys and certificates"
        echo "  - All user bundles (outputs/)"
        echo "  - Global 'moav' command"
        echo ""
        warn "This cannot be undone! All keys and user configs will be lost."
    else
        info "This will remove:"
        echo "  - All Docker containers (data preserved in volumes)"
        echo "  - Global 'moav' command"
        echo ""
        echo "Preserved: .env, keys, user bundles, volumes"
        echo "Use --wipe to remove everything"
    fi
    echo ""

    if [[ "$assume_yes" == "true" ]]; then
        info "Proceeding non-interactively (--yes)"
    else
        read -r -p "Continue? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "Cancelled"
            return 0
        fi
    fi

    echo ""

    # Stop and remove containers
    if command -v docker &>/dev/null && [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
        info "Stopping Docker containers..."
        cd "$SCRIPT_DIR"

        # List running containers before removing
        local containers
        containers=$(docker compose --profile all ps -q 2>/dev/null || true)
        if [[ -n "$containers" ]]; then
            docker compose --profile all ps --format "  - {{.Name}}" 2>/dev/null || true
        fi

        if [[ "$wipe" == "true" ]]; then
            # Remove containers AND volumes
            docker compose --profile all down -v --remove-orphans 2>/dev/null || true
            echo "  Removed containers and volumes"
        else
            # Remove containers only, keep volumes
            docker compose --profile all down --remove-orphans 2>/dev/null || true
            echo "  Removed containers (volumes preserved)"
        fi
        success "Containers removed"
    fi

    # Wipe all generated files if --wipe
    if [[ "$wipe" == "true" ]]; then
        echo ""
        info "Removing configuration files..."

        # Helper: rm that falls back to sudo (Docker creates files as root)
        _wrm() { rm "$@" 2>/dev/null || sudo rm "$@" 2>/dev/null || true; }

        # Remove .env
        if [[ -f "$SCRIPT_DIR/.env" ]]; then
            _wrm -f "$SCRIPT_DIR/.env"
            echo "  - .env"
        fi

        # Remove generated sing-box config
        if [[ -f "$SCRIPT_DIR/configs/sing-box/config.json" ]]; then
            _wrm -f "$SCRIPT_DIR/configs/sing-box/config.json"
            echo "  - configs/sing-box/config.json"
        fi

        # Remove generated dnstt files
        if [[ -d "$SCRIPT_DIR/configs/dnstt" ]] && ls "$SCRIPT_DIR/configs/dnstt/"*.key "$SCRIPT_DIR/configs/dnstt/server.conf" "$SCRIPT_DIR/configs/dnstt/server.pub" &>/dev/null; then
            _wrm -f "$SCRIPT_DIR/configs/dnstt/server.conf"
            _wrm -f "$SCRIPT_DIR/configs/dnstt/server.pub"
            _wrm -f "$SCRIPT_DIR/configs/dnstt/"*.key
            _wrm -f "$SCRIPT_DIR/configs/dnstt/"*.key.hex
            echo "  - configs/dnstt/*"
        fi

        # Remove generated Slipstream files
        if [[ -f "$SCRIPT_DIR/configs/slipstream/cert.pem" ]]; then
            _wrm -f "$SCRIPT_DIR/configs/slipstream/cert.pem"
            echo "  - configs/slipstream/*"
        fi

        # Remove generated WireGuard files
        if [[ -f "$SCRIPT_DIR/configs/wireguard/wg0.conf" ]] || [[ -d "$SCRIPT_DIR/configs/wireguard/wg_confs" ]]; then
            _wrm -f "$SCRIPT_DIR/configs/wireguard/wg0.conf"
            _wrm -f "$SCRIPT_DIR/configs/wireguard/wg0.conf."*
            _wrm -f "$SCRIPT_DIR/configs/wireguard/server.pub"
            _wrm -f "$SCRIPT_DIR/configs/wireguard/server.key"
            _wrm -rf "$SCRIPT_DIR/configs/wireguard/wg_confs/"
            _wrm -rf "$SCRIPT_DIR/configs/wireguard/coredns/"
            _wrm -rf "$SCRIPT_DIR/configs/wireguard/templates/"
            _wrm -rf "$SCRIPT_DIR/configs/wireguard/peer"*
            echo "  - configs/wireguard/*"
        fi

        # Remove generated AmneziaWG files
        if [[ -f "$SCRIPT_DIR/configs/amneziawg/awg0.conf" ]]; then
            _wrm -f "$SCRIPT_DIR/configs/amneziawg/awg0.conf"
            _wrm -f "$SCRIPT_DIR/configs/amneziawg/server.pub"
            echo "  - configs/amneziawg/*"
        fi

        # Remove generated TrustTunnel files
        if [[ -f "$SCRIPT_DIR/configs/trusttunnel/vpn.toml" ]]; then
            _wrm -f "$SCRIPT_DIR/configs/trusttunnel/vpn.toml"
            _wrm -f "$SCRIPT_DIR/configs/trusttunnel/hosts.toml"
            _wrm -f "$SCRIPT_DIR/configs/trusttunnel/credentials.toml"
            echo "  - configs/trusttunnel/*"
        fi

        # Remove generated MasterDNS files
        if [[ -f "$SCRIPT_DIR/configs/masterdns/server_config.toml" ]]; then
            _wrm -f "$SCRIPT_DIR/configs/masterdns/server_config.toml"
            echo "  - configs/masterdns/*"
        fi

        # Remove generated GooseRelay files
        if [[ -f "$SCRIPT_DIR/configs/gooserelay/server_config.json" ]]; then
            _wrm -f "$SCRIPT_DIR/configs/gooserelay/server_config.json"
            echo "  - configs/gooserelay/*"
        fi

        # Remove generated Xray files
        if [[ -f "$SCRIPT_DIR/configs/xray/config.json" ]]; then
            _wrm -f "$SCRIPT_DIR/configs/xray/config.json"
            echo "  - configs/xray/config.json"
        fi

        # Remove generated telemt files
        if [[ -f "$SCRIPT_DIR/configs/telemt/config.toml" ]]; then
            _wrm -f "$SCRIPT_DIR/configs/telemt/config.toml"
            echo "  - configs/telemt/config.toml"
        fi

        # Remove outputs (bundles, keys)
        if [[ -d "$SCRIPT_DIR/outputs" ]] && ls -A "$SCRIPT_DIR/outputs" 2>/dev/null | grep -qv .gitkeep; then
            local bundle_count
            bundle_count=$(find "$SCRIPT_DIR/outputs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || echo "0")
            sudo find "$SCRIPT_DIR/outputs" -mindepth 1 -not -name '.gitkeep' -delete 2>/dev/null || true
            echo "  - outputs/ ($bundle_count user bundles)"
        fi

        # Remove state directory (user credentials)
        if [[ -d "$SCRIPT_DIR/state" ]]; then
            local user_count
            user_count=$(find "$SCRIPT_DIR/state/users" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || echo "0")
            sudo rm -rf "$SCRIPT_DIR/state/" 2>/dev/null || true
            echo "  - state/ ($user_count users)"
        fi

        # Remove certbot certificates
        if [[ -d "$SCRIPT_DIR/certbot" ]]; then
            sudo rm -rf "$SCRIPT_DIR/certbot/" 2>/dev/null || true
            echo "  - certbot/"
        fi

        success "Configuration files removed"

        # Ask about Docker images
        echo ""

        # External images used by MoaV (from docker-compose.yml)
        local external_image_patterns="prom/prometheus|grafana/grafana|prom/node-exporter|gcr.io/cadvisor|certbot/certbot|nginx:alpine"

        # Find MoaV-built images (moav-* prefix)
        local moav_images
        moav_images=$(docker images --format "{{.Repository}}:{{.Tag}} ({{.Size}})" 2>/dev/null | grep -E "^moav-" || true)

        # Find external images used by MoaV
        local external_images
        external_images=$(docker images --format "{{.Repository}}:{{.Tag}} ({{.Size}})" 2>/dev/null | grep -E "^($external_image_patterns)" || true)

        if [[ -n "$moav_images" ]] || [[ -n "$external_images" ]]; then
            info "Docker images found:"

            if [[ -n "$moav_images" ]]; then
                echo "  Built images:"
                echo "$moav_images" | while read -r img; do
                    echo "    - $img"
                done
            fi

            if [[ -n "$external_images" ]]; then
                echo "  External images (pulled):"
                echo "$external_images" | while read -r img; do
                    echo "    - $img"
                done
            fi

            echo ""
            local remove_images
            if [[ "$remove_imgs" == "true" ]]; then
                remove_images="y"
            elif [[ "$assume_yes" == "true" ]]; then
                remove_images="n"   # --yes keeps images unless --remove-images
            else
                read -r -p "Also remove Docker images? [y/N] " remove_images
            fi
            if [[ "$remove_images" =~ ^[Yy]$ ]]; then
                info "Removing Docker images..."
                # Remove moav-* images (include tag for images like moav-nginx:local)
                docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -E "^moav-" | xargs -r docker rmi -f 2>/dev/null || true
                # Remove external images
                docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -E "^($external_image_patterns)" | xargs -r docker rmi -f 2>/dev/null || true
                success "Docker images removed"
            else
                echo "  Docker images kept"
            fi
        fi
    fi

    # Remove shell completions
    uninstall_completions

    # Remove global symlink
    if [[ -e "$INSTALL_PATH" ]]; then
        echo ""
        if [[ -L "$INSTALL_PATH" ]]; then
            info "Removing global command..."
            if [[ -w "$(dirname "$INSTALL_PATH")" ]]; then
                rm -f "$INSTALL_PATH"
            else
                sudo rm -f "$INSTALL_PATH"
            fi
            echo "  - $INSTALL_PATH"
            echo "  - shell completions"
            success "Global command removed"
        else
            warn "$INSTALL_PATH is not a symlink, not removing"
        fi
    fi

    echo ""
    if [[ "$wipe" == "true" ]]; then
        success "MoaV completely uninstalled"
        echo ""
        echo "To reinstall:"
        echo "  curl -fsSL moav.sh/install.sh | bash"
        echo ""
        echo "Or locally:"
        echo "  cp .env.example .env && ./moav.sh"
    else
        success "MoaV uninstalled (data preserved)"
        echo ""
        echo "To reinstall with existing data:"
        echo "  ./moav.sh install"
        echo "  moav start"
    fi
}

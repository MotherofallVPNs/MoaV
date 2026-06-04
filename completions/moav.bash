#!/usr/bin/env bash
# Bash/Zsh completion for moav CLI
# Installed automatically by 'moav install'

# Zsh compatibility — guard for nounset (moav.sh runs under `set -u`).
if [[ -n "${ZSH_VERSION:-}" ]]; then
    autoload -U +X bashcompinit && bashcompinit
fi

_moav() {
    local cur prev cword
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    cword=$COMP_CWORD

    local commands="help version install uninstall check doctor bootstrap domainless profiles start stop restart status logs users user admin build test client donate conduit export import migrate-ip regenerate-users setup-dns update"
    local services="sing-box decoy wstunnel wireguard amneziawg dns-router dnstt slipstream masterdns gooserelay trusttunnel telemt xray admin psiphon-conduit snowflake grafana grafana-proxy prometheus cadvisor node-exporter clash-exporter singbox-exporter telemt-exporter xray-exporter wireguard-exporter amneziawg-exporter snowflake-exporter"
    local profiles="proxy wireguard amneziawg dnstunnel trusttunnel xhttp telegram admin conduit snowflake gooserelay monitoring client all"
    local service_aliases="singbox sing proxy reality wg ws tunnel dns slip mdns masterdns goose gooserelay relay tg mtproxy telegram conduit psiphon snow tor grafana-cdn"
    local protocols="auto reality trojan hysteria2 trusttunnel wireguard psiphon tor dnstt slipstream"

    # Resolve moav project directory (follow symlink)
    local moav_dir=""
    local moav_bin
    moav_bin="$(command -v moav 2>/dev/null)"
    if [[ -n "$moav_bin" && -L "$moav_bin" ]]; then
        moav_dir="$(cd "$(dirname "$(readlink -f "$moav_bin")")" && pwd)"
    elif [[ -f "./moav.sh" ]]; then
        moav_dir="$(pwd)"
    fi

    # Helper: list usernames from bundles directory
    _moav_users() {
        if [[ -n "$moav_dir" && -d "$moav_dir/outputs/bundles" ]]; then
            local d
            for d in "$moav_dir/outputs/bundles"/*/; do
                [[ -d "$d" ]] && basename "$d"
            done
        fi
    }

    # First argument: main command
    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
        return
    fi

    local cmd="${COMP_WORDS[1]}"

    case "$cmd" in
        start)
            COMPREPLY=($(compgen -W "$profiles $service_aliases" -- "$cur"))
            ;;
        stop)
            COMPREPLY=($(compgen -W "$services $service_aliases -r" -- "$cur"))
            ;;
        restart)
            COMPREPLY=($(compgen -W "$services $service_aliases" -- "$cur"))
            ;;
        logs)
            COMPREPLY=($(compgen -W "$services $service_aliases -n" -- "$cur"))
            ;;
        build)
            case "$prev" in
                build)
                    COMPREPLY=($(compgen -W "$services $profiles --local --no-cache" -- "$cur"))
                    ;;
                --local)
                    COMPREPLY=($(compgen -W "cadvisor clash-exporter prometheus grafana node-exporter nginx certbot all --no-cache" -- "$cur"))
                    ;;
                *)
                    COMPREPLY=($(compgen -W "--no-cache" -- "$cur"))
                    ;;
            esac
            ;;
        user)
            local subcmd="${COMP_WORDS[2]:-}"
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "list ls add revoke rm remove delete package pkg" -- "$cur"))
            else
                case "$subcmd" in
                    add)
                        COMPREPLY=($(compgen -W "--batch --prefix --package -p $(_moav_users)" -- "$cur"))
                        ;;
                    revoke|rm|remove|delete|package|pkg)
                        COMPREPLY=($(compgen -W "$(_moav_users)" -- "$cur"))
                        ;;
                esac
            fi
            ;;
        admin)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "password" -- "$cur"))
            fi
            ;;
        donate)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "setup list delete status info" -- "$cur"))
            fi
            ;;
        conduit)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "link status help" -- "$cur"))
            fi
            ;;
        test)
            COMPREPLY=($(compgen -W "$(_moav_users) --json -v --verbose" -- "$cur"))
            ;;
        client)
            local subcmd="${COMP_WORDS[2]:-}"
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "test connect build" -- "$cur"))
            else
                case "$subcmd" in
                    test)
                        COMPREPLY=($(compgen -W "$(_moav_users) --json -v --verbose" -- "$cur"))
                        ;;
                    connect)
                        case "$prev" in
                            --protocol|-p)
                                COMPREPLY=($(compgen -W "$protocols" -- "$cur"))
                                ;;
                            *)
                                COMPREPLY=($(compgen -W "$(_moav_users) --protocol -p" -- "$cur"))
                                ;;
                        esac
                        ;;
                esac
            fi
            ;;
        update)
            COMPREPLY=($(compgen -W "-b --branch" -- "$cur"))
            ;;
        doctor)
            COMPREPLY=($(compgen -W "docker memory disk dns services config ports env updates all" -- "$cur"))
            ;;
        uninstall)
            COMPREPLY=($(compgen -W "--wipe" -- "$cur"))
            ;;
        import)
            COMPREPLY=($(compgen -f -- "$cur"))
            ;;
        export)
            COMPREPLY=($(compgen -f -- "$cur"))
            ;;
    esac
}

complete -F _moav moav

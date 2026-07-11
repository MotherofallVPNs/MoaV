#!/bin/bash
# =============================================================================
# MoaV Quick Installer
# Usage: curl -fsSL moav.sh/install.sh | bash
#        curl -fsSL moav.sh/install.sh | bash -s -- -b dev    # use 'dev' branch
#
# This script will:
# 1. Install missing prerequisites (Docker, git, qrencode) with user confirmation
# 2. Clone MoaV to /opt/moav (or update if exists)
# 3. Guide you through the setup process
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Configuration
REPO_URL="https://github.com/shayanb/MoaV.git"
INSTALL_DIR="${MOAV_INSTALL_DIR:-/opt/moav}"
BRANCH="${MOAV_BRANCH:-main}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--branch)
            BRANCH="$2"
            shift 2
            ;;
        -h|--help)
            echo "MoaV Installer"
            echo ""
            echo "Usage: curl -fsSL moav.sh/install.sh | bash -s -- [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -b, --branch BRANCH   Use specified git branch (default: main)"
            echo "  -h, --help            Show this help"
            echo ""
            echo "Environment variables:"
            echo "  MOAV_INSTALL_DIR      Installation directory (default: /opt/moav)"
            echo "  MOAV_BRANCH           Git branch to use (default: main)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage"
            exit 1
            ;;
    esac
done

# Helper functions
info() { echo -e "${BLUE}$*${NC}"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*"; }

confirm() {
    local prompt="${1:-Continue?}"
    local default="${2:-n}"

    # Detect interactivity by actually opening /dev/tty — under setsid the
    # device node exists but opening returns ENXIO, so -e would lie.
    if [[ ! -t 0 ]] && ! { : < /dev/tty; } 2>/dev/null; then
        [[ "$default" == "y" ]]
        return
    fi

    # Read from /dev/tty to work with curl | bash
    if [[ "$default" == "y" ]]; then
        printf "%s [Y/n] " "$prompt"
    else
        printf "%s [y/N] " "$prompt"
    fi

    # Group the redirect so bash's redirect error is captured by 2>/dev/null.
    if { read -n 1 -r REPLY < /dev/tty; } 2>/dev/null; then
        echo ""
    else
        echo ""
        [[ "$default" == "y" ]]
        return
    fi

    if [[ "$default" == "y" ]]; then
        [[ ! $REPLY =~ ^[Nn]$ ]]
    else
        [[ $REPLY =~ ^[Yy]$ ]]
    fi
}

# Wait for apt/dpkg lock to be released (fresh VPS often has unattended-upgrades running)
wait_for_apt_lock() {
    local max_wait=120
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 || fuser /var/lib/apt/lists/lock &>/dev/null 2>&1; do
        if [[ $waited -eq 0 ]]; then
            info "Waiting for apt lock to be released (another package manager is running)..."
        fi
        sleep 5
        waited=$((waited + 5))
        if [[ $waited -ge $max_wait ]]; then
            warn "Waited ${max_wait}s for apt lock. Proceeding anyway..."
            break
        fi
    done
    if [[ $waited -gt 0 && $waited -lt $max_wait ]]; then
        success "apt lock released after ${waited}s"
    fi
}

# Detect OS
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/fedora-release ]]; then
        echo "rhel"
    elif [[ -f /etc/alpine-release ]]; then
        echo "alpine"
    else
        echo "unknown"
    fi
}

# Banner
echo -e "${CYAN}"
cat << 'EOF'
███╗   ███╗ ██████╗  █████╗ ██╗   ██╗
████╗ ████║██╔═══██╗██╔══██╗██║   ██║
██╔████╔██║██║   ██║███████║██║   ██║
██║╚██╔╝██║██║   ██║██╔══██║╚██╗ ██╔╝
██║ ╚═╝ ██║╚██████╔╝██║  ██║ ╚████╔╝
╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═╝  ╚═══╝

       Mother of all VPNs
EOF
echo -e "${NC}"

info "MoaV Installer"
if [[ "$BRANCH" != "main" ]]; then
    echo -e "${YELLOW}Using branch: $BRANCH${NC}"
fi
echo ""

OS_TYPE=$(detect_os)
info "Detected OS: $OS_TYPE"
echo ""

# =============================================================================
# Check and Install Prerequisites
# =============================================================================

info "Checking prerequisites..."
echo ""

needs_install=()

# Check git
if command -v git &>/dev/null; then
    success "git is installed"
else
    warn "git is not installed"
    needs_install+=("git")
fi

# Check Docker
if command -v docker &>/dev/null; then
    success "Docker is installed"
else
    warn "Docker is not installed"
    needs_install+=("docker")
fi

# Check Docker Compose
if docker compose version &>/dev/null 2>&1; then
    success "Docker Compose is installed"
elif command -v docker-compose &>/dev/null; then
    success "docker-compose (legacy) is installed"
else
    if [[ ! " ${needs_install[*]} " =~ " docker " ]]; then
        warn "Docker Compose is not installed"
        needs_install+=("docker-compose")
    fi
fi

# Check if Docker is running (only if installed)
if command -v docker &>/dev/null; then
    if docker info &>/dev/null 2>&1; then
        success "Docker daemon is running"
    else
        warn "Docker daemon is not running"
    fi
fi

# Check qrencode (optional but recommended)
if command -v qrencode &>/dev/null; then
    success "qrencode is installed"
else
    warn "qrencode is not installed (needed for QR codes)"
    needs_install+=("qrencode")
fi

# Check jq (required for user management)
if command -v jq &>/dev/null; then
    success "jq is installed"
else
    warn "jq is not installed (needed for user management)"
    needs_install+=("jq")
fi

# Check zip (required for user packages)
if command -v zip &>/dev/null; then
    success "zip is installed"
else
    warn "zip is not installed (needed for user packages)"
    needs_install+=("zip")
fi

echo ""

# =============================================================================
# Install Missing Prerequisites
# =============================================================================

if [[ ${#needs_install[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Missing packages: ${needs_install[*]}${NC}"
    echo ""

    if confirm "Install missing packages?" "y"; then
        echo ""

        # On fresh Debian/Ubuntu VPS, unattended-upgrades often holds the apt lock at boot
        [[ "$OS_TYPE" == "debian" ]] && wait_for_apt_lock

        for pkg in "${needs_install[@]}"; do
            case "$pkg" in
                git)
                    info "Installing git..."
                    case "$OS_TYPE" in
                        debian)
                            sudo DEBIAN_FRONTEND=noninteractive apt update && sudo DEBIAN_FRONTEND=noninteractive apt install -y git
                            ;;
                        rhel)
                            sudo dnf install -y git || sudo yum install -y git
                            ;;
                        macos)
                            if command -v brew &>/dev/null; then
                                brew install git
                            else
                                error "Please install Xcode Command Line Tools: xcode-select --install"
                                exit 1
                            fi
                            ;;
                        alpine)
                            sudo apk add git
                            ;;
                        *)
                            error "Cannot auto-install git on this OS. Please install manually."
                            exit 1
                            ;;
                    esac
                    success "git installed"
                    ;;

                docker|docker-compose)
                    info "Installing Docker..."
                    case "$OS_TYPE" in
                        debian|rhel)
                            # Official Docker install script handles both Docker and Compose
                            # DEBIAN_FRONTEND prevents interactive prompts during install
                            curl -fsSL https://get.docker.com | sudo DEBIAN_FRONTEND=noninteractive sh

                            # Add current user to docker group
                            sudo usermod -aG docker "$(whoami)" 2>/dev/null || true

                            # Start Docker
                            sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || true
                            sudo systemctl enable docker 2>/dev/null || true

                            success "Docker installed"
                            echo ""
                            warn "You may need to log out and back in for docker group permissions."
                            warn "Or run: newgrp docker"
                            ;;
                        macos)
                            error "Please install Docker Desktop from: https://www.docker.com/products/docker-desktop"
                            echo "After installing, run this script again."
                            exit 1
                            ;;
                        alpine)
                            sudo apk add docker docker-compose
                            sudo rc-update add docker boot
                            sudo service docker start
                            success "Docker installed"
                            ;;
                        *)
                            error "Cannot auto-install Docker on this OS."
                            echo "Please install from: https://docs.docker.com/engine/install/"
                            exit 1
                            ;;
                    esac
                    # Skip docker-compose if we already installed docker (it includes compose)
                    if [[ "$pkg" == "docker" ]]; then
                        needs_install=("${needs_install[@]/docker-compose}")
                    fi
                    ;;

                qrencode)
                    info "Installing qrencode..."
                    case "$OS_TYPE" in
                        debian)
                            sudo DEBIAN_FRONTEND=noninteractive apt update && sudo DEBIAN_FRONTEND=noninteractive apt install -y qrencode
                            ;;
                        rhel)
                            sudo dnf install -y qrencode || sudo yum install -y qrencode
                            ;;
                        macos)
                            if command -v brew &>/dev/null; then
                                brew install qrencode
                            else
                                warn "Homebrew not installed. Skipping qrencode."
                                warn "Install with: brew install qrencode"
                                continue
                            fi
                            ;;
                        alpine)
                            sudo apk add libqrencode-tools
                            ;;
                        *)
                            warn "Cannot auto-install qrencode on this OS. Skipping."
                            continue
                            ;;
                    esac
                    success "qrencode installed"
                    ;;

                jq)
                    info "Installing jq..."
                    case "$OS_TYPE" in
                        debian)
                            sudo DEBIAN_FRONTEND=noninteractive apt update && sudo DEBIAN_FRONTEND=noninteractive apt install -y jq
                            ;;
                        rhel)
                            sudo dnf install -y jq || sudo yum install -y jq
                            ;;
                        macos)
                            if command -v brew &>/dev/null; then
                                brew install jq
                            else
                                warn "Homebrew not installed. Skipping jq."
                                warn "Install with: brew install jq"
                                continue
                            fi
                            ;;
                        alpine)
                            sudo apk add jq
                            ;;
                        *)
                            warn "Cannot auto-install jq on this OS. Skipping."
                            continue
                            ;;
                    esac
                    success "jq installed"
                    ;;

                zip)
                    info "Installing zip..."
                    case "$OS_TYPE" in
                        debian)
                            sudo DEBIAN_FRONTEND=noninteractive apt update && sudo DEBIAN_FRONTEND=noninteractive apt install -y zip
                            ;;
                        rhel)
                            sudo dnf install -y zip || sudo yum install -y zip
                            ;;
                        macos)
                            # zip is typically pre-installed on macOS
                            if ! command -v zip &>/dev/null; then
                                if command -v brew &>/dev/null; then
                                    brew install zip
                                else
                                    warn "zip not found and Homebrew not installed. Skipping."
                                    continue
                                fi
                            fi
                            ;;
                        alpine)
                            sudo apk add zip
                            ;;
                        *)
                            warn "Cannot auto-install zip on this OS. Skipping."
                            continue
                            ;;
                    esac
                    success "zip installed"
                    ;;
            esac
            echo ""
        done
    else
        if [[ " ${needs_install[*]} " =~ " docker " ]] || [[ " ${needs_install[*]} " =~ " git " ]]; then
            error "Docker and git are required. Please install them and try again."
            echo ""
            echo "Install Docker: https://docs.docker.com/engine/install/"
            exit 1
        fi
    fi
fi

# Verify Docker is working
if ! docker info &>/dev/null 2>&1; then
    echo ""
    warn "Docker daemon is not running."

    if [[ "$OS_TYPE" != "macos" ]]; then
        if confirm "Start Docker now?"; then
            sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || true
            sleep 2

            if docker info &>/dev/null 2>&1; then
                success "Docker started"
            else
                error "Failed to start Docker. You may need to:"
                echo "  1. Log out and back in (for group permissions)"
                echo "  2. Run: sudo systemctl start docker"
                echo "  3. Run this script again"
                exit 1
            fi
        fi
    else
        error "Please start Docker Desktop and run this script again."
        exit 1
    fi
fi

echo ""

# =============================================================================
# Offer swap on low-RAM hosts (image builds, esp. the Go compiles, can briefly
# exceed RAM and get OOM-killed without swap). Opt-in; needs root + free disk.
# =============================================================================
maybe_offer_swap() {
    [[ "$(uname -s)" == "Linux" ]] || return 0
    [[ -r /proc/meminfo ]] || return 0
    # Never make host changes on a fully non-interactive install (cloud-init/CI).
    [[ -t 0 || -e /dev/tty ]] || return 0

    local total_mb swap_kb
    total_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    swap_kb=$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)

    # Only when RAM is tight (<= ~2.5 GB) and no swap is configured.
    [[ "$total_mb" -gt 0 && "$total_mb" -le 2560 ]] || return 0
    [[ "${swap_kb:-0}" -eq 0 ]] || return 0

    echo ""
    warn "Low RAM detected (${total_mb} MB) and no swap is configured."
    echo "  Building the images (the Go compiles) can briefly exceed RAM and get"
    echo "  OOM-killed. A small swapfile makes builds reliable on low-RAM VPSes."
    echo ""
    if ! confirm "Create a 2 GB swapfile at /swapfile and enable it?" "y"; then
        info "Skipping swap. If a build fails, retry serially: MOAV_BUILD_PARALLEL=1 moav build"
        return 0
    fi

    local SUDO=""
    if [[ "$(id -u)" -ne 0 ]]; then
        if command -v sudo &>/dev/null; then SUDO="sudo"; else
            warn "Need root to create swap; skipping (create /swapfile manually if you like)."
            return 0
        fi
    fi

    if [[ -e /swapfile ]] || swapon --show 2>/dev/null | grep -q '/swapfile'; then
        warn "/swapfile already exists; leaving it as-is."
        return 0
    fi

    # Need ~2.2 GB free on / for the swapfile.
    local avail_mb
    avail_mb=$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -n "$avail_mb" && "$avail_mb" -lt 2200 ]]; then
        warn "Not enough free disk on / (${avail_mb} MB) for a 2 GB swapfile; skipping."
        return 0
    fi

    info "Creating 2 GB swapfile..."
    if $SUDO fallocate -l 2G /swapfile 2>/dev/null || \
       $SUDO dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none 2>/dev/null; then
        if $SUDO chmod 600 /swapfile && $SUDO mkswap /swapfile >/dev/null 2>&1 && $SUDO swapon /swapfile 2>/dev/null; then
            if ! grep -q '^/swapfile ' /etc/fstab 2>/dev/null; then
                echo '/swapfile none swap sw 0 0' | $SUDO tee -a /etc/fstab >/dev/null 2>&1 || true
            fi
            success "2 GB swap enabled (persisted in /etc/fstab)."
        else
            warn "Could not enable swap; cleaning up /swapfile."
            $SUDO swapoff /swapfile 2>/dev/null || true
            $SUDO rm -f /swapfile 2>/dev/null || true
        fi
    else
        warn "Could not allocate /swapfile; skipping swap."
        $SUDO rm -f /swapfile 2>/dev/null || true
    fi
}
# Best-effort; never let a swap hiccup abort the installer (set -e is on).
maybe_offer_swap || true

# Offer BBR + kernel network tuning at install time. Mirrors `moav net apply`.
maybe_offer_net_tuning() {
    [[ "$(uname -s)" == "Linux" ]] || return 0
    [[ -t 0 || -e /dev/tty ]] || return 0   # non-interactive → skip

    local NT_CONF=/etc/sysctl.d/99-moav-net.conf
    [[ -f "$NT_CONF" ]] && return 0   # already applied

    # tcp_bbr is a module on most distros — modprobe before declaring absent.
    local avail
    avail=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
    if [[ " $avail " != *" bbr "* ]]; then
        ${SUDO:-} modprobe tcp_bbr 2>/dev/null || sudo modprobe tcp_bbr 2>/dev/null || true
        avail=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
    fi
    [[ " $avail " != *" bbr "* ]] && return 0

    local current_cc
    current_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "?")

    echo ""
    echo -e "${CYAN}Enable Linux network tuning (BBR + larger buffers)?${NC}"
    echo "  Current: tcp_congestion_control=${current_cc}"
    echo "  Real-world testing: 2–5× TCP throughput on long-RTT or lossy paths."
    echo "  Helps UDP/QUIC too (Hysteria2, WireGuard need bigger UDP buffers)."
    echo "  Reversible: ${WHITE}moav net revert${NC} removes the file + reloads sysctl."
    echo ""
    if ! confirm "Apply network tuning?" "y"; then
        info "Skipping network tuning. You can apply later: moav net apply"
        return 0
    fi

    local SUDO=""
    if [[ "$(id -u)" -ne 0 ]]; then
        if command -v sudo &>/dev/null; then SUDO="sudo"; else
            warn "Need root or sudo to write $NT_CONF; skipping. Re-run later as root: moav net apply"
            return 0
        fi
    fi

    # Compute buffer max. 16 MiB on <2GB hosts, 32 MiB otherwise.
    local total_mb bmax
    total_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    if [[ "$total_mb" -gt 0 && "$total_mb" -lt 2048 ]]; then
        bmax=16777216
    else
        bmax=33554432
    fi

    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
# MoaV network tuning — generated $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Reversible: moav net revert. Docs: docs/OPSEC.md → "Network tuning".

# BBR needs fq for pacing.
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc          = fq

net.core.rmem_max               = ${bmax}
net.core.wmem_max               = ${bmax}
net.ipv4.tcp_rmem               = 4096 131072 ${bmax}
net.ipv4.tcp_wmem               = 4096 16384 ${bmax}

# UDP defaults (Hysteria2, WireGuard, quic-go)
net.core.rmem_default           = 1048576
net.core.wmem_default           = 1048576

net.core.netdev_max_backlog     = 16384
net.core.somaxconn              = 8192
net.ipv4.tcp_max_syn_backlog    = 8192

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing           = 1
net.ipv4.tcp_notsent_lowat         = 131072

# tcp_fastopen DELIBERATELY UNSET — middleboxes drop SYN+data, raising latency.
EOF

    if $SUDO install -m 0644 "$tmp" "$NT_CONF"; then
        rm -f "$tmp"
        if $SUDO sysctl -p "$NT_CONF" >/dev/null 2>&1; then
            success "Network tuning applied → $NT_CONF (buffer max: $((bmax / 1048576)) MiB)"
        else
            warn "Wrote $NT_CONF but sysctl reload failed — will activate on next boot."
        fi
    else
        rm -f "$tmp"
        warn "Could not write $NT_CONF; skipping. Re-run later: moav net apply"
    fi
}
maybe_offer_net_tuning || true

# =============================================================================
# Clone or Update MoaV
# =============================================================================

if [ -d "$INSTALL_DIR" ]; then
    warn "MoaV directory exists at $INSTALL_DIR"

    if confirm "Update existing installation?"; then
        info "Updating MoaV (branch: $BRANCH)..."
        cd "$INSTALL_DIR"

        # Check for local changes that would block git pull
        changes=$(git status --porcelain 2>/dev/null)

        if [ -n "$changes" ]; then
            echo ""
            echo -e "${YELLOW}⚠ Local changes detected:${NC}"
            echo ""
            # Show modified files (limit to 10 for readability)
            echo "$changes" | head -10 | while read -r line; do
                echo -e "    ${CYAN}$line${NC}"
            done
            change_count=$(echo "$changes" | wc -l | tr -d ' ')
            if [ "$change_count" -gt 10 ]; then
                echo "    ... and $((change_count - 10)) more files"
            fi
            echo ""
            echo "These changes will conflict with the update."
            echo ""
            echo "Options:"
            echo -e "  ${WHITE}1)${NC} Stash changes (save temporarily, can restore later)"
            echo -e "  ${WHITE}2)${NC} Discard changes (reset to clean state - ${RED}LOSES YOUR CHANGES${NC})"
            echo -e "  ${WHITE}3)${NC} Abort (handle manually)"
            echo ""
            printf "Choice [1/2/3]: "
            read -r choice

            case "$choice" in
                1|"")
                    info "Stashing local changes..."
                    stash_msg="moav-update-$(date +%Y%m%d-%H%M%S)"
                    if git stash push -m "$stash_msg" --include-untracked; then
                        success "Changes stashed"
                        echo ""
                        echo -e "${CYAN}To restore your changes later:${NC}"
                        echo -e "  ${WHITE}cd $INSTALL_DIR && git stash pop${NC}"
                        echo ""
                    else
                        error "Failed to stash changes"
                        echo "  Try manually: cd $INSTALL_DIR && git stash"
                        exit 1
                    fi
                    ;;
                2)
                    echo ""
                    echo -e "${RED}WARNING: This will permanently discard all local changes!${NC}"
                    printf "Are you sure? [y/N]: "
                    read -r confirm_discard
                    if [ "$confirm_discard" = "y" ] || [ "$confirm_discard" = "Y" ]; then
                        info "Discarding local changes..."
                        git checkout -- . 2>/dev/null
                        git clean -fd 2>/dev/null
                        success "Local changes discarded"
                        echo ""
                    else
                        info "Aborted"
                        exit 0
                    fi
                    ;;
                3|*)
                    info "Aborted. Handle changes manually:"
                    echo ""
                    echo -e "  ${WHITE}cd $INSTALL_DIR${NC}"
                    echo -e "  ${WHITE}git status${NC}           # View changes"
                    echo -e "  ${WHITE}git stash${NC}            # Save changes temporarily"
                    echo -e "  ${WHITE}git checkout -- .${NC}    # Discard changes"
                    echo ""
                    exit 0
                    ;;
            esac
        fi

        git fetch origin
        git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH" "origin/$BRANCH"
        if git pull origin "$BRANCH" || git pull; then
            success "MoaV updated"
        else
            error "Failed to update. Check git status."
            exit 1
        fi
    else
        info "Using existing installation."
    fi
else
    info "Installing MoaV to $INSTALL_DIR (branch: $BRANCH)..."

    # Check if we need sudo
    parent_dir=$(dirname "$INSTALL_DIR")
    if [ -w "$parent_dir" ] 2>/dev/null; then
        git clone -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
    else
        info "Need sudo to create $INSTALL_DIR"
        sudo mkdir -p "$INSTALL_DIR"
        sudo chown "$(whoami)" "$INSTALL_DIR"
        git clone -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
    fi

    success "MoaV cloned (branch: $BRANCH)"
fi

cd "$INSTALL_DIR"

# Make scripts executable
chmod +x moav.sh
chmod +x scripts/*.sh 2>/dev/null || true

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  MoaV installed successfully!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""

# =============================================================================
# Global Installation
# =============================================================================

echo -e "${CYAN}Install 'moav' command globally?${NC}"
echo "  This lets you run 'moav' from anywhere instead of './moav.sh'"
echo ""

if confirm "Install globally?" "y"; then
    echo ""
    ./moav.sh install
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}  Installation complete!${NC}"
    echo ""
    echo -e "  Location:  ${CYAN}$INSTALL_DIR${NC}"
    echo -e "  Command:   ${WHITE}moav${NC}"
    echo ""
    echo -e "  ${CYAN}Next step:${NC} Run ${WHITE}moav${NC} to configure and bootstrap your VPN"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
else
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}  Installation complete!${NC}"
    echo ""
    echo -e "  Location:  ${CYAN}$INSTALL_DIR${NC}"
    echo ""
    echo -e "  ${CYAN}Next step:${NC} Run the following to configure and bootstrap your VPN:"
    echo -e "             ${WHITE}cd $INSTALL_DIR && ./moav.sh${NC}"
    echo ""
    echo -e "  ${YELLOW}Tip:${NC} You can install globally later with: ${WHITE}./moav.sh install${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
fi

echo ""
echo -e "${CYAN}Documentation:${NC} https://github.com/shayanb/MoaV"
echo -e "${CYAN}Website:${NC} https://moav.sh"
echo ""

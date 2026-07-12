#!/bin/bash
# =============================================================================
# MoaV Cloud-Init Script
# For one-click VPS deployment (DigitalOcean, Vultr, Linode, Hetzner)
#
# This script runs on first boot and:
# 1. Installs Docker and prerequisites
# 2. Clones MoaV to /opt/moav
# 3. Sets up first-login prompt to run interactive setup
#
# Usage: Paste this URL in your VPS provider's "user-data" or "cloud-init" field:
#        https://moav.sh/cloud-init.sh
# =============================================================================

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Log file for debugging
exec > >(tee -a /var/log/moav-cloud-init.log) 2>&1
echo "[MoaV Cloud-Init] Starting at $(date)"

# =============================================================================
# Install Prerequisites
# =============================================================================

echo "[MoaV Cloud-Init] Updating system packages..."
apt-get update -qq

echo "[MoaV Cloud-Init] Installing prerequisites..."
apt-get install -y -qq git curl qrencode jq zip ca-certificates gnupg

# Install Docker
echo "[MoaV Cloud-Init] Installing Docker..."
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi

echo "[MoaV Cloud-Init] Docker installed: $(docker --version)"

# =============================================================================
# Clone MoaV
# =============================================================================

INSTALL_DIR="/opt/moav"

echo "[MoaV Cloud-Init] Cloning MoaV to $INSTALL_DIR..."
if [ -d "$INSTALL_DIR" ]; then
    cd "$INSTALL_DIR"
    git pull origin main || true
else
    git clone https://github.com/MotherofallVPNs/moav.git "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"
chmod +x moav.sh
chmod +x scripts/*.sh 2>/dev/null || true

# Install moav command globally
./moav.sh install

echo "[MoaV Cloud-Init] MoaV installed successfully"

# =============================================================================
# Setup First-Login Prompt
# =============================================================================

echo "[MoaV Cloud-Init] Setting up first-login prompt..."

cat > /etc/profile.d/moav-welcome.sh << 'WELCOME_SCRIPT'
#!/bin/bash
# MoaV First-Login Welcome Script

# Only show for interactive shells
[[ $- != *i* ]] && return

# Only show if MoaV hasn't been bootstrapped yet
if [ ! -d "/opt/moav/outputs/bundles" ] || [ -z "$(ls -A /opt/moav/outputs/bundles 2>/dev/null)" ]; then
    echo ""
    echo -e "\033[0;36m"
    cat << 'EOF'
███╗   ███╗ ██████╗  █████╗ ██╗   ██╗
████╗ ████║██╔═══██╗██╔══██╗██║   ██║
██╔████╔██║██║   ██║███████║██║   ██║
██║╚██╔╝██║██║   ██║██╔══██║╚██╗ ██╔╝
██║ ╚═╝ ██║╚██████╔╝██║  ██║ ╚████╔╝
╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═╝  ╚═══╝
EOF
    echo -e "\033[0m"
    echo -e "\033[1;32m  Welcome to your MoaV Server!\033[0m"
    echo ""
    echo -e "  Your server is ready to be configured."
    echo -e "  Run \033[1;37mmoav\033[0m to start the interactive setup."
    echo ""
    echo -e "  \033[0;33mNote:\033[0m Make sure your domain DNS is pointing to this server's IP."
    echo ""

    # Auto-prompt to run moav
    echo -e "\033[0;36mWould you like to run the setup now? [Y/n]\033[0m "
    read -t 30 -n 1 -r REPLY < /dev/tty 2>/dev/null || REPLY="y"
    echo ""

    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        moav
    else
        echo -e "  Run \033[1;37mmoav\033[0m when you're ready to set up."
        echo ""
    fi
fi
WELCOME_SCRIPT

chmod +x /etc/profile.d/moav-welcome.sh

# =============================================================================
# Finalize
# =============================================================================

echo "[MoaV Cloud-Init] Complete at $(date)"
echo "[MoaV Cloud-Init] SSH in and run 'moav' to start setup"

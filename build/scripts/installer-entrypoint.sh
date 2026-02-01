#!/bin/bash
# installer-entrypoint.sh - Custom entrypoint for ITL Talos installer
# Prepares the installer with branding and security configurations

set -e

# Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Display ITL banner on startup
display_banner() {
    cat << 'EOF'

╔════════════════════════════════════════════════════════════════════╗
║    ██╗████████╗██╗         ████████╗ █████╗ ██╗      ██████╗ ███████╗
║    ██║╚══██╔══╝██║         ╚══██╔══╝██╔══██╗██║     ██╔═══██╗██╔════╝
║    ██║   ██║   ██║            ██║   ███████║██║     ██║   ██║███████╗
║    ██║   ██║   ██║            ██║   ██╔══██║██║     ██║   ██║╚════██║
║    ██║   ██║   ███████╗       ██║   ██║  ██║███████╗╚██████╔╝███████║
║    ╚═╝   ╚═╝   ╚══════╝       ╚═╝   ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚══════╝
║                    HARDENED OS FOR KUBERNETES                     ║
║                                                                    ║
║  Container: ITL.Talos.HardenedOS Installer                        ║
║  Security Level: MAXIMUM                                          ║
║  Status: Ready for deployment                                     ║
╚════════════════════════════════════════════════════════════════════╝

EOF
}

# Log function
log_info() {
    echo -e "${BLUE}[*]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

# Display banner
display_banner
log_info "ITL.Talos.HardenedOS Installer Starting..."

# Run branding initialization if available
if [ -x /usr/local/bin/branding-init ]; then
    log_info "Running branding initialization..."
    /usr/local/bin/branding-init
else
    log_info "Branding init script not found, continuing..."
fi

# Log environment information
log_info "Environment information:"
log_info "  Talos Version: $(talosctl version 2>/dev/null || echo 'unknown')"
log_info "  Hostname: $(hostname)"
log_info "  Kernel: $(uname -r)"

log_success "Installer ready for Talos deployment"

# Pass all arguments to the original talosctl command or installer process
# This allows the container to function as a drop-in replacement
exec "$@"

#!/bin/bash
# branding-init.sh - Initialize ITL branding in Talos installer
# Sets up custom banners, logos, and branding configuration

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[*]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Main initialization
log_info "Initializing ITL branding for Talos installer"

# Verify branding files exist
if [ ! -f /etc/issue ]; then
    log_error "Console banner not found at /etc/issue"
    exit 1
fi

if [ ! -f /usr/share/talos/logo.png ]; then
    log_warning "Boot logo not found at /usr/share/talos/logo.png"
fi

# Display branding information
log_info "Branding Configuration:"
log_info "  Console Banner: /etc/issue"
log_info "  Boot Logo: /usr/share/talos/logo.png"
log_info "  Boot Logo PPM: /usr/share/talos/logo.ppm"

# Verify file permissions
if [ -r /etc/issue ]; then
    log_success "Console banner readable"
else
    log_error "Console banner not readable"
    exit 1
fi

# Create branding metadata
cat > /etc/itl-branding-info.txt << 'EOF'
╔════════════════════════════════════════════════════════════════════╗
║    ██╗████████╗██╗         ████████╗ █████╗ ██╗      ██████╗ ███████╗
║    ██║╚══██╔══╝██║         ╚══██╔══╝██╔══██╗██║     ██╔═══██╗██╔════╝
║    ██║   ██║   ██║            ██║   ███████║██║     ██║   ██║███████╗
║    ██║   ██║   ██║            ██║   ██╔══██║██║     ██║   ██║╚════██║
║    ██║   ██║   ███████╗       ██║   ██║  ██║███████╗╚██████╔╝███████║
║    ╚═╝   ╚═╝   ╚══════╝       ╚═╝   ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚══════╝
║                    HARDENED OS FOR KUBERNETES                     ║
║                                                                    ║
║  Custom Image with ITL Branding                                   ║
║  Security: MAXIMUM | Encryption: LUKS2+TPM | Auth: Keycloak     ║
╚════════════════════════════════════════════════════════════════════╝
EOF

chmod 644 /etc/itl-branding-info.txt
log_success "Branding metadata created"

# Test console banner display
log_info "Console banner preview:"
head -n 15 /etc/issue || log_warning "Failed to display banner preview"

log_success "ITL branding initialization complete"

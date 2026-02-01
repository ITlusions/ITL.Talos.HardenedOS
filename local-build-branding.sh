#!/bin/bash
set -e

echo "[*] Starting local branding asset build test..."

# Create directories
mkdir -p branding/logos branding/output

# Install required tools
echo "[*] Installing tools..."
apt-get update -qq > /dev/null 2>&1
apt-get install -y imagemagick netpbm figlet toilet > /dev/null 2>&1
echo "[✓] Tools installed"

# Generate ASCII art banners
echo "[*] Generating ASCII art banners..."
mkdir -p branding/output
figlet -f standard "ITL TALOS" > branding/output/title.txt
toilet -f future "HARDENED OS" >> branding/output/title.txt
echo "[✓] ASCII art generated"

# Create console banner
echo "[*] Creating console banner..."
cat << 'EOF' > branding/output/console-banner.txt
╔════════════════════════════════════════════════════════════════════╗
║    ██╗████████╗██╗         ████████╗ █████╗ ██╗      ██████╗ ███████╗
║    ██║╚══██╔══╝██║         ╚══██╔══╝██╔══██╗██║     ██╔═══██╗██╔════╝
║    ██║   ██║   ██║            ██║   ███████║██║     ██║   ██║███████╗
║    ██║   ██║   ██║            ██║   ██╔══██║██║     ██║   ██║╚════██║
║    ██║   ██║   ███████╗       ██║   ██║  ██║███████╗╚██████╔╝███████║
║    ╚═╝   ╚═╝   ╚══════╝       ╚═╝   ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚══════╝
║                    HARDENED OS FOR KUBERNETES                     ║
║                                                                    ║
║  Version: local-build                                             ║
║  Build Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")                 ║
║  Kernel Version: $(uname -r)                                    ║
║                                                                    ║
║  Security: MAXIMUM | Encryption: LUKS2+TPM | Auth: Keycloak     ║
║                                                                    ║
╚════════════════════════════════════════════════════════════════════╝

Node: \n | IP: \4 | Kernel: \r
EOF
echo "[✓] Console banner created"

# Convert logos for kernel
echo "[*] Converting logos for kernel..."
mkdir -p branding/logos
mkdir -p branding/output

# Create placeholder logo if not exists
if [ ! -f branding/logos/boot-logo.png ]; then
  echo "[*] Creating placeholder logo..."
  convert -size 224x224 xc:navy \
    -pointsize 20 -fill white -gravity center \
    -annotate +0+0 "ITL" \
    branding/logos/boot-logo.png
  echo "[✓] Placeholder logo created"
fi

# Debug: List the directory
echo "[*] Directory listing:"
ls -lah branding/logos/ || echo "ERROR: Directory doesn't exist or is empty"

# Convert PNG logo to kernel format
echo "[*] Converting to kernel format..."
convert branding/logos/boot-logo.png \
        -resize 224x224 \
        branding/output/boot-logo.png

convert branding/output/boot-logo.png \
        branding/output/boot-logo.ppm

# Install Perl modules for ppmquant if needed
apt-get install -y libtext-english-perl > /dev/null 2>&1 || true

ppmquant 224 branding/output/boot-logo.ppm | \
  pnmtoplainpnm > branding/output/logo_custom_clut224.ppm

echo "[✓] Logos converted for kernel"

# Summary
echo ""
echo "======================================"
echo "[✓] Build complete!"
echo "======================================"
ls -lah branding/output/

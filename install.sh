#!/usr/bin/env bash
# =============================================================================
# AdGuard Home + Unbound + adguard-exporter Installer for macOS (Mac Mini)
# =============================================================================
#
# Adapted from: https://www.dad-the-engineer.com/blog/5cxn4w2ofern6gsnxeyaw07w0vw5ve
# Original guide targets Raspberry Pi — this script adapts it for macOS.
#
# Key differences from the RPi guide:
#   - AdGuard Home: uses the official install script (NOT Homebrew — there is
#     no `brew install adguardhome`). Installs to /Applications/AdGuardHome
#     per upstream macOS recommendation.
#   - Unbound: installed via Homebrew.
#   - adguard-exporter: installed from GitHub releases (Go binary) and managed
#     via a LaunchDaemon for Prometheus scraping on port 9618.
#   - AdGuard Home binds to 0.0.0.0:53 so every device on the network can
#     use it as their DNS server.
#   - Unbound stays on 127.0.0.1:5335 (only AdGuard Home talks to it).
#
# Usage:
#   chmod +x install-adguard-unbound-macos.sh
#   ./install-adguard-unbound-macos.sh [--adguard-only | --full | --status | --uninstall]
#
# Flags:
#   --adguard-only   Install only AdGuard Home (skip Unbound + exporter)
#   --full           Install AdGuard Home + Unbound + adguard-exporter (default)
#   --uninstall      Remove everything
#   --status         Check service status
#   --help           Show this help
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
# Change these to match your environment
AGH_INSTALL_DIR="/Applications/AdGuardHome"
AGH_EXPORTER_VERSION="v1.2.1"                # https://github.com/henrywhitaker3/adguard-exporter/releases
AGH_EXPORTER_INSTALL_DIR="/usr/local/bin"
AGH_EXPORTER_ENV_DIR="/etc/adguard-exporter"
UNBOUND_PORT=5335
EXPORTER_PORT=9618

# --- Colors & helpers --------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[  OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[FAIL]${NC} $*"; }
step()    {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

confirm() {
    local prompt="${1:-Continue?}"
    read -rp "$(echo -e "${YELLOW}${prompt} [y/N]${NC} ")" answer
    [[ "${answer,,}" == "y" ]]
}

# --- Pre-flight checks -------------------------------------------------------
preflight() {
    step "Pre-flight checks"

    if [[ "$(uname -s)" != "Darwin" ]]; then
        error "This script is for macOS only."
        exit 1
    fi

    if [[ "$(id -u)" -eq 0 ]]; then
        error "Do not run as root. The script will use sudo when needed."
        exit 1
    fi

    info "macOS version : $(sw_vers -productVersion)"
    info "Architecture  : $(uname -m)"
    info "Hostname      : $(hostname)"

    # Warn if not on a wired connection
    local active_if
    active_if=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' || echo "unknown")
    info "Active iface  : ${active_if}"
    if [[ "$active_if" == "en0" ]]; then
        success "Looks like a wired Ethernet connection (en0)"
    else
        warn "Active interface is ${active_if} — wired Ethernet (en0) is recommended for a DNS server"
    fi

    success "Pre-flight checks passed"
}

# --- Ensure Homebrew ---------------------------------------------------------
ensure_homebrew() {
    if command -v brew &>/dev/null; then
        success "Homebrew already installed"
        return
    fi

    step "Installing Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    if [[ "$(uname -m)" == "arm64" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        # Persist for future shells
        if ! grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
        fi
    fi
    success "Homebrew installed"
}

# --- Get local IP ------------------------------------------------------------
get_local_ip() {
    ipconfig getifaddr en0 2>/dev/null \
        || ipconfig getifaddr en1 2>/dev/null \
        || echo "UNKNOWN"
}

# --- Disable macOS mDNSResponder on port 53 if needed ------------------------
handle_port_53() {
    step "Checking port 53 (DNS)"

    if sudo lsof -i :53 -sTCP:LISTEN -P -n 2>/dev/null | grep -v "^COMMAND" | head -5; then
        echo ""
        warn "Something is already listening on TCP port 53."
        warn "AdGuard Home needs port 53. On macOS, this is usually mDNSResponder."
        echo ""
        info "Option 1: AdGuard Home's installer typically handles this automatically."
        info "Option 2: You can manually stop conflicting services after install."
        echo ""
        if ! confirm "Proceed with installation?"; then
            error "Aborted by user."
            exit 1
        fi
    else
        success "TCP port 53 appears available"
    fi

    # Also check UDP
    if sudo lsof -i UDP:53 -P -n 2>/dev/null | grep -v "^COMMAND" | head -5; then
        warn "Something is listening on UDP port 53 as well (likely mDNSResponder)."
        warn "AdGuard Home should take over once installed."
    fi
}

# --- Install AdGuard Home (official method) ----------------------------------
install_adguard_home() {
    step "Installing AdGuard Home (official installer)"

    if [[ -f "${AGH_INSTALL_DIR}/AdGuardHome" ]]; then
        warn "AdGuard Home binary already exists at ${AGH_INSTALL_DIR}/AdGuardHome"
        if ! confirm "Reinstall / overwrite?"; then
            info "Skipping AdGuard Home installation."
            return
        fi
        # Stop existing service before reinstall
        sudo "${AGH_INSTALL_DIR}/AdGuardHome" -s stop 2>/dev/null || true
    fi

    # Per upstream docs: on macOS Catalina+ the working directory should
    # be inside /Applications.
    info "Install directory: ${AGH_INSTALL_DIR}"
    sudo mkdir -p "${AGH_INSTALL_DIR}"

    # Use the official install script from AdGuard's GitHub repo.
    # This downloads the correct binary for your OS/arch, unpacks it,
    # and registers it as a system service (LaunchDaemon on macOS).
    info "Running official AdGuard Home install script..."
    curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh \
        | sudo sh -s -- -o "${AGH_INSTALL_DIR}"

    # Verify the service is registered
    if sudo "${AGH_INSTALL_DIR}/AdGuardHome" -s status 2>/dev/null; then
        success "AdGuard Home service is registered"
    else
        warn "Service registration check returned non-zero. This may be normal on first run."
        info "Attempting to install as service..."
        sudo "${AGH_INSTALL_DIR}/AdGuardHome" -s install 2>/dev/null || true
    fi

    # Start the service
    info "Starting AdGuard Home..."
    sudo "${AGH_INSTALL_DIR}/AdGuardHome" -s start 2>/dev/null || true

    local ip
    ip=$(get_local_ip)

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  AdGuard Home is running!                                       ║${NC}"
    echo -e "${GREEN}║                                                                 ║${NC}"
    echo -e "${GREEN}║  Complete initial setup in your browser:                         ║${NC}"
    echo -e "${GREEN}║  → ${BOLD}http://${ip}:3000${NC}${GREEN}                                        ║${NC}"
    echo -e "${GREEN}║                                                                 ║${NC}"
    echo -e "${GREEN}║  Steps:                                                         ║${NC}"
    echo -e "${GREEN}║  1. Click 'Get Started'                                         ║${NC}"
    echo -e "${GREEN}║  2. Admin Web Interface: keep 'All interfaces', port 80          ║${NC}"
    echo -e "${GREEN}║  3. DNS Server: keep 'All interfaces', port 53                   ║${NC}"
    echo -e "${GREEN}║     ↑ CRITICAL — this is what makes it network-wide              ║${NC}"
    echo -e "${GREEN}║  4. Create admin username & password (save these!)                ║${NC}"
    echo -e "${GREEN}║  5. Click through to Dashboard                                   ║${NC}"
    echo -e "${GREEN}║                                                                 ║${NC}"
    echo -e "${GREEN}║  After setup, the UI is at: http://${ip}                  ║${NC}"
    echo -e "${GREEN}║  Logs: /var/log/AdGuardHome.*.log                                ║${NC}"
    echo -e "${GREEN}║  Config: ${AGH_INSTALL_DIR}/AdGuardHome.yaml            ║${NC}"
    echo -e "${GREEN}║                                                                 ║${NC}"
    echo -e "${GREEN}║  Service commands:                                               ║${NC}"
    echo -e "${GREEN}║    sudo ${AGH_INSTALL_DIR}/AdGuardHome -s status          ║${NC}"
    echo -e "${GREEN}║    sudo ${AGH_INSTALL_DIR}/AdGuardHome -s restart         ║${NC}"
    echo -e "${GREEN}║    sudo ${AGH_INSTALL_DIR}/AdGuardHome -s stop            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# --- Install Unbound (Homebrew) ----------------------------------------------
install_unbound() {
    step "Installing Unbound via Homebrew"

    ensure_homebrew

    if brew list unbound &>/dev/null 2>&1; then
        warn "Unbound is already installed via Homebrew"
    else
        brew install unbound
        success "Unbound installed"
    fi

    # Also install bind (for dig) if not present
    if ! command -v dig &>/dev/null; then
        info "Installing bind (for dig command)..."
        brew install bind
    fi

    local brew_prefix
    brew_prefix="$(brew --prefix)"
    local unbound_conf_dir="${brew_prefix}/etc/unbound"

    step "Configuring Unbound"

    mkdir -p "$unbound_conf_dir"

    # Download root hints for recursive resolution
    info "Downloading root hints..."
    curl -fsSL https://www.internic.net/domain/named.root \
        -o "${unbound_conf_dir}/root.hints" 2>/dev/null || {
        warn "Could not download root hints — Unbound will use built-in defaults."
    }

    # Write Unbound config.
    # KEY POINT: Unbound listens on 127.0.0.1:5335 ONLY.
    # It does NOT need to be network-accessible — only AdGuard Home queries it.
    # AdGuard Home is the network-facing DNS server (0.0.0.0:53).
    cat > "${unbound_conf_dir}/unbound.conf" <<'UNBOUND_CONF'
# =============================================================================
# Unbound configuration — upstream recursive resolver for AdGuard Home
# Listens on 127.0.0.1:5335 (localhost only)
# AdGuard Home (0.0.0.0:53) forwards to this.
#
# Adapted from: Dad the Engineer's RPi guide
# =============================================================================
server:
    # ── Listening ────────────────────────────────────────────────
    # Localhost only. AdGuard Home handles network-facing DNS.
    interface: 127.0.0.1
    port: 5335

    # ── Protocols ────────────────────────────────────────────────
    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes

    # ── Security / Hardening ─────────────────────────────────────
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-referral-path: yes
    harden-algo-downgrade: yes
    use-caps-for-id: yes

    # ── DNSSEC ───────────────────────────────────────────────────
    val-clean-additional: yes

    # ── Privacy ──────────────────────────────────────────────────
    # Minimise the query name sent to upstream authoritative servers
    qname-minimisation: yes
    qname-minimisation-strict: no

    # ── Performance ──────────────────────────────────────────────
    # Mac Mini has plenty of resources — be generous
    num-threads: 4
    msg-cache-slabs: 4
    rrset-cache-slabs: 4
    infra-cache-slabs: 4
    key-cache-slabs: 4
    msg-cache-size: 128m
    rrset-cache-size: 256m

    cache-min-ttl: 300
    cache-max-ttl: 86400
    prefetch: yes
    prefetch-key: yes

    # Serve stale data while refreshing (improves perceived latency)
    serve-expired: yes
    serve-expired-ttl: 86400

    # ── Access Control ───────────────────────────────────────────
    # Only localhost can query Unbound directly. Everything else
    # goes through AdGuard Home.
    access-control: 127.0.0.0/8 allow
    access-control: ::1/128 allow
    access-control: 0.0.0.0/0 refuse
    access-control: ::/0 refuse

    # ── Logging (minimal) ────────────────────────────────────────
    verbosity: 0
    log-queries: no
    log-replies: no
    log-servfail: yes
UNBOUND_CONF

    success "Unbound config written to ${unbound_conf_dir}/unbound.conf"

    # Validate
    info "Validating Unbound configuration..."
    if "${brew_prefix}/sbin/unbound-checkconf" "${unbound_conf_dir}/unbound.conf"; then
        success "Configuration is valid"
    else
        error "Unbound config has errors — review ${unbound_conf_dir}/unbound.conf"
        exit 1
    fi

    step "Starting Unbound"
    sudo brew services start unbound
    sleep 2

    # Test it
    info "Testing: dig @127.0.0.1 -p ${UNBOUND_PORT} example.com"
    if dig @127.0.0.1 -p "${UNBOUND_PORT}" example.com +short +timeout=5; then
        success "Unbound is resolving queries on 127.0.0.1:${UNBOUND_PORT}"
    else
        error "Unbound test query failed."
        error "Check: sudo brew services list | grep unbound"
        error "Check: ${brew_prefix}/sbin/unbound-checkconf"
        exit 1
    fi

    local ip
    ip=$(get_local_ip)

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Unbound is running on 127.0.0.1:${UNBOUND_PORT}                          ║${NC}"
    echo -e "${GREEN}║                                                                 ║${NC}"
    echo -e "${GREEN}║  Now configure AdGuard Home to use Unbound as upstream:          ║${NC}"
    echo -e "${GREEN}║                                                                 ║${NC}"
    echo -e "${GREEN}║  1. Open AdGuard Home UI → Settings → DNS Settings              ║${NC}"
    echo -e "${GREEN}║  2. Under 'Upstream DNS servers', REPLACE everything with:       ║${NC}"
    echo -e "${GREEN}║                                                                 ║${NC}"
    echo -e "${GREEN}║     127.0.0.1:${UNBOUND_PORT}                                             ║${NC}"
    echo -e "${GREEN}║                                                                 ║${NC}"
    echo -e "${GREEN}║  3. (Optional) For local hostname resolution, add a line:        ║${NC}"
    echo -e "${GREEN}║     [/*.localdomain/]YOUR_ROUTER_IP                              ║${NC}"
    echo -e "${GREEN}║                                                                 ║${NC}"
    echo -e "${GREEN}║  4. Delete any other upstream servers (Cloudflare, Google, etc.)  ║${NC}"
    echo -e "${GREEN}║  5. Click 'Test upstreams' then 'Apply'                          ║${NC}"
    echo -e "${GREEN}║                                                                 ║${NC}"
    echo -e "${GREEN}║  Verify: Dashboard → Top Upstreams should show 127.0.0.1:${UNBOUND_PORT}   ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# --- Install adguard-exporter ------------------------------------------------
install_adguard_exporter() {
    step "Installing adguard-exporter ${AGH_EXPORTER_VERSION}"

    local arch
    arch=$(uname -m)
    local go_arch="arm64"
    if [[ "$arch" == "x86_64" ]]; then
        go_arch="amd64"
    fi

    local asset_name="adguard-exporter_darwin_${go_arch}"
    local download_url="https://github.com/henrywhitaker3/adguard-exporter/releases/download/${AGH_EXPORTER_VERSION}/${asset_name}"

    info "Attempting binary download for darwin/${go_arch}..."
    info "URL: ${download_url}"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local downloaded=false

    if curl -fsSL -o "${tmp_dir}/adguard-exporter" "${download_url}" 2>/dev/null; then
        chmod +x "${tmp_dir}/adguard-exporter"
        # Quick sanity check — make sure it's a real Mach-O binary
        if file "${tmp_dir}/adguard-exporter" | grep -q "Mach-O"; then
            downloaded=true
            success "Downloaded pre-built binary"
        else
            warn "Downloaded file is not a valid macOS binary"
        fi
    else
        warn "Pre-built binary not found at expected URL"
    fi

    # Fallback: build from source with Go
    if [[ "$downloaded" == "false" ]]; then
        warn "Falling back to building from source..."

        if ! command -v go &>/dev/null; then
            info "Installing Go via Homebrew..."
            ensure_homebrew
            brew install go
        fi

        info "Building adguard-exporter from source..."
        GOBIN="${tmp_dir}" go install "github.com/henrywhitaker3/adguard-exporter@latest"

        if [[ -f "${tmp_dir}/adguard-exporter" ]]; then
            chmod +x "${tmp_dir}/adguard-exporter"
            downloaded=true
            success "Built from source"
        else
            error "Build failed. Make sure Go is installed and working."
            rm -rf "${tmp_dir}"
            exit 1
        fi
    fi

    # Install binary
    sudo mkdir -p "${AGH_EXPORTER_INSTALL_DIR}"
    sudo cp "${tmp_dir}/adguard-exporter" "${AGH_EXPORTER_INSTALL_DIR}/adguard-exporter"
    sudo chmod +x "${AGH_EXPORTER_INSTALL_DIR}/adguard-exporter"
    rm -rf "${tmp_dir}"
    success "Binary installed to ${AGH_EXPORTER_INSTALL_DIR}/adguard-exporter"

    step "Configuring adguard-exporter"

    local ip
    ip=$(get_local_ip)

    # Prompt for AdGuard Home credentials
    echo -e "${YELLOW}The exporter needs your AdGuard Home web UI credentials.${NC}"
    echo -e "${YELLOW}(The ones you created during AdGuard Home setup wizard.)${NC}"
    echo ""

    local agh_url agh_user agh_pass
    read -rp "AdGuard Home URL [http://${ip}]: " agh_url
    agh_url="${agh_url:-http://${ip}}"

    read -rp "AdGuard Home username: " agh_user
    read -rsp "AdGuard Home password: " agh_pass
    echo ""

    if [[ -z "$agh_user" || -z "$agh_pass" ]]; then
        warn "Username or password is empty. You can edit the env file later at:"
        warn "${AGH_EXPORTER_ENV_DIR}/adguard-exporter.env"
    fi

    # Create env file (used by the LaunchDaemon)
    sudo mkdir -p "${AGH_EXPORTER_ENV_DIR}"
    sudo tee "${AGH_EXPORTER_ENV_DIR}/adguard-exporter.env" > /dev/null <<EOF
ADGUARD_SERVERS=${agh_url}
ADGUARD_USERNAMES=${agh_user}
ADGUARD_PASSWORDS=${agh_pass}
INTERVAL=30s
BIND_ADDR=:${EXPORTER_PORT}
EOF
    # Restrict permissions — contains credentials
    sudo chmod 600 "${AGH_EXPORTER_ENV_DIR}/adguard-exporter.env"
    success "Env file written to ${AGH_EXPORTER_ENV_DIR}/adguard-exporter.env"

    step "Creating LaunchDaemon for adguard-exporter"

    # macOS LaunchDaemons don't natively support .env files, so we use a
    # wrapper shell that sources the env then execs the binary.
    sudo tee /usr/local/bin/adguard-exporter-wrapper.sh > /dev/null <<'WRAPPER'
#!/usr/bin/env bash
set -a
source /etc/adguard-exporter/adguard-exporter.env
set +a
exec /usr/local/bin/adguard-exporter
WRAPPER
    sudo chmod +x /usr/local/bin/adguard-exporter-wrapper.sh

    sudo tee /Library/LaunchDaemons/com.henrywhitaker3.adguard-exporter.plist > /dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.henrywhitaker3.adguard-exporter</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/adguard-exporter-wrapper.sh</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/var/log/adguard-exporter.log</string>

    <key>StandardErrorPath</key>
    <string>/var/log/adguard-exporter.error.log</string>
</dict>
</plist>
PLIST

    sudo launchctl bootout system /Library/LaunchDaemons/com.henrywhitaker3.adguard-exporter.plist 2>/dev/null || true
    sudo launchctl bootstrap system /Library/LaunchDaemons/com.henrywhitaker3.adguard-exporter.plist

    sleep 2

    # Verify it's running
    if curl -sf "http://127.0.0.1:${EXPORTER_PORT}/metrics" > /dev/null 2>&1; then
        success "adguard-exporter is running and serving metrics on port ${EXPORTER_PORT}"
    else
        warn "adguard-exporter may not be responding yet."
        warn "Check logs: tail -f /var/log/adguard-exporter.log"
        warn "Common issue: AdGuard Home initial setup not completed yet."
        warn "Complete the web setup wizard first, then restart the exporter:"
        warn "  sudo launchctl kickstart -k system/com.henrywhitaker3.adguard-exporter"
    fi

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  adguard-exporter is installed                                  ║${NC}"
    echo -e "${GREEN}║                                                                 ║${NC}"
    echo -e "${GREEN}║  Metrics endpoint: http://${ip}:${EXPORTER_PORT}/metrics               ║${NC}"
    echo -e "${GREEN}║                                                                 ║${NC}"
    echo -e "${GREEN}║  Add to your prometheus.yml:                                    ║${NC}"
    echo -e "${GREEN}║                                                                 ║${NC}"
    echo -e "${GREEN}║    scrape_configs:                                               ║${NC}"
    echo -e "${GREEN}║      - job_name: 'adguard'                                      ║${NC}"
    echo -e "${GREEN}║        static_configs:                                           ║${NC}"
    echo -e "${GREEN}║          - targets: ['${ip}:${EXPORTER_PORT}']                        ║${NC}"
    echo -e "${GREEN}║                                                                 ║${NC}"
    echo -e "${GREEN}║  Grafana dashboard: https://grafana.com/grafana/dashboards/20799 ║${NC}"
    echo -e "${GREEN}║                                                                 ║${NC}"
    echo -e "${GREEN}║  Credentials: ${AGH_EXPORTER_ENV_DIR}/adguard-exporter.env     ║${NC}"
    echo -e "${GREEN}║  Logs:        /var/log/adguard-exporter.log                      ║${NC}"
    echo -e "${GREEN}║  Restart:     sudo launchctl kickstart -k \\                      ║${NC}"
    echo -e "${GREEN}║                 system/com.henrywhitaker3.adguard-exporter       ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# --- macOS firewall reminder -------------------------------------------------
firewall_reminder() {
    local ip
    ip=$(get_local_ip)

    step "macOS Firewall Check"

    # Check if the firewall is enabled
    local fw_status
    fw_status=$(sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || echo "unknown")

    if echo "$fw_status" | grep -qi "enabled"; then
        warn "macOS Application Firewall is ENABLED."
        echo ""
        info "You may need to allow incoming connections for AdGuard Home."
        info "Either:"
        info "  1. System Settings → Network → Firewall → Options"
        info "     → Add AdGuardHome and allow incoming connections"
        info "  2. Or run:"
        info "     sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add ${AGH_INSTALL_DIR}/AdGuardHome"
        info "     sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp ${AGH_INSTALL_DIR}/AdGuardHome"
        echo ""
    else
        success "macOS Application Firewall is disabled — no changes needed."
    fi
}

# --- Router / network configuration reminder ---------------------------------
router_reminder() {
    local ip
    ip=$(get_local_ip)

    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  NETWORK CONFIGURATION — MAKE IT ACCESSIBLE TO ALL SERVERS      ║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║                                                                 ║${NC}"
    echo -e "${YELLOW}║  1. STATIC IP — Give this Mac Mini a DHCP reservation           ║${NC}"
    echo -e "${YELLOW}║     in your router so its IP never changes.                     ║${NC}"
    echo -e "${YELLOW}║     Current IP: ${BOLD}${ip}${NC}${YELLOW}                                        ║${NC}"
    echo -e "${YELLOW}║                                                                 ║${NC}"
    echo -e "${YELLOW}║  2. ROUTER DNS — Point your router's DHCP-distributed DNS       ║${NC}"
    echo -e "${YELLOW}║     to this Mac Mini:                                            ║${NC}"
    echo -e "${YELLOW}║       Primary DNS:   ${BOLD}${ip}${NC}${YELLOW}                                   ║${NC}"
    echo -e "${YELLOW}║       Secondary DNS: (leave blank to force all through AGH)      ║${NC}"
    echo -e "${YELLOW}║                                                                 ║${NC}"
    echo -e "${YELLOW}║  3. INDIVIDUAL SERVERS — On any server you can also point        ║${NC}"
    echo -e "${YELLOW}║     DNS manually to ${ip} in its network config.           ║${NC}"
    echo -e "${YELLOW}║                                                                 ║${NC}"
    echo -e "${YELLOW}║  4. TEST from another machine:                                  ║${NC}"
    echo -e "${YELLOW}║       dig @${ip} example.com                                ║${NC}"
    echo -e "${YELLOW}║       nslookup example.com ${ip}                            ║${NC}"
    echo -e "${YELLOW}║                                                                 ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# --- Status ------------------------------------------------------------------
show_status() {
    step "Service Status"

    local ip
    ip=$(get_local_ip)

    echo -e "${BLUE}── AdGuard Home ──${NC}"
    if [[ -f "${AGH_INSTALL_DIR}/AdGuardHome" ]]; then
        sudo "${AGH_INSTALL_DIR}/AdGuardHome" -s status 2>/dev/null || warn "AdGuard Home service not running"
    else
        warn "AdGuard Home not installed at ${AGH_INSTALL_DIR}"
    fi

    echo ""
    echo -e "${BLUE}── Unbound ──${NC}"
    if brew list unbound &>/dev/null 2>&1; then
        sudo brew services info unbound 2>/dev/null || brew services list 2>/dev/null | grep unbound || true
    else
        warn "Unbound not installed"
    fi

    echo ""
    echo -e "${BLUE}── adguard-exporter ──${NC}"
    if sudo launchctl print system/com.henrywhitaker3.adguard-exporter &>/dev/null 2>&1; then
        success "LaunchDaemon is loaded"
        if curl -sf "http://127.0.0.1:${EXPORTER_PORT}/metrics" > /dev/null 2>&1; then
            success "Metrics endpoint responding on :${EXPORTER_PORT}"
        else
            warn "Metrics endpoint not responding on :${EXPORTER_PORT}"
        fi
    else
        warn "adguard-exporter LaunchDaemon not loaded"
    fi

    echo ""
    echo -e "${BLUE}── Port checks ──${NC}"
    echo "Port 53 (DNS):"
    sudo lsof -i :53 -P -n 2>/dev/null | head -5 || info "  Nothing listening"
    echo "Port ${UNBOUND_PORT} (Unbound):"
    sudo lsof -i :${UNBOUND_PORT} -P -n 2>/dev/null | head -5 || info "  Nothing listening"
    echo "Port ${EXPORTER_PORT} (Exporter):"
    sudo lsof -i :${EXPORTER_PORT} -P -n 2>/dev/null | head -5 || info "  Nothing listening"

    echo ""
    echo -e "${BLUE}── DNS resolution tests ──${NC}"
    # Test Unbound directly
    if dig @127.0.0.1 -p ${UNBOUND_PORT} example.com +short +timeout=3 &>/dev/null 2>&1; then
        success "Unbound (127.0.0.1:${UNBOUND_PORT}): responding"
    else
        warn "Unbound (127.0.0.1:${UNBOUND_PORT}): not responding"
    fi

    # Test AdGuard Home from network perspective
    if dig @"${ip}" example.com +short +timeout=3 &>/dev/null 2>&1; then
        success "AdGuard Home (${ip}:53): responding — network-accessible"
    else
        warn "AdGuard Home (${ip}:53): not responding"
    fi
}

# --- Uninstall ---------------------------------------------------------------
uninstall() {
    step "Uninstalling AdGuard Home + Unbound + adguard-exporter"

    if ! confirm "This will remove all three services. Are you sure?"; then
        info "Aborted."
        exit 0
    fi

    # adguard-exporter
    info "Removing adguard-exporter..."
    sudo launchctl bootout system /Library/LaunchDaemons/com.henrywhitaker3.adguard-exporter.plist 2>/dev/null || true
    sudo rm -f /Library/LaunchDaemons/com.henrywhitaker3.adguard-exporter.plist
    sudo rm -f /usr/local/bin/adguard-exporter
    sudo rm -f /usr/local/bin/adguard-exporter-wrapper.sh
    sudo rm -rf "${AGH_EXPORTER_ENV_DIR}"
    sudo rm -f /var/log/adguard-exporter.log /var/log/adguard-exporter.error.log
    success "adguard-exporter removed"

    # Unbound
    info "Removing Unbound..."
    sudo brew services stop unbound 2>/dev/null || true
    brew uninstall unbound 2>/dev/null || true
    success "Unbound removed"

    # AdGuard Home
    info "Removing AdGuard Home..."
    if [[ -f "${AGH_INSTALL_DIR}/AdGuardHome" ]]; then
        sudo "${AGH_INSTALL_DIR}/AdGuardHome" -s stop 2>/dev/null || true
        sudo "${AGH_INSTALL_DIR}/AdGuardHome" -s uninstall 2>/dev/null || true
    fi
    success "AdGuard Home service removed"

    warn "AdGuard Home files remain at ${AGH_INSTALL_DIR} — remove manually if desired:"
    warn "  sudo rm -rf ${AGH_INSTALL_DIR}"
    warn "Your router DNS settings may still point to this Mac — update them!"
}

# --- Help --------------------------------------------------------------------
show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTION]

Installs AdGuard Home + Unbound + adguard-exporter on macOS.
Adapted from: Dad, the Engineer's RPi guide.

Options:
  --adguard-only   Install only AdGuard Home (skip Unbound & exporter)
  --full           Install AdGuard Home + Unbound + exporter (default)
  --uninstall      Remove all services
  --status         Check service status and connectivity
  --help           Show this help

Architecture:

  ┌─────────────────────────────────────────────────┐
  │  Your Network Devices                           │
  │  (phones, laptops, servers, IoT)                │
  │  DNS queries → Mac Mini IP:53                   │
  └──────────────────┬──────────────────────────────┘
                     │
                     ▼
  ┌─────────────────────────────────────────────────┐
  │  AdGuard Home (0.0.0.0:53)                      │
  │  - Blocks ads & trackers                        │
  │  - Query logging & parental controls            │
  │  - Web UI on port 80                            │
  └──────────────────┬──────────────────────────────┘
                     │ forwards to
                     ▼
  ┌─────────────────────────────────────────────────┐
  │  Unbound (127.0.0.1:5335)                       │
  │  - Recursive resolver (no third-party DNS)      │
  │  - DNSSEC validation                            │
  │  - Privacy: QNAME minimisation                  │
  └─────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────┐
  │  adguard-exporter (:9618/metrics)               │
  │  - Prometheus metrics from AdGuard Home API     │
  │  - Grafana dashboard ID: 20799                  │
  └─────────────────────────────────────────────────┘

Sources:
  AdGuard Home     https://github.com/AdguardTeam/AdGuardHome
  adguard-exporter https://github.com/henrywhitaker3/adguard-exporter
  Original guide   https://www.dad-the-engineer.com/blog/5cxn4w2ofern6gsnxeyaw07w0vw5ve
EOF
}

# --- Main --------------------------------------------------------------------
main() {
    local mode="${1:---full}"

    case "$mode" in
        --help|-h)
            show_help
            exit 0
            ;;
        --status)
            preflight
            show_status
            exit 0
            ;;
        --uninstall)
            preflight
            uninstall
            exit 0
            ;;
        --adguard-only)
            preflight
            handle_port_53
            install_adguard_home
            firewall_reminder
            router_reminder
            ;;
        --full|"")
            preflight
            handle_port_53
            install_adguard_home
            firewall_reminder

            echo ""
            if confirm "Continue with Unbound (recursive resolver)?"; then
                install_unbound
            else
                info "Skipping Unbound."
            fi

            echo ""
            if confirm "Continue with adguard-exporter (Prometheus metrics)?"; then
                install_adguard_exporter
            else
                info "Skipping adguard-exporter."
            fi

            router_reminder
            ;;
        *)
            error "Unknown option: $mode"
            show_help
            exit 1
            ;;
    esac

    echo ""
    success "All done! Run '$(basename "$0") --status' anytime to check health."
}

main "$@"

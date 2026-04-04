#!/usr/bin/env bats

# Tier 3: Full lifecycle integration tests
# Runs the complete: install → configure → verify → uninstall cycle.
# Only runs on schedule or manual dispatch (expensive).
#
# Requires: macOS, passwordless sudo, Homebrew, network access

load helpers/setup.bash

# --- Helpers -----------------------------------------------------------------

# Complete AdGuard Home initial setup via its REST API.
# This replaces the interactive web wizard.
setup_adguard_home_api() {
    local max_wait=30 elapsed=0
    # Wait for the setup wizard to be available
    while (( elapsed < max_wait )); do
        if curl -sf http://127.0.0.1:3000/ >/dev/null 2>&1; then
            break
        fi
        sleep 1
        (( elapsed++ )) || true
    done

    curl -s -X POST http://127.0.0.1:3000/control/install/configure \
        -H 'Content-Type: application/json' \
        -d '{
            "dns": {"ip": "0.0.0.0", "port": 53},
            "web": {"ip": "0.0.0.0", "port": 80},
            "username": "admin",
            "password": "testpass123"
        }'
}

# Configure AdGuard Home to use Unbound as upstream DNS
configure_adguard_upstream() {
    curl -s -X POST http://127.0.0.1:80/control/dns_config \
        -H 'Content-Type: application/json' \
        -u admin:testpass123 \
        -d '{
            "upstream_dns": ["127.0.0.1:5335"],
            "bootstrap_dns": ["1.1.1.1"]
        }'
}

# Try to free port 53 from mDNSResponder
try_free_port_53() {
    if sudo lsof -i :53 -sTCP:LISTEN -P -n 2>/dev/null | grep -q mDNSResponder; then
        sudo launchctl unload -w /System/Library/LaunchDaemons/com.apple.mDNSResponder.plist 2>/dev/null || true
        sleep 2
    fi
}

PORT_53_AVAILABLE=0

# --- File-level setup/teardown -----------------------------------------------

setup_file() {
    skip_unless_macos
    skip_unless_sudo
    require_brew

    # Ensure clean state
    cleanup_exporter
    cleanup_unbound
    cleanup_adguard_home

    # Try to free port 53
    try_free_port_53
    if ! sudo lsof -i :53 -sTCP:LISTEN -P -n 2>/dev/null | grep -v "^COMMAND" | head -1 | grep -q .; then
        export PORT_53_AVAILABLE=1
    else
        export PORT_53_AVAILABLE=0
        echo "# WARNING: Port 53 still in use — some DNS chain tests will be skipped" >&3
    fi

    # Run the full installer in non-interactive mode
    export NONINTERACTIVE=1
    export AGH_EXPORTER_URL="http://127.0.0.1"
    export AGH_EXPORTER_USER="admin"
    export AGH_EXPORTER_PASS="testpass123"
    bash "$SCRIPT" --full
}

teardown_file() {
    # Clean up everything
    export NONINTERACTIVE=1
    bash "$SCRIPT" --uninstall 2>/dev/null || true
    cleanup_exporter
    cleanup_unbound
    cleanup_adguard_home

    # Restart mDNSResponder if we stopped it
    sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.mDNSResponder.plist 2>/dev/null || true
}

setup() {
    skip_unless_macos
    skip_unless_sudo
    require_brew
}

# --- Install verification tests ----------------------------------------------

@test "full install completes without error" {
    # If we got here, setup_file succeeded — the install worked
    true
}

@test "AdGuard Home binary exists" {
    [ -f /Applications/AdGuardHome/AdGuardHome ]
}

@test "AdGuard Home service is running" {
    run sudo /Applications/AdGuardHome/AdGuardHome -s status
    [ "$status" -eq 0 ]
}

@test "AdGuard Home web UI responds on port 3000" {
    run curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/
    [ "$status" -eq 0 ]
}

@test "complete AdGuard Home initial setup via API" {
    setup_adguard_home_api
    # After setup, the web UI should be on port 80
    sleep 2
    run curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:80/
    [ "$status" -eq 0 ]
}

@test "Unbound resolves on port 5335" {
    if ! command -v dig &>/dev/null; then
        skip "dig not available"
    fi
    run dig @127.0.0.1 -p 5335 example.com +short +timeout=10 +retry=2
    [ "$status" -eq 0 ]
    [[ "$output" =~ [0-9]+\.[0-9]+ ]]
}

@test "configure AdGuard Home upstream to Unbound" {
    if [[ "${PORT_53_AVAILABLE:-0}" != "1" ]]; then
        skip "port 53 not available — cannot test DNS chain"
    fi
    configure_adguard_upstream
    sleep 2
    # Verify the config was accepted
    run curl -sf -u admin:testpass123 http://127.0.0.1:80/control/dns_info
    [ "$status" -eq 0 ]
    [[ "$output" == *"5335"* ]]
}

@test "full DNS chain works (AdGuard Home -> Unbound -> root)" {
    if [[ "${PORT_53_AVAILABLE:-0}" != "1" ]]; then
        skip "port 53 not available — cannot test DNS chain"
    fi
    if ! command -v dig &>/dev/null; then
        skip "dig not available"
    fi
    run dig @127.0.0.1 example.com +short +timeout=10 +retry=2
    [ "$status" -eq 0 ]
    [[ "$output" =~ [0-9]+\.[0-9]+ ]]
}

@test "exporter binary exists" {
    [ -f /usr/local/bin/adguard-exporter ]
}

@test "--status reports service information" {
    run bash "$SCRIPT" --status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Service Status"* ]]
}

# --- Uninstall tests ---------------------------------------------------------

@test "--uninstall removes all components" {
    export NONINTERACTIVE=1
    run bash "$SCRIPT" --uninstall
    [ "$status" -eq 0 ]
    [[ "$output" == *"removed"* ]]
}

@test "post-uninstall: services are gone" {
    # Unbound port should be free
    run nc -z 127.0.0.1 5335 2>&1
    [ "$status" -ne 0 ]

    # Exporter plist should be gone
    [ ! -f /Library/LaunchDaemons/com.henrywhitaker3.adguard-exporter.plist ]
}

#!/usr/bin/env bats

# Tier 2: Unbound integration tests
# Actually installs Unbound via Homebrew, writes config, starts the service,
# and verifies DNS resolution. Cleans up after itself.
#
# Requires: macOS, Homebrew, passwordless sudo, network access

load helpers/setup.bash

# --- File-level setup/teardown -----------------------------------------------

setup_file() {
    skip_unless_macos
    skip_unless_sudo
    require_brew

    # Clean any leftover state from previous runs
    cleanup_unbound

    # Install Unbound
    brew install unbound

    # Resolve paths
    export BREW_PREFIX
    BREW_PREFIX="$(brew --prefix)"
    export UNBOUND_CONF_DIR="${BREW_PREFIX}/etc/unbound"
    export UNBOUND_CONF="${UNBOUND_CONF_DIR}/unbound.conf"
    export UNBOUND_CHECKCONF="${BREW_PREFIX}/sbin/unbound-checkconf"

    mkdir -p "$UNBOUND_CONF_DIR"

    # Download root hints (same as install.sh)
    curl -fsSL https://www.internic.net/domain/named.root \
        -o "${UNBOUND_CONF_DIR}/root.hints" 2>/dev/null || true

    # Write the same config that install.sh produces
    cat > "${UNBOUND_CONF}" <<UNBOUND_CONF
server:
    interface: 127.0.0.1
    port: 5335
    root-hints: "${UNBOUND_CONF_DIR}/root.hints"

    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes

    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-referral-path: yes
    harden-algo-downgrade: yes
    use-caps-for-id: yes

    val-clean-additional: yes

    qname-minimisation: yes
    qname-minimisation-strict: no

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

    serve-expired: yes
    serve-expired-ttl: 86400

    access-control: 127.0.0.0/8 allow
    access-control: ::1/128 allow
    access-control: 0.0.0.0/0 refuse
    access-control: ::/0 refuse

    verbosity: 0
    log-queries: no
    log-replies: no
    log-servfail: yes
UNBOUND_CONF

    # Start the service
    sudo brew services start unbound

    # Wait for it to be ready
    local elapsed=0
    while (( elapsed < 15 )); do
        if nc -z 127.0.0.1 5335 2>/dev/null; then
            return 0
        fi
        sleep 1
        (( elapsed++ )) || true
    done
}

teardown_file() {
    cleanup_unbound
}

# Re-export paths in per-test setup (BATS file-level exports don't carry over)
setup() {
    skip_unless_macos
    skip_unless_sudo
    require_brew
    BREW_PREFIX="$(brew --prefix)"
    UNBOUND_CONF_DIR="${BREW_PREFIX}/etc/unbound"
    UNBOUND_CONF="${UNBOUND_CONF_DIR}/unbound.conf"
    UNBOUND_CHECKCONF="${BREW_PREFIX}/sbin/unbound-checkconf"
}

# --- Tests -------------------------------------------------------------------

@test "brew install unbound succeeds" {
    run brew list unbound
    [ "$status" -eq 0 ]
}

@test "unbound.conf contains correct settings" {
    [ -f "$UNBOUND_CONF" ]
    run cat "$UNBOUND_CONF"
    [[ "$output" == *"interface: 127.0.0.1"* ]]
    [[ "$output" == *"port: 5335"* ]]
    [[ "$output" == *"access-control: 127.0.0.0/8 allow"* ]]
    [[ "$output" == *"harden-dnssec-stripped: yes"* ]]
}

@test "root.hints downloaded successfully" {
    [ -f "${UNBOUND_CONF_DIR}/root.hints" ]
    [ -s "${UNBOUND_CONF_DIR}/root.hints" ]
}

@test "unbound-checkconf validates config" {
    run "$UNBOUND_CHECKCONF" "$UNBOUND_CONF"
    [ "$status" -eq 0 ]
}

@test "unbound is listening on port 5335" {
    run nc -z 127.0.0.1 5335
    [ "$status" -eq 0 ]
}

@test "unbound resolves DNS queries" {
    # Install dig if not available
    if ! command -v dig &>/dev/null; then
        brew install bind 2>/dev/null || skip "dig not available"
    fi
    run dig @127.0.0.1 -p 5335 example.com +short +timeout=10 +retry=2
    [ "$status" -eq 0 ]
    # Should return at least one IP address
    [[ "$output" =~ [0-9]+\.[0-9]+ ]]
}

@test "unbound enforces DNSSEC (SERVFAIL on bad signature)" {
    if ! command -v dig &>/dev/null; then
        skip "dig not available"
    fi
    # dnssec-failed.org is a well-known test domain with intentionally broken DNSSEC
    run dig @127.0.0.1 -p 5335 dnssec-failed.org A +timeout=10 +retry=1
    # Should get SERVFAIL status (DNSSEC validation failure)
    [[ "$output" == *"SERVFAIL"* ]]
}

@test "unbound cleanup removes everything" {
    # This test runs cleanup and verifies — it must be last
    cleanup_unbound
    run brew list unbound 2>&1
    [ "$status" -ne 0 ]
    run nc -z 127.0.0.1 5335 2>&1
    [ "$status" -ne 0 ]
}

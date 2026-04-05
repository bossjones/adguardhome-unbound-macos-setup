#!/usr/bin/env bash
# Shared helpers for integration tests

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/install.sh"

# --- Skip guards -------------------------------------------------------------

skip_unless_macos() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        skip "requires macOS"
    fi
}

skip_unless_sudo() {
    if ! sudo -n true 2>/dev/null; then
        skip "requires passwordless sudo"
    fi
}

require_brew() {
    if ! command -v brew &>/dev/null; then
        skip "requires Homebrew"
    fi
}

# --- Port utilities ----------------------------------------------------------

# wait_for_port HOST PORT MAX_SECONDS
# Polls until a TCP connection succeeds or timeout is reached.
wait_for_port() {
    local host="$1" port="$2" max_seconds="${3:-15}"
    local elapsed=0
    while (( elapsed < max_seconds )); do
        if nc -z "$host" "$port" 2>/dev/null; then
            return 0
        fi
        sleep 1
        (( elapsed++ )) || true
    done
    return 1
}

# port_is_free PORT
# Returns 0 if nothing is listening on the given port.
port_is_free() {
    local port="$1"
    ! nc -z 127.0.0.1 "$port" 2>/dev/null
}

# --- Cleanup functions -------------------------------------------------------

cleanup_unbound() {
    # Stop the service (started with sudo, so stop with sudo)
    sudo brew services stop unbound 2>/dev/null || true
    # Fully deregister from launchd — sudo creates a system-level plist
    # that can block brew uninstall if not explicitly removed
    sudo launchctl bootout system/homebrew.mxcl.unbound 2>/dev/null || true
    sudo rm -f /Library/LaunchDaemons/homebrew.mxcl.unbound.plist 2>/dev/null || true
    # Kill any lingering process
    sudo killall unbound 2>/dev/null || true
    sleep 2
    # sudo needed: brew services start with sudo sets restrictive permissions on binaries
    sudo brew uninstall --force --ignore-dependencies unbound 2>/dev/null || true
    # Fallback: if brew uninstall failed, remove the keg directly
    local cellar_dir
    cellar_dir="$(brew --cellar 2>/dev/null)/unbound" 2>/dev/null || true
    if [[ -n "$cellar_dir" && -d "$cellar_dir" ]]; then
        sudo rm -rf "$cellar_dir"
    fi
    local conf_dir
    conf_dir="$(brew --prefix 2>/dev/null)/etc/unbound" 2>/dev/null || true
    if [[ -n "$conf_dir" && -d "$conf_dir" ]]; then
        rm -rf "$conf_dir"
    fi
}

cleanup_exporter() {
    # Stop the service if running
    sudo launchctl bootout system /Library/LaunchDaemons/com.henrywhitaker3.adguard-exporter.plist 2>/dev/null || true
    # Remove files
    sudo rm -f /usr/local/bin/adguard-exporter 2>/dev/null || true
    sudo rm -f /usr/local/bin/adguard-exporter-wrapper.sh 2>/dev/null || true
    sudo rm -f /Library/LaunchDaemons/com.henrywhitaker3.adguard-exporter.plist 2>/dev/null || true
    sudo rm -rf /etc/adguard-exporter 2>/dev/null || true
    sudo rm -f /var/log/adguard-exporter.log 2>/dev/null || true
    sudo rm -f /var/log/adguard-exporter.error.log 2>/dev/null || true
}

cleanup_adguard_home() {
    sudo /Applications/AdGuardHome/AdGuardHome -s stop 2>/dev/null || true
    sudo /Applications/AdGuardHome/AdGuardHome -s uninstall 2>/dev/null || true
    sudo rm -rf /Applications/AdGuardHome 2>/dev/null || true
}

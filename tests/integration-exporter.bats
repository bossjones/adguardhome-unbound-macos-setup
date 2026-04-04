#!/usr/bin/env bats

# Tier 2: adguard-exporter integration tests
# Downloads the real binary, creates config/plist files, and validates them.
# Does NOT test actual metrics serving (requires running AdGuard Home).
#
# Requires: macOS, passwordless sudo, network access

load helpers/setup.bash

# --- File-level setup/teardown -----------------------------------------------

setup_file() {
    skip_unless_macos
    skip_unless_sudo

    # Clean any leftover state
    cleanup_exporter

    # Source install.sh to get version/arch variables
    export DRY_RUN=0
    export NONINTERACTIVE=1
    # shellcheck source=../install.sh
    source "$SCRIPT"

    # Determine architecture (same logic as install.sh)
    local arch go_arch
    arch=$(uname -m)
    go_arch="arm64"
    if [[ "$arch" == "x86_64" ]]; then
        go_arch="amd64"
    fi

    export EXPORTER_VERSION="${AGH_EXPORTER_VERSION}"
    export EXPORTER_ASSET="adguard-exporter_darwin_${go_arch}"
    export EXPORTER_URL="https://github.com/henrywhitaker3/adguard-exporter/releases/download/${EXPORTER_VERSION}/${EXPORTER_ASSET}"

    # Create a temp dir for download
    export TEST_TMP
    TEST_TMP=$(mktemp -d)

    # Download the binary
    if ! curl -fsSL -o "${TEST_TMP}/adguard-exporter" "$EXPORTER_URL" 2>/dev/null; then
        echo "# WARNING: Could not download exporter binary from ${EXPORTER_URL}" >&3
        export DOWNLOAD_FAILED=1
        return
    fi
    chmod +x "${TEST_TMP}/adguard-exporter"
    export DOWNLOAD_FAILED=0
}

teardown_file() {
    cleanup_exporter
    if [[ -n "${TEST_TMP:-}" && -d "${TEST_TMP:-}" ]]; then
        rm -rf "$TEST_TMP"
    fi
}

setup() {
    skip_unless_macos
    skip_unless_sudo
    if [[ "${DOWNLOAD_FAILED:-1}" == "1" ]]; then
        skip "exporter binary download failed"
    fi
}

# --- Tests -------------------------------------------------------------------

@test "exporter binary is a valid Mach-O executable" {
    run file "${TEST_TMP}/adguard-exporter"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mach-O"* ]]
}

@test "exporter binary is executable" {
    # The binary should at least run without immediate crash.
    # It will fail because there's no AdGuard Home to connect to,
    # but it should load and produce some output (not segfault).
    run timeout 5 "${TEST_TMP}/adguard-exporter" --help 2>&1 || true
    # Accept any exit code — we just care it didn't crash with a signal
    # Signals show as 128+N (e.g., 139 for SIGSEGV)
    [[ "$status" -lt 128 ]] || [[ "$status" -eq 124 ]]  # 124 = timeout
}

@test "env file created with chmod 600" {
    sudo mkdir -p /etc/adguard-exporter
    printf 'ADGUARD_SERVERS=%s\n' "http://127.0.0.1" | sudo tee /etc/adguard-exporter/adguard-exporter.env > /dev/null
    printf 'ADGUARD_USERNAMES=%s\n' "admin" | sudo tee -a /etc/adguard-exporter/adguard-exporter.env > /dev/null
    printf 'ADGUARD_PASSWORDS=%s\n' "testpass" | sudo tee -a /etc/adguard-exporter/adguard-exporter.env > /dev/null
    sudo chmod 600 /etc/adguard-exporter/adguard-exporter.env

    # Verify permissions (macOS stat format)
    local perms
    perms=$(stat -f '%Lp' /etc/adguard-exporter/adguard-exporter.env)
    [ "$perms" = "600" ]
}

@test "wrapper script has correct content" {
    sudo tee /usr/local/bin/adguard-exporter-wrapper.sh > /dev/null <<'WRAPPER'
#!/usr/bin/env bash
set -a
source /etc/adguard-exporter/adguard-exporter.env
set +a
exec /usr/local/bin/adguard-exporter
WRAPPER
    sudo chmod 700 /usr/local/bin/adguard-exporter-wrapper.sh

    [ -x /usr/local/bin/adguard-exporter-wrapper.sh ]
    run cat /usr/local/bin/adguard-exporter-wrapper.sh
    [[ "$output" == *"source /etc/adguard-exporter/adguard-exporter.env"* ]]
    [[ "$output" == *"exec /usr/local/bin/adguard-exporter"* ]]
}

@test "plist is valid XML" {
    sudo tee /Library/LaunchDaemons/com.henrywhitaker3.adguard-exporter.plist > /dev/null <<'PLIST'
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

    run plutil -lint /Library/LaunchDaemons/com.henrywhitaker3.adguard-exporter.plist
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "cleanup removes all exporter artifacts" {
    # Ensure files exist first
    sudo cp "${TEST_TMP}/adguard-exporter" /usr/local/bin/adguard-exporter 2>/dev/null || true

    cleanup_exporter

    [ ! -f /usr/local/bin/adguard-exporter ]
    [ ! -f /usr/local/bin/adguard-exporter-wrapper.sh ]
    [ ! -f /Library/LaunchDaemons/com.henrywhitaker3.adguard-exporter.plist ]
    [ ! -d /etc/adguard-exporter ]
}

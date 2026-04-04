#!/usr/bin/env bats

# Tier 1: Enhanced dry-run integration tests
# Verifies all major functions produce expected output in DRY_RUN mode.
# Safe to run anywhere — no system changes.

load helpers/setup.bash

setup() {
    export DRY_RUN=1
    export NONINTERACTIVE=1
    # shellcheck source=../install.sh
    source "$SCRIPT"
}

# --- preflight ---------------------------------------------------------------

@test "preflight succeeds on macOS" {
    skip_unless_macos
    run preflight
    [ "$status" -eq 0 ]
    [[ "$output" == *"Pre-flight"* ]]
}

# --- handle_port_53 ----------------------------------------------------------

@test "handle_port_53 dry-run shows port check" {
    run handle_port_53
    [ "$status" -eq 0 ]
    [[ "$output" == *"port 53"* ]] || [[ "$output" == *"Port 53"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

# --- install_adguard_home ----------------------------------------------------

@test "install_adguard_home dry-run shows all steps" {
    run install_adguard_home
    [ "$status" -eq 0 ]
    [[ "$output" == *"AdGuard Home"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

# --- install_unbound ---------------------------------------------------------

@test "install_unbound dry-run shows config steps" {
    require_brew
    run install_unbound
    [ "$status" -eq 0 ]
    [[ "$output" == *"Unbound"* ]]
    [[ "$output" == *"Would write unbound.conf"* ]]
}

# --- install_adguard_exporter ------------------------------------------------

@test "install_adguard_exporter dry-run shows download steps" {
    run install_adguard_exporter
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would download/build"* ]]
}

# --- show_status -------------------------------------------------------------

@test "show_status dry-run completes without error" {
    require_brew
    run show_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Service Status"* ]]
}

# --- uninstall ---------------------------------------------------------------

@test "uninstall dry-run exercises all removal paths" {
    require_brew
    run uninstall
    [ "$status" -eq 0 ]
    [[ "$output" == *"adguard-exporter"* ]]
    [[ "$output" == *"Unbound"* ]]
    [[ "$output" == *"AdGuard Home"* ]]
}

# --- Full subprocess tests ---------------------------------------------------

@test "--full dry-run runs all stages in order" {
    run bash "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Pre-flight"* ]]
    [[ "$output" == *"AdGuard Home"* ]]
    [[ "$output" == *"Unbound"* ]]
    [[ "$output" == *"adguard-exporter"* ]]
}

@test "--adguard-only dry-run installs only AdGuard Home" {
    run env DRY_RUN=1 bash "$SCRIPT" --adguard-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"AdGuard Home"* ]]
    # Should NOT contain install steps for Unbound or exporter
    [[ "$output" != *"Would write unbound.conf"* ]]
    [[ "$output" != *"Would download/build adguard-exporter"* ]]
}

@test "--uninstall dry-run completes" {
    run env DRY_RUN=1 bash "$SCRIPT" --uninstall
    [ "$status" -eq 0 ]
    [[ "$output" == *"Uninstalling"* ]]
}

#!/usr/bin/env bats

# Unit tests for install.sh
# Requires: bats-core (brew install bats-core)

SCRIPT_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." && pwd )"
SCRIPT="$SCRIPT_DIR/install.sh"

setup() {
    export DRY_RUN=1
    # Source the script — the BASH_SOURCE guard prevents main() from running
    # shellcheck source=../install.sh
    source "$SCRIPT"
}

# --- Helper function tests ---------------------------------------------------

@test "info outputs INFO tag" {
    run info "test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO]"* ]]
    [[ "$output" == *"test message"* ]]
}

@test "warn outputs WARN tag" {
    run warn "test warning"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WARN]"* ]]
    [[ "$output" == *"test warning"* ]]
}

@test "error outputs FAIL tag" {
    run error "test error"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[FAIL]"* ]]
    [[ "$output" == *"test error"* ]]
}

@test "success outputs OK tag" {
    run success "test ok"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    [[ "$output" == *"test ok"* ]]
}

@test "step outputs decorated header" {
    run step "Test Step"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Test Step"* ]]
}

# --- get_local_ip tests ------------------------------------------------------

@test "get_local_ip returns IP or UNKNOWN" {
    run get_local_ip
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$output" == "UNKNOWN" ]]
}

# --- warn_if_unknown_ip tests ------------------------------------------------

@test "warn_if_unknown_ip warns on UNKNOWN" {
    run warn_if_unknown_ip "UNKNOWN"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Could not detect"* ]]
}

@test "warn_if_unknown_ip silent on valid IP" {
    run warn_if_unknown_ip "192.168.1.1"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- confirm tests -----------------------------------------------------------

@test "confirm auto-accepts in DRY_RUN mode" {
    export DRY_RUN=1
    export NONINTERACTIVE=0
    run confirm "Test prompt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"AUTO"* ]]
}

@test "confirm auto-accepts in NONINTERACTIVE mode" {
    export DRY_RUN=0
    export NONINTERACTIVE=1
    run confirm "Test prompt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"AUTO"* ]]
}

# --- wait_for_service tests --------------------------------------------------

@test "wait_for_service succeeds on immediate success" {
    run wait_for_service "test-service" "true" 3 0
    [ "$status" -eq 0 ]
}

@test "wait_for_service fails after max attempts" {
    run wait_for_service "test-service" "false" 2 0
    [ "$status" -eq 1 ]
}

# --- show_help tests ---------------------------------------------------------

@test "show_help outputs usage info" {
    run show_help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"--full"* ]]
    [[ "$output" == *"--adguard-only"* ]]
    [[ "$output" == *"--uninstall"* ]]
    [[ "$output" == *"--status"* ]]
    [[ "$output" == *"--dry-run"* ]]
    [[ "$output" == *"--help"* ]]
}

# --- Argument parsing (integration-level) ------------------------------------

@test "--help exits 0" {
    run bash "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "unknown flag exits 1" {
    run bash "$SCRIPT" --bogus-flag
    [ "$status" -eq 1 ]
}

# --- Regression guards (grep-based) ------------------------------------------

@test "no @latest in go install — must use pinned version" {
    run grep '@latest' "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "PLIST heredoc is single-quoted" {
    run grep "<<'PLIST'" "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "env file uses printf not unquoted heredoc" {
    # The old bug used <<EOF with ADGUARD_PASSWORDS — verify it's gone
    run grep -A1 'ADGUARD_PASSWORDS' "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"printf"* ]]
}

@test "no bash 4+ lowercase expansion" {
    # ${var,,} requires bash 4+; macOS ships 3.2
    run grep -n '${.*,,}' "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "DRY_RUN variable is initialized" {
    run grep 'DRY_RUN=.*DRY_RUN:-' "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "NONINTERACTIVE variable is initialized" {
    run grep 'NONINTERACTIVE=.*NONINTERACTIVE:-' "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "BASH_SOURCE guard exists" {
    run grep 'BASH_SOURCE\[0\]' "$SCRIPT"
    [ "$status" -eq 0 ]
}

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

macOS installer for a network-wide DNS stack: **AdGuard Home** (ad-blocking DNS on `0.0.0.0:53`) + **Unbound** (recursive resolver on `127.0.0.1:5335`) + **adguard-exporter** (Prometheus metrics on `:9618`). Targets Mac Mini as a dedicated DNS server.

## Architecture

```
Network devices → AdGuard Home (0.0.0.0:53) → Unbound (127.0.0.1:5335) → root DNS
                                                adguard-exporter (:9618) → Prometheus/Grafana
```

- AdGuard Home: installed via official upstream script to `/Applications/AdGuardHome`, registered as a LaunchDaemon
- Unbound: installed via Homebrew, config written to `$(brew --prefix)/etc/unbound/unbound.conf`
- adguard-exporter: Go binary from GitHub releases, managed via LaunchDaemon with env-sourcing wrapper script

## Repository Structure

- `install.sh` — the main installer script (~920 lines of Bash) with functions for each component's install, status check, and uninstall
- `tests/install.bats` — BATS unit tests for helper functions and regression guards
- `.github/workflows/ci.yml` — GitHub Actions CI (shellcheck, syntax, BATS, dry-run smoke tests)
- `.shellcheckrc` — ShellCheck configuration

## Running the Script

```bash
chmod +x install.sh
./install.sh --full          # Install all three components (default)
./install.sh --adguard-only  # Install only AdGuard Home
./install.sh --status        # Check service status and connectivity
./install.sh --uninstall     # Remove everything
./install.sh --dry-run       # Simulate full install (no changes made)
./install.sh --help          # Show help with architecture diagram
```

The script requires macOS, must NOT be run as root (uses `sudo` internally as needed), and is interactive (prompts for confirmation at each stage, asks for AdGuard Home credentials for the exporter).

### Dry-Run Mode

Set `DRY_RUN=1` or pass `--dry-run` to simulate installation without making any changes. External commands (`sudo`, `brew`, `curl`, `dig`, `launchctl`, `lsof`) are stubbed, prompts auto-accept, and file writes are skipped. Read-only brew queries (`--prefix`, `list`) pass through.

## Shell Script Conventions

- Uses `set -euo pipefail` for strict error handling
- Colored output helpers: `info()`, `success()`, `warn()`, `error()`, `step()` for consistent formatting
- `confirm()` for interactive yes/no prompts (auto-accepts in dry-run mode)
- `warn_if_unknown_ip()` guards against displaying `http://UNKNOWN:...` URLs
- `wait_for_service()` retry loop replaces fixed `sleep` calls
- ERR trap provides recovery guidance on failure
- Configuration variables at top of file (install dirs, versions, ports)
- Each component has its own install function that is independently callable
- `BASH_SOURCE` guard at bottom allows sourcing without executing `main()`

## Key Paths and Ports

| Component | Install Location | Port | Scope |
|---|---|---|---|
| AdGuard Home | `/Applications/AdGuardHome` | 53 (DNS), 80/3000 (web UI) | Network-facing |
| Unbound | Homebrew prefix | 5335 | Localhost only |
| adguard-exporter | `/usr/local/bin/adguard-exporter` | 9618 | Metrics endpoint |
| Exporter credentials | `/etc/adguard-exporter/adguard-exporter.env` | — | chmod 600 |

## Testing

CI runs automatically on push/PR via GitHub Actions (`.github/workflows/ci.yml`).

```bash
bash -n install.sh                    # Syntax check
shellcheck install.sh                 # Lint (uses .shellcheckrc)
bats tests/                           # Unit tests (requires: brew install bats-core)
DRY_RUN=1 bash install.sh --full      # Smoke test full flow
DRY_RUN=1 bash install.sh --adguard-only  # Smoke test adguard-only flow
```

To run a single BATS test: `bats tests/install.bats --filter "test name pattern"`

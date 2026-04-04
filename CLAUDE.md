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

Single-file project: `install.sh` is the entire codebase — a Bash script (~830 lines) with functions for each component's install, status check, and uninstall.

## Running the Script

```bash
chmod +x install.sh
./install.sh --full          # Install all three components (default)
./install.sh --adguard-only  # Install only AdGuard Home
./install.sh --status        # Check service status and connectivity
./install.sh --uninstall     # Remove everything
./install.sh --help          # Show help with architecture diagram
```

The script requires macOS, must NOT be run as root (uses `sudo` internally as needed), and is interactive (prompts for confirmation at each stage, asks for AdGuard Home credentials for the exporter).

## Shell Script Conventions

- Uses `set -euo pipefail` for strict error handling
- Colored output helpers: `info()`, `success()`, `warn()`, `error()`, `step()` for consistent formatting
- `confirm()` for interactive yes/no prompts
- Configuration variables at top of file (install dirs, versions, ports)
- Each component has its own install function that is independently callable

## Key Paths and Ports

| Component | Install Location | Port | Scope |
|---|---|---|---|
| AdGuard Home | `/Applications/AdGuardHome` | 53 (DNS), 80/3000 (web UI) | Network-facing |
| Unbound | Homebrew prefix | 5335 | Localhost only |
| adguard-exporter | `/usr/local/bin/adguard-exporter` | 9618 | Metrics endpoint |
| Exporter credentials | `/etc/adguard-exporter/adguard-exporter.env` | — | chmod 600 |

## Testing Changes

No automated test suite. To validate changes:
1. Run `bash -n install.sh` to syntax-check
2. Run `shellcheck install.sh` if shellcheck is available
3. Test with `--status` flag on a macOS machine with the stack installed

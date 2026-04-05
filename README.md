# AdGuard Home + Unbound + adguard-exporter for macOS

A single-script installer that turns a Mac Mini (or any Mac) into a network-wide, ad-blocking, privacy-respecting DNS server with Prometheus metrics.

Adapted from [Dad, the Engineer's Raspberry Pi guide](https://www.dad-the-engineer.com/blog/5cxn4w2ofern6gsnxeyaw07w0vw5ve) for macOS.

## Architecture

```
  ┌─────────────────────────────────────────────────┐
  │  Your Network Devices                           │
  │  (phones, laptops, servers, IoT)                │
  │  DNS queries -> Mac Mini IP:53                  │
  └──────────────────┬──────────────────────────────┘
                     │
                     v
  ┌─────────────────────────────────────────────────┐
  │  AdGuard Home (0.0.0.0:53)                      │
  │  - Blocks ads & trackers                        │
  │  - Query logging & parental controls            │
  │  - Web UI on port 80                            │
  └──────────────────┬──────────────────────────────┘
                     │ forwards to
                     v
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
```

**AdGuard Home** is the network-facing DNS server that all your devices point to. It filters ads and trackers, then forwards clean queries to **Unbound**, a local recursive resolver that talks directly to root DNS servers -- no Google, Cloudflare, or other third-party DNS involved. **adguard-exporter** exposes AdGuard Home stats as Prometheus metrics for Grafana dashboards.

## Quick Start

```bash
git clone https://github.com/bossjones/adguardhome-unbound-macos-setup.git
cd adguardhome-unbound-macos-setup

chmod +x install.sh
./install.sh --full
```

The script will walk you through each step interactively, prompting for confirmation before installing each component.

### Requirements

- macOS (tested on Apple Silicon Mac Mini)
- [Homebrew](https://brew.sh)
- Must **not** be run as root (the script uses `sudo` internally as needed)
- Port 53 available (no other DNS server running)

## Usage

```bash
./install.sh --full            # Install all three components (default)
./install.sh --adguard-only    # Install only AdGuard Home
./install.sh --exporter-only   # Install only adguard-exporter (Prometheus metrics)
./install.sh --status          # Check service status and connectivity
./install.sh --uninstall       # Remove everything
./install.sh --dry-run         # Simulate full install (no changes made)
./install.sh --help            # Show help with architecture diagram
```

### What Gets Installed

| Component | Method | Location | Ports |
|---|---|---|---|
| AdGuard Home | Official upstream script | `/Applications/AdGuardHome` | 53 (DNS), 80/3000 (web UI) |
| Unbound | Homebrew | `$(brew --prefix)/sbin/unbound` | 5335 (localhost only) |
| adguard-exporter | GitHub release binary | `/usr/local/bin/adguard-exporter` | 9618 (metrics) |

All three components are registered as LaunchDaemons and start automatically on boot.

### Post-Install Setup

After `install.sh --full` completes:

1. **Complete AdGuard Home setup** -- open the URL shown by the installer (usually `http://<your-mac-ip>:3000`) and follow the setup wizard
2. **Configure AdGuard Home's upstream DNS** -- in the AdGuard Home web UI, go to Settings > DNS settings and set the upstream DNS server to `127.0.0.1:5335` (Unbound)
3. **Point your router's DNS** to your Mac's IP address so all devices on your network use it

### Non-Interactive Mode

For headless or automated deployments:

```bash
NONINTERACTIVE=1 \
  AGH_EXPORTER_URL="http://localhost" \
  AGH_EXPORTER_USER="admin" \
  AGH_EXPORTER_PASS="yourpassword" \
  ./install.sh --full
```

### Dry-Run Mode

Preview what the installer would do without making any changes:

```bash
./install.sh --dry-run
# or
DRY_RUN=1 ./install.sh --full
```

External commands (`sudo`, `brew`, `curl`, `dig`, `launchctl`, `lsof`) are stubbed, prompts auto-accept, and file writes are skipped.

## Repository Structure

```
.
├── install.sh                          # Main installer (~970 lines of Bash)
├── tests/
│   ├── helpers/
│   │   └── setup.bash                  # Shared test helpers
│   ├── install.bats                    # Unit tests
│   ├── integration-dryrun.bats         # Tier 1: dry-run integration tests
│   ├── integration-unbound.bats        # Tier 2: real Unbound tests
│   ├── integration-exporter.bats       # Tier 2: exporter binary tests
│   └── integration-lifecycle.bats      # Tier 3: full install/uninstall cycle
├── .github/workflows/
│   ├── ci.yml                          # ShellCheck, syntax, BATS, smoke tests
│   └── integration.yml                 # Tiered integration tests on macOS
├── .shellcheckrc                       # ShellCheck configuration
└── CLAUDE.md                           # AI assistant instructions
```

## Testing

CI runs automatically on push and pull requests via GitHub Actions.

### Running Tests Locally

```bash
# Lint and syntax
shellcheck install.sh
bash -n install.sh

# Unit tests (safe, no side effects)
bats tests/install.bats

# Dry-run integration tests (safe, no side effects)
bats tests/integration-dryrun.bats

# Smoke test the full flow
DRY_RUN=1 bash install.sh --full
DRY_RUN=1 bash install.sh --adguard-only
```

### Test Tiers

| Tier | File | Requires | What It Tests |
|------|------|----------|---------------|
| Unit | `tests/install.bats` | bats | Helper functions, regression guards |
| 1 | `tests/integration-dryrun.bats` | bats | All major functions in DRY_RUN mode |
| 2 | `tests/integration-unbound.bats` | bats, sudo, Homebrew | Real Unbound: install, config, DNS, DNSSEC, cleanup |
| 2 | `tests/integration-exporter.bats` | bats, sudo, network | Exporter binary download, plist validation, cleanup |
| 3 | `tests/integration-lifecycle.bats` | bats, sudo, Homebrew, network | Full install -> configure -> verify -> uninstall |

Tier 2-3 tests run on macOS CI runners with `sudo` access. They install real software and clean up after themselves.

## Uninstalling

```bash
./install.sh --uninstall
```

This stops all services, removes the exporter binary and LaunchDaemon plists, and uninstalls Unbound via Homebrew. AdGuard Home files at `/Applications/AdGuardHome` are left for manual removal. Remember to update your router's DNS settings after uninstalling.

## Monitoring

The adguard-exporter exposes Prometheus metrics at `http://<your-mac-ip>:9618/metrics`. Import [Grafana dashboard 20799](https://grafana.com/grafana/dashboards/20799) for a pre-built visualization.

Credentials for the exporter are stored in `/etc/adguard-exporter/adguard-exporter.env` (chmod 600).

## Credits

- [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome)
- [Unbound](https://nlnetlabs.nl/projects/unbound/about/)
- [adguard-exporter](https://github.com/henrywhitaker3/adguard-exporter) by Henry Whitaker
- [Dad, the Engineer's original RPi guide](https://www.dad-the-engineer.com/blog/5cxn4w2ofern6gsnxeyaw07w0vw5ve)

## License

See [LICENSE](LICENSE) for details.

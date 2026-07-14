# Protocol Integration Checklist

> Machine-readable checklist for adding a new protocol to MoaV.
> Reference implementation: TrustTunnel (most recently added protocol).
> Placeholder `NEWPROTO` = protocol name (lowercase, no hyphens in env vars).
>
> **Also add the protocol to the single-source roster** `data/protocols.json`,
> then run `python3 scripts/gen-protocol-docs.py --write` (regenerates the
> `docs/protocols.md` overview table) and `--check` (CI gate — every protocol
> must also appear in `site/index.html` + `README.md`).

---

## Pre-flight

- [ ] Decide: Does this protocol require a domain/TLS? (affects bootstrap.sh domain_required check)
- [ ] Decide: Does this protocol require privileged/host networking? (affects docker-compose.yml)
- [ ] Decide: Default `ENABLE_NEWPROTO` value — `true` (production-ready) or `false` (experimental)
- [ ] Decide: Does the client binary exist as a pre-built release, or must it be compiled from source?
- [ ] Decide: Port number and protocol (TCP/UDP/both) — check `.env.example` PORT_ section for conflicts
- [ ] Decide: Authentication model — UUID-based (like VLESS), password-based (like Trojan/TrustTunnel), or key-based (like WireGuard)

---

## 1. Docker Infrastructure

### 1a. `dockerfiles/Dockerfile.newproto` (NEW FILE)

- [ ] Create multi-stage build if compiling from source:
  ```
  FROM golang:1.23-alpine AS builder
  ...
  FROM alpine:3.20
  ```
- [ ] Or single-stage with pre-built binary download
- [ ] Add runtime dependencies (bash, curl, jq at minimum)
- [ ] Copy entrypoint script: `COPY scripts/newproto-entrypoint.sh /app/entrypoint.sh`
- [ ] Set `ENTRYPOINT ["/app/entrypoint.sh"]`

### 1b. `scripts/newproto-entrypoint.sh` (NEW FILE)

- [ ] `#!/bin/bash` + `set -euo pipefail`
- [ ] Load config from mounted volume or env vars
- [ ] Generate runtime config if needed
- [ ] Health/readiness logging
- [ ] `exec` the protocol binary (PID 1)

### 1c. `configs/newproto/.gitkeep` (NEW FILE)

- [ ] Create empty directory placeholder for config mount
- [ ] Add `.template` files here if using `envsubst` pattern (see TrustTunnel)

### 1d. `docker-compose.yml`

- [ ] Add service block (find TrustTunnel block as reference, ~line 294):
  ```yaml
  newproto:
    build:
      context: .
      dockerfile: dockerfiles/Dockerfile.newproto
    container_name: moav-newproto
    restart: unless-stopped
    networks:
      - moav_net            # or network_mode: host if needed
    ports:
      - "${PORT_NEWPROTO:-XXXX}:XXXX/tcp"
    volumes:
      - ./configs/newproto:/etc/newproto:ro
      - moav_state:/state
    environment:
      - TZ=${TZ:-UTC}
    profiles:
      - newproto
      - all
  ```
- [ ] If TLS-dependent: add `depends_on: certbot: condition: service_completed_successfully`
- [ ] If TLS-dependent: add `newproto` to certbot's `profiles:` list (~line 174)
- [ ] Add to bootstrap service `environment:` section (~line 567):
  ```yaml
  - ENABLE_NEWPROTO=${ENABLE_NEWPROTO:-false}
  - PORT_NEWPROTO=${PORT_NEWPROTO:-XXXX}
  ```

---

## 2. Configuration & Environment

### 2a. `.env.example`

- [ ] Add `ENABLE_NEWPROTO=false` in PROTOCOL TOGGLES section (~line 38, after last ENABLE_)
- [ ] Add version variable in VERSIONS section (~line 61):
  ```bash
  # NewProto - https://github.com/org/newproto/releases
  NEWPROTO_VERSION=x.y.z
  ```
- [ ] Add port in PORTS section (~line 137):
  ```bash
  PORT_NEWPROTO=XXXX    # NewProto (protocol description)
  ```
- [ ] Add `newproto` to DEFAULT_PROFILES comment (~line 175)

---

## 3. Bootstrap & User Generation

### 3a. `scripts/bootstrap.sh`

- [ ] If TLS-required: add domain_required check (~line 38):
  ```bash
  [[ "${ENABLE_NEWPROTO:-false}" == "true" ]] && domain_required=true
  ```
- [ ] Add key/secret generation section (after existing key sections, ~line 160):
  ```bash
  if [[ "${ENABLE_NEWPROTO:-false}" == "true" ]]; then
      # Generate keys/secrets specific to this protocol
      ...
  fi
  ```
- [ ] Add to export section (~line 186):
  ```bash
  export ENABLE_NEWPROTO="${ENABLE_NEWPROTO:-false}"
  export PORT_NEWPROTO="${PORT_NEWPROTO:-XXXX}"
  ```
- [ ] If protocol has per-user credentials: add accumulator variable before user loop (~line 261):
  ```bash
  NEWPROTO_CREDENTIALS=""
  ```
- [ ] If protocol has per-user credentials: add to user loop body (~line 297):
  ```bash
  NEWPROTO_CREDENTIALS+="<per-user config block>"
  ```
- [ ] Add config generation section after user loop (~line 316):
  ```bash
  if [[ "${ENABLE_NEWPROTO:-false}" == "true" ]]; then
      log_info "Generating NewProto configuration..."
      # envsubst or direct generation
  fi
  ```

### 3b. `scripts/generate-user.sh`

- [ ] Add user bundle generation section (find TrustTunnel section ~line 268):
  ```bash
  if [[ "${ENABLE_NEWPROTO:-false}" == "true" ]]; then
      # Generate client config file(s) in $OUTPUT_DIR/
      cat > "$OUTPUT_DIR/newproto.conf" <<EOF
      ...
      EOF
      log_info "  - NewProto config generated"
  fi
  ```
- [ ] Generate at minimum: config file + human-readable instructions text file
- [ ] Optionally: JSON format for programmatic use

### 3c. `scripts/generate-single-user.sh`

- [ ] Add server-side config append section (find TrustTunnel section ~line 71):
  ```bash
  NEWPROTO_CONFIG="/configs/newproto/config.file"
  if [[ -f "$NEWPROTO_CONFIG" ]]; then
      if grep -q "<user identifier>" "$NEWPROTO_CONFIG" 2>/dev/null; then
          log_info "User $USER_ID already exists in NewProto"
      else
          cat >> "$NEWPROTO_CONFIG" <<EOF
  <per-user config block>
  EOF
          log_info "Added $USER_ID to NewProto"
      fi
  fi
  ```
- [ ] Add to export section (~line 99):
  ```bash
  export ENABLE_NEWPROTO="${ENABLE_NEWPROTO:-false}"
  export PORT_NEWPROTO="${PORT_NEWPROTO:-XXXX}"
  ```

### 3d. `scripts/user-add.sh` (host-side user creation)

> **Important:** `user-add.sh` runs on the host (via `moav user add`), separately from
> `generate-single-user.sh` (which runs inside the bootstrap container). Both paths must
> handle the new protocol.

- [ ] Add peer/credential creation step (after WireGuard section ~line 177):
  - Generate keys, calculate client IP, save credentials to `state/users/$USERNAME/`
  - Append peer to server config (e.g., `configs/newproto/config.file`)
  - Generate client config file + QR code in `$OUTPUT_DIR/`
- [ ] Update step counters (`[1/N]`, `[2/N]`, etc.) to include new protocol
- [ ] Add `CONFIG_NEWPROTO` reading in README.html section:
  ```bash
  CONFIG_NEWPROTO=$(cat "$OUTPUT_DIR/newproto.conf" 2>/dev/null || echo "")
  ```
- [ ] Add `QR_NEWPROTO_B64` generation and sed replacement:
  ```bash
  QR_NEWPROTO_B64=$(qr_to_base64 "$OUTPUT_DIR/newproto-qr.png")
  sed -i.bak "s|{{QR_NEWPROTO}}|$QR_NEWPROTO_B64|g" "$OUTPUT_HTML"
  ```
- [ ] Add `replace_placeholder` call for `{{CONFIG_NEWPROTO}}`
- [ ] Add service reload in batch mode section (after WireGuard reload)

---

## 4. CLI Tool (`moav.sh`)

### 4a. Profile System

- [ ] Add to `valid_profiles` string (~line 2892):
  ```bash
  local valid_profiles="proxy wireguard dnstt trusttunnel newproto admin conduit snowflake monitoring client all setup"
  ```
- [ ] Add ENABLE_ flag reading in `select_profiles()` (~line 1687):
  ```bash
  local newproto_enabled=true
  local enable_newproto=$(grep "^ENABLE_NEWPROTO=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "false")
  [[ "$enable_newproto" != "true" ]] && newproto_enabled=false
  ```
- [ ] Add menu display line (~line 1731, use next available number N):
  ```bash
  if [[ "$newproto_enabled" == "true" ]]; then
      newproto_line="  ${CYAN}│${NC}  ${GREEN}N${NC}   newproto     Description here                              ${CYAN}│${NC}"
  else
      newproto_line="  ${CYAN}│${NC}  ${DIM}N   newproto     NewProto (disabled)${NC}                          ${CYAN}│${NC}"
  fi
  ```
- [ ] Add case statement entry (~line 1865):
  ```bash
  N) SELECTED_PROFILES+=("newproto") ;;
  ```
- [ ] Add "all" profile auto-add block (~line 1805):
  ```bash
  if [[ "$enable_newproto" == "true" ]]; then
      SELECTED_PROFILES+=("newproto")
  fi
  ```

### 4b. Profile Resolution

- [ ] If protocol has short aliases, add to `resolve_profile()` (~line 3001):
  ```bash
  np|newp)
      echo "newproto" ;;
  ```
- [ ] If no aliases needed: protocol passes through `*)` catch-all (no change needed)

### 4c. Help Text

- [ ] Add to profiles list in help output (~line 2682):
  ```
  Profiles: proxy, wireguard, dnstt, trusttunnel, newproto, admin, ...
  ```
- [ ] Add to services list
- [ ] Add to aliases list (if applicable)

### 4d. Cleanup/Wipe

- [ ] Add generated config cleanup in wipe function (~line 831):
  ```bash
  if [[ -f "$SCRIPT_DIR/configs/newproto/<generated-file>" ]]; then
      rm -f "$SCRIPT_DIR/configs/newproto/<generated-file>" 2>/dev/null
      echo "  - configs/newproto/*"
  fi
  ```

### 4e. Regenerate Users

- [ ] Add ENABLE_ flag reading in `cmd_regenerate_users()` (~line 4355):
  ```bash
  local enable_newproto=$(grep -E '^ENABLE_NEWPROTO=' .env 2>/dev/null | cut -d= -f2 | tr -d '"')
  ```
- [ ] Add to docker run `-e` flags (~line 4374):
  ```bash
  -e "ENABLE_NEWPROTO=${enable_newproto:-false}" \
  ```

### 4f. Version-Based Rebuild Detection

- [ ] Add to version change detection (~line 1188):
  ```bash
  NEWPROTO_VERSION)
      if [[ ! " ${services_to_rebuild[*]} " =~ " newproto " ]]; then
          services_to_rebuild+=("newproto")
      fi
      ;;
  ```

---

## 5. Client Container

### 5a. `dockerfiles/Dockerfile.client`

- [ ] If building from source: add builder stage
  ```dockerfile
  FROM golang:1.23-alpine AS newproto-builder
  RUN go install github.com/org/newproto@latest
  ```
- [ ] If downloading pre-built binary: add ARG + RUN download block (~line 108):
  ```dockerfile
  ARG NEWPROTO_VERSION=x.y.z
  RUN ... download and install binary ...
  ```
- [ ] Add runtime dependencies if needed (e.g., `libpcap` for raw sockets)
- [ ] Add to comment header listing supported protocols (~line 4)

### 5b. `scripts/client-connect.sh`

- [ ] Add to `PROTOCOL_PRIORITY` array (~line 27):
  ```bash
  PROTOCOL_PRIORITY=(reality hysteria2 trojan trusttunnel newproto wireguard tor dnstt)
  ```
- [ ] Add `connect_newproto()` function:
  - Check for config file(s)
  - Check binary exists: `command -v newproto_binary`
  - Start client process
  - Wait for connection (sleep appropriate amount)
  - Test connectivity (SOCKS5 proxy test or direct TUN test)
  - Set `CURRENT_PROTOCOL="newproto"`
- [ ] Add to `connect_auto` case block (~line 764)
- [ ] Add to `main()` case block (~line 827)
- [ ] If protocol requires privileged mode or manual config: exclude from auto mode

### 5c. `tests/client-test.sh`

- [ ] Add `test_newproto()` function:
  - Look for config files (ordered preference)
  - Validate config contents
  - Check binary availability
  - TCP reachability test: `nc -z -w 3 "$server_ip" "$port"`
  - Set `RESULTS[newproto]="pass|fail|skip|warn"`
- [ ] Add `newproto` to `output_json` protocol loop (~line 1133)
- [ ] Add `newproto` to `output_human` protocol loop (~line 1164)
- [ ] Add `test_newproto` call to main test sequence (~line 1198)
- [ ] If SOCKS-based: assign dedicated SOCKS port (next after 10803)

---

## 6. Documentation

### 6a. `README.md`

- [ ] Add row to protocol comparison table (~line 132):
  ```markdown
  | NewProto | XXXX/tcp | ★★★☆☆ | ★★★☆☆ | Description |
  ```
- [ ] Add `newproto` to profiles list (~line 186)

### 6b. `README-fa.md`

- [ ] Mirror all README.md changes in Farsi

### 6c. `docs/SETUP.md`

- [ ] Add to domain requirement note (~line 40) — required or not-required list
- [ ] Add row to ports table (~line 51)
- [ ] Add to profiles listing (~line 248)
- [ ] Add firewall commands (~line 265)
- [ ] Add to user bundle files listing (~line 312)
- [ ] If domainless capable: add to domainless mode available list (~line 369)

### 6d. `docs/CLIENTS.md`

- [ ] Add TOC entry (~line 19)
- [ ] Add row to protocol table (~line 39)
- [ ] Add client app entries per platform (iOS ~line 62, Android ~line 78, Windows ~line 92)
- [ ] Add full setup section with config file descriptions and install instructions

### 6e. `docs/TROUBLESHOOTING.md`

- [ ] Add TOC entry (~line 19)
- [ ] Add troubleshooting section:
  - Container running check: `docker compose --profile newproto ps`
  - Log check: `docker compose logs newproto`
  - Port open check
  - Certificate check (if TLS)
  - Client config verification

### 6f. `docs/client-guide-template.html` (User Bundle README)

The HTML guide template generates per-user `README.html` files in each user's bundle.
It has **two language sections** (English and Farsi) that must both be updated.

- [ ] **English TOC**: Add entry with appropriate number and badge
- [ ] **English protocol section**: Add full section with:
  - Protocol header (name, badge, port)
  - Description paragraph
  - "When to use" guidance box
  - Download links for client apps (iOS, Android, Windows, macOS, Linux)
  - QR code section: `<img src="data:image/png;base64,{{QR_NEWPROTO}}">`
  - Config box: `<div class="config-value multiline">{{CONFIG_NEWPROTO}}</div>`
- [ ] **English apps table**: Add app rows per platform, update `rowspan` values
- [ ] **Farsi TOC**: Mirror English TOC with Farsi text and numbering (۱, ۲, ۳...)
- [ ] **Farsi protocol section**: Mirror English section with Farsi text, RTL-compatible
- [ ] **Farsi apps table**: Mirror English apps table updates
- [ ] **Renumber**: If inserting mid-list, update all subsequent section numbers in both languages
- [ ] **`scripts/generate-user.sh`**: Add template variable replacements:
  ```bash
  CONFIG_NEWPROTO=$(cat "$OUTPUT_DIR/newproto.conf" 2>/dev/null || echo "")
  QR_NEWPROTO_B64=$(qr_to_base64 "$OUTPUT_DIR/newproto-qr.png")
  sed -i "s|{{QR_NEWPROTO}}|$QR_NEWPROTO_B64|g" "$OUTPUT_HTML"
  replace_placeholder "{{CONFIG_NEWPROTO}}" "$CONFIG_NEWPROTO"
  ```

**Badge types available:** `badge-primary` (green), `badge-secondary` (blue), `badge-fallback` (orange), `badge-standalone` (purple)

---

## 7. `.gitignore` — Exclude Generated Config Files

Any config files generated at runtime (by bootstrap or entrypoint) must be added to `.gitignore`, otherwise `moav update` will warn about "local changes detected" and block the update.

Add entries following the existing pattern in `.gitignore`:

```gitignore
# NewProto generated files
configs/newproto/config-file.conf
configs/newproto/server.pub
```

**What to ignore:** Any file created by bootstrap/entrypoint that lives in `configs/newproto/` but is NOT a `.gitkeep` or template file.

**Reference — existing patterns:**
| Protocol | Ignored files |
|----------|--------------|
| sing-box | `configs/sing-box/config.json` |
| WireGuard | `configs/wireguard/wg0.conf`, `server.pub`, `server.key`, `wg_confs/`, `peer*/` |
| AmneziaWG | `configs/amneziawg/awg0.conf`, `server.pub` |
| dnstt | `configs/dnstt/server.conf`, `server.pub`, `*.key`, `*.key.hex` |
| TrustTunnel | `configs/trusttunnel/vpn.toml`, `hosts.toml`, `credentials.toml` |

---

## 8. Grafana Monitoring (Optional)

> Before building anything, research existing community/official Prometheus exporters for the
> protocol. Present options to the team (official exporter, custom exporter, or both) with
> trade-offs (maintenance burden, metric granularity, resource usage).

### 8a. Research & Decision

- [ ] Search GitHub for `<protocol-name> prometheus exporter` or `<protocol-name> exporter`
- [ ] Check if the protocol's official project provides an exporter
- [ ] Document options found and present to team:
  - **Official/community exporter:** What metrics? Docker image available? Dependencies (Redis, etc.)?
  - **Custom exporter (our pattern):** What data can we scrape? (`docker exec`, log parsing, API?)
  - **Both:** Does combining official + custom give meaningfully better coverage?
- [ ] Decide on approach based on: metric coverage, maintenance, resource usage

### 8b. Exporter(s) — `exporters/newproto/` (NEW DIRECTORY)

- [ ] If custom exporter: create `exporters/newproto/main.py` + `Dockerfile`
  - Follow pattern from `exporters/wireguard/` (docker exec + parsing) or `exporters/conduit/` (log tailing)
  - Use metric prefix `newproto_` for all custom metrics
  - Port: pick next available (check existing: 9100, 9101, 9102, 9351, 9586, 9587)
- [ ] If official exporter: use pre-built Docker image in docker-compose.yml

### 8c. `docker-compose.yml` — Add exporter service(s)

- [ ] Add under monitoring section (after `wireguard-exporter` block):
  ```yaml
  newproto-exporter:
    build:                            # or image: for official
      context: ./exporters/newproto
      dockerfile: Dockerfile
    container_name: moav-newproto-exporter
    restart: unless-stopped
    networks:
      - moav_net
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./configs/newproto:/etc/newproto:ro
    environment:
      - TZ=${TZ:-UTC}
    profiles:
      - monitoring
      - all
  ```

### 8d. `configs/monitoring/prometheus.yml` — Add scrape job(s)

- [ ] Add scrape config:
  ```yaml
  - job_name: 'newproto'
    static_configs:
      - targets: ['newproto-exporter:PORT']
    scrape_timeout: 10s
  ```

### 8e. Grafana Dashboard — `configs/monitoring/grafana/provisioning/dashboards/newproto.json` (NEW FILE)

- [ ] Create dashboard JSON following existing pattern (see `wireguard.json`)
- [ ] Include: stat panels (top row), time series charts (traffic rate), table (peer/connection details)
- [ ] Set `"uid": "moav-newproto"` and `"title": "MoaV - NewProto"`
- [ ] Tags: `["moav", "newproto", "vpn"]`

---

## 9. Verification

- [ ] `bash -n moav.sh` — syntax check passes
- [ ] `docker compose config --profiles newproto` — compose config valid
- [ ] `chmod +x scripts/newproto-entrypoint.sh` — entrypoint is executable
- [ ] `git diff main --stat` — only newproto-related files changed
- [ ] Grep for hardcoded paths/ports that should be variables
- [ ] Grep for old-style paths if porting from an older branch
- [ ] Test: `./moav.sh start newproto` — service starts
- [ ] Test: `./moav.sh stop newproto` — service stops
- [ ] Test: `./moav.sh status` — shows newproto status
- [ ] Test: bootstrap with `ENABLE_NEWPROTO=true` — user bundles include newproto configs
- [ ] Test: `./moav.sh add-user testuser` — new user gets newproto credentials

---

## Quick Reference: Naming Conventions

| Item | Pattern | Example |
|------|---------|---------|
| Service name | `newproto` | `trusttunnel` |
| Container name | `moav-newproto` | `moav-trusttunnel` |
| Dockerfile | `dockerfiles/Dockerfile.newproto` | `dockerfiles/Dockerfile.trusttunnel` |
| Entrypoint | `scripts/newproto-entrypoint.sh` | `scripts/trusttunnel-entrypoint.sh` |
| Config dir | `configs/newproto/` | `configs/trusttunnel/` |
| Enable flag | `ENABLE_NEWPROTO` | `ENABLE_TRUSTTUNNEL` |
| Port var | `PORT_NEWPROTO` | `PORT_TRUSTTUNNEL` |
| Version var | `NEWPROTO_VERSION` | `TRUSTTUNNEL_VERSION` |
| Profile name | `newproto` | `trusttunnel` |
| User bundle file | `newproto.conf` | `trusttunnel.toml` |
| Client binary | `newproto` or `newproto_client` | `trusttunnel_client` |
| Log path | `/var/log/moav/newproto.log` | `/var/log/moav/trusttunnel.log` |
| Test result key | `RESULTS[newproto]` | `RESULTS[trusttunnel]` |

---

## File Count Summary

| Type | Count | Files |
|------|-------|-------|
| New files | 3-4 | Dockerfile, entrypoint, configs/.gitkeep, (templates) |
| Modified files | 13-15 | docker-compose.yml, .env.example, .gitignore, moav.sh, bootstrap.sh, generate-user.sh, generate-single-user.sh, user-add.sh, Dockerfile.client, client-connect.sh, client-test.sh, README.md, README-fa.md, SETUP.md, CLIENTS.md, TROUBLESHOOTING.md |
| **Total** | **15-18** | |

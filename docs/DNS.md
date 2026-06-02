# DNS Configuration Guide

This guide explains how to configure DNS records for MoaV.

## Table of Contents

- [Do I Need a Domain?](#do-i-need-a-domain)
- [Domainless Mode](#domainless-mode)
- [Domain Setup](#domain-setup)
  - [Minimum Setup (Without DNS Tunnels)](#minimum-setup-without-dns-tunnels)
  - [Full Setup (With DNS Tunnels)](#full-setup-with-dns-tunnels)
- [Provider-Specific Instructions](#provider-specific-instructions)
  - [Cloudflare](#cloudflare)
  - [AWS CloudFront (Alternative CDN)](#aws-cloudfront-alternative-cdn)
  - [Namecheap](#namecheap)
  - [Google Domains / Squarespace](#google-domains--squarespace)
  - [Hetzner DNS](#hetzner-dns)
- [Home Servers & Raspberry Pi](#home-servers--raspberry-pi)
  - [Port Forwarding](#port-forwarding)
  - [Dynamic DNS (DDNS)](#dynamic-dns-ddns)
  - [DuckDNS (Free)](#duckdns-free)
  - [Cloudflare DDNS (Own Domain)](#cloudflare-ddns-own-domain)
  - [Home Server Tips](#home-server-tips)
- [Verification](#verification)
- [Common Issues](#common-issues)
- [Domain Acquisition Tips](#domain-acquisition-tips)

---

## Do I Need a Domain?

**No.** MoaV can run without a domain in **domainless mode**. A domain unlocks more protocols, but several work with just an IP address.

| Protocol | Requires Domain | Port |
|----------|:-:|------|
| Reality (VLESS) | No | 443/tcp |
| XHTTP (VLESS+XHTTP+Reality) | No | 2096/tcp |
| WireGuard | No | 51820/udp |
| WireGuard (wstunnel) | No | 8080/tcp |
| AmneziaWG | No | 51821/udp |
| Telegram MTProxy (telemt) | No | 993/tcp |
| Admin Dashboard | No | 9443/tcp |
| Conduit (Psiphon donation) | No | — |
| Snowflake (Tor donation) | No | — |
| Trojan | **Yes** | 8443/tcp |
| Hysteria2 | **Yes** | 443/udp |
| TrustTunnel | **Yes** | 4443/tcp+udp |
| CDN (VLESS+WebSocket) | **Yes** (Cloudflare) or **No** (CloudFront) | 2082/tcp |
| dnstt (DNS tunnel) | **Yes** (NS records) | 53/udp |
| Slipstream (QUIC-over-DNS) | **Yes** (NS records) | 53/udp |
| MasterDNS (ARQ DNS tunnel, MahsaNG v16) | **Yes** (NS records) | 53/udp |
| XDNS (mKCP DNS tunnel) | **Yes** (NS records) | 53/udp |

**Domain-dependent protocols** need a valid TLS certificate (via Let's Encrypt) or NS delegation, which both require a domain.

---

## Domainless Mode

Leave `DOMAIN=` empty in your `.env` file. MoaV automatically detects this and runs only protocols that work without a domain:

- **Reality** — VLESS with TLS camouflage (uses `REALITY_TARGET` like `dl.google.com` instead of your own domain)
- **XHTTP** — VLESS+XHTTP+Reality via Xray-core (same TLS camouflage, different transport)
- **WireGuard** — Full VPN, direct UDP or tunneled over WebSocket (TCP) when UDP is blocked
- **AmneziaWG** — DPI-resistant WireGuard with packet-level obfuscation
- **Telegram MTProxy** — Direct Telegram access via fake-TLS, no VPN needed
- **Admin Dashboard** — Web UI with self-signed certificate
- **Conduit / Snowflake** — Bandwidth donation (optional)

This is ideal for:
- **Raspberry Pi** or home servers without a registered domain
- Quick deployments when you can't register a domain
- Environments where only VPN-style protocols are needed

You can upgrade to a full domain setup later — just set `DOMAIN=` in `.env` and run `moav bootstrap`.

### Port Forwarding (Domainless)

If running on a home network, forward these ports on your router:

| Port | Protocol | Service |
|------|----------|---------|
| 443/tcp | TCP | Reality (VLESS) |
| 2096/tcp | TCP | XHTTP (VLESS+XHTTP+Reality) |
| 51820/udp | UDP | WireGuard |
| 8080/tcp | TCP | wstunnel (WireGuard over WebSocket) |
| 51821/udp | UDP | AmneziaWG |
| 993/tcp | TCP | Telegram MTProxy |
| 9443/tcp | TCP | Admin Dashboard |

> No port 80 needed — domainless mode doesn't use Let's Encrypt.

---

## Domain Setup

If you have a domain, you unlock all 16+ protocols. How many DNS records you need depends on which features you enable.

### Minimum Setup (Without DNS Tunnels)

If you don't need DNS tunnels (dnstt / Slipstream / MasterDNS / XDNS), you only need one record:

```
Type: A
Name: @ (or your domain name)
Value: YOUR_SERVER_IP
TTL: 300 (or Auto)
```

This enables: Reality, Trojan, Hysteria2, TrustTunnel, CDN mode, and all domainless protocols.

### Full Setup (With DNS Tunnels)

#### Step 1: Main A Record

```
Type: A
Name: @ (or your domain name)
Value: YOUR_SERVER_IP
TTL: 300
```

#### Step 2: DNS Server A Record

```
Type: A
Name: dns
Value: YOUR_SERVER_IP
TTL: 300
```

This creates `dns.yourdomain.com` pointing to your server (used as the nameserver for tunnel subdomains).

#### Steps 3–6: NS Delegations for the four DNS tunnels

All four tunnels — **dnstt** (`t.`), **Slipstream** (`s.`), **MasterDNS** (`m.`), and **XDNS** (`x.`) — are enabled by default and share port 53 via `dns-router`, which fans queries out by subdomain. Each needs its own NS delegation:

| Tunnel | Subdomain | `ENABLE_*` |
|--------|-----------|------------|
| **dnstt** — KCP+Noise, broadest client support | `t.` | `ENABLE_DNSTT` |
| **Slipstream** — QUIC-over-DNS, 1.5–5× faster than dnstt | `s.` | `ENABLE_SLIPSTREAM` |
| **MasterDNS** — ARQ + resolver load-balancing, bundled in MahsaNG v16 | `m.` | `ENABLE_MASTERDNS` |
| **XDNS** — Xray FinalMask mKCP, per-user auth (needs FinalMask client: Happ, Xray CLI) | `x.` | `ENABLE_XDNS` |

Add one NS record per tunnel you want to expose, all pointing at the same nameserver host:

```
Type: NS
Name: t        # or s / m / x (one record per tunnel)
Value: dns.yourdomain.com
TTL: 300
```

The container for any disabled tunnel stays down — `dns-router` just doesn't route to it. To opt a tunnel out, set its `ENABLE_*` to `false` in `.env`.

> **Client-side resolver choice**: All four tunnels rely on a public DNS resolver the *client* can reach. `1.1.1.1` / `8.8.8.8` are commonly throttled or null-routed during shutdowns. XDNS round-robins across multiple resolvers via `XDNS_RESOLVERS` in `.env`; dnstt and Slipstream take a `--dns-server` / `-doh` flag at the client. See [protocols.md → Reachable DNS resolvers](protocols.md#reachable-dns-resolvers) for resolver-scanning ([findns](https://github.com/SamNet-dev/findns), [dns-mns](https://gitlab.com/E-Gurl/dns-mns)).

#### Which DNS tunnel should I use?

All four are last-resort transports for when almost everything except DNS is
blocked. They differ in speed, client support, and resilience:

| Tunnel | Subdomain | Speed (vs dnstt) | Packet-loss resilience | Default | Best for |
|--------|-----------|------------------|------------------------|---------|----------|
| **dnstt** | `t` | 1× (baseline) | low | ✅ on | Maximum client support (standalone client on 25+ platforms) |
| **Slipstream** | `s` | 1.5–5× | medium | ✅ on | Faster general use where a Slipstream client is available |
| **MasterDNS** | `m` | up to 9× | high (ARQ + packet duplication + multi-resolver) | ✅ on | Harsh networks / heavy shutdowns; **native MahsaNG v16** import |
| **XDNS** | `x` | ~1× | low | ✅ on | FinalMask-aware clients (Happ, Xray CLI); per-user auth |

All four tunnels run in parallel, sharing port 53 via `dns-router` — queries are
fanned out by subdomain suffix. All four are enabled by default. Toggle any tunnel
independently with `ENABLE_XXX=true/false` or via `moav switch-dns`. For Iran during severe
throttling/blackouts, MasterDNS is the strongest choice and works directly from
the MahsaNG app (see [docs/mahsanet.md](mahsanet.md)).

#### Optional: IPv6 Support

If your server has IPv6, you can also add an AAAA record for the nameserver:

```
Type: AAAA
Name: dns
Value: YOUR_SERVER_IPV6
TTL: 300
```

> **More Info**: For detailed dnstt documentation, see the [official dnstt guide](https://www.bamsoftware.com/software/dnstt/).

### Summary of All DNS Records

| Record | Name | Value | Proxy | Purpose | Required? |
|--------|------|-------|-------|---------|-----------|
| A | `@` | Server IP | DNS only | Main domain (Trojan, Hysteria2, Reality) | Yes |
| A | `dns` | Server IP | DNS only | Nameserver for DNS tunnels | Only for dnstt/Slipstream/MasterDNS/XDNS |
| NS | `t` | `dns.domain.com` | — | dnstt tunnel subdomain | Only for dnstt |
| NS | `s` | `dns.domain.com` | — | Slipstream tunnel subdomain | Only for Slipstream |
| NS | `m` | `dns.domain.com` | — | MasterDNS tunnel subdomain | Only for MasterDNS (MahsaNG v16) |
| NS | `x` | `dns.domain.com` | — | XDNS tunnel subdomain | Only for XDNS |
| A | `cdn` | Server IP | **Proxied** | CDN-fronted VLESS | Only for CDN mode |
| A | `www` | Server IP | **Proxied** | CDN stealth connect address | Optional (CDN stealth) |
| A | `grafana` | Server IP | **Proxied** | Grafana via CDN | Optional (monitoring) |

---

## Provider-Specific Instructions

### Cloudflare

1. Log into Cloudflare Dashboard
2. Select your domain
3. Go to DNS → Records
4. Add records:

**Important:** Set proxy status to "DNS only" (gray cloud) for most records. Only CDN-related records should be "Proxied" (orange cloud).

| Type | Name | Content | Proxy status |
|------|------|---------|--------------|
| A | @ | YOUR_IP | DNS only |
| A | dns | YOUR_IP | DNS only |
| NS | t | dns.yourdomain.com | — |
| NS | s | dns.yourdomain.com | — |
| NS | m | dns.yourdomain.com | — |
| NS | x | dns.yourdomain.com | — |
| A | cdn | YOUR_IP | **Proxied** (orange cloud) |
| A | www | YOUR_IP | **Proxied** (orange cloud) |
| A | grafana | YOUR_IP | **Proxied** (orange cloud) |

> The `cdn`, `www`, and `grafana` records are optional:
> - `cdn` — Required if you want CDN-fronted VLESS (`ENABLE_CDN=true` or CDN_SUBDOMAIN set)
> - `www` — Recommended for CDN stealth. Used as the CDN connect address so DNS queries don't reveal the "cdn" subdomain to DPI. Set `CDN_ADDRESS=www.yourdomain.com` in `.env`
> - `grafana` — Only needed if you want faster Grafana loading via CDN (see [Monitoring Guide](MONITORING.md#cloudflare-cdn-for-faster-grafana-recommended))
>
> All other records **must** be DNS only (gray cloud).

#### CDN settings (required for CDN Mode)

If you added the `cdn` record above, CDN mode needs **two** Cloudflare settings — both are required, neither is optional:

**1. Origin Rule** — rewrites Cloudflare → origin port to 2082, because MoaV's CDN listener doesn't bind 80 or 443.

In Cloudflare Dashboard → **Rules → Origin Rules → Create rule**:

| Field | Value |
|-------|-------|
| Rule name | `CDN to port 2082` |
| When incoming requests match… | **Hostname** equals `cdn.yourdomain.com` |
| Then… | **Destination Port** → Rewrite to `2082` |

Click **Deploy**.

**2. SSL/TLS encryption mode** — set to **Flexible**, because MoaV's CDN inbound on 2082 is plain HTTP (Cloudflare terminates TLS for the client).

In Cloudflare Dashboard → **SSL/TLS → Overview**: choose **Flexible**.

If you need Full / Full (Strict) for *other* subdomains, leave the global setting alone and add a **Configuration Rule** scoped to `cdn.yourdomain.com` only with SSL/TLS mode = Flexible.

**Verify both are working:**
```bash
curl -s -o /dev/null -w "%{http_code}" https://cdn.yourdomain.com/anything
```

| Response | Meaning |
|---|---|
| `400` or `404` | sing-box is responding — CDN is working |
| `521` | Origin Rule is missing — Cloudflare can't reach origin port 2082 |
| `525` | SSL mode is wrong — set Cloudflare SSL/TLS to Flexible |

See [CDN Setup Guide](SETUP.md#cdn-fronted-vlesswebsocket-cloudflare) for end-to-end configuration.

### AWS CloudFront (Alternative CDN)

CloudFront can be used as an alternative to Cloudflare for CDN-fronted VLESS. The main advantage: **no domain required** — CloudFront gives you a `*.cloudfront.net` domain automatically. This is useful when you can't register a domain or want an additional CDN fallback.

**How it works:** Client connects to CloudFront (AWS CDN IPs) → CloudFront forwards to your server on port 2082 → sing-box handles the VLESS+WS connection. DPI only sees connections to AWS infrastructure.

#### Important: CloudFront Requires a Domain Name as Origin

CloudFront **does not accept bare IP addresses** as origins — you'll get `InvalidArgument: The parameter origin name cannot be an IP address`. If you already have a domain, use it. If not, use the free wildcard DNS service **sslip.io**:

```
YOUR_SERVER_IP.sslip.io    →    resolves to YOUR_SERVER_IP
```

For example, `139.59.22.221.sslip.io` resolves to `139.59.22.221`. This works with any IP and requires no registration. `sslip.io` is purely a DNS service — no traffic passes through it. Users never interact with it; only CloudFront uses it internally to reach your server.

#### Step 1: Create CloudFront Distribution

##### Option A: AWS Console (Web UI)

1. Log into [AWS Console](https://console.aws.amazon.com/cloudfront/)
2. Click **Create Distribution**
3. Configure origin:

| Setting | Value |
|---------|-------|
| Origin domain | `YOUR_SERVER_IP.sslip.io` (or your domain) |
| Protocol | **HTTP only** |
| HTTP port | `2082` |
| HTTPS port | `443` |

> **Note:** Type your origin domain (e.g., `139.59.22.221.sslip.io`) directly into the "Origin domain" field. Ignore the dropdown suggestions (S3 buckets, etc.) — CloudFront accepts any valid domain name.

4. Configure behavior:

| Setting | Value |
|---------|-------|
| Viewer protocol policy | **HTTPS only** |
| Allowed HTTP methods | **GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE** |
| Cache policy | **CachingDisabled** |
| Origin request policy | **AllViewer** |

5. Configure WebSocket support:

| Setting | Value |
|---------|-------|
| Response headers policy | None |

> CloudFront supports WebSocket natively — no extra configuration needed.

6. Click **Create Distribution** and wait for deployment (5-15 minutes)
7. Note your distribution domain: `d1234abcd.cloudfront.net`

##### Option B: AWS CLI

Install the CLI first: [AWS CLI Installation Guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)

Then authenticate:

```bash
# Option 1: SSO login (recommended if your org uses AWS IAM Identity Center)
aws sso login

# Option 2: Configure with access keys (from IAM → Users → Security credentials)
aws configure
```

Create the distribution (replace `YOUR_SERVER_IP`):

```bash
aws cloudfront create-distribution --distribution-config '{
  "CallerReference": "moav-cdn-'$(date +%s)'",
  "Comment": "MoaV CDN",
  "Enabled": true,
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "moav-origin",
        "DomainName": "YOUR_SERVER_IP.sslip.io",
        "CustomOriginConfig": {
          "HTTPPort": 2082,
          "HTTPSPort": 443,
          "OriginProtocolPolicy": "http-only"
        }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "moav-origin",
    "ViewerProtocolPolicy": "https-only",
    "AllowedMethods": {
      "Quantity": 7,
      "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
      "CachedMethods": {"Quantity": 2, "Items": ["GET","HEAD"]}
    },
    "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
    "OriginRequestPolicyId": "216adef6-5c7f-47e4-b989-5492eafa07d3",
    "Compress": false
  },
  "PriceClass": "PriceClass_200"
}'
```

##### Fix Existing Distribution (Missing Policies)

If you already created a distribution without the correct policies (common cause of `bad "Sec-WebSocket-Key" header` errors), fix it with:

```bash
# Download current config
aws cloudfront get-distribution-config --id YOUR_DISTRIBUTION_ID > /tmp/cf-config.json

# Add AllViewer origin request policy + CachingDisabled cache policy
jq '.DistributionConfig.DefaultCacheBehavior.OriginRequestPolicyId = "216adef6-5c7f-47e4-b989-5492eafa07d3" | .DistributionConfig.DefaultCacheBehavior.CachePolicyId = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" | .DistributionConfig' /tmp/cf-config.json > /tmp/cf-update.json

# Apply update (ETag is required for optimistic locking)
ETAG=$(jq -r '.ETag' /tmp/cf-config.json)
aws cloudfront update-distribution --id YOUR_DISTRIBUTION_ID --if-match "$ETAG" --distribution-config file:///tmp/cf-update.json
```

Wait 5-10 minutes for deployment. The key policies:
- **`AllViewer`** (`216adef6-...`) — forwards all client headers including WebSocket upgrade headers to your origin
- **`CachingDisabled`** (`4135ea2d-...`) — prevents caching, which breaks WebSocket connections

> **Example:** For server IP `139.59.22.221`, use `"DomainName": "139.59.22.221.sslip.io"`

The `PriceClass` controls which edge locations (regions) are used:

| PriceClass | Regions | Cost |
|-----------|---------|------|
| `PriceClass_100` | US, Canada, Europe | Cheapest |
| `PriceClass_200` | + Asia, Middle East, Africa | Mid-tier |
| `PriceClass_All` | All edge locations worldwide | Most expensive |

> For users in Iran/Middle East, use `PriceClass_200` or `PriceClass_All` for better latency — these include Middle East and Asia edge nodes.

> **Note:** You can't pick a specific datacenter/city. CloudFront is an anycast CDN — it automatically routes users to the nearest edge location within your selected price class.

Get your distribution domain:

```bash
aws cloudfront list-distributions \
  --query 'DistributionList.Items[0].DomainName' --output text
```

Wait for deployment to complete (status changes from `InProgress` to `Deployed`):

```bash
aws cloudfront list-distributions \
  --query 'DistributionList.Items[*].[Id,DomainName,Status]' --output table
```

#### Step 2: Configure MoaV

In your `.env` file:

```bash
# Use CloudFront instead of Cloudflare for CDN
CDN_SUBDOMAIN=           # Leave empty (not using Cloudflare subdomain)
CDN_DOMAIN=d1234abcd.cloudfront.net
CDN_ADDRESS=d1234abcd.cloudfront.net
CDN_SNI=d1234abcd.cloudfront.net
CDN_TRANSPORT=ws         # IMPORTANT: must be 'ws' for CloudFront (not 'httpupgrade')
```

> **Important:** CloudFront requires `CDN_TRANSPORT=ws` (standard WebSocket). The default `httpupgrade` is a sing-box-specific protocol that works with Cloudflare but fails on CloudFront with `bad "Sec-WebSocket-Key" header` errors. If you switch from Cloudflare to CloudFront, change this setting and re-bootstrap.

Then re-bootstrap to regenerate configs:
```bash
moav bootstrap
```

#### Step 3: Verify

```bash
# Should return 400 (sing-box responding)
curl -s -o /dev/null -w "%{http_code}" https://d1234abcd.cloudfront.net/test
```

#### CloudFront vs Cloudflare

| Feature | Cloudflare | CloudFront |
|---------|-----------|------------|
| Cost | Free tier | ~$0.085/GB (1TB free/month for 12 months) |
| Domain required | Yes | **No** (get `*.cloudfront.net`) |
| Setup complexity | DNS + Origin Rule | AWS Console distribution |
| WebSocket support | Yes | Yes |
| Origin port config | Needs Origin Rule to rewrite to 2082 | Direct port configuration |
| SNI flexibility | Can use root domain for stealth | Must use `*.cloudfront.net` or your CNAME |
| Domain fronting | Partially supported | **Blocked since 2018** |
| Global edge network | Yes (larger) | Yes |

> **SNI note:** CloudFront validates that the TLS SNI matches your distribution domain or a configured CNAME. You cannot use an arbitrary domain (like `google.com`) as SNI — AWS blocked domain fronting in 2018. For Reality-based protocols (XHTTP, VLESS+Reality), SNI camouflage works differently and does not rely on the CDN.

#### Using Both Cloudflare and CloudFront

You can run both CDN providers simultaneously for redundancy. Users get two CDN share links — if one CDN's IPs get blocked, the other likely still works:

1. Set up Cloudflare CDN as described above (requires domain)
2. Set up CloudFront as a second distribution pointing to the same server
3. Share both links with users

To generate links for both, you'd need to run bootstrap with Cloudflare settings first, then manually create CloudFront share links using the same UUID and WS path.

#### CloudFront CLI Management

```bash
# List all distributions
aws cloudfront list-distributions \
  --query 'DistributionList.Items[*].[Id,DomainName,Status]' --output table

# Check which edge location a user is hitting
curl -sI https://d1234abcd.cloudfront.net/ | grep x-amz-cf-pop
# Example output: x-amz-cf-pop: FRA56-P4 (Frankfurt)

# Disable a distribution (must disable before deleting)
# First get the ETag:
ETAG=$(aws cloudfront get-distribution-config --id DIST_ID \
  --query 'ETag' --output text)
# Then disable:
aws cloudfront get-distribution-config --id DIST_ID \
  --query 'DistributionConfig' --output json \
  | jq '.Enabled = false' \
  | aws cloudfront update-distribution --id DIST_ID \
    --if-match "$ETAG" --distribution-config file:///dev/stdin

# Delete (only after status is "Deployed" and distribution is disabled)
aws cloudfront delete-distribution --id DIST_ID --if-match "$ETAG"
```

### Namecheap

1. Log into Namecheap
2. Domain List → Manage → Advanced DNS
3. Add records:

| Type | Host | Value | TTL |
|------|------|-------|-----|
| A Record | @ | YOUR_IP | Automatic |
| A Record | dns | YOUR_IP | Automatic |
| NS Record | t | dns.yourdomain.com. | Automatic |
| NS Record | s | dns.yourdomain.com. | Automatic |

Note: NS value may need trailing dot. The `dns`, `t`, and `s` records are only needed if using DNS tunnels.

### Google Domains / Squarespace

1. Go to DNS settings
2. Add custom records:

| Host name | Type | TTL | Data |
|-----------|------|-----|------|
| (blank) | A | 300 | YOUR_IP |
| dns | A | 300 | YOUR_IP |
| t | NS | 300 | dns.yourdomain.com |
| s | NS | 300 | dns.yourdomain.com |

### Hetzner DNS

1. Go to DNS Console
2. Select your zone
3. Add records:

```
@ IN A YOUR_IP
dns IN A YOUR_IP
t IN NS dns.yourdomain.com.
s IN NS dns.yourdomain.com.
```

---

## Home Servers & Raspberry Pi

MoaV runs on Raspberry Pi 4+ (2GB+ RAM) and any ARM64/x64 Linux machine. Home servers typically have dynamic IPs and sit behind a router, so you need port forwarding and (if using a domain) Dynamic DNS.

### Port Forwarding

Configure your router to forward the ports you need to your MoaV server's local IP.

**Domainless mode** (minimum):

| Port | Protocol | Service |
|------|----------|---------|
| 443/tcp | TCP | Reality (VLESS) |
| 51820/udp | UDP | WireGuard |
| 8080/tcp | TCP | wstunnel (WireGuard over WebSocket) |
| 51821/udp | UDP | AmneziaWG |
| 993/tcp | TCP | Telegram MTProxy |
| 9443/tcp | TCP | Admin Dashboard |

**With domain** (add these):

| Port | Protocol | Service |
|------|----------|---------|
| 80/tcp | TCP | Let's Encrypt verification (only during certificate setup/renewal) |
| 443/udp | UDP | Hysteria2 |
| 8443/tcp | TCP | Trojan |
| 4443/tcp | TCP | TrustTunnel (HTTP/2) |
| 4443/udp | UDP | TrustTunnel (HTTP/3 / QUIC) |
| 53/udp | UDP | DNS tunnels (dnstt / Slipstream / MasterDNS / XDNS — all via dns-router) |

**Optional**:

| Port | Protocol | Service |
|------|----------|---------|
| 9444/tcp | TCP | Grafana monitoring dashboard |

> Only forward ports for protocols you actually enable. Check your `.env` file for `ENABLE_*` toggles.

### Before You Start

1. **Check for CGNAT**: Some ISPs use Carrier-Grade NAT which prevents incoming connections entirely. Test by comparing your router's WAN IP with `curl ipinfo.io/ip`. If they differ, contact your ISP for a public IP or use a VPS instead.

2. **Static local IP**: Assign a static IP to your MoaV server in your router's DHCP settings so port forwarding rules don't break when the local IP changes.

### Dynamic DNS (DDNS)

If you're using a domain with a home server, your ISP likely assigns a dynamic public IP that changes periodically. Dynamic DNS services automatically update your domain to point to your current IP.

> **Domainless mode does not need DDNS.** Users connect via your public IP directly. You can find your current public IP with `curl ifconfig.me` and share it manually. If your IP changes, update the configs you shared.

### DuckDNS (Free)

DuckDNS is a free DDNS service that provides subdomains like `yourname.duckdns.org`. Let's Encrypt works with DuckDNS domains.

#### Step 1: Create Account

1. Go to [duckdns.org](https://www.duckdns.org/)
2. Sign in with Google, GitHub, Twitter, or Reddit
3. Create a subdomain (e.g., `myvpn` → `myvpn.duckdns.org`)
4. Copy your **token** from the dashboard

#### Step 2: Install Update Script

On your MoaV server (Raspberry Pi or home server):

```bash
# Create update script
mkdir -p /opt/duckdns
cat > /opt/duckdns/duck.sh << 'EOF'
#!/bin/bash
DOMAIN="YOUR_SUBDOMAIN"  # e.g., myvpn (without .duckdns.org)
TOKEN="YOUR_TOKEN"

curl -s "https://www.duckdns.org/update?domains=${DOMAIN}&token=${TOKEN}&ip=" | logger -t duckdns
EOF

# Replace with your values
nano /opt/duckdns/duck.sh

# Make executable
chmod +x /opt/duckdns/duck.sh

# Test it
/opt/duckdns/duck.sh
```

#### Step 3: Schedule Automatic Updates

```bash
# Add to crontab (runs every 5 minutes)
(crontab -l 2>/dev/null; echo "*/5 * * * * /opt/duckdns/duck.sh") | crontab -
```

#### Step 4: Configure MoaV

In your `.env` file:
```bash
DOMAIN=yourname.duckdns.org
```

Then run bootstrap as normal.

> **Note:** DuckDNS subdomains don't support NS delegation, so DNS tunnels (dnstt, Slipstream, XDNS) won't work with DuckDNS. All other domain-based protocols work fine.

### Cloudflare DDNS (Own Domain)

If you have your own domain on Cloudflare, you can use the Cloudflare API to update DNS records automatically. This supports all features including DNS tunnels.

#### Step 1: Get API Token

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com/) → My Profile → API Tokens
2. Create a token with **Zone:DNS:Edit** permission for your domain
3. Copy the token

#### Step 2: Get Zone ID

1. Go to your domain in Cloudflare
2. Scroll down on the Overview page
3. Copy the **Zone ID** from the right sidebar

#### Step 3: Install Update Script

```bash
mkdir -p /opt/cloudflare-ddns
cat > /opt/cloudflare-ddns/update.sh << 'EOF'
#!/bin/bash

# Configuration
CF_API_TOKEN="YOUR_API_TOKEN"
CF_ZONE_ID="YOUR_ZONE_ID"
DOMAIN="yourdomain.com"
RECORD_NAME="@"  # Use "@" for root domain or "subdomain" for subdomain

# Get current public IP
CURRENT_IP=$(curl -s https://api.ipify.org)

# Get current DNS record
RECORD_DATA=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${DOMAIN}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")

RECORD_ID=$(echo "$RECORD_DATA" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
RECORD_IP=$(echo "$RECORD_DATA" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4)

# Update if IP changed
if [ "$CURRENT_IP" != "$RECORD_IP" ]; then
    echo "IP changed from $RECORD_IP to $CURRENT_IP, updating..."
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${RECORD_ID}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${DOMAIN}\",\"content\":\"${CURRENT_IP}\",\"ttl\":300,\"proxied\":false}" | logger -t cloudflare-ddns
else
    echo "IP unchanged ($CURRENT_IP)"
fi
EOF

# Edit with your values
nano /opt/cloudflare-ddns/update.sh

chmod +x /opt/cloudflare-ddns/update.sh
```

#### Step 4: Schedule Updates

```bash
# Run every 5 minutes
(crontab -l 2>/dev/null; echo "*/5 * * * * /opt/cloudflare-ddns/update.sh") | crontab -
```

#### Step 5: Configure MoaV

In your `.env`:
```bash
DOMAIN=yourdomain.com
```

### After DDNS Setup

1. **Wait for propagation**: After the first update, wait 5-10 minutes
2. **Verify**: `dig +short yourdomain.com` should show your home IP
3. **Run MoaV setup**: `moav` to start the interactive setup
4. **Test from outside**: Use mobile data (not home WiFi) to test connectivity

### Home Server Tips

- **UPS recommended**: Protect against power outages, especially for Raspberry Pi
- **Monitor uptime**: Use a free service like [UptimeRobot](https://uptimerobot.com/) to alert you if your server goes down
- **Backup regularly**: `moav export` to backup your configuration
- **Temperature**: Ensure adequate cooling for Raspberry Pi under sustained VPN load
- **SD card**: Use a high-endurance microSD card or boot from USB/SSD for reliability

---

## Verification

After configuring DNS, wait for propagation (usually 5-30 minutes, up to 48 hours).

### Verify with MoaV

```bash
moav doctor dns
```

### Verify A Record

```bash
dig +short yourdomain.com
# Should return: YOUR_SERVER_IP

dig +short dns.yourdomain.com
# Should return: YOUR_SERVER_IP
```

### Verify NS Delegation

```bash
dig NS t.yourdomain.com
# Should show: dns.yourdomain.com in AUTHORITY SECTION

# Test that queries reach your server
dig @YOUR_SERVER_IP test.t.yourdomain.com
# Should get a response (after dnstt is running)
```

### Online Tools

- https://dnschecker.org - Check propagation worldwide
- https://mxtoolbox.com/DNSLookup.aspx - Detailed DNS lookup

## Common Issues

### "DNS not propagated yet"

Wait longer (up to 48 hours in rare cases). Check with multiple DNS servers:

```bash
dig @8.8.8.8 yourdomain.com
dig @1.1.1.1 yourdomain.com
```

### "NS record not working"

- Ensure the A record for `dns.yourdomain.com` exists
- Some registrars require a trailing dot: `dns.yourdomain.com.`
- NS delegation can take longer to propagate

### "Certificate acquisition failed"

- Verify A record is correct: `dig yourdomain.com`
- Ensure port 80 is open (temporarily, for ACME HTTP-01)
- Check that no other service is using port 80
- Not applicable in domainless mode (no certificates needed)

### "Can't connect from outside my home network"

- Verify port forwarding is configured on your router
- Check for CGNAT: `curl ifconfig.me` should match your router's WAN IP
- Ensure your ISP doesn't block the ports you need
- Test from mobile data, not your home WiFi

---

## Domain Acquisition Tips

For users in censored regions:

1. **Use privacy protection** - Hide your personal info in WHOIS
2. **Pay with crypto** if possible - For anonymity
3. **Choose a neutral TLD** - `.com`, `.net`, `.org` are less suspicious than country-specific TLDs
4. **Avoid "VPN" or "proxy" in the domain name** - Keep it generic
5. **Consider multiple domains** - Have backups ready if one gets blocked

### Domain Naming Strategy

Your domain name is the first thing DPI systems see in the TLS SNI. A good domain blends with legitimate traffic:

**Good examples:**
- Names that look like business infrastructure: `cloudops-services.com`, `cdn-platform.net`
- Names that look like SaaS products: `dataflow-sync.com`, `metrics-hub.net`
- Generic tech names: `stackbuilder.io`, `nodebridge.net`

**Bad examples:**
- Anything with "vpn", "proxy", "tunnel", "free", "bypass" in the name
- Random strings: `xk4m2p.com` (suspicious to automated systems)
- Known circumvention patterns: `v2ray-server.com`

**Subdomain naming** also matters. MoaV's CDN subdomain defaults to `cdn` — consider changing it to something like `assets`, `static`, `api`, or `app` in your `.env`:
```bash
CDN_SUBDOMAIN=assets
```

### Recommended Registrars

- Namecheap - Good privacy, accepts crypto
- Porkbun - Cheap, good privacy
- Njalla - Maximum privacy (they own the domain for you)

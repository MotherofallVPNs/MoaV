#!/usr/bin/env python3
"""
MoaV Admin Dashboard
Simple stats viewer for the circumvention stack
"""

import os
import json
import asyncio
import zipfile
import io
import re
import subprocess
import time
from datetime import datetime
from pathlib import Path

import httpx
from fastapi import FastAPI, Request, HTTPException, Depends
from fastapi.responses import HTMLResponse, StreamingResponse, FileResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.templating import Jinja2Templates
import secrets

app = FastAPI(title="MoaV Admin", docs_url=None, redoc_url=None)
security = HTTPBasic()
templates = Jinja2Templates(directory="templates")

# Configuration
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "admin")
ADMIN_IP_WHITELIST = os.environ.get("ADMIN_IP_WHITELIST", "").split(",")
ADMIN_IP_WHITELIST = [ip.strip() for ip in ADMIN_IP_WHITELIST if ip.strip()]

SERVER_IP = os.environ.get("SERVER_IP", "")
DOMAIN = os.environ.get("DOMAIN", "")


def get_system_uptime() -> int:
    """Get system uptime in seconds from /proc/uptime."""
    try:
        with open("/proc/uptime") as f:
            return int(float(f.read().split()[0]))
    except Exception:
        return 0

SINGBOX_API = "http://moav-sing-box:9090"
CLASH_SECRET = ""

# Try to load Clash API secret
try:
    with open("/state/keys/clash-api.env") as f:
        for line in f:
            if line.startswith("CLASH_API_SECRET="):
                CLASH_SECRET = line.split("=", 1)[1].strip()
except FileNotFoundError:
    pass

# Current version
CURRENT_VERSION = "unknown"
for _vpath in ["/project/VERSION", "/app/VERSION"]:
    try:
        with open(_vpath) as f:
            CURRENT_VERSION = f.read().strip()
            break
    except FileNotFoundError:
        continue

# Update check cache
UPDATE_CACHE = {"version": None, "checked_at": 0}
UPDATE_CACHE_TTL = 3600  # 1 hour


def version_gt(v1: str, v2: str) -> bool:
    """Check if v1 > v2 (semver comparison)"""
    try:
        v1_parts = [int(x) for x in v1.split(".")[:3]]
        v2_parts = [int(x) for x in v2.split(".")[:3]]
        return v1_parts > v2_parts
    except (ValueError, AttributeError):
        return False


async def check_for_updates() -> dict:
    """Check GitHub for latest release (cached for 1 hour)"""
    now = time.time()

    # Return cached result if still valid
    if UPDATE_CACHE["version"] and (now - UPDATE_CACHE["checked_at"]) < UPDATE_CACHE_TTL:
        latest = UPDATE_CACHE["version"]
        return {
            "update_available": version_gt(latest, CURRENT_VERSION),
            "latest_version": latest,
            "current_version": CURRENT_VERSION,
        }

    # Fetch from GitHub API
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(
                "https://api.github.com/repos/shayanb/MoaV/releases/latest"
            )
            if resp.status_code == 200:
                data = resp.json()
                latest = data.get("tag_name", "").lstrip("v")
                if latest:
                    UPDATE_CACHE["version"] = latest
                    UPDATE_CACHE["checked_at"] = now
                    return {
                        "update_available": version_gt(latest, CURRENT_VERSION),
                        "latest_version": latest,
                        "current_version": CURRENT_VERSION,
                    }
    except Exception:
        pass

    return {
        "update_available": False,
        "latest_version": None,
        "current_version": CURRENT_VERSION,
    }


def verify_auth(request: Request, credentials: HTTPBasicCredentials = Depends(security)):
    """Verify authentication via password and optional IP whitelist"""
    client_ip = request.client.host

    # Check IP whitelist if configured
    if ADMIN_IP_WHITELIST:
        ip_allowed = any(
            client_ip.startswith(allowed.rstrip("0123456789").rstrip("."))
            if "/" in allowed else client_ip == allowed
            for allowed in ADMIN_IP_WHITELIST
        )
        if not ip_allowed:
            raise HTTPException(status_code=403, detail="IP not allowed")

    # Check password
    correct_password = secrets.compare_digest(credentials.password, ADMIN_PASSWORD)
    if not correct_password:
        raise HTTPException(
            status_code=401,
            detail="Invalid credentials",
            headers={"WWW-Authenticate": "Basic"},
        )
    return credentials.username


# Dashboard service name → docker container name. One source of truth.
# Keep in sync with all_services in get_services_status() and with
# `container_name:` fields in docker-compose.yml.
SERVICE_CONTAINERS = {
    "sing-box":    "moav-sing-box",
    "decoy":       "moav-decoy",
    "xray":        "moav-xray",
    "wireguard":   "moav-wireguard",
    "wstunnel":    "moav-wstunnel",
    "amneziawg":   "moav-amneziawg",
    "trusttunnel": "moav-trusttunnel",
    "telemt":      "moav-telemt",
    "dnstt":       "moav-dnstt",
    "slipstream":  "moav-slipstream",
    "masterdns":   "moav-masterdns",
    "dns-router":  "moav-dns-router",
    "conduit":     "moav-conduit",
    "snowflake":   "moav-snowflake",
    "gooserelay":  "moav-gooserelay",
    "grafana":     "moav-grafana",
}


def _fetch_running_containers():
    """Query docker-socket-proxy for the set of currently-running container
    names. Returns a set on success, or None on any error so callers can
    surface "unknown" instead of mis-reporting everything as stopped.

    /containers/json returns only running containers by default (no `all=1`).
    The admin container has DOCKER_HOST=tcp://docker-proxy:2375 set in
    docker-compose.yml, and docker-proxy has CONTAINERS=1 capability.
    """
    base = os.environ.get("DOCKER_HOST", "tcp://docker-proxy:2375").replace("tcp://", "http://")
    try:
        resp = httpx.get(f"{base}/containers/json", timeout=1.5)
        if resp.status_code != 200:
            return None
        names = set()
        for c in resp.json():
            # /containers/json returns names with a leading slash, e.g. "/moav-xray".
            for n in c.get("Names", []):
                names.add(n.lstrip("/"))
        return names
    except Exception:
        return None


def check_service_status(name: str, _running=None) -> str:
    """Check whether a service's container is running.

    Uniform docker-socket-proxy lookup. One round-trip lists every running
    container; we cross-reference against SERVICE_CONTAINERS. Works for both
    bridge-networked (moav_net) and host-networked (snowflake) services
    without per-service special cases.

    `_running` lets get_services_status() pass a pre-fetched set so the dashboard
    only makes one docker-proxy call per refresh, not one per service card.
    """
    running = _running if _running is not None else _fetch_running_containers()
    if running is None:
        return "unknown"
    container = SERVICE_CONTAINERS.get(name)
    if container is None:
        return "unknown"
    return "running" if container in running else "stopped"


async def fetch_singbox_stats():
    """Fetch stats from sing-box Clash API"""
    stats = {
        "connections": [],
        "traffic": {"upload": 0, "download": 0},
        "memory": 0,
        "error": None
    }

    headers = {}
    if CLASH_SECRET:
        headers["Authorization"] = f"Bearer {CLASH_SECRET}"

    # Use explicit timeout config to prevent hanging
    timeout = httpx.Timeout(connect=2.0, read=3.0, write=2.0, pool=2.0)

    try:
        # Wrap entire operation in asyncio timeout as backup
        async with asyncio.timeout(10.0):
            async with httpx.AsyncClient(timeout=timeout) as client:
                try:
                    # Get connections (includes upload/download per connection)
                    resp = await client.get(f"{SINGBOX_API}/connections", headers=headers)
                    if resp.status_code == 200:
                        data = resp.json()
                        stats["connections"] = data.get("connections", []) or []
                        stats["traffic"]["upload"] = data.get("uploadTotal", 0)
                        stats["traffic"]["download"] = data.get("downloadTotal", 0)

                    # Get memory - this is a streaming endpoint, read first line only
                    async with client.stream("GET", f"{SINGBOX_API}/memory", headers=headers) as resp:
                        if resp.status_code == 200:
                            async for line in resp.aiter_lines():
                                if line.strip():
                                    try:
                                        data = json.loads(line)
                                        stats["memory"] = data.get("inuse", 0)
                                    except json.JSONDecodeError:
                                        pass
                                    break  # Only need first line

                except httpx.ConnectError:
                    stats["error"] = "sing-box API not reachable"
                except httpx.ConnectTimeout:
                    stats["error"] = "sing-box connection timeout"
                except httpx.ReadTimeout:
                    stats["error"] = "sing-box read timeout"
                except httpx.TimeoutException:
                    stats["error"] = "sing-box API timeout"

    except asyncio.TimeoutError:
        stats["error"] = "sing-box API timeout (10s)"
    except Exception as e:
        stats["error"] = f"Error: {type(e).__name__}: {str(e)}"

    return stats


def _parse_prometheus_metric(lines: list[str], metric_name: str) -> float:
    """Extract a simple gauge/counter value from Prometheus text format."""
    for line in lines:
        if line.startswith(metric_name + " ") or line.startswith(metric_name + "{"):
            # Simple metric without labels: "metric_name value"
            if line.startswith(metric_name + " "):
                try:
                    return float(line.split()[-1])
                except (ValueError, IndexError):
                    pass
    return 0


def _parse_prometheus_labeled(lines: list[str], metric_name: str) -> list[dict]:
    """Extract labeled metrics (e.g. per-region) from Prometheus text format."""
    results = []
    for line in lines:
        if line.startswith(metric_name + "{"):
            try:
                # Parse: metric_name{label="value",...} number
                labels_str = line[line.index("{") + 1:line.index("}")]
                value = float(line.split()[-1])
                labels = {}
                for part in labels_str.split(","):
                    k, v = part.split("=", 1)
                    labels[k.strip()] = v.strip().strip('"')
                results.append({"labels": labels, "value": value})
            except (ValueError, IndexError):
                pass
    return results


async def fetch_conduit_stats():
    """Fetch stats from Psiphon Conduit v2 native metrics endpoint"""
    stats = {
        "running": False,
        "connections": {"connecting": 0, "connected": 0},
        "bandwidth": {"upload": "0 B", "download": "0 B"},
        "regions": [],
        "error": None
    }

    # Check if conduit is running
    if check_service_status("conduit") != "running":
        stats["error"] = "Conduit not running"
        return stats

    stats["running"] = True

    # Query native Prometheus metrics endpoint
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get("http://psiphon-conduit:9090/metrics")
            resp.raise_for_status()
            lines = resp.text.strip().split("\n")

        stats["connections"]["connecting"] = int(_parse_prometheus_metric(lines, "conduit_connecting_clients"))
        stats["connections"]["connected"] = int(_parse_prometheus_metric(lines, "conduit_connected_clients"))

        upload_bytes = _parse_prometheus_metric(lines, "conduit_bytes_uploaded")
        download_bytes = _parse_prometheus_metric(lines, "conduit_bytes_downloaded")
        stats["bandwidth"]["upload"] = format_bytes(upload_bytes)
        stats["bandwidth"]["download"] = format_bytes(download_bytes)

        # Per-region connected clients
        region_clients = _parse_prometheus_labeled(lines, "conduit_region_connected_clients")
        region_download = {r["labels"].get("region", ""): r["value"]
                          for r in _parse_prometheus_labeled(lines, "conduit_region_bytes_downloaded")}
        region_upload = {r["labels"].get("region", ""): r["value"]
                        for r in _parse_prometheus_labeled(lines, "conduit_region_bytes_uploaded")}

        for r in region_clients:
            region = r["labels"].get("region", "Unknown")
            stats["regions"].append({
                "region": region,
                "connected": int(r["value"]),
                "download": format_bytes(region_download.get(region, 0)),
                "upload": format_bytes(region_upload.get(region, 0)),
            })
        stats["regions"].sort(key=lambda x: x["connected"], reverse=True)

    except Exception as e:
        stats["error"] = f"Failed to fetch metrics: {e}"

    return stats


PROMETHEUS_URL = "http://prometheus:9091"


async def fetch_aggregate_stats():
    """Fetch aggregated stats across all protocols from Prometheus."""
    stats = {
        "active_users": 0,
        "total_users": 0,
        "total_connections": 0,
        "protocols": {},  # protocol_name -> {active_users, connections}
    }

    queries = {
        # Active users per protocol
        "singbox_active": "singbox_active_users",
        "xray_active": "xray_active_users",
        "wg_active": 'count(wireguard_peer_active == 1)',
        "awg_active": 'count(amneziawg_peer_active == 1)',
        # Total users per protocol
        "singbox_total": "singbox_total_users",
        "xray_total": "xray_total_users",
        "wg_total": "wireguard_peers_total",
        "awg_total": "amneziawg_peers_total",
        # Connections
        "singbox_conns": "singbox_total_connections",
        "xray_conns": "xray_total_connections",
        # Traffic
        "xray_up": "xray_upload_bytes_total",
        "xray_down": "xray_download_bytes_total",
    }

    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            for key, query in queries.items():
                try:
                    resp = await client.get(
                        f"{PROMETHEUS_URL}/api/v1/query",
                        params={"query": query}
                    )
                    if resp.status_code == 200:
                        data = resp.json()
                        results = data.get("data", {}).get("result", [])
                        if results:
                            queries[key] = float(results[0].get("value", [0, 0])[1])
                        else:
                            queries[key] = 0
                    else:
                        queries[key] = 0
                except Exception:
                    queries[key] = 0

        stats["protocols"]["sing-box"] = {
            "active": int(queries.get("singbox_active", 0) if isinstance(queries.get("singbox_active"), (int, float)) else 0),
            "total": int(queries.get("singbox_total", 0) if isinstance(queries.get("singbox_total"), (int, float)) else 0),
            "connections": int(queries.get("singbox_conns", 0) if isinstance(queries.get("singbox_conns"), (int, float)) else 0),
        }
        stats["protocols"]["xray"] = {
            "active": int(queries.get("xray_active", 0) if isinstance(queries.get("xray_active"), (int, float)) else 0),
            "total": int(queries.get("xray_total", 0) if isinstance(queries.get("xray_total"), (int, float)) else 0),
            "connections": int(queries.get("xray_conns", 0) if isinstance(queries.get("xray_conns"), (int, float)) else 0),
            "upload": queries.get("xray_up", 0) if isinstance(queries.get("xray_up"), (int, float)) else 0,
            "download": queries.get("xray_down", 0) if isinstance(queries.get("xray_down"), (int, float)) else 0,
        }
        stats["protocols"]["wireguard"] = {
            "active": int(queries.get("wg_active", 0) if isinstance(queries.get("wg_active"), (int, float)) else 0),
            "total": int(queries.get("wg_total", 0) if isinstance(queries.get("wg_total"), (int, float)) else 0),
        }
        stats["protocols"]["amneziawg"] = {
            "active": int(queries.get("awg_active", 0) if isinstance(queries.get("awg_active"), (int, float)) else 0),
            "total": int(queries.get("awg_total", 0) if isinstance(queries.get("awg_total"), (int, float)) else 0),
        }

        for p in stats["protocols"].values():
            stats["active_users"] += p.get("active", 0)
            stats["total_users"] += p.get("total", 0)
            stats["total_connections"] += p.get("connections", 0)

    except Exception as e:
        print(f"[admin] Prometheus query failed: {e}")

    return stats


def format_bytes(bytes_val):
    """Format bytes to human readable"""
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if bytes_val < 1024:
            return f"{bytes_val:.2f} {unit}"
        bytes_val /= 1024
    return f"{bytes_val:.2f} PB"


def get_services_status():
    """Get status of all services with live checks"""
    all_services = [
        {"name": "sing-box",    "ports": "443, 8443",    "profile": "proxy"},
        {"name": "decoy",       "ports": "80",            "profile": "proxy"},
        {"name": "xray",        "ports": "2096, 53/udp",  "profile": "xhttp"},
        {"name": "wireguard",   "ports": "51820/udp",     "profile": "wireguard"},
        {"name": "wstunnel",    "ports": "8080",          "profile": "wireguard"},
        {"name": "amneziawg",   "ports": "51821/udp",     "profile": "amneziawg"},
        {"name": "trusttunnel", "ports": "4443",          "profile": "trusttunnel"},
        {"name": "telemt",      "ports": "993",           "profile": "telegram"},
        {"name": "dns-router",  "ports": "53/udp",        "profile": "dnstunnel"},
        {"name": "dnstt",       "ports": "via :53",       "profile": "dnstunnel"},
        {"name": "slipstream",  "ports": "via :53",       "profile": "dnstunnel"},
        {"name": "masterdns",   "ports": "via :53",       "profile": "dnstunnel"},
        {"name": "conduit",     "ports": "dynamic",       "profile": "conduit"},
        {"name": "snowflake",   "ports": "dynamic",       "profile": "snowflake"},
        {"name": "gooserelay",  "ports": "8444",          "profile": "gooserelay"},
        {"name": "grafana",     "ports": "9444",          "profile": "monitoring"},
    ]
    # One docker-proxy call lists every running container; cross-reference each
    # card against that set instead of N per-service checks.
    running = _fetch_running_containers()
    for svc in all_services:
        svc["status"] = check_service_status(svc["name"], _running=running)
    return all_services


@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request, username: str = Depends(verify_auth)):
    """Main dashboard page"""
    stats = await fetch_singbox_stats()
    conduit_stats = await fetch_conduit_stats()
    agg_stats = await fetch_aggregate_stats()
    services = get_services_status()
    update_info = await check_for_updates()

    # Get all users with their bundle info (no active status tracking)
    all_users = list_users()

    # Show all services (running and stopped)
    active_services = services

    # Detect domainless mode (no Let's Encrypt certs = domainless)
    import glob
    has_letsencrypt = any(
        Path(f"{d}fullchain.pem").exists()
        for d in (glob.glob("/tmp/certs/live/*/") or glob.glob("/certs/live/*/"))
    )

    return templates.TemplateResponse("dashboard.html", {
        "request": request,
        "stats": stats,
        "conduit_stats": conduit_stats,
        "services": active_services,
        "all_users": all_users,
        "format_bytes": format_bytes,
        "active_connections": len(stats.get("connections", [])),
        "total_upload": format_bytes(stats["traffic"]["upload"]),
        "total_download": format_bytes(stats["traffic"]["download"]),
        "memory_usage": format_bytes(stats.get("memory", 0)),
        "domainless": not has_letsencrypt,
        "error": stats.get("error"),
        "timestamp": datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC"),
        "update_available": update_info["update_available"],
        "latest_version": update_info["latest_version"],
        "current_version": update_info["current_version"],
        "agg_stats": agg_stats,
        "mahsanet_configured": bool(MAHSANET_API_KEY),
        "mahsanet_protocols": MAHSANET_PROTOCOLS,
        "mahsanet_all_protocols": list(PROTOCOL_FILE_MAP.keys()),
        "server_ip": SERVER_IP,
        "domain": DOMAIN,
        "uptime_seconds": get_system_uptime(),
    })


@app.get("/api/stats")
async def api_stats(username: str = Depends(verify_auth)):
    """JSON API for stats"""
    stats = await fetch_singbox_stats()
    conduit_stats = await fetch_conduit_stats()
    services = get_services_status()
    return {
        "singbox": stats,
        "conduit": conduit_stats,
        "services": services
    }


@app.get("/api/health")
async def health():
    """Health check endpoint (no auth required)"""
    return {"status": "ok", "timestamp": datetime.utcnow().isoformat()}


@app.get("/favicon.ico", include_in_schema=False)
async def favicon():
    """Serve favicon"""
    for p in ["/project/site/assets/favicon.ico", "/app/site/assets/favicon.ico"]:
        if Path(p).exists():
            return FileResponse(p, media_type="image/x-icon")
    raise HTTPException(status_code=404)


@app.get("/logo.png", include_in_schema=False)
async def logo():
    """Serve logo"""
    for p in ["/project/site/assets/favicon.png", "/app/site/assets/favicon.png"]:
        if Path(p).exists():
            return FileResponse(p, media_type="image/png")
    raise HTTPException(status_code=404)


# -------------------------------------------------------------------------
# User Management API
# -------------------------------------------------------------------------
PROJECT_DIR = Path("/project")
USER_ADD_SCRIPT = PROJECT_DIR / "scripts" / "user-add.sh"


@app.post("/api/users")
async def create_user(request: Request, _: str = Depends(verify_auth)):
    """Create user(s) by calling user-add.sh."""
    body = await request.json()
    name = body.get("username", "").strip()
    batch = int(body.get("batch", 0))

    # Validate inputs
    if not name:
        raise HTTPException(status_code=400, detail="Username is required")
    if not re.match(r'^[a-zA-Z0-9_-]+$', name):
        raise HTTPException(status_code=400, detail="Invalid username. Use only letters, numbers, underscores, and hyphens.")
    if batch > 50:
        raise HTTPException(status_code=400, detail="Batch count cannot exceed 50")

    # Check script exists
    if not USER_ADD_SCRIPT.exists():
        raise HTTPException(status_code=500, detail="user-add.sh not found. Is /project mounted?")

    # Build command
    cmd = ["bash", str(USER_ADD_SCRIPT)]
    if batch > 0:
        # Batch mode: username becomes prefix → alice_01, alice_02, ...
        cmd += ["--batch", str(batch), "--prefix", name]
    else:
        # Single user mode
        bundle_path = get_bundle_path()
        if (bundle_path / name).exists():
            raise HTTPException(status_code=409, detail=f"User '{name}' already exists")
        cmd.append(name)

    # Run the script (batch creates take longer — ~30s per user)
    script_timeout = max(120, batch * 60) if batch > 0 else 120
    try:
        result = subprocess.run(
            cmd,
            cwd=str(PROJECT_DIR),
            capture_output=True,
            text=True,
            timeout=script_timeout,
        )
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail=f"User creation timed out ({script_timeout}s)")

    return {
        "success": result.returncode == 0,
        "output": result.stdout,
        "errors": result.stderr if result.returncode != 0 else "",
        "username": name if batch <= 0 else f"{name} (batch {batch})",
    }


# User bundle paths - check multiple possible locations
BUNDLE_PATHS = [
    Path("/project/outputs/bundles"),
    Path("/outputs/bundles"),
    Path("/app/outputs/bundles"),
]


def get_bundle_path():
    """Find the bundles directory"""
    for path in BUNDLE_PATHS:
        if path.exists():
            return path
    return BUNDLE_PATHS[0]  # Default


def _get_donated_users() -> set:
    """Get set of usernames that have been donated to MahsaNet."""
    donated = set()
    for donations_path in [Path("/project/outputs/mahsanet-donations.json"), Path("outputs/mahsanet-donations.json")]:
        if donations_path.exists():
            try:
                data = json.loads(donations_path.read_text())
                for c in data.get("configs", []):
                    if c.get("user"):
                        donated.add(c["user"])
            except Exception:
                pass
            break
    return donated


def list_users():
    """List all users from bundles directory"""
    users = []
    bundle_path = get_bundle_path()

    if not bundle_path.exists():
        return users

    donated_users = _get_donated_users()

    for user_dir in bundle_path.iterdir():
        # Skip non-directories and zip files
        if not user_dir.is_dir():
            continue
        # Skip special directories
        if user_dir.name.startswith('.') or user_dir.name.endswith('-configs'):
            continue

        username = user_dir.name

        # Check what files exist in the bundle
        has_reality = (user_dir / "reality.txt").exists()
        has_wireguard = (user_dir / "wireguard.conf").exists()
        has_hysteria2 = (user_dir / "hysteria2.yaml").exists() or (user_dir / "hysteria2.txt").exists()
        has_trojan = (user_dir / "trojan.txt").exists()
        has_trusttunnel = (user_dir / "trusttunnel.toml").exists() or (user_dir / "trusttunnel.txt").exists()
        has_cdn = (user_dir / "cdn-vless.txt").exists()
        has_amneziawg = (user_dir / "amneziawg.conf").exists()
        has_telemt = (user_dir / "telegram-proxy-link.txt").exists()
        has_xhttp = (user_dir / "xhttp-vless.txt").exists()
        has_xdns = (user_dir / "xdns-config.json").exists()
        has_dnstt = (user_dir / "dnstt-instructions.txt").exists()
        has_slipstream = (user_dir / "slipstream-instructions.txt").exists() or (user_dir / "slipstream-cert.pem").exists()
        has_masterdns = (user_dir / "masterdns-instructions.txt").exists()
        has_gooserelay = (user_dir / "gooserelay-instructions.txt").exists()

        # Check if zip already exists
        zip_exists = (bundle_path / f"{username}.zip").exists()

        # Get creation date from directory modification time
        created_at = datetime.fromtimestamp(user_dir.stat().st_mtime)

        users.append({
            "username": username,
            "has_reality": has_reality,
            "has_wireguard": has_wireguard,
            "has_hysteria2": has_hysteria2,
            "has_trojan": has_trojan,
            "has_trusttunnel": has_trusttunnel,
            "has_cdn": has_cdn,
            "has_amneziawg": has_amneziawg,
            "has_xhttp": has_xhttp,
            "has_xdns": has_xdns,
            "has_telemt": has_telemt,
            "has_dnstt": has_dnstt,
            "has_slipstream": has_slipstream,
            "has_masterdns": has_masterdns,
            "has_gooserelay": has_gooserelay,
            "is_donated": username in donated_users,
            "zip_exists": zip_exists,
            "created_at": created_at,
        })

    # Sort by creation date, newest first
    users.sort(key=lambda u: u["created_at"], reverse=True)

    return users


@app.get("/download/{username}")
async def download_bundle(username: str, _: str = Depends(verify_auth)):
    """Download user bundle as zip file"""
    bundle_path = get_bundle_path()
    user_dir = bundle_path / username

    # Security: validate username (no path traversal)
    if ".." in username or "/" in username or "\\" in username:
        raise HTTPException(status_code=400, detail="Invalid username")

    if not user_dir.exists() or not user_dir.is_dir():
        raise HTTPException(status_code=404, detail="User bundle not found")

    # Check if pre-packaged zip exists
    zip_path = bundle_path / f"{username}.zip"
    if zip_path.exists():
        # Serve existing zip
        def iter_file():
            with open(zip_path, "rb") as f:
                yield from f
        return StreamingResponse(
            iter_file(),
            media_type="application/zip",
            headers={"Content-Disposition": f"attachment; filename={username}.zip"}
        )

    # Create zip on-the-fly
    zip_buffer = io.BytesIO()
    with zipfile.ZipFile(zip_buffer, "w", zipfile.ZIP_DEFLATED) as zf:
        for file_path in user_dir.rglob("*"):
            if file_path.is_file():
                arcname = file_path.relative_to(user_dir)
                zf.write(file_path, arcname)

    zip_buffer.seek(0)

    return StreamingResponse(
        iter([zip_buffer.getvalue()]),
        media_type="application/zip",
        headers={"Content-Disposition": f"attachment; filename={username}.zip"}
    )




# =============================================================================
# MahsaNet Config Donation API
# =============================================================================

MAHSANET_API_URL = "https://www.mahsaserver.com/backend/api/v1/config/"
MAHSANET_API_KEY = os.environ.get("MAHSANET_API_KEY", "")
MAHSANET_PROTOCOLS = os.environ.get("MAHSANET_PROTOCOLS", "reality hysteria2").split()
MAHSANET_POOL = os.environ.get("MAHSANET_POOL", "mahsa")

PROTOCOL_FILE_MAP = {
    "reality": "reality.txt",
    "hysteria2": "hysteria2.txt",
    "trojan": "trojan.txt",
    "cdn": "cdn-vless.txt",
    "xhttp": "xhttp-vless.txt",
    "telegram": "telegram-proxy-link.txt",
}

PROTOCOL_PREFIX_MAP = {
    "reality": "vless://",
    "hysteria2": "hysteria2://",
    "trojan": "trojan://",
    "cdn": "vless://",
    "xhttp": "vless://",
    "telegram": "tg://proxy",
}


def validate_share_link(link: str, protocol: str) -> bool:
    """Validate a share link has correct format."""
    if not link:
        return False
    # Telegram links have different structure
    if protocol == "telegram":
        return link.startswith("tg://proxy") and "server=" in link and "secret=" in link
    if len(link) < 50:
        return False
    if "@" not in link or "#" not in link:
        return False
    expected_prefix = PROTOCOL_PREFIX_MAP.get(protocol, "")
    if expected_prefix and not link.startswith(expected_prefix):
        return False
    return True


async def mahsanet_api_call(method: str, endpoint: str = "", data: dict = None):
    """Make an API call to MahsaNet."""
    url = f"{MAHSANET_API_URL}{endpoint}"
    headers = {
        "Authorization": f"Token {MAHSANET_API_KEY}",
        "Content-Type": "application/json",
    }
    async with httpx.AsyncClient(timeout=15.0, follow_redirects=True) as client:
        if method == "GET":
            resp = await client.get(url, headers=headers)
        elif method == "POST":
            resp = await client.post(url, headers=headers, json=data)
        elif method == "DELETE":
            resp = await client.delete(url, headers=headers)
        else:
            raise ValueError(f"Unsupported method: {method}")
    return resp


@app.get("/api/mahsanet/status")
async def mahsanet_status(_: str = Depends(verify_auth)):
    """Get MahsaNet donation status."""
    if not MAHSANET_API_KEY:
        return {"configured": False}

    try:
        resp = await mahsanet_api_call("GET", "?limit=1")
        if resp.status_code != 200:
            return {"configured": True, "error": f"API error (HTTP {resp.status_code})"}

        total = resp.json().get("count", 0)

        # Get active count
        active_resp = await mahsanet_api_call("GET", "?limit=1&is_active=true")
        active = active_resp.json().get("count", 0) if active_resp.status_code == 200 else 0

        return {
            "configured": True,
            "total": total,
            "active": active,
            "inactive": total - active,
        }
    except Exception as e:
        return {"configured": True, "error": str(e)}


@app.get("/api/mahsanet/configs")
async def mahsanet_configs(_: str = Depends(verify_auth)):
    """List donated configs from MahsaNet."""
    if not MAHSANET_API_KEY:
        raise HTTPException(status_code=400, detail="MahsaNet API key not configured")

    try:
        resp = await mahsanet_api_call("GET", "?limit=100")
        if resp.status_code != 200:
            raise HTTPException(status_code=resp.status_code, detail="MahsaNet API error")
        return resp.json()
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"MahsaNet API unreachable: {e}")


@app.post("/api/mahsanet/donate")
async def mahsanet_donate(request: Request, _: str = Depends(verify_auth)):
    """Generate users and donate configs to MahsaNet."""
    if not MAHSANET_API_KEY:
        raise HTTPException(status_code=400, detail="MahsaNet API key not configured")

    body = await request.json()
    count = int(body.get("count", 1))
    prefix = body.get("prefix", "mahsa").strip()
    protocols = body.get("protocols", MAHSANET_PROTOCOLS)

    # Validate
    if count < 1 or count > 50:
        raise HTTPException(status_code=400, detail="Count must be 1-50")
    if not re.match(r'^[a-zA-Z0-9_-]+$', prefix):
        raise HTTPException(status_code=400, detail="Invalid prefix")

    # Generate users via user-add.sh
    if not USER_ADD_SCRIPT.exists():
        raise HTTPException(status_code=500, detail="user-add.sh not found")

    cmd = ["bash", str(USER_ADD_SCRIPT), "--batch", str(count), "--prefix", prefix]
    script_timeout = max(120, count * 60)

    # Pass DONATE_ONLY_PROTOCOLS to skip WireGuard/AmneziaWG/etc.
    env = {**os.environ, "DONATE_ONLY_PROTOCOLS": " ".join(protocols)}

    try:
        result = subprocess.run(
            cmd, cwd=str(PROJECT_DIR), env=env,
            capture_output=True, text=True, timeout=script_timeout,
        )
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail=f"User creation timed out ({script_timeout}s)")

    if result.returncode != 0:
        raise HTTPException(status_code=500, detail=f"User creation failed: {result.stderr}")

    # Find generated user directories by parsing script output for created usernames
    # user-add.sh logs: "✓ User 'mahsa05' created successfully"
    bundle_path = get_bundle_path()
    donated = []
    errors = []
    generated_users = []

    # Extract usernames from script output: "[INFO] ✓ User 'xxx' created successfully"
    script_output = result.stdout or ""
    seen = set()
    for match in re.finditer(r"User '([^']+)' created", script_output):
        uname = match.group(1)
        if uname not in seen and (bundle_path / uname).exists():
            seen.add(uname)
            generated_users.append(uname)

    # Fallback: find the LAST N dirs matching prefix (sorted by mtime, newest first)
    if not generated_users:
        import time
        now = time.time()
        candidates = []
        for d in bundle_path.iterdir():
            if d.is_dir() and d.name.startswith(prefix):
                candidates.append((d.stat().st_mtime, d.name))
        # Sort by mtime descending (newest first), take only the count we need
        candidates.sort(reverse=True)
        for _, uname in candidates[:count]:
            generated_users.append(uname)

    import asyncio
    api_call_count = 0
    call_delay = 1  # seconds between calls, increases after 429

    for username in generated_users:
        user_dir = bundle_path / username

        for protocol in protocols:
            link_file = PROTOCOL_FILE_MAP.get(protocol)
            if not link_file:
                errors.append(f"{username}: unknown protocol '{protocol}'")
                continue

            filepath = user_dir / link_file
            if not filepath.exists():
                errors.append(f"{username}: {link_file} not found")
                continue

            link = filepath.read_text().strip().split("\n")[0]
            if not validate_share_link(link, protocol):
                errors.append(f"{username}: {protocol} link failed validation")
                continue

            # POST to MahsaNet — telegram goes to "telegram" pool
            config_pool = "telegram" if protocol == "telegram" else MAHSANET_POOL

            # Rate limit: pause between calls (adaptive — slows down after 429)
            api_call_count += 1
            if api_call_count > 1:
                await asyncio.sleep(call_delay)

            max_retries = 2
            for attempt in range(max_retries + 1):
                try:
                    resp = await mahsanet_api_call("POST", "", {
                        "url": link,
                        "ads_url": "https://t.me/VahidOnline",
                        "pool": config_pool,
                        "use_mux": False,
                        "use_fragment": False,
                    })
                    if resp.status_code == 201:
                        config_data = resp.json()
                        donated.append({
                            "user": username,
                            "protocol": protocol,
                            "id": config_data.get("hash", config_data.get("id", "unknown")),
                        })
                        break
                    elif resp.status_code == 429 and attempt < max_retries:
                        # Extract wait time from API response
                        wait = 30
                        try:
                            detail = resp.json().get("detail", "")
                            m = re.search(r'(\d+)\s*second', detail)
                            if m:
                                wait = int(m.group(1)) + 2
                        except Exception:
                            pass
                        # Wait the requested time, then increase pace for all future calls
                        await asyncio.sleep(wait)
                        call_delay = max(call_delay, 3)  # slow down to 3s between calls after first 429
                        continue
                    else:
                        err_detail = resp.text[:200]
                        errors.append(f"{username}/{protocol}: HTTP {resp.status_code} - {err_detail}")
                        break
                except Exception as e:
                    errors.append(f"{username}/{protocol}: {str(e)}")
                    break

    # Save donations to tracking file
    if donated:
        donations_path = Path("/project/outputs/mahsanet-donations.json")
        try:
            existing = {"configs": []}
            if donations_path.exists():
                existing = json.loads(donations_path.read_text())
            for d in donated:
                existing["configs"].append({
                    "id": d["id"],
                    "user": d["user"],
                    "protocol": d["protocol"],
                    "donated_at": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                })
            donations_path.parent.mkdir(parents=True, exist_ok=True)
            donations_path.write_text(json.dumps(existing, indent=2))
        except Exception:
            pass  # Non-critical

    return {
        "success": len(donated) > 0,
        "users": generated_users,
        "donated": len(donated),
        "donated_configs": donated,
        "errors": errors,
        "script_output": result.stdout[-2000:] if result.stdout else "",
        "script_errors": result.stderr[-2000:] if result.stderr else "",
    }


@app.delete("/api/mahsanet/configs/{config_id}")
async def mahsanet_delete_config(config_id: str, _: str = Depends(verify_auth)):
    """Delete a donated config from MahsaNet."""
    if not MAHSANET_API_KEY:
        raise HTTPException(status_code=400, detail="MahsaNet API key not configured")

    try:
        # Try multiple URL patterns — MahsaNet API lookup_field is unknown
        attempts = [
            f"{config_id}/",   # /config/{hash}/
            f"{config_id}",    # /config/{hash} (no trailing slash)
        ]

        # First, try to get the config's actual 'id' via GET single
        get_resp = await mahsanet_api_call("GET", f"{config_id}/")
        if get_resp.status_code == 200:
            actual_id = get_resp.json().get("id", "")
            if actual_id and str(actual_id) != config_id:
                attempts.insert(0, f"{actual_id}/")
                attempts.insert(1, f"{actual_id}")
        else:
            # Try filter lookup
            lookup = await mahsanet_api_call("GET", f"?hash={config_id}&limit=1")
            if lookup.status_code == 200:
                results = lookup.json().get("results", [])
                if results:
                    for field in ["id", "pk", "uuid"]:
                        val = results[0].get(field)
                        if val and str(val) != config_id:
                            attempts.insert(0, f"{val}/")
                    print(f"[MahsaNet] Config fields for hash={config_id}: {list(results[0].keys())}")

        last_resp = None
        for path in attempts:
            resp = await mahsanet_api_call("DELETE", path)
            if resp.status_code in (200, 204):
                return {"success": True}
            last_resp = resp

        detail = "Delete not supported — MahsaNet API does not expose the required config ID. Use the MahsaNet web dashboard to delete configs."
        raise HTTPException(status_code=422, detail=detail)
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"MahsaNet API unreachable: {e}")


def find_certificates(wait_for_letsencrypt=True, max_wait=60):
    """
    Find SSL certificates with priority: Let's Encrypt > Self-signed

    Args:
        wait_for_letsencrypt: If True, wait for Let's Encrypt certs to appear
        max_wait: Maximum seconds to wait for Let's Encrypt certs

    Returns:
        Tuple of (ssl_keyfile, ssl_certfile) or (None, None)
    """
    import glob
    import time

    # Check for self-signed first to determine if we're in domainless mode
    # Check /tmp/certs first (moav-readable copy), fall back to /certs (original)
    for certs_base in ["/tmp/certs", "/certs"]:
        selfsigned_key = f"{certs_base}/selfsigned/privkey.pem"
        selfsigned_cert = f"{certs_base}/selfsigned/fullchain.pem"
        if Path(selfsigned_key).exists() and Path(selfsigned_cert).exists():
            break
    has_selfsigned = Path(selfsigned_key).exists() and Path(selfsigned_cert).exists()

    # Wait for Let's Encrypt certs if requested
    if wait_for_letsencrypt:
        waited = 0
        check_interval = 5
        print(f"Waiting for Let's Encrypt certificate (up to {max_wait}s)...")

        while waited < max_wait:
            cert_dirs = glob.glob("/tmp/certs/live/*/") or glob.glob("/certs/live/*/")
            for cert_dir in cert_dirs:
                # Skip README-only directories
                key_path = f"{cert_dir}privkey.pem"
                cert_path = f"{cert_dir}fullchain.pem"
                if Path(key_path).exists() and Path(cert_path).exists():
                    print(f"Found Let's Encrypt certificate from {cert_dir}")
                    return key_path, cert_path

            # If we have self-signed, we might be in domainless mode
            # Don't wait too long in that case
            if has_selfsigned and waited >= 15:
                print("Self-signed cert exists, assuming domainless mode")
                break

            time.sleep(check_interval)
            waited += check_interval
            if waited < max_wait:
                print(f"  Still waiting... ({waited}s)")

    # Check one more time without waiting
    cert_dirs = glob.glob("/tmp/certs/live/*/") or glob.glob("/certs/live/*/")
    for cert_dir in cert_dirs:
        key_path = f"{cert_dir}privkey.pem"
        cert_path = f"{cert_dir}fullchain.pem"
        if Path(key_path).exists() and Path(cert_path).exists():
            print(f"Using Let's Encrypt certificate from {cert_dir}")
            return key_path, cert_path

    # Fallback to self-signed certificate (domainless mode)
    if has_selfsigned:
        print("Using self-signed certificate (domainless mode)")
        return selfsigned_key, selfsigned_cert

    return None, None


if __name__ == "__main__":
    import uvicorn

    # Find certificate files (waits for Let's Encrypt if needed)
    ssl_keyfile, ssl_certfile = find_certificates(wait_for_letsencrypt=True, max_wait=60)

    if not ssl_keyfile:
        print("WARNING: No SSL certificates found, running without HTTPS")

    # Run with SSL if certs found
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8443,
        ssl_keyfile=ssl_keyfile,
        ssl_certfile=ssl_certfile,
    )

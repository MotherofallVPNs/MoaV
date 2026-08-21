#!/usr/bin/env python3
"""Render a user's client-guide README.html from the template + bundle files,
and write subscription.txt. Driven by lib/bundle-readme.sh via RB_* env vars.

One pass, pure Python: no sed (so no BSD/GNU flavor split), multiline configs and
passwords with shell-special chars handled natively. subscription.txt is written
UNCONDITIONALLY (empty when the bundle has no V2Ray-compatible links)."""
import base64
import glob
import os
import re

OUT = os.environ["RB_OUTPUT_DIR"]
CONTEXT = os.environ.get("RB_CONTEXT", "container")


def _read(name):
    for candidate in _candidates(name):
        try:
            with open(os.path.join(OUT, candidate), encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            continue
    return ""


def _candidates(name):
    """Resolve a logical bundle file to what is actually on disk.

    WireGuard-family configs are named moav-<server>-wg.conf now (clients take
    the tunnel name from the filename), but bundles generated before the rename
    use the plain names — and a stale guide would show "No WireGuard config
    available" for a config that is sitting right there. Try the new glob first,
    then the legacy name.
    """
    globs = {
        "wireguard.conf":          "moav-*-wg.conf",
        "wireguard-wstunnel.conf": "moav-*-wgws.conf",
        "wireguard-ipv6.conf":     "moav-*-wg6.conf",
        "amneziawg.conf":          "moav-*-awg.conf",
        "amneziawg-ipv6.conf":     "moav-*-awg6.conf",
    }
    pattern = globs.get(name)
    if pattern:
        for hit in sorted(glob.glob(os.path.join(OUT, pattern))):
            yield os.path.basename(hit)
    yield name


def link(name):        # single-line share link (.txt)
    return _read(name).strip()


def conf(name):        # multiline config (.conf) — keep internal formatting
    return _read(name).rstrip("\n")


def instr(name):       # multiline instructions / JSON
    return _read(name).strip()


def qr(name):          # base64 of a QR png, "" if absent
    p = os.path.join(OUT, name)
    if not os.path.isfile(p):
        return ""
    with open(p, "rb") as f:
        return base64.b64encode(f.read()).decode("ascii")


def val_or(value, fallback):
    return value if value else fallback


def _hide(name):       # "" (show) if the artifact exists in the bundle, else CSS hide
    # Through _candidates, so a renamed WireGuard config (moav-<server>-wg.conf)
    # still shows its section. A direct isfile() here would embed the config via
    # _read() and then CSS-hide the section containing it.
    for candidate in _candidates(name):
        if os.path.isfile(os.path.join(OUT, candidate)):
            return ""
    return "display:none"


# MasterDNS/GooseRelay can't be generated on the host path (server-shared key
# lives in the state volume) — nudge to regenerate-users there; else "not enabled".
def absent_extra(label):
    if CONTEXT == "host":
        return f"Run 'moav regenerate-users' to include {label}"
    return f"{label} not enabled"


# --- V2Ray/MahsaNG subscription: first proxy URI from each link file -----------
SUB_FILES = ["reality", "cdn-vless", "xhttp-vless", "trojan", "anytls",
             "shadowsocks", "hysteria2", "reality-ipv6", "trojan-ipv6",
             "anytls-ipv6", "shadowsocks-ipv6", "hysteria2-ipv6"]
SUB_RE = re.compile(r"^(vless|trojan|anytls|ss|hysteria2|vmess)://")

uris = []
for stem in SUB_FILES:
    txt = _read(f"{stem}.txt")
    if not txt:
        continue
    for line in txt.replace("\r", "").splitlines():
        if SUB_RE.match(line):
            uris.append(line)
            break

# Append the compact moav:// bundle (one URL for every enabled proxy) so
# moav-client receives it in the subscription too; it expands + dedups it
# against the legacy URIs above. Other clients ignore the unknown scheme.
_moav = _read("moav-bundle.txt")
if _moav:
    for _line in _moav.replace("\r", "").splitlines():
        if _line.startswith("moav://"):
            uris.append(_line)
            break

sub_b64 = base64.b64encode(("\n".join(uris) + "\n").encode()).decode() if uris else ""
# Unconditional: the bundle always carries subscription.txt (empty if no links).
with open(os.path.join(OUT, "subscription.txt"), "w", encoding="utf-8") as f:
    f.write(sub_b64 + "\n" if sub_b64 else "")

# --- demo-user notice (container demo user only) ------------------------------
demo_en = demo_fa = ""
if os.environ.get("RB_IS_DEMO_USER", "false") == "true":
    disabled = []
    for flag, name in (("RB_ENABLE_WIREGUARD", "WireGuard"), ("RB_ENABLE_DNSTT", "DNS Tunnel"),
                       ("RB_ENABLE_TROJAN", "Trojan"), ("RB_ENABLE_ANYTLS", "AnyTLS"),
                       ("RB_ENABLE_HYSTERIA2", "Hysteria2"), ("RB_ENABLE_REALITY", "Reality")):
        default = "false" if flag == "RB_ENABLE_ANYTLS" else "true"
        if os.environ.get(flag, default) != "true":
            disabled.append(name)
    extra = f" ({', '.join(disabled)})" if disabled else ""
    style = ('background: rgba(210, 153, 34, 0.1); border-color: var(--accent-orange); '
             'color: var(--accent-orange); margin-top: 12px;')
    doc = 'https://github.com/moav-project/moav/tree/main/docs'
    demo_en = (f'<div class="warning" style="{style}"><strong>Demo User Notice:</strong> '
               'This is a demo account created during initial setup. Some config files may be '
               f'missing if services were not enabled{extra}. See <a href="{doc}" '
               'style="color: var(--accent-orange);">documentation</a> for setup.</div>')
    demo_fa = (f'<div class="warning" style="{style}"><strong>توجه:</strong> '
               'این یک حساب کاربری آزمایشی است. برخی فایل‌های پیکربندی ممکن است وجود نداشته باشند. '
               f'برای راهنمایی به <a href="{doc}" style="color: var(--accent-orange);">مستندات</a> '
               'مراجعه کنید.</div>')

# --- placeholder → value map --------------------------------------------------
xdns_present = os.path.isfile(os.path.join(OUT, "xdns-config.json"))
slipstream_present = os.path.isfile(os.path.join(OUT, "slipstream-cert.pem"))
cdn = link("cdn-vless.txt")
# MasterDNS/GooseRelay embed their canonical client-config artifact (the setup
# guide lives in this README, not a separate instructions .txt).
md = instr("masterdns-client_config.toml")
gr = instr("gooserelay-client_config.json")
# TrustTunnel ships .toml (client config) + .json (credentials); either proves it.
tt_present = any(os.path.isfile(os.path.join(OUT, n))
                 for n in ("trusttunnel.toml", "trusttunnel.json"))
# dnstt now ships the server pubkey per user (dnstt-server.pub), written only
# when dnstt is enabled for that user. Keying on the pubkey ENV instead made the
# section appear for donated users, whose bundles have no dnstt at all: the env
# value is server-wide and set regardless of ENABLE_DNSTT.
dnstt_present = os.path.isfile(os.path.join(OUT, "dnstt-server.pub"))

repl = {
    "USERNAME": os.environ.get("RB_USERNAME", ""),
    "SERVER_IP": os.environ.get("RB_SERVER_IP", ""),
    "DOMAIN": os.environ.get("RB_DOMAIN", ""),
    "PORT_SS": os.environ.get("RB_PORT_SS", "8388"),
    "WSTUNNEL_CMD": os.environ.get("RB_WSTUNNEL_CMD", ""),
    "GENERATED_DATE": os.environ.get("RB_GENERATED_DATE", ""),
    "DNSTT_DOMAIN": os.environ.get("RB_DNSTT_DOMAIN", ""),
    "DNSTT_PUBKEY": os.environ.get("RB_DNSTT_PUBKEY", ""),
    "SLIPSTREAM_DOMAIN": os.environ.get("RB_SLIPSTREAM_DOMAIN", ""),

    "CONFIG_REALITY": val_or(link("reality.txt"), "No Reality config available"),
    "CONFIG_HYSTERIA2": val_or(link("hysteria2.txt"), "No Hysteria2 config available"),
    "CONFIG_TROJAN": val_or(link("trojan.txt"), "No Trojan config available"),
    "CONFIG_ANYTLS": val_or(link("anytls.txt"), "No AnyTLS config available"),
    "CONFIG_SHADOWSOCKS": val_or(link("shadowsocks.txt"), "No Shadowsocks config available"),
    "CONFIG_XHTTP": val_or(link("xhttp-vless.txt"), "XHTTP not enabled"),
    "CONFIG_TELEMT": val_or(link("telegram-proxy-link.txt"), "Telegram MTProxy not enabled"),
    "CONFIG_CDN": val_or(cdn, "CDN not configured"),
    "CDN_DOMAIN": os.environ.get("RB_CDN_DOMAIN", "") if cdn else "Not configured",
    "CONFIG_WIREGUARD": val_or(conf("wireguard.conf"), "No WireGuard config available"),
    "CONFIG_WIREGUARD_WSTUNNEL": val_or(conf("wireguard-wstunnel.conf"),
                                        "No WireGuard-wstunnel config available"),
    "CONFIG_AMNEZIAWG": val_or(conf("amneziawg.conf"), "No AmneziaWG config available"),
    "CONFIG_SLIPSTREAM": "" if slipstream_present else "display:none",

    "CONFIG_XDNS": instr("xdns-config.json") if xdns_present else "XDNS not enabled",
    "CONFIG_XDNS_DIRECT": (val_or(instr("xdns-direct-config.json"), "XDNS direct config not available")
                           if xdns_present else "XDNS not enabled"),
    "XDNS_DISPLAY": "" if xdns_present else "display:none",

    "CONFIG_MASTERDNS": val_or(md, absent_extra("MasterDNS")),
    "MASTERDNS_DISPLAY": "" if md else "display:none",
    "CONFIG_GOOSERELAY": val_or(gr, absent_extra("GooseRelay")),
    "GOOSERELAY_DISPLAY": "" if gr else "display:none",

    # #73: hide a protocol's whole section + its TOC entry when the user's
    # bundle has no artifact for it (a disabled/not-running protocol), instead
    # of showing a "No X config available" null section. Keyed on the real
    # per-user artifact file — the same signal the CONFIG_* values read above.
    "REALITY_DISPLAY":     _hide("reality.txt"),
    "HYSTERIA2_DISPLAY":   _hide("hysteria2.txt"),
    "TROJAN_DISPLAY":      _hide("trojan.txt"),
    "ANYTLS_DISPLAY":      _hide("anytls.txt"),
    "SHADOWSOCKS_DISPLAY": _hide("shadowsocks.txt"),
    "CDN_DISPLAY":         "" if cdn else "display:none",
    "XHTTP_DISPLAY":       _hide("xhttp-vless.txt"),
    "AMNEZIAWG_DISPLAY":   _hide("amneziawg.conf"),
    "WIREGUARD_DISPLAY":   _hide("wireguard.conf"),
    # Keyed on artifacts that are actually written. trusttunnel.txt and
    # dnstt-instructions.txt never existed, so both sections were always hidden.
    "TRUSTTUNNEL_DISPLAY": "" if tt_present else "display:none",
    "DNSTT_DISPLAY":       "" if dnstt_present else "display:none",
    "TELEMT_DISPLAY":      _hide("telegram-proxy-link.txt"),

    "TRUSTTUNNEL_PASSWORD": val_or(os.environ.get("RB_USER_PASSWORD", ""), "See trusttunnel.json"),
    "DEMO_NOTICE_EN": demo_en,
    "DEMO_NOTICE_FA": demo_fa,

    "MAHSANET_SUB": sub_b64 if sub_b64 else "No V2Ray-compatible configs in this bundle",
    "MAHSANET_DISPLAY": "" if sub_b64 else "display:none",

    "QR_REALITY": qr("reality-qr.png"),
    "QR_HYSTERIA2": qr("hysteria2-qr.png"),
    "QR_TROJAN": qr("trojan-qr.png"),
    "QR_ANYTLS": qr("anytls-qr.png"),
    "QR_CDN": qr("cdn-vless-qr.png"),
    "QR_WIREGUARD": qr("wireguard-qr.png"),
    "QR_AMNEZIAWG": qr("amneziawg-qr.png"),
    "QR_SHADOWSOCKS": qr("shadowsocks-qr.png"),
    "QR_XHTTP": qr("xhttp-qr.png"),
    "QR_TELEMT": qr("telegram-proxy-qr.png"),
}

with open(os.environ["RB_TEMPLATE"], encoding="utf-8") as f:
    html = f.read()
for key, value in repl.items():
    html = html.replace("{{%s}}" % key, value)
with open(os.environ["RB_OUTPUT_HTML"], "w", encoding="utf-8") as f:
    f.write(html)

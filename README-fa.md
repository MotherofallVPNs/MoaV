<div align="center">

<img src="branding/logo.png" alt="MoaV logo" width="130">

# مادر همهٔ VPN‌ها

**پشتهٔ چندپروتکلی عبور از سانسور اینترنت، ساخته‌شده برای شبکه‌های خصمانه.**

[![Website](https://img.shields.io/badge/website-moav.sh-06b6d4.svg)](https://moav.sh) [![Docs](https://img.shields.io/badge/docs-moav.sh%2Fdocs-2563eb.svg)](https://moav.sh/docs/) [![Release](https://img.shields.io/github/v/release/MotherofallVPNs/MoaV?label=release&color=16a34a&logo=github&logoColor=white)](https://github.com/MotherofallVPNs/MoaV/releases/latest) [![Pre-release](https://img.shields.io/github/v/release/MotherofallVPNs/MoaV?include_prereleases&label=pre-release&color=f59e0b&logo=github&logoColor=white)](https://github.com/MotherofallVPNs/MoaV/releases)

[![Protocols](https://img.shields.io/badge/protocols-16%2B-ef4444.svg)](#protocols) [![moav-client](https://img.shields.io/badge/client-moav--client-06b6d4.svg?logo=github&logoColor=white)](https://github.com/MotherofallVPNs/moav-client) [![AI agents](https://img.shields.io/badge/AI_agents-AGENTS.md-8b5cf6.svg)](AGENTS.md) [![Telegram](https://img.shields.io/badge/Telegram-motherofallvpns-2CA5E0.svg?logo=telegram)](https://t.me/motherofallvpns) [![X](https://img.shields.io/badge/X-@motherofallvpns-000000.svg?logo=x)](https://x.com/motherofallvpns)

[![License: MIT](https://img.shields.io/badge/license-MIT-22c55e.svg)](LICENSE) [![Stars](https://img.shields.io/github/stars/MotherofallVPNs/MoaV?style=social)](https://github.com/MotherofallVPNs/MoaV/stargazers) [![Forks](https://img.shields.io/github/forks/MotherofallVPNs/MoaV?style=social)](https://github.com/MotherofallVPNs/MoaV/network/members) [![Last commit](https://img.shields.io/github/last-commit/MotherofallVPNs/MoaV/dev?label=last%20commit&color=64748b)](https://github.com/MotherofallVPNs/MoaV/commits/dev)

🇬🇧 [English](README.md) &nbsp;·&nbsp; 🇮🇷 [فارسی](README-fa.md)

ساخته و نگهداری‌شده توسط جامعهٔ **[MoaV](https://github.com/MotherofallVPNs)**.

</div>

---

<a id="why"></a>

## چرا MoaV وجود دارد

هیچ ترابردی از دست هر سانسورگری جان سالم به در نمی‌برد. پروتکلی که امروز صبح کار می‌کند
می‌تواند تا بعدازظهر شناسایی و انگشت‌نگاری شود، و کسی که به آن تکیه کرده هیچ راهی ندارد که
از قبل بداند کدام یکی دوام می‌آورد.

پس MoaV چندتا را با هم راه می‌اندازد، از یک سرور و در یک بستهٔ کاربری. وقتی یک مسیر از کار
می‌افتد، کاربر به مسیر دیگری سوئیچ می‌کند، نه این‌که منتظر بماند کسی چیزی را از نو نصب کند.
کل ایده همین است؛ باقی چیزها در خدمت آن هستند.

[مأموریت](https://moav.sh/docs/mission)، [مدل تهدید](https://moav.sh/docs/threat-model)
برای این‌که MoaV از چه چیزی محافظت می‌کند و از چه چیزی نه، و
[فلسفه](https://moav.sh/docs/philosophy) برای استدلال بلندتر را بخوانید.

---

## فهرست مطالب

**لینک‌ها** &nbsp;·&nbsp; [وب‌سایت](https://moav.sh) &nbsp;·&nbsp; [مستندات](https://moav.sh/docs/) &nbsp;·&nbsp; [تلگرام](https://t.me/motherofallvpns) &nbsp;·&nbsp; [moav-client](https://github.com/MotherofallVPNs/moav-client)

**شروع کنید** &nbsp;·&nbsp; [چرا MoaV وجود دارد](#why) &nbsp;·&nbsp; [ویژگی‌ها](#features) &nbsp;·&nbsp; [شروع سریع](#quick-start) &nbsp;·&nbsp; [پیش‌نیازها](#requirements) &nbsp;·&nbsp; [اجرا بدون دامنه](#domainless)

**استفاده** &nbsp;·&nbsp; [کار با MoaV](#using) &nbsp;·&nbsp; [اپلیکیشن‌های کاربر](#clients) &nbsp;·&nbsp; [مستندات](#docs)

**زیر پوسته** &nbsp;·&nbsp; [معماری](#architecture) &nbsp;·&nbsp; [پروتکل‌ها](#protocols) &nbsp;·&nbsp; [ساختار پروژه](#structure) &nbsp;·&nbsp; [امنیت](#security)

**کمک کنید** &nbsp;·&nbsp; [حمایت از پروژه](#support) &nbsp;·&nbsp; [جامعه](#community) &nbsp;·&nbsp; [پروژه‌های مرتبط](#related)

---

![نمای کلی](https://github.com/user-attachments/assets/60e1726f-2733-4d49-9fa2-30be8c2dbeb5)

---

<a id="features"></a>

## ویژگی‌ها

- **چند پروتکل هم‌زمان** — بیش از ۱۶ ترابرد و مسیر جایگزین عبور از فیلترینگ، به‌همراه یکپارچه‌سازی‌های اختیاری اهدای پهنای‌باند با Psiphon، Tor و MahsaNet:
  - **پروکسی با پنهان‌کاری بالا** — Reality (VLESS)، Trojan، Hysteria2، XHTTP (VLESS+XHTTP+Reality)، CDN (VLESS+WS از طریق Cloudflare)
  - **VPN کامل** — WireGuard (مستقیم و روی wstunnel)، AmneziaWG
  - **ویژه** — TrustTunnel (HTTP/2+QUIC)، Telegram MTProxy (fake-TLS)، Shadowsocks-2022، GooseRelay (SOCKS5 روی Google Apps Script)
  - **تونل‌های DNS** — dnstt، Slipstream، MasterDNS و XDNS — هر چهار تا هم‌زمان روی پورت ۵۳ از طریق `dns-router`
- **پنهان‌کاری در اولویت** — ترافیک شبیه HTTPS، WebSocket، DNS یا IMAPS معمولی دیده می‌شود
- **اعتبارنامهٔ مستقل برای هر کاربر** — ساخت، لغو و مدیریت کاربران به‌صورت جداگانه
- **راه‌اندازی ساده** — بر پایهٔ Docker Compose، با یک فرمان
- **مناسب موبایل** — کد QR و لینک برای واردکردن آسان در اپلیکیشن‌ها
- **وب‌سایت پوششی** — به بازدیدکنندهٔ بدون اعتبارنامه محتوای بی‌خطر نشان می‌دهد
- **آمادهٔ سرور خانگی** — روی Raspberry Pi یا هر لینوکس ARM64/x64 به‌عنوان VPN شخصی
- **[Psiphon Conduit](https://github.com/Psiphon-Inc/conduit)** — اهدای اختیاری پهنای‌باند برای کمک به عبور دیگران از سانسور
- **[Tor Snowflake](https://snowflake.torproject.org/)** — اهدای اختیاری پهنای‌باند برای کمک به کاربران Tor
- **[MahsaNet](https://www.mahsaserver.com/)** — اهدای کانفیگ به کاربران Mahsa VPN (بیش از ۲ میلیون کاربر در ایران)
- **مانیتورینگ** — پشتهٔ اختیاری Grafana و Prometheus

> **[مستندات کامل را بخوانید](https://moav.sh/docs/)** — راهنمای نصب، مرجع خط فرمان، اپلیکیشن‌های کاربر، مانیتورینگ، OPSEC و بیشتر.

<a id="quick-start"></a>

## شروع سریع

**نصب با یک فرمان** (پیشنهادی):

```bash
curl -fsSL moav.sh/install.sh | bash
```

این کار:
- پیش‌نیازها را نصب می‌کند (Docker، git، qrencode) اگر نبودند
- MoaV را در `/opt/moav` کلون می‌کند
- دامنه، ایمیل و رمز مدیریت را می‌پرسد
- پیشنهاد می‌کند فرمان `moav` را به‌صورت سراسری نصب کند
- راه‌اندازی تعاملی را اجرا می‌کند

**نصب دستی** (جایگزین):

```bash
git clone https://github.com/MotherofallVPNs/moav.git
cd moav
cp .env.example .env
nano .env  # مقادیر DOMAIN، ACME_EMAIL و ADMIN_PASSWORD را تنظیم کنید
./moav.sh
```

<img src="docs/assets/moav.sh.png" alt="منوی تعاملی MoaV" width="350">

**بعد از نصب، `moav` را از هر جایی اجرا کنید:**

```bash
moav                      # منوی تعاملی
moav start                # اجرای سرویس‌ها
moav status               # وضعیت سرویس‌ها
moav user add alice       # افزودن کاربر (کانفیگ و کد QR می‌سازد)
moav user add --batch 10  # ساخت گروهی کاربر
moav donate               # اهدای کانفیگ به MahsaNet/Psiphon/Snowflake
moav doctor               # عیب‌یابی (DNS، پورت‌ها، سرویس‌ها)
moav update               # به‌روزرسانی MoaV
moav admin password       # تغییر رمز پنل و Grafana
moav help                 # نمایش همهٔ فرمان‌ها
```

برای دستورهای کامل [راهنمای نصب](https://moav.sh/docs/SETUP)، برای همهٔ فرمان‌ها
[مرجع خط فرمان](https://moav.sh/docs/CLI)، یا [مستندات کامل](https://moav.sh/docs/) را ببینید.

### سرور خودتان را راه بیندازید

[![Deploy on Hetzner](https://img.shields.io/badge/Deploy%20on-Hetzner-d50c2d?style=for-the-badge&logo=hetzner&logoColor=white)](https://moav.sh/docs/DEPLOY#hetzner)  [![Deploy on Linode](https://img.shields.io/badge/Deploy%20on-Linode-00a95c?style=for-the-badge&logo=linode&logoColor=white)](https://moav.sh/docs/DEPLOY#linode)  [![Deploy on Vultr](https://img.shields.io/badge/Deploy%20on-Vultr-007bfc?style=for-the-badge&logo=vultr&logoColor=white)](https://moav.sh/docs/DEPLOY#vultr)  [![Deploy on DigitalOcean](https://img.shields.io/badge/Deploy%20on-DigitalOcean-0080ff?style=for-the-badge&logo=digitalocean&logoColor=white)](https://moav.sh/docs/DEPLOY#digitalocean)



<a id="architecture"></a>

## معماری

```
                                                              ┌───────────────┐  ┌───────────────┐
       ┌───────────────┐                                      │ Psiphon Users │  │   Tor Users   │
       │  Your Clients │                                      │  (worldwide)  │  │  (worldwide)  │
       │   (private)   │                                      └───────┬───────┘  └───────┬───────┘
       └───────┬───────┘                                              │                  │
               │                                                      │                  │
               ├─────────────────┐                                    │                  │
               │                 │ (when IP blocked)                  │                  │
               │          ┌──────┴───────┐                            │                  │
               │          │ Cloudflare   │                            │                  │
               │          │  CDN (VLESS) │                            │                  │
               │          └──────┬───────┘                            │                  │
               │                 │                                    │                  │
┌──────────────╪─────────────────╪────────────────────────────────────╪──────────────────╪─────────┐
│              │                 │          Restricted Internet       │                  │         │
└──────────────╪─────────────────╪────────────────────────────────────╪──────────────────╪─────────┘
               │                 │                                    │                  │
╔══════════════╪═════════════════╪════════════════════════════════════╪══════════════════╪═════════╗
║              │                 │                                    │                  │         ║
║     ┌────────┼─────────────────┼───────┼──────┐                     │                  │         ║
║     │        │         │       │       │      │                     │                  │         ║
║     ▼        ▼         ▼       ▼       ▼      ▼                     ▼                  ▼         ║
║ ┌─────────┐┌─────────┐┌───────┐┌─────────┐┌────────┐          ┌───────────┐      ┌───────────┐   ║
║ │ Reality ││WireGuard││ Trust ││  DNS    ││Telegram│          │           │      │           │   ║
║ │ 443/tcp ││51820/udp││Tunnel ││ 53/udp  ││MTProxy │          │  Conduit  │      │ Snowflake │   ║
║ │ Trojan  ││AmneziaWG││4443/  │├─────────┤│993/tcp │          │  (donate  │      │  (donate  │   ║
║ │8443/tcp ││51821/udp││tcp+udp││  dnstt  │└───┬────┘          │ bandwidth)│      │ bandwidth)│   ║
║ │Hysteria2││wstunnel ││       ││Slipstrm │    │               └─────┬─────┘      └─────┬─────┘   ║
║ │ 443/udp ││8080/tcp ││       │└────┬────┘    │                     │                  │         ║
║ │ CDN WS  │└────┬────┘└───┬───┘     │         │                     │                  │         ║
║ │2082/tcp │     │         │         │         │  ┌────────────────┐ │                  │     M   ║
║ ├─────────┤     │         │         │         │  │ Grafana  :9444 │ │                  │     O   ║
║ │ sing-box│     │         │         │         │  │ Prometheus     │ │                  │     A   ║
║ └────┬────┘     │         │         │         │  └────────────────┘ │                  │     V   ║
║      │          │         │         │         │                     │                  │         ║
╚══════╪══════════╪═════════╪═════════╪═════════╪═════════════════════╪══════════════════╪═════════╝
       │          │         │         │         │                     │                  │
       ▼          ▼         ▼         ▼         ▼                     ▼                  ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                        Open Internet                                            │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
```

<a id="protocols"></a>

## پروتکل‌ها

| پروتکل | پورت | پنهان‌کاری | سرعت | پیش‌فرض | کاربرد |
|----------|------|---------|-------|---------|----------|
| Reality (VLESS) | 443/tcp | ★★★★★ | ★★★★☆ | ✅ | اصلی؛ نخستین انتخاب خوب در شبکه‌هایی که کار می‌کند |
| Hysteria2 | 443/udp | ★★★★☆ | ★★★★★ | ✅ | سریع، وقتی TCP کند شده کار می‌کند |
| Trojan | 8443/tcp | ★★★★☆ | ★★★★☆ | ✅ | پشتیبان، از دامنهٔ شما استفاده می‌کند |
| AnyTLS | 8445/tcp | ★★★★★ | ★★★★☆ | ⬜ | مقاوم در برابر انگشت‌نگاری TLS-in-TLS، از دامنهٔ شما استفاده می‌کند |
| Shadowsocks-2022 | 8388/tcp+udp | ★★★★☆ | ★★★★☆ | ✅ | AEAD-2022 ضد کاوش فعال؛ سازگار با اپ Outline |
| CDN (VLESS+WS) | 443 via Cloudflare | ★★★★★ | ★★★☆☆ | ⬜ | وقتی IP سرور بسته شده؛ نیاز به تنظیم Cloudflare دارد |
| TrustTunnel | 4443/tcp+udp | ★★★★★ | ★★★★☆ | ✅ | HTTP/2 و QUIC، شبیه HTTPS دیده می‌شود |
| WireGuard (Direct) | 51820/udp | ★★★☆☆ | ★★★★★ | ✅ | VPN کامل، راه‌اندازی ساده |
| AmneziaWG | 51821/udp | ★★★★★ | ★★★★☆ | ✅ | WireGuard مبهم‌شده، مقاوم در برابر امضاهای رایج DPI |
| WireGuard (wstunnel) | 8080/tcp | ★★★★☆ | ★★★★☆ | ✅ | VPN وقتی UDP بسته است |
| DNS Tunnel (dnstt) | 53/udp | ★★★☆☆ | ★☆☆☆☆ | ✅ | آخرین راه، سخت‌بستنی |
| Slipstream | 53/udp | ★★★☆☆ | ★★☆☆☆ | ✅ | QUIC روی DNS، ۱.۵ تا ۵ برابر سریع‌تر از dnstt |
| MasterDNS | 53/udp | ★★★☆☆ | ★★★☆☆ | ✅ | تونل DNS پیشرفته (ARQ و توزیع بار resolver)، MahsaNG v16 |
| XDNS (VLESS+mKCP+DNS) | 53/udp | ★★★☆☆ | ★☆☆☆☆ | ✅ | تونل DNS با Xray FinalMask؛ هر چهار تونل DNS پورت ۵۳ را مشترک دارند |
| GooseRelay | 8444/tcp | ★★★★★ | ★★☆☆☆ | ⬜ | SOCKS5 روی Google Apps Script، با نمای google.com، MahsaNG v16 |
| Telegram MTProxy | 993/tcp | ★★★★☆ | ★★★☆☆ | ✅ | Fake-TLS V2، دسترسی مستقیم به تلگرام |
| XHTTP (VLESS+XHTTP+Reality) | 2096/tcp | ★★★★★ | ★★★★☆ | ✅ | Xray-core، بدون نیاز به دامنه |
| Psiphon Conduit | — | — | — | ✅ | اهدای پهنای‌باند به Psiphon (بیش از ۲ میلیون کاربر) |
| Tor Snowflake | — | — | — | ✅ | اهدای پهنای‌باند به شبکهٔ Tor |
| MahsaNet | — | — | — | ⬜ | اهدای کانفیگ به Mahsa VPN (بیش از ۲ میلیون کاربر) |

**Default** = enabled in `.env.example`. Services still only run under their
profile, so `moav start conduit` is what actually starts Conduit. MahsaNet is an
action (`moav donate`), not a service.

<a id="using"></a>

## کار با MoaV

```bash
moav                          # منوی تعاملی روی همهٔ موارد زیر
moav status                   # چه چیزی در حال اجراست، کدام پروفایل‌ها، سلامت در یک نگاه
moav doctor                   # عیب‌یابی DNS، پورت‌ها، گواهی‌ها، منابع
moav logs sing-box            # دیدن لاگ یک سرویس

moav user add alice --package # ساخت کاربر و ساختن فایل zip بستهٔ او
moav user add --batch 10      # ده کاربر یک‌جا
moav user list                # چه کسانی هستند
moav user revoke alice        # لغو فوری دسترسی
moav test alice               # اثبات این‌که کانفیگ‌های alice واقعاً ترافیک را رد می‌کنند

moav start proxy admin        # اجرای پروفایل‌های مشخص
moav restart sing-box         # اعمال تغییر .env روی یک سرویس
moav donate                   # اهدای کانفیگ و پهنای‌باند (MahsaNet، Psiphon، Snowflake)
```

هر کاربر پوشهٔ `outputs/bundles/<username>/` را می‌گیرد با فایل‌های کانفیگ، کدهای QR و
راهنمای `README.html`، به‌همراه یک **اشتراک V2Ray** به‌صورت base64 در `subscription.txt`
که با یک بار چسباندن همهٔ پروتکل‌های پروکسی را در
[MahsaNG](https://github.com/GFW-knocker/MahsaNG)، v2rayNG یا Hiddify وارد می‌کند.
[راهنمای واردکردن در MahsaNG](https://moav.sh/docs/mahsanet) را ببینید.

برای بررسی یک بسته از دید کاربر، [**moav-client**](https://github.com/MotherofallVPNs/moav-client)
اشتراک را می‌خواند، هر نقطهٔ اتصال را از تونل خودش آزمایش می‌کند و از سالم‌ترین و سریع‌ترین
مسیر عبور می‌دهد.

**پنل‌ها** — رمز هر دو در زمان نصب تنظیم می‌شود (`ADMIN_PASSWORD` در `.env`) و با
`moav admin password` قابل تغییر است:

| | نشانی | ورود |
|---|---|---|
| **پنل مدیریت** | `https://your-server:9443` | هر نام کاربری — فقط رمز بررسی می‌شود |
| **Grafana** | `https://your-server:9444` | کاربر `admin` |

**پروفایل‌ها:** `proxy`، `wireguard`، `amneziawg`، `dnstunnel`، `trusttunnel`، `telegram`، `xhttp`، `admin`، `conduit`، `snowflake`، `gooserelay`، `monitoring`، `all`

**انتقال به سرور جدید:** `moav export`، بعد روی سرور تازه `moav import moav-backup-*.tar.gz`
و `moav migrate-ip <new-ip>`. مرحله‌به‌مرحله در [راهنمای نصب](https://moav.sh/docs/SETUP#server-migration).

**Psiphon Conduit:** به‌محض اجرای `conduit`، از طریق استخر عمومی به کاربران Psiphon خدمت
می‌دهد و چیزی برای اشتراک‌گذاری نیست. `moav conduit link` یک لینک/QR خصوصی برای افراد
مشخص می‌سازد؛ این لینک کلید خصوصی را در خود دارد، پس فقط از راه Personal Pairing داخل Ryve
به اشتراک بگذارید. [Psiphon Conduit](https://moav.sh/docs/protocols#psiphon-conduit) را ببینید.

همهٔ فرمان‌ها، گزینه‌ها و متغیرهای محیطی: **[مرجع خط فرمان](https://moav.sh/docs/CLI)**.

<a id="clients"></a>

## اپلیکیشن‌های کاربر

| سیستم‌عامل | اپلیکیشن‌های پیشنهادی |
|----------|------------------|
| iOS | Happ، Streisand، Hiddify، WireGuard، Shadowrocket |
| Android | Happ، v2rayNG، Hiddify، WireGuard، NekoBox |
| macOS | Happ، Hiddify، Streisand، WireGuard |
| Windows | Happ، v2rayN، Hiddify، WireGuard |
| Linux | Hiddify، sing-box، WireGuard |

فهرست کامل و دستور راه‌اندازی در [راهنمای اپلیکیشن‌های کاربر](https://moav.sh/docs/CLIENTS)،
یا [**moav-client**](https://github.com/MotherofallVPNs/moav-client)
([مستندات](https://moav.sh/docs/client)) برای کلاینت دسکتاپ/خط فرمان با جابه‌جایی خودکار.

<a id="docs"></a>

## مستندات

مستندات کامل: **[moav.sh/docs](https://moav.sh/docs/)**

**راه‌اندازی** — [شروع سریع](https://moav.sh/docs/quick-start) · [راهنمای نصب](https://moav.sh/docs/SETUP) · [راه‌اندازی روی VPS](https://moav.sh/docs/DEPLOY) · [تنظیمات DNS](https://moav.sh/docs/DNS)

**درک پروژه** — [پروتکل‌های پشتیبانی‌شده](https://moav.sh/docs/protocols) · [معماری](https://moav.sh/docs/architecture) · [مدل تهدید](https://moav.sh/docs/threat-model) · [مأموریت](https://moav.sh/docs/mission) · [فلسفه](https://moav.sh/docs/philosophy)

**اتصال کاربران** — [اپلیکیشن‌های کاربر](https://moav.sh/docs/CLIENTS) · [واردکردن در MahsaNG](https://moav.sh/docs/mahsanet) · [کلاینت MoaV](https://moav.sh/docs/client)

**بهره‌برداری** — [مرجع خط فرمان](https://moav.sh/docs/CLI) · [مانیتورینگ](https://moav.sh/docs/MONITORING) · [عیب‌یابی](https://moav.sh/docs/TROUBLESHOOTING) · [راهنمای OPSEC](https://moav.sh/docs/OPSEC)

**مشارکت** — [توسعه و تست](https://moav.sh/docs/development) · [ترجمهٔ مستندات](https://moav.sh/docs/TRANSLATING) · [حمایت از MoaV](https://moav.sh/docs/support)

**برای عامل‌های هوش مصنوعی** — [AGENTS.md](AGENTS.md) برای کار در این مخزن، [llms.txt](https://moav.sh/llms.txt) به‌عنوان فهرست فشرده، و [llms-full.txt](https://moav.sh/llms-full.txt) برای کل مستندات.

<a id="requirements"></a>

## پیش‌نیازها

**سرور:**
- Debian 12، Ubuntu 22.04 یا 24.04
- کمینه ۱ هستهٔ پردازنده و ۱ گیگابایت رم (۲ هسته و ۲ گیگابایت در صورت استفاده از مانیتورینگ)
- IPv4 عمومی
- دامنه (اختیاری — بخش بعد را ببینید)

**پورت‌ها (به‌اندازهٔ نیاز باز کنید):**
| پورت | پروتکل | سرویس | نیاز به دامنه |
|------|----------|---------|-----------------|
| 443/tcp | TCP | Reality (VLESS) | خیر — از یک SNI عمومی با `REALITY_TARGET` استفاده می‌کند |
| 443/udp | UDP | Hysteria2 | بله |
| 8443/tcp | TCP | Trojan | بله |
| 8445/tcp | TCP | AnyTLS | بله |
| 8388/tcp+udp | TCP+UDP | Shadowsocks-2022 | خیر |
| 4443/tcp+udp | TCP+UDP | TrustTunnel | بله |
| 2082/tcp | TCP | CDN WebSocket | Cloudflare: بله · CloudFront: خیر |
| 51820/udp | UDP | WireGuard | خیر |
| 51821/udp | UDP | AmneziaWG | خیر |
| 8080/tcp | TCP | wstunnel | خیر |
| 993/tcp | TCP | Telegram MTProxy | خیر |
| 2096/tcp | TCP | XHTTP (VLESS+XHTTP+Reality) | خیر |
| 8444/tcp | TCP | GooseRelay exit (when `ENABLE_GOOSERELAY=true`) | خیر |
| 9443/tcp | TCP | Admin dashboard | خیر |
| 9444/tcp | TCP | Grafana (monitoring) | خیر |
| 53/udp | UDP | DNS tunnels (dnstt / Slipstream / MasterDNS / XDNS — all share this port) | بله |
| 80/tcp | TCP | Let's Encrypt | بله (در زمان نصب) |

<a id="domainless"></a>

## اجرا بدون دامنه

دامنه ندارید؟ MoaV می‌تواند در **حالت بی‌دامنه** اجرا شود با:
- **Reality** (VLESS+Reality، پروتکل اصلی)
- **XHTTP** (VLESS+XHTTP+Reality روی Xray-core)
- **WireGuard** (UDP مستقیم و تونل WebSocket)
- **AmneziaWG** (WireGuard مبهم‌شده، مقاوم در برابر امضاهای رایج DPI)
- **Shadowsocks-2022** (AEAD-2022، بدون نیاز به گواهی)
- **Telegram MTProxy** (fake-TLS، دسترسی مستقیم به تلگرام)
- **GooseRelay** (SOCKS5 روی Google Apps Script — بدون دامنه)
- **پنل مدیریت** (با گواهی خودامضا)
- **Conduit** (اهدای پهنای‌باند به Psiphon)
- **Snowflake** (اهدای پهنای‌باند به Tor)

`moav` را اجرا کنید و در پرسش دامنه گزینهٔ «بدون دامنه» را انتخاب کنید، یا از `moav domainless` استفاده کنید.

<a id="structure"></a>

## ساختار پروژه

```
MoaV/
├── moav.sh              # خط فرمان: تفسیر آرگومان‌ها و رفتن به تابع cmd_*
├── lib/                 # ۱۵ ماژول سمت میزبان — service، users، bootstrap، doctor،
│                        #   cert، migrate، donate، nettune، dns، peers، menu، …
├── scripts/             # نقطهٔ ورود کانتینرها و آماده‌سازی
│   ├── *-entrypoint.sh  #   یکی برای هر سرویس
│   └── lib/             #   کتابخانه‌های مشترک، سوارشده در کانتینرها روی /app/lib
├── configs/             # فایل‌های *.template (در گیت) که به *.json/*.conf رندر می‌شوند (بیرون از گیت)
├── dockerfiles/         # ساخت ایمیج‌ها، یکی برای هر سرویس
├── exporters/           # exporter‌های Prometheus (sing-box، xray، wireguard، amneziawg، …)
├── dns-router/          # دیمن Go که پورت ۵۳ را بین چهار تونل DNS پخش می‌کند
├── admin/               # پنل FastAPI
├── web/                 # وب‌سایت پوششی
├── data/                # protocols.json — فهرست مرجع پروتکل‌ها
├── tests/               # مجموعهٔ تست، هر کدام به نام دسته‌ای از باگ که مهار می‌کند
├── docs/devdocs/        # مستندات مشارکت‌کننده (مستندات کاربر در moav-site است)
├── docker-compose.yml
└── .env.example         # مرجع تنظیمات با توضیح؛ متغیرهای پرکاربرد در بالا
```

`moav.sh` فقط توزیع‌کنندهٔ فرمان‌هاست — منطق در `lib/` است. پوشه‌های `outputs/` (بسته‌های
کاربران) و `state/` (کلیدها) ساخته می‌شوند و در گیت نیستند.

<a id="security"></a>

## امنیت

- همهٔ پروتکل‌ها احراز هویت می‌خواهند
- وب‌سایت پوششی برای ترافیک بدون اعتبارنامه
- اعتبارنامهٔ مستقل برای هر کاربر با امکان لغو فوری
- لاگ حداقلی (بدون URL، بدون محتوا)
- TLS 1.3 در همه جا

**سطح دسترسی کانتینرها.** دسترسی به Docker API محدود به یک پروکسی سوکت فیلترشده روی یک
شبکهٔ مدیریتی جداست، و exporter‌های مانیتورینگ به‌جای سوکت، فایل‌های وضعیت منتشرشده را
می‌خوانند. تنها استثنای پذیرفته‌شده **cAdvisor** است (پروفایل اختیاری `monitoring`): آمار
پردازنده/حافظه/دیسک هر کانتینر به حالت privileged با mount‌های فقط‌خواندنی نیاز دارد، که
همان شیوهٔ استقرار بالادستی خودش است. اگر این معاوضه برایتان قابل قبول نیست، بدون پروفایل
مانیتورینگ اجرا کنید.

[راهنمای OPSEC](https://moav.sh/docs/OPSEC) را برای اصول امنیتی ببینید.

<a id="support"></a>

## حمایت از پروژه

**سرور راه بیندازید.** مؤثرترین کاری که می‌توانید بکنید. هر سرور MoaV ظرفیتی است که پیش‌تر
وجود نداشت — برای خانواده‌تان، همکارانتان، یا کسانی که هرگز نمی‌بینید. هیچ‌کس به‌جای شما
زیرساخت نمی‌گرداند؛ این شبکه *همان* آدم‌هایی است که سرور می‌گردانند. یک VPS پنج‌دلاری یا یک
Raspberry Pi کافی است.

**ظرفیتی که همین حالا دارید را اهدا کنید.** می‌توانید بدون داشتن کاربر، برای شبکه‌های دیگر
عبور از سانسور رله کنید — `moav start conduit` (Psiphon) و `moav start snowflake` (Tor)،
هر دو اختیاری و سقف‌دار. یا با `moav donate` کانفیگ به [MahsaNet](https://www.mahsaserver.com/)
اهدا کنید، که آن‌ها را به کاربران ایرانی می‌رساند که خودشان نمی‌توانند سرور راه بیندازند.

**کد بنویسید یا ترجمه کنید.** باگ، پروتکل، بسته‌بندی، مستندات — [توسعه و تست](https://moav.sh/docs/development)
را ببینید. ترجمه مفیدترین مشارکت غیرکدنویسی است: مستندات برای فارسی و روسی آماده شده و
ترجمهٔ یک صفحه هم یک مشارکت کامل است ([راهنمای ترجمه](https://moav.sh/docs/TRANSLATING)).
گزارش باگ هم به‌حساب می‌آید — یک گزارش قابل‌بازتولید همراه خروجی `moav doctor` معمولاً از
خود رفع اشکال زحمت بیشتری دارد.

> هرگز بستهٔ کاربر، محتوای `.env` یا لینک اشتراک را در یک issue نگذارید — این‌ها کلید زندهٔ در آن‌ها هست.

**هزینهٔ زیرساخت را تأمین کنید.** سرورهای تست برای مجموعهٔ تست سرتاسری، دامنه‌ها و ظرفیت
ساخت. نه حقوق و دستمزد.

<!-- FUNDING:START -->
| پلتفرم | لینک |
|---|---|
| **GitHub Sponsors** | [github.com/sponsors/shayanb](https://github.com/sponsors/shayanb) |
| **Buy Me a Coffee** | [buymeacoffee.com/pangana](https://buymeacoffee.com/pangana) |

| ارز | نشانی |
|---|---|
| **Bitcoin (BTC)** | `bc1p6rpwzkgrlvpkre0n94fqayafpw47kl2j5lmvhvl0rfrtzm94wvvsmd3w5s` |
| **Ethereum (ETH)** ¹ | `0xB4D06BDb0C2f1D81E0b0b805Ed813F4ffe960aE2` |
| **Monero (XMR)** | `8BmduJgZLok9xiaX8FboSWBBbzYAugqLxUts7eZNsF2x9QDhk3Ua7iwQufBBNB8VFzcMEMAE1Uo6PjQvAYNYHmXsBRbqQqG` |
| **Zcash (ZEC)** | `u1pclheucppc87qlffh9m8wjfw87w2nka40w9nxjuqnyppj0kx9xp7z9rg6wx556662y5f8dtfyeynmm2lnz5aqvaqzmnpajlq0mnmkntdqzqqegk8lwv09cnudf3ttzm3878p3030j3lwupj257rmmv9p3ea32hgwsuf3jdh8ycv7q587` |
| **Lightning** | `lno1zrxq8pjw7qjlm68mtp7e3yvxee4y5xrgjhhyf2fxhlphpckrvevh50u0q0zdgjjahpdv7tnd9vstumyrw43snsmfmlzv0pgkqrjkgy48tsne6qsr0k64d8rz4k394pmre2rgnmstdxqsfj0w4dsmq2ec73ssek5wzqtqqv7argu9ptk09h9vfvvvham5xnwe306zjw6lptxx0d2yfk5rlvznjwefmsrmmpu8qnkqmghe0v96c8qy3m3nqgm977ay8f5p6k2d2ll2j3knnc8c4s6haufe203jx4ufy8z25tsscqqseg8jzh2qykejnc9sp2v4qm3z2q` |
| **Lightning Address** | `shayan@bitrefill.me` |
| **Tron** ² | `TBSCbnTZCELrMnioobZMkah5r9qS6B1tC6` |

¹ **Ethereum (ETH)** — همین نشانی روی همهٔ زنجیره‌های EVM کار می‌کند و برای هر توکن ERC-20

² **Tron** — فقط TRX و TRC-20 — با نشانی EVM بالا یکی نیست
<!-- FUNDING:END -->

نشانی‌ها از [`.github/FUNDING.yml`](.github/FUNDING.yml) ساخته می‌شوند، که تنها مرجع است، پس
آنچه اینجا می‌بینید همان است که در آن فایل نوشته شده. نشانی را از همین صفحه یا از مخزن روی
HTTPS بردارید و بعد از چسباندن، چند نویسهٔ اول و آخرش را بررسی کنید.
**ما هرگز نشانی را برایتان دایرکت نمی‌فرستیم.**

<a id="community"></a>

## جامعه

- **تلگرام:** [t.me/motherofallvpns](https://t.me/motherofallvpns) — پرسش، کمک و اطلاع‌رسانی نسخه‌ها
- **X:** [@motherofallvpns](https://x.com/motherofallvpns)
- **Issues:** [GitHub Issues](https://github.com/MotherofallVPNs/MoaV/issues) برای باگ و پیشنهاد ویژگی
- **مستندات:** [moav.sh/docs](https://moav.sh/docs)

<a id="related"></a>

## پروژه‌های مرتبط

MoaV یک لایهٔ استقرار است. کار روی خود پروتکل‌ها به این پروژه‌ها تعلق دارد:

**کلاینت همراه** — [moav-client](https://github.com/MotherofallVPNs/moav-client): کلاینت
دسکتاپ/خط فرمان که اشتراک MoaV را می‌خواند، هر نقطهٔ اتصال را از تونل خودش آزمایش می‌کند و
از سالم‌ترین و سریع‌ترین مسیر عبور می‌دهد ([مستندات](https://moav.sh/docs/client)).

**موتورهای پروتکل**

| پروژه | MoaV از آن برای چه استفاده می‌کند |
|---|---|
| [sing-box](https://github.com/SagerNet/sing-box) | Reality، Trojan، AnyTLS، Hysteria2، Shadowsocks-2022، CDN VLESS+WS |
| [Xray-core](https://github.com/XTLS/Xray-core) | XHTTP و XDNS |
| [REALITY](https://github.com/XTLS/REALITY) | پوشش TLS که Reality و XHTTP روی آن ساخته شده‌اند |
| [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-go) · [ابزارها](https://github.com/amnezia-vpn/amneziawg-tools) | WireGuard مقاوم در برابر DPI |
| [WireGuard](https://www.wireguard.com/) | VPN مستقیم روی UDP |
| [wstunnel](https://github.com/erebe/wstunnel) | WireGuard روی `wss://` وقتی UDP بسته است |
| [TrustTunnel](https://github.com/TrustTunnel/TrustTunnel) · [کلاینت](https://github.com/TrustTunnel/TrustTunnelClient) | ترابرد HTTP/2 و QUIC |
| [telemt](https://github.com/telemt/telemt) | Telegram MTProxy (fake-TLS) |
| [dnstt](https://www.bamsoftware.com/software/dnstt/) | تونل DNS اصلی |
| [Slipstream](https://github.com/net2share/slipstream-rust-build) | QUIC روی DNS |
| [MasterDNS](https://github.com/masterking32/MasterDnsVPN) | تونل DNS با ARQ و توزیع بار روی resolver‌ها |
| [GooseRelay](https://github.com/kianmhz/GooseRelayVPN) | SOCKS5 روی Google Apps Script |

**شبکه‌هایی که می‌توانید به آن‌ها ظرفیت اهدا کنید**

| پروژه | |
|---|---|
| [Psiphon Conduit](https://github.com/Psiphon-Inc/conduit) | رله برای کاربران Psiphon |
| [Tor Snowflake](https://snowflake.torproject.org/) | رله برای کاربران Tor |
| [MahsaNet](https://www.mahsaserver.com/) · [MahsaNG](https://github.com/GFW-knocker/MahsaNG) | اهدای کانفیگ و کلاینتی که بیشتر کاربران ایرانی دارند |

**مانیتورینگ** — [Prometheus](https://github.com/prometheus/prometheus)، [Grafana](https://github.com/grafana/grafana)،
[node_exporter](https://github.com/prometheus/node_exporter)، [cAdvisor](https://github.com/google/cadvisor).

نسخه‌های پین‌شدهٔ همهٔ این‌ها در [`.env.example`](.env.example) است.

## مجوز

MIT

## تغییرات
[CHANGELOG.md](CHANGELOG.md) را برای یادداشت نسخه‌ها و تاریخ تغییرات ببینید.

---
## سلب مسئولیت

این پروژه فقط **نرم‌افزار شبکه‌ای آزاد و همه‌منظوره** ارائه می‌کند.

این یک سرویس نیست، یک پلتفرم نیست، و یک شبکهٔ تحت بهره‌برداری نیست.

نویسندگان و مشارکت‌کنندگان:
- زیرساختی نمی‌گردانند
- دسترسی ارائه نمی‌دهند
- اعتبارنامه توزیع نمی‌کنند
- کاربری را مدیریت نمی‌کنند
- استقراری را هماهنگ نمی‌کنند

همهٔ استفاده، استقرار و بهره‌برداری تنها بر عهدهٔ اشخاص ثالث است.

این نرم‌افزار **«همان‌گونه که هست»** ارائه می‌شود، بدون هیچ‌گونه ضمانت.
نویسندگان و مشارکت‌کنندگان **هیچ مسئولیتی** در قبال استفاده یا سوءاستفاده از آن نمی‌پذیرند.

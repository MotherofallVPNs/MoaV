<div dir="rtl">

# MoaV

[![Website](https://img.shields.io/badge/website-moav.sh-cyan.svg)](https://moav.sh)  [![Docs](https://img.shields.io/badge/docs-moav.sh%2Fdocs-cyan.svg)](https://moav.sh/docs/)  [![Version](https://img.shields.io/badge/version-1.8.2-blue.svg)](CHANGELOG.md)  [![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**[English](README.md)** | فارسی

استک عبور از سانسور چند پروتکلی بهینه‌سازی شده برای محیط‌های شبکه‌ای خصمانه.

## ویژگی‌ها

- **پروتکل‌های متعدد** — ۱۶+ پروتکل برای هر سناریوی سانسور:
  - **پروکسی با پنهان‌کاری بالا** — Reality (VLESS)، Trojan، Hysteria2، XHTTP (VLESS+XHTTP+Reality)، CDN (VLESS+WS از طریق Cloudflare)
  - **VPN کامل** — WireGuard (مستقیم و wstunnel)، AmneziaWG
  - **تخصصی** — TrustTunnel (HTTP/2+QUIC)، Telegram MTProxy (Fake-TLS)، Shadowsocks-2022، GooseRelay (SOCKS5 از طریق Google Apps Script)
  - **تونل‌های DNS** — dnstt، Slipstream، MasterDNS و XDNS — همه چهار تونل به‌صورت هم‌زمان روی پورت ۵۳ از طریق `dns-router` کار می‌کنند
- **اولویت پنهان‌کاری** - تمام ترافیک شبیه HTTPS معمولی، WebSocket، DNS، یا IMAPS به نظر می‌رسد
- **اعتبارنامه‌های جداگانه برای هر کاربر** - ایجاد، لغو و مدیریت کاربران به صورت مستقل
- **نصب آسان** - مبتنی بر Docker Compose، راه‌اندازی با یک دستور
- **سازگار با موبایل** - کدهای QR و لینک‌ها برای وارد کردن آسان در کلاینت
- **وب‌سایت پوششی** - ارائه محتوای بی‌خطر به بازدیدکنندگان احراز هویت نشده
- **قابل نصب در خانه** - اجرا روی Raspberry Pi یا هر سیستم لینوکس ARM64/x64 به عنوان VPN شخصی
- **[Psiphon Conduit](https://github.com/Psiphon-Inc/conduit)** - اهدای پهنای باند اختیاری برای کمک به دیگران در عبور از سانسور
- **[Tor Snowflake](https://snowflake.torproject.org/)** - اهدای پهنای باند اختیاری برای کمک به کاربران Tor در عبور از سانسور
- **[MahsaNet](https://www.mahsaserver.com/)** - اهدای کانفیگ VPN به کاربران اپلیکیشن مهسا (۲+ میلیون کاربر در ایران)
- **مانیتورینگ** - Grafana + Prometheus برای نظارت بر عملکرد سرور (اختیاری)

> **[مستندات کامل](https://moav.sh/docs/)** — راهنمای نصب، مرجع دستورات، اپلیکیشن‌های کلاینت، مانیتورینگ، امنیت عملیاتی و موارد بیشتر.

## شروع سریع

**نصب با یک دستور** (پیشنهادی):

<div dir="ltr">

```bash
curl -fsSL moav.sh/install.sh | bash
```

</div>

این کار:
- پیش‌نیازها را نصب می‌کند (Docker، git، qrencode) در صورت نیاز
- MoaV را در `/opt/moav` کلون می‌کند
- دامنه، ایمیل و رمز عبور ادمین را درخواست می‌کند
- پیشنهاد نصب سراسری دستور `moav` را می‌دهد
- نصب تعاملی را راه‌اندازی می‌کند

**نصب دستی** (جایگزین):

<div dir="ltr">

```bash
git clone https://github.com/MotherofallVPNs/moav.git
cd moav
cp .env.example .env
nano .env  # تنظیم DOMAIN، ACME_EMAIL، ADMIN_PASSWORD
./moav.sh
```

</div>

<img src="docs/assets/moav.sh.png" alt="منوی تعاملی MoaV" width="400">

**پس از نصب، از هر مکانی از `moav` استفاده کنید:**

<div dir="ltr">

```bash
moav                      # منوی تعاملی
moav start                # شروع سرویس‌ها
moav status               # نمایش وضعیت سرویس‌ها
moav user add alice       # افزودن کاربر (کانفیگ + QR code)
moav user add --batch 10  # ساخت دسته‌ای کاربران
moav donate               # اهدای کانفیگ به MahsaNet/Psiphon/Snowflake
moav doctor               # تشخیص مشکلات (DNS، پورت‌ها، سرویس‌ها)
moav update               # به‌روزرسانی MoaV
moav admin password       # تغییر رمز ادمین/Grafana
moav help                 # نمایش تمام دستورات
```

</div>

برای دستورالعمل‌های کامل نصب به [راهنمای نصب](docs/SETUP.md)، برای لیست دستورات به [مرجع دستورات](docs/CLI.md)، یا [مستندات کامل](https://moav.sh/docs/) مراجعه کنید.

### راه‌اندازی سرور خود

[![Deploy on Hetzner](https://img.shields.io/badge/نصب%20روی-Hetzner-d50c2d?style=for-the-badge&logo=hetzner&logoColor=white)](docs/DEPLOY.md#hetzner)
[![Deploy on Linode](https://img.shields.io/badge/نصب%20روی-Linode-00a95c?style=for-the-badge&logo=linode&logoColor=white)](docs/DEPLOY.md#linode)
[![Deploy on Vultr](https://img.shields.io/badge/نصب%20روی-Vultr-007bfc?style=for-the-badge&logo=vultr&logoColor=white)](docs/DEPLOY.md#vultr)
[![Deploy on DigitalOcean](https://img.shields.io/badge/نصب%20روی-DigitalOcean-0080ff?style=for-the-badge&logo=digitalocean&logoColor=white)](docs/DEPLOY.md#digitalocean)


## معماری

<div dir="ltr">

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

</div>

## پروتکل‌ها

| پروتکل | پورت | پنهان‌کاری | سرعت | پیش‌فرض | کاربرد |
|--------|------|---------|-------|---------|--------|
| Reality (VLESS) | 443/tcp | ★★★★★ | ★★★★☆ | ✅ | اصلی، قابل اعتمادترین |
| Hysteria2 | 443/udp | ★★★★☆ | ★★★★★ | ✅ | سریع، کار می‌کند وقتی TCP محدود است |
| Trojan | 8443/tcp | ★★★★☆ | ★★★★☆ | ✅ | پشتیبان، از دامنه شما استفاده می‌کند |
| AnyTLS | 8445/tcp | ★★★★★ | ★★★★☆ | ⬜ | خنثی‌سازی اثرانگشت TLS-in-TLS، از دامنه شما استفاده می‌کند |
| Shadowsocks-2022 | 8388/tcp+udp | ★★★★☆ | ★★★★☆ | ⬜ | AEAD-2022 ضد پروب فعال؛ سازگار با اپ Outline |
| CDN (VLESS+WS) | 443 از Cloudflare | ★★★★★ | ★★★☆☆ | ✅ | وقتی IP سرور مسدود است |
| TrustTunnel | 4443/tcp+udp | ★★★★★ | ★★★★☆ | ✅ | HTTP/2 و QUIC، شبیه HTTPS |
| WireGuard (مستقیم) | 51820/udp | ★★★☆☆ | ★★★★★ | ✅ | VPN کامل، نصب ساده |
| AmneziaWG | 51821/udp | ★★★★★ | ★★★★☆ | ✅ | وایرگارد مبهم‌سازی شده، دور زدن DPI |
| WireGuard (wstunnel) | 8080/tcp | ★★★★☆ | ★★★★☆ | ✅ | VPN وقتی UDP مسدود است |
| تونل DNS (dnstt) | 53/udp | ★★★☆☆ | ★☆☆☆☆ | ✅ | آخرین راه‌حل، سخت برای مسدود کردن |
| Slipstream | 53/udp | ★★★☆☆ | ★★☆☆☆ | ✅ | QUIC-over-DNS، ۱.۵-۵ برابر سریعتر از dnstt |
| MasterDNS | 53/udp | ★★★☆☆ | ★★★☆☆ | ✅ | تونل DNS پیشرفته (ARQ + تعادل بار)، مهسا v16 |
| XDNS (VLESS+mKCP+DNS) | 53/udp | ★★★☆☆ | ★☆☆☆☆ | ✅ | تونل DNS با FinalMask؛ هر ۴ تونل DNS پورت ۵۳ را شریک می‌شوند |
| GooseRelay | 8444/tcp | ★★★★★ | ★★☆☆☆ | ⬜ | SOCKS5 از طریق Google Apps Script، مهسا v16 |
| Telegram MTProxy | 993/tcp | ★★★★☆ | ★★★☆☆ | ✅ | Fake-TLS V2، دسترسی مستقیم به تلگرام |
| XHTTP (VLESS+XHTTP+Reality) | 2096/tcp | ★★★★★ | ★★★★☆ | ✅ | Xray-core، بدون نیاز به دامنه |
| Psiphon Conduit | — | — | — | ⬜ | اهدای پهنای باند به Psiphon (۲+ میلیون کاربر) |
| Tor Snowflake | — | — | — | ⬜ | اهدای پهنای باند به شبکه Tor |
| MahsaNet | — | — | — | ⬜ | اهدای کانفیگ VPN به مهسا VPN (۲+ میلیون کاربر) |

## مدیریت کاربران

<div dir="ltr">

```bash
moav user list            # لیست تمام کاربران
moav user add joe         # افزودن کاربر به تمام پروتکل‌ها
moav user add alice bob   # افزودن چند کاربر
moav user add --batch 10 --prefix team  # ساخت دسته‌ای team01..team10
moav user revoke joe      # لغو دسترسی کاربر
moav user package joe     # ایجاد فایل zip
```

</div>

هر کاربر یک بسته در `outputs/bundles/<username>/` دریافت میکنه شامل فایل کانفیگ، QR code و راهنمای README.html.

**دانلود بسته‌ها** از داشبورد ادمین در `https://سرور:9443` یا با SCP.

## داشبورد ادمین و مانیتورینگ

- **داشبورد ادمین**: `https://سرور:9443` — مدیریت کاربران، وضعیت سرویس‌ها، اهدای MahsaNet
- **Grafana**: `https://سرور:9444` — ترافیک هر کاربر، تفکیک پروتکل‌ها، توزیع جغرافیایی
- **نام کاربری**: `admin` | **رمز عبور**: هنگام نصب تنظیم میشه (در `.env` با نام `ADMIN_PASSWORD`)
- **تغییر رمز**: `moav admin password`

## مدیریت سرویس‌ها

<div dir="ltr">

```bash
moav status               # نمایش وضعیت تمام سرویس‌ها
moav start                # شروع سرویس‌ها
moav start proxy admin    # شروع پروفایل‌های خاص
moav stop                 # توقف تمام سرویس‌ها
moav restart sing-box     # راه‌اندازی مجدد سرویس خاص
moav logs sing-box        # مشاهده لاگ‌های سرویس
moav doctor               # تشخیص مشکلات
moav doctor dns           # بررسی تنظیمات DNS
moav donate               # اهدای کانفیگ به MahsaNet/Psiphon/Snowflake
```

</div>

**پروفایل‌ها:** `proxy`، `wireguard`، `amneziawg`، `dnstunnel`، `trusttunnel`، `telegram`، `xhttp`، `admin`، `conduit`، `snowflake`، `monitoring`، `all`

## مهاجرت سرور

خروجی گرفتن و انتقال MoaV به سرور جدید:

<div dir="ltr">

```bash
# خروجی کامل (کلیدها، کاربران، تنظیمات)
moav export                        # ایجاد moav-backup-TIMESTAMP.tar.gz

# در سرور جدید: وارد کردن و به‌روزرسانی IP
moav import moav-backup-*.tar.gz   # بازیابی تنظیمات
moav migrate-ip 1.2.3.4            # به‌روزرسانی همه تنظیمات با IP جدید
moav start                         # شروع سرویس‌ها
```

</div>

برای جزئیات بیشتر به [docs/SETUP.md](docs/SETUP.md#server-migration) مراجعه کنید.

MoaV شامل یک کانتینر کلاینت داخلی برای تست اتصال و اتصال از طریق سرور شماست.
## تست

<div dir="ltr">

```bash
moav test user1           # تست تمام پروتکل‌ها برای یک کاربر
moav test user1 -v        # خروجی مفصل برای دیباگ
moav client connect user1 # اتصال به عنوان کاربر (پراکسی SOCKS5/HTTP محلی)
```

</div>

## اپلیکیشن‌های کلاینت

| پلتفرم | اپلیکیشن‌های توصیه شده |
|--------|----------------------|
| iOS | Happ، Streisand، Hiddify، WireGuard، Shadowrocket |
| Android | Happ، v2rayNG، Hiddify، WireGuard، NekoBox |
| macOS | Happ، Hiddify، Streisand، WireGuard |
| Windows | Happ، v2rayN، Hiddify، WireGuard |
| Linux | Hiddify، sing-box، WireGuard |

برای دستورالعمل‌های راه‌اندازی به [docs/CLIENTS.md](docs/CLIENTS.md) مراجعه کنید.

## مستندات

- [راهنمای نصب](docs/SETUP.md) - دستورالعمل‌های کامل نصب
- [مرجع CLI](docs/CLI.md) - تمام دستورات و گزینه‌های moav
- [پیکربندی DNS](docs/DNS.md) - تنظیم رکوردهای DNS
- [راه‌اندازی کلاینت](docs/CLIENTS.md) - نحوه اتصال از دستگاه‌ها
- [نصب روی VPS](docs/DEPLOY.md) - نصب یک‌کلیکی روی سرور ابری
- [مانیتورینگ](docs/MONITORING.md) - Grafana + Prometheus برای نظارت
- [عیب‌یابی](docs/TROUBLESHOOTING.md) - مشکلات رایج و راه‌حل‌ها
- [راهنمای امنیت عملیاتی](docs/OPSEC.md) - بهترین روش‌های امنیتی

## پیش‌نیازها

**سرور:**
- Debian 12، Ubuntu 22.04/24.04
- حداقل 1 vCPU، 1 GB RAM (2 vCPU، 2 GB RAM برای مانیتورینگ)
- IPv4 عمومی
- نام دامنه (اختیاری - حالت بدون دامنه را ببینید)

**پورت‌ها (در صورت نیاز باز کنید):**

| پورت | پروتکل | سرویس | نیاز به دامنه |
|------|--------|-------|---------------|
| 443/tcp | TCP | Reality (VLESS) | بله |
| 443/udp | UDP | Hysteria2 | بله |
| 8443/tcp | TCP | Trojan | بله |
| 8445/tcp | TCP | AnyTLS | بله |
| 8388/tcp+udp | TCP+UDP | Shadowsocks-2022 | خیر |
| 4443/tcp+udp | TCP+UDP | TrustTunnel | بله |
| 2082/tcp | TCP | CDN WebSocket | بله (Cloudflare) |
| 51820/udp | UDP | WireGuard | خیر |
| 51821/udp | UDP | AmneziaWG | خیر |
| 8080/tcp | TCP | wstunnel | خیر |
| 993/tcp | TCP | Telegram MTProxy | خیر |
| 2096/tcp | TCP | XHTTP (VLESS+XHTTP+Reality) | خیر |
| 9443/tcp | TCP | داشبورد ادمین | خیر |
| 9444/tcp | TCP | Grafana (مانیتورینگ) | خیر |
| 53/udp | UDP | تونل‌های DNS (dnstt / Slipstream / MasterDNS / XDNS — همه پورت ۵۳ را شریک می‌شوند) | بله |
| 8444/tcp | TCP | GooseRelay (وقتی `ENABLE_GOOSERELAY=true`) | خیر |
| 80/tcp | TCP | Let's Encrypt | بله (هنگام نصب) |

### حالت بدون دامنه

دامنه ندارید؟ MoaV می‌تواند در **حالت بدون دامنه** با سرویس‌های زیر اجرا شود:
- **Reality** (VLESS+Reality، پروتکل اصلی)
- **XHTTP** (VLESS+XHTTP+Reality، بدون نیاز به دامنه)
- **WireGuard** (UDP مستقیم + تونل WebSocket)
- **AmneziaWG** (وایرگارد مبهم‌سازی شده، دور زدن DPI)
- **Telegram MTProxy** (Fake-TLS، دسترسی مستقیم به تلگرام)
- **داشبورد ادمین** (با گواهی خودامضا)
- **Conduit** (اهدای پهنای باند Psiphon)
- **Snowflake** (اهدای پهنای باند Tor)

دستور `moav` را اجرا کنید و وقتی پرسیده شد "بدون دامنه" را انتخاب کنید، یا از `moav domainless` استفاده کنید.

**VPS توصیه شده:**
- VPS Price Trackers: [VPS-PRICES](https://vps-prices.com/)، [VPS Price Tracker](https://vpspricetracker.com/), [Cheap VPS Price Cheat Sheet](https://docs.google.com/spreadsheets/d/e/2PACX-1vTOC_THbM2RZzfRUhFCNp3SDXKdYDkfmccis4vxr7WtVIcPmXM-2lGKuZTBr8o_MIJ4XgIUYz1BmcqM/pubhtml)
- [Time4VPS](https://www.time4vps.com/?affid=8471): 1 vCPU، 1GB RAM، IPv4، 3.99€/ماه 

## ساختار پروژه

<div dir="ltr">

```
MoaV/
├── moav.sh                 # ابزار مدیریت CLI (نصب با: ./moav.sh install)
├── docker-compose.yml      # فایل compose اصلی
├── .env.example            # قالب متغیرهای محیطی
├── Dockerfile.*            # تعاریف کانتینر
├── configs/                # پیکربندی‌های سرویس‌ها
│   ├── sing-box/
│   ├── wireguard/
│   ├── amneziawg/
│   ├── trusttunnel/
│   ├── dnstt/
│   ├── masterdns/
│   ├── gooserelay/
│   ├── telemt/
│   └── monitoring/
├── scripts/                # اسکریپت‌های مدیریت
│   ├── bootstrap.sh
│   ├── user-add.sh
│   ├── user-revoke.sh
│   └── lib/
├── outputs/                # پیکربندی‌های تولید شده (gitignore شده)
│   └── bundles/
├── web/                    # وب‌سایت پوششی
├── admin/                  # داشبورد آمار
└── docs/                   # مستندات
```

</div>

## امنیت

- تمام پروتکل‌ها نیاز به احراز هویت دارند
- وب‌سایت پوششی برای ترافیک احراز هویت نشده
- اعتبارنامه‌های جداگانه برای هر کاربر با قابلیت لغو فوری
- حداقل لاگ‌گیری (بدون URL، بدون محتوا)
- TLS 1.3 همه جا

برای راهنمای امنیتی به [docs/OPSEC.md](docs/OPSEC.md) مراجعه کنید.

## مجوز

MIT

## تغییرات

برای یادداشت‌های انتشار و تاریخچه نسخه‌ها به [CHANGELOG.md](CHANGELOG.md) مراجعه کنید.

## سلب مسئولیت

این پروژه **فقط نرم‌افزار شبکه متن‌باز با کاربرد عمومی** ارائه می‌دهد.

این یک سرویس، پلتفرم، یا شبکه عملیاتی نیست.

نویسندگان و مشارکت‌کنندگان:
- زیرساختی را اداره نمی‌کنند
- دسترسی ارائه نمی‌دهند
- اعتبارنامه توزیع نمی‌کنند
- کاربران را مدیریت نمی‌کنند
- استقرارها را هماهنگ نمی‌کنند

تمام استفاده، استقرار و بهره‌برداری مسئولیت کامل اشخاص ثالث است.

این نرم‌افزار **«همانطور که هست»** ارائه می‌شود، بدون هیچ گونه ضمانتی.
نویسندگان و مشارکت‌کنندگان **هیچ مسئولیتی** در قبال هرگونه استفاده یا سوء استفاده از این نرم‌افزار نمی‌پذیرند.

کاربران مسئول رعایت تمام قوانین و مقررات قابل اعمال هستند.

</div>

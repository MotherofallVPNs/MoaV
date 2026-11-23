# Donate mode

Donate mode creates **lightweight users whose configs are handed to another
network** (MahsaNet today) instead of to one of your own users. Those recipients
import a share link into a phone app — they never run a client daemon, never get
a tunnel device, and never control a DNS resolver.

That single fact decides what is donatable.

## What it is

Setting `DONATE_ONLY_PROTOCOLS` on a `user add` switches it into donate mode:

```bash
DONATE_ONLY_PROTOCOLS="reality hysteria2" ./scripts/user-add.sh alice
```

The value is a **space-separated list of protocol tokens**. Everything not in
that list is disabled for that user, so the bundle carries only what was asked
for.

## Who sets it

| Caller | Where | Source of the list |
|---|---|---|
| CLI | `lib/donate.sh` (`export DONATE_ONLY_PROTOCOLS`) | `MAHSANET_PROTOCOLS` in `.env`, default `"reality hysteria2"` |
| Admin dashboard | `admin/main.py`, MahsaNet batch endpoint | request body `protocols`, defaulting to `MAHSANET_PROTOCOLS` |

Both end at the same place: `scripts/user-add.sh`, the `DONATE_ONLY` block.

## Donatable vs not

**Donatable** — sing-box / xray protocols that travel as a single share link or
subscription entry:

`reality` · `trojan` · `anytls` · `hysteria2` · `shadowsocks` · `telegram` ·
`xhttp` · `cdn`

**Never donated**, forced off regardless of `.env`:

WireGuard · AmneziaWG · TrustTunnel · GooseRelay · dnstt · Slipstream (deprecated) ·
MasterDNS · XDNS

The reason is the same for all of them: each needs something the recipient
cannot get from a pasted link — a client-side daemon, a `wg`/`awg` tunnel
device, or an NS delegation pointed at your server. Donating one would produce a
config that looks valid and cannot connect.

`cdn` is the odd one out: it has no `ENABLE_` flag and is switched by clearing
`CDN_SUBDOMAIN`.

## Adding a protocol to donate mode

1. Confirm it is actually donatable by the test above: can a recipient use it
   with **only** a share link or subscription entry, no daemon and no DNS
   control? If not, stop — it belongs in the forced-off list.
2. Add a `_donated <token> && ENABLE_X=true || ENABLE_X=false` line to the
   donatable block in `scripts/user-add.sh`.
3. Make sure the generator honours `ENABLE_X` on **both** add paths —
   `scripts/singbox-user-add.sh` (host, what `moav user add` runs) and
   `scripts/generate-user.sh` (container/bootstrap). They drifted apart once and
   shipped protocols that were switched off;
   `tests/enable-flag-gating-test.sh` guards that now.
4. Add the token to `MAHSANET_PROTOCOLS` in `.env.example` only if it should be
   donated **by default**.
5. If the dashboard should offer it, it is already list-driven — the endpoint
   validates against the same set.

## Gotcha

Donate mode only sets the `ENABLE_*` variables. It relies on each generator
actually checking its flag. A generator that keys on "does this config file
exist" instead of its flag will keep producing configs in donate mode, because
those files are server-wide and survive the toggle. TrustTunnel had exactly that
bug: it was gated on `configs/trusttunnel/credentials.toml` existing.

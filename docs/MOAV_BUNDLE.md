# `moav://` compact bundle

Every user bundle's `subscription.txt` (the base64 V2Ray subscription) now
carries one extra line: a **`moav://` compact bundle** that encodes the user's
entire enabled proxy surface in a single URL. The legacy per-protocol URIs
(`vless://`, `trojan://`, …) stay exactly as before — the `moav://` line is
additive.

- **[moav-client](https://github.com/MotherofallVPNs/moav-client)** recognizes
  the line, expands it back into one endpoint per protocol, and **dedups it
  against the legacy URIs** (by protocol + address), so importing the
  subscription yields each server once, not twice.
- Every other client ignores the unknown `moav://` scheme and uses the legacy
  URIs. Nothing regresses.

Why: a MoaV subscription is N URIs that repeat the same host, UUID, Reality
keypair, and passwords. The `moav://` form factors the shared parts out once, so
it's far smaller and a shared-credential rotation is a one-line change.

## Where it comes from

`scripts/lib/moav-bundle.sh` → `moav_bundle_link <label> <host>` builds the URL
from the same environment the per-protocol share-link builders use
(`USER_UUID`, `USER_PASSWORD`, `REALITY_*`, `DOMAIN`, `CDN_*`,
`HYSTERIA2_OBFS_PASSWORD`, `SS_*`, `PORT_*`, `ENABLE_*`). `generate-user.sh`
calls it after building the per-protocol links, writes `moav-bundle.txt`, and
`bundle_readme.py` appends the line to `subscription.txt`. Golden test:
`tests/moav-bundle-test.sh`; the parse/round-trip contract is pinned in the
moav-client repo (`proxy-core/subscription/moavbundle_test.go`).

## Format

```
moav://<uuid>@<server-host>?<shared>&p=<record>&p=<record>…#<label>
```

- **`<uuid>`** (userinfo) — the VLESS UUID; applies to every `vless-*` record.
- **`<shared>`** — flat query params common to multiple protocols, each value
  percent-encoded: `pw`, `pbk`, `sid`, `sni_default`, `fp`, `ss_method`,
  `ss_pw`, `obfs_pw`.
- **`p=<record>`** — one per enabled protocol: `p=<name>,<port>[,k=v…]`. The
  commas and `=` inside a record are structural; sub-values are percent-encoded
  (the client url-decodes the whole record before splitting).

### Per-protocol records (gated by `ENABLE_*`, ports match the legacy links)

| Protocol | Record | Credentials read (shared) |
|---|---|---|
| Reality | `p=reality,443,sni=<REALITY_TARGET_HOST>,flow=xtls-rprx-vision` | `pbk`, `sid` |
| XHTTP | `p=vless-xhttp,<PORT_XHTTP>,sni=<xhttp target>,fp=chrome` | `pbk`, `sid` |
| CDN | `p=vless-ws` **or** `p=vless-httpupgrade` (per `CDN_TRANSPORT`) `,443,host=<CDN_ADDRESS>,path=<CDN_WS_PATH>,sni=<CDN_SNI>,alpn=http/1.1` | — |
| Trojan | `p=trojan,8443` | `pw`, `sni_default` |
| AnyTLS | `p=anytls,<PORT_ANYTLS>` | `pw`, `sni_default` |
| Hysteria2 | `p=hy2,443,obfs=salamander` | `pw`, `sni_default`, `obfs_pw` |
| Shadowsocks-2022 | `p=ss,<SS_PORT>` | `ss_method`, `ss_pw` (`server_psk:user_psk`) |

CDN's `host=` is the connection/fronting address; moav-client defaults the WS/
httpupgrade **Host header** to it, which is correct for the common case where
`CDN_ADDRESS == CDN_DOMAIN`.

### Encoding note

Values are percent-encoded so URL-specials survive — the reality `pbk` is base64
(`+`, `/`, `=`) and would otherwise corrupt. Structural separators (`?`, `&`,
`#`, the record commas, and each `key=`) are never encoded.

## Not driven by `data/protocols.json`

The emitter is a bash builder alongside the existing `singbox_*_link` /
`xray_*_link` share-link builders (the established single source for links),
rather than a `protocols.json`-driven generator — for consistency with those
builders and to keep the per-protocol credential mapping in one readable place.
Adding a protocol is one `if [[ "$ENABLE_X" ]]` block, mirroring how a protocol
gets its `singbox_x_link`.

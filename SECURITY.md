# Security Policy

MoaV is run by people in hostile network environments, so a security bug here
can put operators and their users at real risk. Please report vulnerabilities
privately and give us a chance to ship a fix before details become public.

## Supported versions

Security fixes land in the latest minor release. Older releases do not get
backports; the fix is to upgrade.

| Version | Supported |
|---|---|
| 2.4.x (latest) | ✅ |
| 2.0.x to 2.3.x | ❌ upgrade with `moav update`, then `moav apply` |
| 1.x | ❌ see [docs/V2-MIGRATION.md](docs/V2-MIGRATION.md) |

Run `moav version` to see what a server is on.

## Reporting a vulnerability

**Do not open a public issue, pull request or discussion for a security bug,
and do not post it in the Telegram group.**

1. **Preferred: GitHub Private Vulnerability Reporting.** Open the
   [Security tab](https://github.com/MotherofallVPNs/MoaV/security) and click
   **Report a vulnerability**
   ([direct link](https://github.com/MotherofallVPNs/MoaV/security/advisories/new)).
   The report is visible only to the maintainers, and we can work on the fix
   with you in a private fork.
2. **Fallback: email** `info@moav.sh` if you cannot use GitHub.
3. **PGP (optional):** key not published yet (TBD). Until it is, send only a
   short summary by email and we will agree on a secure channel for the details.

A useful report includes:

- the MoaV version (`moav version`) and the affected service or file,
- what an attacker needs (network position, a valid user credential, admin
  access) and what they gain,
- steps to reproduce or a proof of concept, against your own test server,
- any fix or mitigation you have in mind.

Please strip secrets first: no `ADMIN_PASSWORD`, private keys, share-links,
subscription URLs, real server IPs or domains, and nothing from `state/` or
`outputs/`.

## What to expect

MoaV is maintained by volunteers. These are the targets we hold ourselves to:

| Step | Target |
|---|---|
| Acknowledge your report | within 72 hours |
| Triage: confirm or reject, with a severity | within 7 days |
| Fix released | as fast as severity demands; critical issues take priority over everything else |
| Public disclosure | coordinated with you, once a fixed release is out and operators have had time to update (90 days from the report at the latest, unless we agree otherwise) |

We will keep you updated while the fix is in progress. Fixes ship in a normal
release with a `Security` entry in [CHANGELOG.md](CHANGELOG.md) and, where it
applies, a GitHub Security Advisory.

## Scope

**In scope:** anything this repository ships.

- The server stack as MoaV configures it: `docker-compose.yml`, `dockerfiles/`,
  `configs/` templates, container privileges, network isolation and what is
  exposed by default.
- The control plane: the `moav` CLI (`moav.sh`, `lib/`), `install.sh`,
  bootstrap and user provisioning (`scripts/`), and the admin dashboard
  (`admin/`).
- `dns-router`, the exporters, and the bundled Prometheus and Grafana
  provisioning.
- Key, credential and bundle handling: generation, storage, file permissions,
  and leaks into logs, bundles, subscriptions or `--json` output.
- Anything MoaV adds that makes a server or its users easier to identify,
  probe or deanonymise (for example the decoy site, or what the monitoring
  stack records).
- The release and CI workflows, and how upstream components are pinned and
  verified.

**Out of scope:**

- **Bugs in upstream protocol engines and bundled third-party software**
  (sing-box, Xray-core, WireGuard, AmneziaWG, wstunnel, TrustTunnel, telemt,
  dnstt, Slipstream, MasterDNS, GooseRelay, Psiphon Conduit, Snowflake,
  Prometheus, Grafana, cAdvisor and the rest of the
  [related projects](README.md#related-projects)). Report those to the upstream
  project. Do tell us if MoaV pins a vulnerable version or if our configuration
  is what makes the bug reachable; that part is ours.
- Other MoaV repositories (`moav-client`, `moav-deploy-app`, `moav-site`).
  Report those in their own repository, through the same channels.
- Social engineering or phishing of maintainers, operators or users, and
  physical attacks.
- Denial of service: volumetric attacks, resource exhaustion by flooding, and
  anything that needs testing against servers you do not own.
- A censor being able to block or throttle an upstream protocol in general.
  That is a protocol limitation, see the
  [threat model](https://moav.sh/docs/threat-model).
- Attacks that start from root on the host, a known `ADMIN_PASSWORD`, or an
  operator ignoring the [OPSEC guide](https://moav.sh/docs/OPSEC).
- Scanner output with no demonstrated impact, and `contrib/` tools (opt-in,
  not core; report those as normal issues unless they expose secrets).

Not sure whether something is in scope? Report it privately anyway.

## Safe harbor

We consider security research done in good faith under this policy to be
authorized, and we will not pursue or support legal action against you for it.
Good faith means:

- you test only on servers you own or have explicit permission to test. MoaV is
  software, not a hosted service; other people's deployments are never fair
  game,
- you do not access, modify or keep data that is not yours, and you stop and
  report as soon as you come across any,
- you do not degrade a service or put its users at risk,
- you give us reasonable time to fix the issue before you disclose it.

If a third party takes action against you for research that followed this
policy, we will make it known that you acted within it. This policy cannot
authorize testing of third-party systems or bind anyone other than the MoaV
maintainers.

## Credit

We credit reporters in the release notes and in the security advisory, with a
name or handle of your choice, and may keep a hall of fame of past reporters
here. Tell us if you would rather stay anonymous; many people in this field
have good reason to. There is no bug bounty.

---

_This security policy was drafted with the assistance of an AI model (Claude Opus 4.8) and reviewed by the MoaV maintainers before adoption._

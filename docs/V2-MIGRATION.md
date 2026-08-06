# Upgrading to MoaV v2.0.0

This guide covers an in-place upgrade of an existing **1.9.x** install to
**v2.0.0**. A fresh install needs none of this — see the [Quick Start](https://moav.sh/docs/quick-start/).

v2 is the same protocols you already run, rebuilt underneath: a security and
correctness pass, a much smaller dispatcher, and a lot of quietly-broken things
fixed. No new protocols. Your keys, users, and certificates are preserved.

## Before you start

- **Take a backup.** A VPS snapshot if you can, and at minimum:
  ```bash
  cd /opt/moav
  tar czf ~/moav-pre-v2.tgz .env state outputs configs
  docker run --rm -v moav_moav_state:/state -v ~:/backup alpine \
    tar czf /backup/moav-state-volume.tgz /state
  ```
- **Note a working client.** Pick one existing user's config and confirm it
  connects *now*. After the upgrade, that same config still connecting is the
  single most important check.
- Run the upgrade in `tmux`/`screen` so a dropped SSH session can't interrupt it.

## The upgrade

```bash
cd /opt/moav
moav update -b main      # or the v2.0.0 tag; pulls the new code
moav build               # REQUIRED — every image is stale coming from 1.9.x
moav start               # recreate containers on the new images
```

**`moav build` is not optional.** Coming from 1.9.x, all images predate v2 (the
admin image especially — it changed how it reads its secret and which uid it
runs as). Skipping the build leaves you on old images against new configs.

That's the whole path. The three commands above are what a healthy upgrade needs.

## What you'll see (and why it's fine)

- **Permission repair, silently.** v2 tightens `state/keys` to `0600` and user
  bundles to non-world-readable, and it *repairs existing installs* on the first
  `moav start` (1.9.x shipped some of these `0644`/world-writable). You won't see
  much log output for it — that's expected; it runs as a one-shot against the
  state volume.
- **A config-template change notice.** `moav update` may say it changed a server
  config *template*. Your generated `config.json` files are gitignored and are
  **not** touched by the pull. If prompted, `moav bootstrap` (idempotent, keeps
  keys + users) re-renders them from the new template.
- **Grafana looks branded** (favicon + logo in MoaV colors) if you run
  monitoring.

## After the upgrade — verify in order

1. `docker ps` — nothing stuck in `Restarting` (watch ~2 min).
2. `moav doctor` — should be green (BBR/buffer lines are advisory).
3. **Your existing user's config still connects.** ← the headline check.
4. `moav test <user>` — protocol validation end-to-end.
5. `moav user add throwaway && moav user revoke throwaway` — exercises the
   provisioning + permission paths on the new code.
6. Dashboard: your full user list is present; download a bundle.

### Bundles now show only enabled protocols

The user guide (`README.html`) in each bundle used to list every protocol with
"No X config available" filler. v2 shows only what the user actually has. To
refresh existing bundles to the new format:

```bash
moav regenerate-users     # rebuilds every bundle from state; keys unchanged
```
This is safe — it reuses stored keys and re-emits configs; users just
re-download. `moav update` will remind you when a bundle-guide change lands.

## If something comes up

Escalate in this order; each rung is more involved than the last, and **state
and keys survive all of them**:

1. `docker compose --profile all up -d --remove-orphans` — the compose topology
   changed (a management-only network, socketless exporters); this reconciles it.
2. `moav regenerate-users` — rebuilds bundles + reconciles server configs from
   state.
3. Re-bootstrap (regenerates configs from templates, keeps keys/users):
   ```bash
   docker run --rm -v moav_moav_state:/state alpine rm /state/.bootstrapped
   moav bootstrap --yes && moav start
   ```

### Rollback

Your state and keys are untouched by any of the above, so rollback is:
```bash
git checkout <your-1.9.x-tag>   # in /opt/moav
moav build && moav start
```

## Known post-upgrade notes

- **`moav build` disk use.** The build caches BuildKit layers; v2 caps that
  cache at ~4 GB automatically. If a small VPS was already tight, prune first:
  `docker builder prune -f`.
- **`moav user add` right after `moav start`.** On a 1-vCPU box the stack takes a
  minute to settle; adding a user in the first ~60s while containers are still
  starting can occasionally time out a WireGuard/AmneziaWG key op. Give it a
  minute after start, or just retry — it is not a data problem.
- **Grafana browser-tab title** stays "Grafana" on the default (prebuilt) image;
  the favicon and logo are branded. The tab text only changes on a locally-built
  image (`moav build --local`).

## Questions

- Telegram: https://t.me/motherofallvpns
- Issues: https://github.com/MotherofallVPNs/MoaV/issues

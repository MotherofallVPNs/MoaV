#!/bin/bash
# Regression test for world-writable user bundles.
#
# outputs/bundles (client private keys, share URIs) and state/users were held
# together with chmod 777 / chmod -R a+rwX so the non-root admin app and the
# root-run provisioning paths could both write. Any local account could read
# AND MODIFY every user's keys. The fix pins the admin user to uid/gid 2000
# (Dockerfile.admin), root-run paths chown to it via grant_admin_rw, and every
# world bit is stripped.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

echo "bundle permission tests"

log_info() { :; }   # stub before sourcing
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/common.sh" 2>/dev/null || { echo "cannot source common.sh"; exit 1; }

# --- grant_admin_rw: functional (chmod half; the chown half needs root and is
# --- asserted statically below) -------------------------------------------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bundle/user1"
echo key > "$T/bundle/user1/wg.conf"
chmod 777 "$T/bundle" "$T/bundle/user1"
chmod 666 "$T/bundle/user1/wg.conf"

grant_admin_rw "$T/bundle"

m=$(mode "$T/bundle/user1/wg.conf")
[[ "${m: -1}" == "0" ]] && ok "world bits stripped from bundle file ($m)" \
                        || bad "bundle file still world-accessible ($m)"
m=$(mode "$T/bundle/user1")
[[ "${m: -1}" == "0" ]] && ok "world bits stripped from bundle dir ($m)" \
                        || bad "bundle dir still world-accessible ($m)"
[[ -w "$T/bundle/user1/wg.conf" ]] && ok "owner keeps write" || bad "owner lost write"

grant_admin_rw "$T/bundle"
[[ $? -eq 0 ]] && ok "second pass is idempotent (exit 0)" || bad "second pass returned non-zero"

grant_admin_rw "$T/nope"
[[ $? -eq 0 ]] && ok "missing path is a clean no-op" || bad "missing path returned non-zero"

# --- the uid contract both sides depend on --------------------------------
grep -qE 'adduser .*-u 2000' "$ROOT/dockerfiles/Dockerfile.admin" \
    && ok "Dockerfile.admin pins the moav user to uid 2000" \
    || bad "admin uid is not pinned — grant_admin_rw chowns to 2000 for nobody"
grep -q 'ADMIN_UID=2000' "$ROOT/scripts/lib/common.sh" \
    && ok "grant_admin_rw targets uid 2000" \
    || bad "ADMIN_UID drifted from the Dockerfile's uid 2000"

# --- no world-writable modes may come back --------------------------------
# Any `a+` grant counts: the first version of this check matched a+w/a+rwX and
# sailed straight past a `chmod a+rw` on the six protocol config files.
loose=$(grep -rnE 'chmod[^#]*(777|666|a\+|o\+w)' --include='*.sh' "$ROOT/scripts" "$ROOT/lib" 2>/dev/null \
        | grep -vE '^\S+:[0-9]+:\s*#' || true)
[[ -z "$loose" ]] && ok "no world-writable chmod in scripts/ or lib/" \
                  || bad "world-writable chmod reintroduced: $loose"

# --- configs must be OWNED BY ROOT, not the admin uid ---------------------
# wireguard/amneziawg/telemt/xray run cap_drop ALL without DAC_OVERRIDE, so
# their in-container root cannot bypass file modes: with o-rwx configs it can
# only read as OWNER. Chowning configs to uid 2000 crash-looped the WireGuard
# container ("Config file not found") in e2e.
if grep -qE 'chown -R root:moav /project/configs' "$ROOT/scripts/admin-entrypoint.sh" \
   && ! grep -qE 'chown -R moav:moav[^#]*/project/configs' "$ROOT/scripts/admin-entrypoint.sh"; then
    ok "admin entrypoint keeps configs owner root (cap-dropped containers read as owner)"
else
    bad "admin entrypoint chowns configs away from root — DAC-less container roots lose read"
fi
grep -qE 'chown -R "0:\$ADMIN_GID" /configs/' "$ROOT/scripts/bootstrap.sh" \
    && ok "bootstrap keeps configs owner root" \
    || bad "bootstrap no longer chowns configs to 0:\$ADMIN_GID — DAC-less container roots lose read"

# --- the world-read split -------------------------------------------------
# wireguard/amneziawg configs (server private keys) are consumed by
# container-root: fully locked. sing-box/xray/telemt/trusttunnel run their
# daemons as NON-root uids and crash-looped in e2e when world-read was
# stripped ("Permission denied" reading their config) — they keep o+rX and
# lose only o-w.
for f in "$ROOT/scripts/admin-entrypoint.sh" "$ROOT/lib/service.sh" "$ROOT/scripts/bootstrap.sh"; do
    b=$(basename "$f")
    if grep -E 'o-rwx' "$f" | grep -vE '^\s*#' | grep -qE 'sing-box|xray|trusttunnel|telemt'; then
        bad "$b strips world-read from a non-root-daemon config dir — sing-box/xray/telemt/trusttunnel crash-loop"
    else
        ok "$b keeps world-read on the non-root-daemon config dirs"
    fi
    if grep -E 'o\+rX' "$f" | grep -vE '^\s*#' | grep -qE 'wireguard|amneziawg'; then
        bad "$b grants world-read on configs/wireguard or amneziawg — server private keys exposed"
    else
        ok "$b keeps configs/wireguard + amneziawg fully locked"
    fi
done

grep -E '^[^#]*chown[^#]*0:1000' "$ROOT/scripts/bootstrap.sh" >/dev/null \
    && bad "bootstrap.sh still chowns to gid 1000 — the admin user never had it" \
    || ok "bootstrap.sh no longer chowns to the phantom gid 1000"

# --- the paths that used the crutches must now use the grant --------------
grep -q 'grant_admin_rw' "$ROOT/scripts/user-add.sh" \
    && ok "user-add.sh grants the bundle to the admin uid" \
    || bad "user-add.sh no longer calls grant_admin_rw — root-created bundles lock the admin out"
grep -q 'grant_admin_rw' "$ROOT/scripts/user-package.sh" \
    && ok "user-package.sh grants the zip to the admin uid" \
    || bad "user-package.sh zip stays root-owned world-readable"

# Existing installs keep 777 bundles unless something repairs them: the admin
# entrypoint covers admin-enabled installs, the host start path covers the rest.
if grep -q 'repair_bundle_perms()' "$ROOT/lib/service.sh" \
   && [[ $(grep -cE '^\s*repair_bundle_perms$' "$ROOT/lib/service.sh") -ge 2 ]]; then
    ok "moav start paths repair bundle perms (covers upgrades)"
else
    bad "lib/service.sh start paths do not call repair_bundle_perms — upgraded installs keep 777 bundles"
fi

# --- monitoring configs must stay world-readable (grafana 472 / prom 65534)
if grep -E 'chmod -R (ug\+rwX,)?o-rwx' "$ROOT/scripts/admin-entrypoint.sh" | grep -q 'monitoring'; then
    bad "admin entrypoint strips world-read from configs/monitoring — grafana/prometheus cannot read their configs"
else
    ok "admin entrypoint leaves configs/monitoring world-readable"
fi
if grep -E 'o-rwx' "$ROOT/scripts/bootstrap.sh" | grep -q 'monitoring'; then
    bad "bootstrap strips world-read from configs/monitoring — grafana/prometheus cannot read their configs"
else
    ok "bootstrap leaves configs/monitoring world-readable"
fi

echo ""
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]

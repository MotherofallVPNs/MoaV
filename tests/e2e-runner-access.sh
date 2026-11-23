#!/usr/bin/env bash
# e2e harness: give the non-root runner host-CLI access without moving
# configs/{wireguard,amneziawg} off root; their cap-dropped containers read as owner.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

uid=$(id -u); gid=$(id -g)
admin_gid="${ADMIN_GID:-2000}"
root_read=(configs/wireguard configs/amneziawg)

sudo chown -R "$uid:$gid" state outputs 2>/dev/null || true
[ -d configs ] && sudo chown "$uid:$gid" configs
sudo find configs -mindepth 1 -maxdepth 1 \
    ! -path configs/wireguard ! -path configs/amneziawg \
    -exec chown -R "$uid:$gid" {} + 2>/dev/null || true

for d in "${root_read[@]}"; do
    [ -d "$d" ] || continue
    # Same ownership/mode repair_bundle_perms (lib/service.sh) applies on start.
    sudo chown -R "0:$admin_gid" "$d"
    sudo chmod -R ug+rwX,o-rwx "$d"
    # setfacl -m recomputes the mask, so a later chmod 600 cannot hide the entry.
    sudo setfacl -R -m "u:$uid:rwX" "$d"
    sudo find "$d" -type d -exec setfacl -d -m "u:$uid:rwX" {} +
    if ! { [ -r "$d" ] && [ -w "$d" ]; }; then
        echo "::error::runner still cannot use $d after the ACL grant"; exit 1
    fi
done

# Prove the property the containers depend on, not just that commands ran.
for d in "${root_read[@]}"; do
    [ -d "$d" ] || continue
    bad=$(sudo find "$d" ! -uid 0 -printf '%p (uid %U)\n')
    if [ -n "$bad" ]; then
        echo "::error::not owned by root (WG/AWG would crash on restart): $bad"; exit 1
    fi
done
echo "runner access granted; configs/{wireguard,amneziawg} remain owner root"

#!/bin/bash
# lib/keys.sh — single-source key generation for provisioning.
#
# Sourced by both the host scripts (scripts/lib/keys.sh) and the container ones
# (/app/lib/keys.sh). WireGuard and AmneziaWG use the same Curve25519 key format,
# so one generator serves both.
#
# CRLF-safe by construction: `docker compose exec` into some images emits CRLF,
# and $() strips only the trailing \n — a leftover \r makes a 44-char key 45
# chars, which `wg/awg pubkey` rejects, silently writing a broken peer. Every
# path here pipes through `tr -d '\r\n'`.

# Resolve a working wg/awg generator once and cache it. Preference:
#   1. a local `wg`/`awg` binary — present in the bootstrap container and on any
#      host with wireguard-tools (also sidesteps the container-exec hang class);
#   2. a running `wireguard`/`amneziawg` container via `docker compose exec`,
#      bounded with `timeout -k` so a wedged container can't hang `user add`;
#   3. a throwaway image (host with neither).
_keys_resolved=""
_keys_bin=""
_keys_prefix=()   # command prefix as an array (empty for a local binary)
_keys_resolve() {
    [[ -n "$_keys_resolved" ]] && return 0
    local t=()
    command -v timeout >/dev/null 2>&1 && t=(timeout -k 5 20)
    if command -v wg >/dev/null 2>&1; then
        _keys_bin=wg; _keys_prefix=(); _keys_resolved=1; return 0
    fi
    if command -v awg >/dev/null 2>&1; then
        _keys_bin=awg; _keys_prefix=(); _keys_resolved=1; return 0
    fi
    local pair svc bin
    for pair in "wireguard wg" "amneziawg awg"; do
        svc=${pair% *}; bin=${pair#* }
        if "${t[@]}" docker compose ps "$svc" --status running 2>/dev/null | tail -n +2 | grep -q .; then
            _keys_bin="$bin"; _keys_prefix=("${t[@]}" docker compose exec -T "$svc"); _keys_resolved=1; return 0
        fi
    done
    _keys_bin=wg; _keys_prefix=("${t[@]}" docker run --rm -i lscr.io/linuxserver/wireguard); _keys_resolved=1; return 0
}

# wg_privkey — emit one CRLF-clean private key.
wg_privkey() {
    _keys_resolve
    "${_keys_prefix[@]}" "$_keys_bin" genkey 2>/dev/null | tr -d '\r\n'
}

# wg_pubkey <private-key> — derive the CRLF-clean public key from a private key.
wg_pubkey() {
    _keys_resolve
    printf '%s' "${1:-}" | "${_keys_prefix[@]}" "$_keys_bin" pubkey 2>/dev/null | tr -d '\r\n'
}

# wg_keypair — emit "<private>\n<public>" (both CRLF-clean). Returns 1 if no
# generator produced a key. Callers: { read -r PRIV; read -r PUB; } < <(wg_keypair)
wg_keypair() {
    local priv pub
    priv=$(wg_privkey)
    pub=$(wg_pubkey "$priv")
    [[ -n "$priv" && -n "$pub" ]] || return 1
    printf '%s\n%s\n' "$priv" "$pub"
}

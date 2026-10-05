#!/bin/bash
# Regression test: install.sh non-interactive mode (moav-deploy-app#8).
# MOAV_NONINTERACTIVE=1 + environment, or --answers FILE (0600, owned by the
# caller). Fail closed on every missing/invalid answer, never take the admin
# password from argv, never print it, write .env at 0600 through a temp file.
#
# The ni_* helpers are exercised by sourcing install.sh with
# MOAV_INSTALL_LIB_ONLY=1 (returns before the banner); nothing is cloned or
# installed. The argv guard is checked by running the script for real with a
# forbidden flag (it exits before doing anything).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SECRET_PW="Corr3ct-Horse-Battery"

echo "install.sh non-interactive: answers validation + .env rendering"

# --- 1. the password is never taken from argv --------------------------------
for flag in "--admin-password=$SECRET_PW" "--password" "MOAV_ADMIN_PASSWORD=$SECRET_PW"; do
    out=$(bash "$ROOT/install.sh" "$flag" 2>&1); rc=$?
    if [[ $rc -eq 1 ]] && printf '%s' "$out" | grep -q "not accepted on the command line" && ! printf '%s' "$out" | grep -qF "$SECRET_PW"; then
        ok "argv '${flag%%=*}' refused without echoing the value"
    else
        bad "argv '${flag%%=*}': rc=$rc out=$out"
    fi
done
help=$(bash "$ROOT/install.sh" --help 2>&1)
printf '%s' "$help" | grep -q -- '--answers FILE' && ok "--help documents --answers / MOAV_* answers" || bad "--help lacks non-interactive docs"

# --- helpers under test -------------------------------------------------------
# A fresh shell per case so exported answers never bleed between cases.
# run_case <env assignments...> -- <bash snippet>   (snippet runs after sourcing)
run_case() {
    local envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
    env -i PATH="$PATH" HOME="$WORK" MOAV_INSTALL_LIB_ONLY=1 MOAV_INSTALL_DIR="$WORK/moav" "${envs[@]}" \
        bash -c 'source "$0"; '"$1" "$ROOT/install.sh"
}

# --- 2. ni_validate: fail closed ---------------------------------------------
out=$(run_case MOAV_DOMAIN=vpn.example.com MOAV_EMAIL=a@b.co -- 'ni_validate' 2>&1); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q 'MOAV_ADMIN_PASSWORD is required' && ok "missing password -> fail" || bad "missing password: rc=$rc $out"
out=$(run_case MOAV_ADMIN_PASSWORD="$SECRET_PW" -- 'ni_validate' 2>&1); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q 'MOAV_DOMAIN is not set' && ok "no domain and no explicit MOAV_DOMAINLESS -> fail" || bad "no domain: rc=$rc $out"
out=$(run_case MOAV_DOMAIN=vpn.example.com MOAV_ADMIN_PASSWORD="$SECRET_PW" -- 'ni_validate' 2>&1); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q 'MOAV_EMAIL is required' && ok "domain without email -> fail" || bad "no email: rc=$rc $out"
out=$(run_case MOAV_DOMAIN='not a domain' MOAV_EMAIL=a@b.co MOAV_ADMIN_PASSWORD="$SECRET_PW" -- 'ni_validate' 2>&1); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q 'not a valid hostname' && ok "invalid hostname -> fail" || bad "bad hostname: rc=$rc $out"
for weak in "change_me_to_something_secure" "admin" "short1" 'has"quote-inside' 'has space inside' 'has#hash-inside' 'has$dollar-inside'; do
    out=$(run_case MOAV_DOMAINLESS=1 MOAV_ADMIN_PASSWORD="$weak" -- 'ni_validate' 2>&1); rc=$?
    if [[ $rc -ne 0 ]] && ! printf '%s' "$out" | grep -qF -- "$weak"; then
        ok "password rejected without echo: ${weak:0:6}…"
    else
        bad "password '$weak': rc=$rc out=$out"
    fi
done
out=$(run_case MOAV_DOMAINLESS=1 MOAV_ADMIN_PASSWORD="$SECRET_PW" ENABLE_TROJAN=maybe -- 'ni_validate' 2>&1); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q 'ENABLE_TROJAN must be true or false' && ok "ENABLE_* must be true|false" || bad "ENABLE_TROJAN=maybe: rc=$rc $out"
out=$(run_case MOAV_DOMAIN='HTTPS://VPN.Example.com/' MOAV_EMAIL=a@b.co MOAV_ADMIN_PASSWORD="$SECRET_PW" ENABLE_SS=FALSE -- 'ni_validate && echo "$NI_DOMAIN|$ENABLE_SS"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "vpn.example.com|false" ]] && ok "valid answers pass; domain sanitised, toggles lower-cased" || bad "valid: rc=$rc $out"
out=$(run_case MOAV_DOMAINLESS=yes MOAV_ADMIN_PASSWORD="$SECRET_PW" -- 'ni_validate && echo "$NI_DOMAINLESS"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "true" ]] && ok "explicit MOAV_DOMAINLESS=yes is accepted" || bad "domainless: rc=$rc $out"

# --- 3. --answers file: perms, owner, keys ------------------------------------
ANS="$WORK/answers.env"
printf 'MOAV_DOMAIN="vpn.example.com"\nMOAV_EMAIL=ops@example.com\nMOAV_ADMIN_PASSWORD=%s\n# comment\n\nENABLE_TROJAN=false\n' "$SECRET_PW" > "$ANS"
chmod 644 "$ANS"
out=$(run_case -- "ni_load_answers '$ANS'" 2>&1); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q 'must be mode 0600' && ok "answers file 0644 -> refused" || bad "0644 answers: rc=$rc $out"
chmod 600 "$ANS"
out=$(run_case -- "ni_load_answers '$ANS' && ni_validate && echo \"\$NI_DOMAIN|\$NI_EMAIL|\$ENABLE_TROJAN|\${#MOAV_ADMIN_PASSWORD}\"" 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "vpn.example.com|ops@example.com|false|${#SECRET_PW}" ]] && ok "answers file 0600: parsed (quotes stripped, comments skipped)" || bad "0600 answers: rc=$rc $out"
printf '%s' "$out" | grep -qF "$SECRET_PW" && bad "answers load echoed the password" || ok "answers load never prints the password"
chmod 400 "$ANS"
run_case -- "ni_load_answers '$ANS'" >/dev/null 2>&1 && ok "answers file 0400 accepted too" || bad "0400 answers refused"
chmod 600 "$ANS"
printf 'MOAV_DOMAINLESS=1\nMOAV_ADMIN_PASSWORD=%s\nMOAV_INSTALL_DIR=/tmp/evil\n' "$SECRET_PW" > "$ANS"
out=$(run_case -- "ni_load_answers '$ANS'" 2>&1); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q 'key not allowed: MOAV_INSTALL_DIR' && ok "answers file: unknown key -> refused" || bad "unknown key: rc=$rc $out"
printf 'MOAV_DOMAINLESS=1\njunk line\n' > "$ANS"
out=$(run_case -- "ni_load_answers '$ANS'" 2>&1); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q 'expected KEY=VALUE' && ok "answers file: malformed line -> refused" || bad "malformed: rc=$rc $out"
ln -s "$ANS" "$WORK/link.env"
out=$(run_case -- "ni_load_answers '$WORK/link.env'" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "answers file: symlink refused" || bad "symlink answers accepted"
out=$(run_case -- "ni_load_answers '$WORK/missing.env'" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "answers file: missing -> refused" || bad "missing answers accepted"
# File overrides environment.
printf 'MOAV_DOMAINLESS=1\nMOAV_ADMIN_PASSWORD=%s\n' "$SECRET_PW" > "$ANS"
out=$(run_case MOAV_ADMIN_PASSWORD=from-env-value-12 -- "ni_load_answers '$ANS' && [[ \"\$MOAV_ADMIN_PASSWORD\" == '$SECRET_PW' ]] && echo override" 2>&1)
[[ "$out" == "override" ]] && ok "answers file overrides the environment" || bad "override: $out"

# --- 4. ni_configure_env: fresh .env ------------------------------------------
mkdir -p "$WORK/moav"
cp "$ROOT/.env.example" "$WORK/moav/.env.example"
ln -s "$ROOT/lib" "$WORK/moav/lib"; ln -s "$ROOT/scripts" "$WORK/moav/scripts"
out=$(run_case MOAV_DOMAIN=vpn.example.com MOAV_EMAIL=ops@example.com MOAV_ADMIN_PASSWORD="$SECRET_PW" ENABLE_TROJAN=false ENABLE_MONITORING=true -- 'ni_validate && ni_configure_env' 2>&1); rc=$?
ENVF="$WORK/moav/.env"
[[ $rc -eq 0 && -f "$ENVF" ]] && ok "fresh install: .env created" || bad "fresh: rc=$rc $out"
printf '%s' "$out" | grep -qF "$SECRET_PW" && bad "configure output contains the password" || ok "configure output never contains the password"
mode=$(stat -c '%a' "$ENVF" 2>/dev/null || stat -f '%Lp' "$ENVF")
[[ "$mode" == "600" ]] && ok ".env is 0600" || bad ".env mode is $mode"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"   # get_env_val — the same reader moav uses
[[ "$(get_env_val DOMAIN "$ENVF")" == "vpn.example.com" ]] && ok "DOMAIN written" || bad "DOMAIN=$(get_env_val DOMAIN "$ENVF")"
[[ "$(get_env_val ACME_EMAIL "$ENVF")" == "ops@example.com" ]] && ok "ACME_EMAIL written" || bad "ACME_EMAIL=$(get_env_val ACME_EMAIL "$ENVF")"
[[ "$(get_env_val ADMIN_PASSWORD "$ENVF")" == "$SECRET_PW" ]] && ok "ADMIN_PASSWORD round-trips through get_env_val" || bad "ADMIN_PASSWORD mismatch"
[[ "$(grep -c '^ADMIN_PASSWORD=' "$ENVF")" == "1" ]] && ok "exactly one ADMIN_PASSWORD line (placeholder replaced in place)" || bad "ADMIN_PASSWORD lines: $(grep -c '^ADMIN_PASSWORD=' "$ENVF")"
[[ "$(get_env_val ENABLE_TROJAN "$ENVF")" == "false" ]] && ok "ENABLE_TROJAN toggle applied" || bad "ENABLE_TROJAN=$(get_env_val ENABLE_TROJAN "$ENVF")"
[[ "$(get_env_val ENABLE_MONITORING "$ENVF")" == "true" ]] && ok "commented #ENABLE_MONITORING= uncommented + set" || bad "ENABLE_MONITORING=$(get_env_val ENABLE_MONITORING "$ENVF")"
[[ "$(get_env_val ENABLE_HYSTERIA2 "$ENVF")" == "true" ]] && ok "untouched toggles keep their .env.example default" || bad "ENABLE_HYSTERIA2 changed"
dp=$(get_env_val DEFAULT_PROFILES "$ENVF")
[[ "$dp" == *proxy* && "$dp" == *admin* && "$dp" == *monitoring* && "$dp" == *dnstunnel* ]] && ok "DEFAULT_PROFILES derived from ENABLE_* (+monitoring): $dp" || bad "DEFAULT_PROFILES=$dp"
# .env must still be sourceable (the provisioning scripts `source .env`).
( set -e; source "$ENVF" >/dev/null 2>&1 ) && ok ".env still sources cleanly" || bad ".env no longer sources"

# --- 5. ni_configure_env: existing .env is not silently reconfigured ---------
out=$(run_case MOAV_DOMAIN=other.example.org MOAV_EMAIL=x@y.zz MOAV_ADMIN_PASSWORD="Another-Secret-Pw1" ENABLE_SS=false -- 'ni_validate && ni_configure_env' 2>&1); rc=$?
[[ $rc -eq 0 ]] || bad "re-run: rc=$rc $out"
[[ "$(get_env_val DOMAIN "$ENVF")" == "vpn.example.com" ]] && ok "re-run keeps the existing DOMAIN" || bad "re-run changed DOMAIN"
[[ "$(get_env_val ADMIN_PASSWORD "$ENVF")" == "$SECRET_PW" ]] && ok "re-run keeps the existing ADMIN_PASSWORD" || bad "re-run changed ADMIN_PASSWORD"
[[ "$(get_env_val ENABLE_SS "$ENVF")" == "false" ]] && ok "re-run still applies an explicit ENABLE_* toggle" || bad "re-run ignored ENABLE_SS"
printf '%s' "$out" | grep -q 'already set' && ok "re-run says what it kept" || bad "re-run silent about kept values"

# --- 6. domainless: certificate-dependent protocols forced off ---------------
rm -f "$ENVF"
out=$(run_case MOAV_DOMAINLESS=1 MOAV_ADMIN_PASSWORD="$SECRET_PW" ENABLE_TROJAN=true -- 'ni_validate && ni_configure_env' 2>&1); rc=$?
[[ $rc -eq 0 ]] || bad "domainless: rc=$rc $out"
for k in ENABLE_TROJAN ENABLE_ANYTLS ENABLE_HYSTERIA2 ENABLE_DNSTT ENABLE_SLIPSTREAM ENABLE_MASTERDNS ENABLE_XDNS ENABLE_TRUSTTUNNEL; do
    [[ "$(get_env_val "$k" "$ENVF")" == "false" ]] || bad "domainless left $k=$(get_env_val "$k" "$ENVF")"
done
[[ "$(get_env_val ENABLE_TROJAN "$ENVF")" == "false" ]] && ok "domainless disables the certificate-dependent set (explicit true overridden with a warning)" || true
printf '%s' "$out" | grep -q 'ENABLE_TROJAN=true needs a domain' && ok "domainless override is announced" || bad "no warning for overridden ENABLE_TROJAN"
[[ -z "$(get_env_val DOMAIN "$ENVF")" ]] && ok "domainless leaves DOMAIN empty" || bad "DOMAIN set in domainless"
dp=$(get_env_val DEFAULT_PROFILES "$ENVF")
[[ "$dp" != *dnstunnel* && "$dp" != *trusttunnel* && "$dp" == *proxy* ]] && ok "domainless DEFAULT_PROFILES excludes dnstunnel/trusttunnel: $dp" || bad "domainless DEFAULT_PROFILES=$dp"

# --- 7. ni_env_set is sed-free: | & / in values survive ----------------------
printf 'FOO=\n' > "$WORK/t.env"
run_case -- "ni_env_set '$WORK/t.env' FOO 'a|b&c/d'" >/dev/null 2>&1
[[ "$(get_env_val FOO "$WORK/t.env")" == 'a|b&c/d' ]] && ok "ni_env_set keeps | & / literally" || bad "ni_env_set: $(cat "$WORK/t.env")"

# --- 8. install.sh's own confirm() honours NONINTERACTIVE --------------------
out=$(run_case -- 'NONINTERACTIVE=1; confirm "x?" "y" </dev/null && echo yes; confirm "x?" "n" </dev/null || echo no' 2>&1)
[[ "$out" == $'yes\nno' ]] && ok "installer confirm() takes the default when non-interactive" || bad "confirm(): $out"
grep -q 'confirm "Start Docker now?" "$(\[\[ "$NONINTERACTIVE" == "1" \]\] && echo y || echo n)"' "$ROOT/install.sh" \
    && ok "unattended install starts Docker (default flips to yes)" || bad "Start Docker default not flipped for non-interactive"
n=$(grep -c '\[\[ "$NONINTERACTIVE" != "1" \]\] || return 0' "$ROOT/install.sh")
[[ "$n" -ge 2 ]] && ok "swap + net-tuning skipped when non-interactive" || bad "swap/net-tuning not gated ($n)"

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"

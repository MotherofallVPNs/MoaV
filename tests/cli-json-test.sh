#!/bin/bash
# Regression test: `--json` output on status / doctor / user list|add|remove
# (moav-deploy-app#8). Every document must (1) be valid JSON, (2) be the ONLY
# thing on stdout — script/progress noise goes to stderr — and (3) carry no
# secret: no server IP, no key/password/UUID, no share-link. The mobile app
# parses these and may log them, so a leak here is a leak to a phone.
#
# Pure-function level where possible (lib sourced with stubs); the user paths run
# through the real `./moav.sh` dispatcher against a scratch install dir with a
# fake `docker` and fake provisioning scripts on PATH. Needs bash >= 4 (moav.sh)
# and jq (user-list.sh) — same as CI.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

if [[ -z "${BASH_VERSINFO:-}" ]] || (( BASH_VERSINFO[0] < 4 )); then
    echo "SKIP: needs bash >= 4 (found ${BASH_VERSION:-unknown})"; exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 2; }

# Secrets planted in every fixture. If any of these strings shows up in a JSON
# document, the redaction / field selection is broken.
SECRET_IP="203.0.113.77"
SECRET_IP6="2001:db8:0:1::77"
SECRET_PW="hunter2-SuperSecret-Pass"
SECRET_UUID="123e4567-e89b-12d3-a456-426614174000"
SECRET_KEY="qwertyuiopASDFGHJKLzxcvbnm0123456789ABCD="
SECRET_LINK="vless://${SECRET_UUID}@${SECRET_IP}:443?security=reality#alice"

valid_json() {   # valid_json <desc> <text>
    if printf '%s' "$2" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
        ok "$1: valid JSON"
    else
        bad "$1: invalid JSON: $(printf '%s' "$2" | head -c 300)"
    fi
}
no_secrets() {   # no_secrets <desc> <text>
    local leak="" s
    for s in "$SECRET_IP" "$SECRET_IP6" "$SECRET_PW" "$SECRET_UUID" "$SECRET_KEY" "$SECRET_LINK" "ADMIN_PASSWORD=" "PrivateKey"; do
        printf '%s' "$2" | grep -qF -- "$s" && leak="$leak [$s]"
    done
    if [[ -z "$leak" ]]; then ok "$1: no secret substrings"; else bad "$1: leaked$leak"; fi
}
jget() { printf '%s' "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print($2)" 2>/dev/null; }

echo "moav --json output (status / doctor / user list|add|remove)"

# =============================================================================
# 1. helpers (lib/common.sh)
# =============================================================================
# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"
: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${BLUE:=}" "${CYAN:=}" "${WHITE:=}" "${DIM:=}" "${NC:=}"

s=$(json_str $'a"b\\c\n\t\x1b[0m')
if [[ "$(printf '%s' "$s" | python3 -c 'import sys,json; print(repr(json.load(sys.stdin)))')" == "'a\"b\\\\c\\n\\t\\x1b[0m'" ]]; then
    ok "json_escape round-trips quotes, backslash, newline, tab, ESC"
else
    bad "json_escape produced: $s"
fi
[[ "$(json_str_array a 'b c' '')" == '["a","b c",""]' ]] && ok "json_str_array" || bad "json_str_array: $(json_str_array a 'b c' '')"
[[ "$(json_bool yes)$(json_bool 0)" == "truefalse" ]] && ok "json_bool" || bad "json_bool"

r=$(printf 'A %s B %s C %s D %s E %s F 12:30 v1.13.19 fe80::1 2001:db8::1 end\n' \
      "$SECRET_IP" "$SECRET_IP6" "$SECRET_LINK" "$SECRET_UUID" "$SECRET_KEY" | json_redact)
no_secrets "json_redact" "$r"
printf '%s' "$r" | grep -q 'F 12:30 v1.13.19' && ok "json_redact keeps times and versions" || bad "json_redact mangled benign text: $r"
printf '%s' "$r" | grep -q 'fe80::1\|2001:db8::1' && bad "json_redact missed an adjacent IPv6: $r" || ok "json_redact masks adjacent IPv6 literals"

d=$(printf '  \033[0;32m✓\033[0m Docker running\n    ✗ A record %s\n' "$SECRET_IP" | json_detail)
[[ "$d" == "✓ Docker running; ✗ A record [redacted-ip]" ]] && ok "json_detail strips ANSI, joins lines, redacts" || bad "json_detail: $d"

# confirm() must not touch the tty in non-interactive mode
if out=$(MOAV_NONINTERACTIVE=1 confirm "Proceed?" "y" 2>&1 < /dev/null) && ! MOAV_NONINTERACTIVE=1 confirm "Proceed?" "n" < /dev/null 2>/dev/null; then
    ok "confirm() returns the default under MOAV_NONINTERACTIVE=1"
else
    bad "confirm() under MOAV_NONINTERACTIVE=1: rc/out unexpected ($out)"
fi

# =============================================================================
# scratch install: real moav.sh + libs, fake docker + provisioning scripts
# =============================================================================
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
APP="$WORK/moav"; mkdir -p "$APP/scripts" "$APP/outputs/bundles" "$APP/configs/sing-box" "$APP/configs/wireguard" "$APP/configs/amneziawg" "$APP/configs/xray" "$APP/configs/trusttunnel" "$APP/configs/telemt" "$WORK/bin"
cp "$ROOT/moav.sh" "$APP/moav.sh"; chmod +x "$APP/moav.sh"
ln -s "$ROOT/lib" "$APP/lib"
cp "$ROOT/VERSION" "$APP/VERSION"
cp "$ROOT/.env.example" "$APP/.env.example"
for f in "$ROOT"/scripts/*; do ln -s "$f" "$APP/scripts/$(basename "$f")"; done
# .env with the planted secrets; SERVER_IP is what must never reach a document.
cat > "$APP/.env" <<ENV
DOMAIN=
ACME_EMAIL=
ADMIN_PASSWORD="$SECRET_PW"
SERVER_IP="$SECRET_IP"
SERVER_IPV6="$SECRET_IP6"
PORT_ADMIN=9443
PORT_GRAFANA=9444
DEFAULT_PROFILES="proxy admin"
ENABLE_MONITORING=false
ENV
chmod 600 "$APP/.env"

# fake docker: compose ps/config/services answers; everything else is a no-op
cat > "$WORK/bin/docker" <<DOCKER
#!/bin/bash
args="\$*"
case "\$args" in
    "compose --profile all config --services")
        printf '%s\n' admin bootstrap certbot geoip-updater grafana sing-box wireguard ;;
    "compose --profile all ps -a --format json")
        # JSON-array form (compose v2.21+); NDJSON is the other shape.
        printf '[{"Name":"moav-sing-box","Service":"sing-box","State":"running","Health":"healthy","Status":"Up 3 hours (healthy)","CreatedAt":"2026-09-14 10:00:00 +0000 UTC","Publishers":[{"URL":"","TargetPort":443,"PublishedPort":443,"Protocol":"tcp"},{"URL":"","TargetPort":8443,"PublishedPort":8443,"Protocol":"udp"}]},{"Name":"moav-admin","Service":"admin","State":"running","Health":"","Status":"Up About an hour","CreatedAt":"2026-09-14 12:00:00 +0000 UTC","Publishers":[{"URL":"0.0.0.0","TargetPort":9443,"PublishedPort":9443,"Protocol":"tcp"}]},{"Name":"moav-certbot","Service":"certbot","State":"exited","Health":"","Status":"Exited (0) 2 hours ago","CreatedAt":"2026-09-14 09:00:00 +0000 UTC","Publishers":[]},{"Name":"moav-geoip-updater","Service":"geoip-updater","State":"exited","Health":"","Status":"Exited (0)","CreatedAt":"","Publishers":[]},{"Name":"moav-grafana","Service":"grafana","State":"running","Health":"unhealthy","Status":"Up 5 minutes (unhealthy)","CreatedAt":"","Publishers":[{"URL":"","TargetPort":3000,"PublishedPort":9444,"Protocol":"tcp"}]}]\n' ;;
    "compose ps --services --filter status=running")
        printf '%s\n' sing-box admin grafana ;;
    *) exit 0 ;;
esac
DOCKER
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"
cd "$APP"

# =============================================================================
# 2. moav status --json
# =============================================================================
out=$(./moav.sh status --json 2>"$WORK/status.err"); rc=$?
valid_json "status --json" "$out"
no_secrets "status --json" "$out"
[[ $rc -eq 0 ]] && ok "status --json exits 0" || bad "status --json rc=$rc"
[[ "$(jget "$out" 'd["version"]')" == "$(cat "$ROOT/VERSION")" ]] && ok "status: version field" || bad "status: version = $(jget "$out" 'd["version"]')"
names=$(jget "$out" '" ".join(s["name"] for s in d["services"])')
[[ "$names" == "sing-box admin certbot grafana wireguard" ]] && ok "status: services listed (one-shot geoip/bootstrap hidden, never-started included)" || bad "status: services = '$names'"
[[ "$(jget "$out" 'd["services"][0]["state"]+"|"+d["services"][0]["uptime"]+"|"+",".join(map(str,d["services"][0]["ports"]))')" == "running|3 hours|443,8443" ]] \
    && ok "status: state/uptime/ports parsed" || bad "status: sing-box row = $(jget "$out" 'd["services"][0]')"
[[ "$(jget "$out" '[s["state"] for s in d["services"] if s["name"]=="grafana"][0]')" == "unhealthy" ]] && ok "status: unhealthy surfaces as its own state" || bad "status: grafana state"
[[ "$(jget "$out" '[s["state"] for s in d["services"] if s["name"]=="wireguard"][0]')" == "never" ]] && ok "status: never-created service = never" || bad "status: wireguard state"
[[ "$(jget "$out" 'd["services"][1]["uptime"]')" == "~1 hour" ]] && ok "status: 'About an hour' normalised" || bad "status: admin uptime = $(jget "$out" 'd["services"][1]["uptime"]')"
# No DOMAIN -> the URL would embed SERVER_IP -> must be null; ports still given.
[[ "$(jget "$out" 'str(d["admin_url"])+"|"+str(d["grafana_url"])+"|"+str(d["admin_port"])+"|"+str(d["grafana_port"])')" == "None|None|9443|9444" ]] \
    && ok "status: domainless -> admin_url/grafana_url null (no SERVER_IP leak), ports present" || bad "status: urls = $(jget "$out" '(d["admin_url"], d["grafana_url"])')"
[[ "$(jget "$out" '" ".join(d["default_profiles"])')" == "proxy admin" ]] && ok "status: default_profiles" || bad "status: default_profiles"
[[ ! -s "$WORK/status.err" ]] && ok "status --json: stderr quiet" || bad "status --json: stderr: $(head -3 "$WORK/status.err")"

# With a DOMAIN the URLs are domain-based (public DNS, not a server address).
sed -i.bak 's/^DOMAIN=.*/DOMAIN="vpn.example.com"/' .env && rm -f .env.bak
out=$(./moav.sh status --json 2>/dev/null)
valid_json "status --json (domain)" "$out"; no_secrets "status --json (domain)" "$out"
[[ "$(jget "$out" 'd["admin_url"]+" "+d["grafana_url"]')" == "https://vpn.example.com:9443 https://vpn.example.com:9444" ]] \
    && ok "status: domain-based URLs when DOMAIN is set" || bad "status: urls = $(jget "$out" '(d["admin_url"], d["grafana_url"])')"
sed -i.bak 's/^DOMAIN=.*/DOMAIN=/' .env && rm -f .env.bak

# Unknown option is rejected; plain `moav status` still renders the table.
./moav.sh status --bogus >/dev/null 2>&1 && bad "status --bogus accepted" || ok "status rejects an unknown option"
plain=$(./moav.sh status 2>/dev/null)
printf '%s' "$plain" | grep -q 'Service Status' && ok "plain 'moav status' table still renders" || bad "plain 'moav status' broke"
printf '%s' "$plain" | grep -q '443,8443' && ok "plain 'moav status' shows both published ports (array-form ps output)" || bad "plain status lost ports: $(printf '%s' "$plain" | grep sing-box)"

# =============================================================================
# 3. moav doctor --json
# =============================================================================
# 3a. the real CLI, real `env` check (file-only, no docker).
out=$(./moav.sh doctor env --json 2>"$WORK/doctor.err"); rc=$?
valid_json "doctor env --json" "$out"; no_secrets "doctor env --json" "$out"
[[ "$(jget "$out" 'd[0]["id"]+"|"+d[0]["status"]')" == "env|pass" || "$(jget "$out" 'd[0]["id"]+"|"+d[0]["status"]')" == "env|fail" ]] \
    && ok "doctor env --json: [{id, status, detail}]" || bad "doctor env --json: $out"
[[ ! -s "$WORK/doctor.err" ]] && ok "doctor --json: stderr quiet" || bad "doctor --json stderr: $(head -3 "$WORK/doctor.err")"
./moav.sh doctor nosuchcheck --json >"$WORK/d.out" 2>/dev/null; rc=$?
[[ $rc -ne 0 && ! -s "$WORK/d.out" ]] && ok "doctor --json: unknown check -> non-zero, nothing on stdout" || bad "doctor nosuchcheck --json rc=$rc out=$(cat "$WORK/d.out")"

# 3b. sourced, with fake checks covering every rc and a prompt + secrets.
(
    pass=0; fail=0   # subshell keeps its own tally; the parent adds it back
    SCRIPT_DIR="$APP"; VERSION="test"
    # shellcheck source=/dev/null
    source "$ROOT/lib/doctor.sh"
    DOCTOR_CHECKS=("good:passes" "skipped:not applicable" "broken:fails" "nosy:prompts and prints secrets")
    doctor_check_good()    { echo -e "    ${GREEN}✓${NC} all fine"; return 0; }
    doctor_check_skipped() { echo "    ○ not on this host"; return 2; }
    doctor_check_broken()  { echo "    ✗ thing \"quoted\" failed"; echo "      Run: sudo fix"; return 1; }
    doctor_check_nosy()    {
        confirm "Show zone file?" "y" && echo "zone: A @ $SECRET_IP AAAA $SECRET_IP6"
        read -r -p "Truncate? [y/N] " ans; echo "answer='${ans:-}'"
        echo "link $SECRET_LINK key $SECRET_KEY uuid $SECRET_UUID pw $SECRET_PW"
        return 1
    }
    out=$(cmd_doctor --json 2>"$WORK/doctor2.err"); rc=$?
    valid_json "doctor --json (fake checks)" "$out"
    no_secrets "doctor --json (fake checks)" "$out"
    [[ $rc -ne 0 ]] && ok "doctor --json: exit non-zero when a check fails" || bad "doctor --json rc=$rc with a failing check"
    [[ "$(jget "$out" '",".join(c["id"]+"="+c["status"] for c in d)')" == "good=pass,skipped=warn,broken=fail,nosy=fail" ]] \
        && ok "doctor --json: rc 0/2/1 -> pass/warn/fail" || bad "doctor --json statuses: $(jget "$out" '[(c["id"],c["status"]) for c in d]')"
    [[ "$(jget "$out" 'd[2]["detail"]')" == '✗ thing "quoted" failed; Run: sudo fix' ]] && ok "doctor --json: multi-line detail joined + escaped" || bad "doctor detail: $(jget "$out" 'd[2]["detail"]')"
    printf '%s' "$(jget "$out" 'd[3]["detail"]')" | grep -q "answer=''" && ok "doctor --json: prompts get no input (stdin closed, confirm defaulted)" || bad "doctor --json: prompt detail = $(jget "$out" 'd[3]["detail"]')"
    [[ ! -s "$WORK/doctor2.err" ]] && ok "doctor --json (fake): nothing on stderr" || bad "doctor --json (fake) stderr: $(cat "$WORK/doctor2.err")"
    out=$(cmd_doctor good --json 2>/dev/null)
    [[ "$(jget "$out" 'len(d)')" == "1" ]] && ok "doctor <check> --json selects one check" || bad "doctor good --json: $out"
    exit $fail
) ; sub=$?; pass=$((pass + 8 - sub)); fail=$((fail + sub))   # 8 assertions in the subshell

# =============================================================================
# 4. moav user list --json  (real scripts/user-list.sh on fixture configs)
# =============================================================================
cat > configs/sing-box/config.json <<JSON
{"inbounds":[
 {"type":"vless","tag":"reality","users":[{"name":"alice","uuid":"$SECRET_UUID"},{"name":"bob","uuid":"$SECRET_UUID"}]},
 {"type":"trojan","tag":"trojan","users":[{"name":"alice","password":"$SECRET_PW"}]},
 {"type":"direct","tag":"decoy"}
]}
JSON
cat > configs/wireguard/wg0.conf <<CONF
[Interface]
PrivateKey = $SECRET_KEY
Address = 10.66.66.1/24

[Peer]
# alice
PublicKey = $SECRET_KEY
AllowedIPs = 10.66.66.2/32

[Peer]
# carol
PublicKey = $SECRET_KEY
AllowedIPs = 10.66.66.3/32
CONF
sed 's/10\.66\.66/10.67.67/; s/# carol/# alice/' configs/wireguard/wg0.conf > configs/amneziawg/awg0.conf
cat > configs/xray/config.json <<JSON
{"inbounds":[{"tag":"xhttp","settings":{"clients":[{"email":"alice@moav","id":"$SECRET_UUID"}]}},{"tag":"xdns","settings":{"users":[{"email":"bob@moav","id":"$SECRET_UUID"}]}}]}
JSON
printf '[[client]]\nusername = "bob"\npassword = "%s"\n' "$SECRET_PW" > configs/trusttunnel/credentials.toml
printf '[access.users]\nalice = "deadbeefdeadbeefdeadbeefdeadbeef"\n# comment\n' > configs/telemt/config.toml
mkdir -p outputs/bundles/alice outputs/bundles/alice-configs
printf '%s\n' "$SECRET_LINK" > outputs/bundles/alice/reality.txt

out=$(./moav.sh user list --json 2>"$WORK/list.err"); rc=$?
valid_json "user list --json" "$out"; no_secrets "user list --json" "$out"
[[ $rc -eq 0 ]] && ok "user list --json exits 0" || bad "user list --json rc=$rc"
[[ "$(jget "$out" '";".join(u["user"]+":"+",".join(u["services"])+":"+str(u["bundle"]) for u in d)')" == "alice:amneziawg,sing-box,telemt,wireguard,xray:True;bob:sing-box,trusttunnel,xray:False;carol:wireguard:False" ]] \
    && ok "user list --json: users merged across services, bundle flag, zip dir skipped" || bad "user list --json: $out"
[[ ! -s "$WORK/list.err" ]] && ok "user list --json: stderr quiet" || bad "user list --json stderr: $(head -3 "$WORK/list.err")"
printf '%s' "$out" | grep -q '10\.66\.66' && bad "user list --json leaks peer addresses" || ok "user list --json: no tunnel addresses"
out2=$(./moav.sh users --json 2>/dev/null)
[[ "$out2" == "$out" ]] && ok "'moav users --json' == 'moav user list --json'" || bad "users --json differs"
plain=$(./moav.sh user list 2>/dev/null)
printf '%s' "$plain" | grep -q '=== sing-box Users' && ok "plain 'moav user list' text unchanged" || bad "plain user list broke"

# =============================================================================
# 5. moav user add / remove --json  (fake provisioning scripts, real cmd_user)
# =============================================================================
rm -f scripts/user-add.sh scripts/user-revoke.sh scripts/reload-proxy.sh
cat > scripts/user-add.sh <<'ADD'
#!/bin/bash
# Fake: noisy on stdout like the real one; creates the bundle dir; "bad*" fails.
names=(); pkg=false
while [[ $# -gt 0 ]]; do case "$1" in --package|-p) pkg=true; shift ;; --batch) n="$2"; shift 2 ;; --prefix) pre="$2"; shift 2 ;; -*) echo "Unknown option: $1"; exit 1 ;; *) names+=("$1"); shift ;; esac; done
if [[ -n "${n:-}" ]]; then for i in $(seq 1 "$n"); do names+=("${pre:-user}$(printf %02d "$i")"); done; fi
rc=0
for u in "${names[@]}"; do
    echo "[INFO] Adding user '$u' to all services"
    echo "  share link: SECRET_LINK_MARKER"
    if [[ "$u" == bad* ]]; then echo "[ERROR] boom" >&2; rc=1; continue; fi
    mkdir -p "outputs/bundles/$u"; echo "[INFO] ✓ User '$u' created successfully"
done
exit $rc
ADD
cat > scripts/user-revoke.sh <<'REV'
#!/bin/bash
u="$1"; echo "[INFO] Revoking user '$u'"
[[ -d "outputs/bundles/$u" ]] || { echo "[ERROR] User '$u' not found" >&2; exit 1; }
rm -rf "outputs/bundles/$u"
REV
printf '#!/bin/bash\necho "[INFO] reloading proxies (noise)"\n' > scripts/reload-proxy.sh
chmod +x scripts/user-add.sh scripts/user-revoke.sh scripts/reload-proxy.sh

out=$(./moav.sh user add dave --json 2>"$WORK/add.err"); rc=$?
valid_json "user add --json" "$out"
[[ $rc -eq 0 ]] && ok "user add --json exits 0 on success" || bad "user add --json rc=$rc"
[[ "$(jget "$out" 'str(d["ok"])+"|"+d["action"]+"|"+d["users"][0]["user"]+"|"+str(d["users"][0]["ok"])+"|"+d["users"][0]["bundle_dir"]')" == "True|add|dave|True|outputs/bundles/dave" ]] \
    && ok "user add --json: {ok, action, users:[{user, ok, bundle_dir}]}" || bad "user add --json: $out"
printf '%s' "$out" | grep -q 'SECRET_LINK_MARKER\|\[INFO\]' && bad "user add --json: script noise on stdout" || ok "user add --json: stdout is only the document"
grep -q 'SECRET_LINK_MARKER' "$WORK/add.err" && ok "user add --json: script log went to stderr" || bad "user add --json: script log lost"
[[ -d outputs/bundles/dave ]] && ok "user add --json actually ran the script" || bad "user add --json did not create the user"

out=$(./moav.sh user add dave --json 2>/dev/null); rc=$?
[[ $rc -ne 0 && "$(jget "$out" 'str(d["ok"])+"|"+d["users"][0]["error"]')" == "False|already exists" ]] && ok "user add --json: duplicate -> ok:false, error, exit 1" || bad "user add dup: rc=$rc $out"

out=$(./moav.sh user add erin badguy --package --json 2>/dev/null); rc=$?
valid_json "user add (mixed) --json" "$out"
[[ $rc -ne 0 && "$(jget "$out" 'str(d["ok"])+"|"+",".join(u["user"]+"="+str(u["ok"]) for u in d["users"])')" == "False|erin=True,badguy=False" ]] \
    && ok "user add --json: per-user results, overall ok:false on any failure" || bad "user add mixed: rc=$rc $out"

out=$(./moav.sh user add 'bad name!' --json 2>/dev/null); rc=$?
valid_json "user add (invalid name) --json" "$out"
[[ $rc -ne 0 && "$(jget "$out" 'str(d["ok"])')" == "False" ]] && ok "user add --json: invalid username -> JSON error, exit 1" || bad "user add invalid: rc=$rc $out"

out=$(./moav.sh user add --batch 2 --prefix team --json 2>/dev/null); rc=$?
valid_json "user add --batch --json" "$out"
[[ $rc -eq 0 && "$(jget "$out" '",".join(u["user"] for u in d["users"])')" == "team01,team02" ]] && ok "user add --batch N --json reports the created names" || bad "user add batch: rc=$rc $out"

out=$(./moav.sh user remove dave nobody --json 2>"$WORK/rm.err"); rc=$?
valid_json "user remove --json" "$out"
[[ $rc -ne 0 && "$(jget "$out" 'd["action"]+"|"+",".join(u["user"]+"="+str(u["ok"]) for u in d["users"])')" == "remove|dave=True,nobody=False" ]] \
    && ok "user remove --json: per-user ok, unknown user -> ok:false + exit 1 (the text path always exits 0)" || bad "user remove: rc=$rc $out"
[[ ! -d outputs/bundles/dave ]] && ok "user remove --json actually revoked" || bad "user remove --json did not revoke"
printf '%s' "$out" | grep -q '\[INFO\]' && bad "user remove --json: script noise on stdout" || ok "user remove --json: stdout is only the document"
grep -q 'reloading proxies' "$WORK/rm.err" && ok "user remove --json: proxy reload ran (to stderr)" || bad "user remove --json: reload-proxy not run / not on stderr"
out=$(./moav.sh user revoke erin --json 2>/dev/null); rc=$?
[[ $rc -eq 0 && "$(jget "$out" 'str(d["ok"])')" == "True" ]] && ok "'user revoke --json' alias works, exit 0 on success" || bad "user revoke erin: rc=$rc $out"
out=$(./moav.sh user remove --all --json 2>/dev/null); rc=$?
[[ $rc -ne 0 ]] && valid_json "user remove --all --json (refused)" "$out" || bad "user remove --all --json must be refused"

# =============================================================================
# 6. surface: help + completions + `moav test --json` keeps stdout clean
# =============================================================================
help=$(./moav.sh help 2>/dev/null)
for c in "status \[--json\]" "doctor \[CHECK\] \[--json\]" "user list \[--json\]" "test USERNAME \[-v\] \[--json\]"; do
    printf '%s' "$help" | grep -q "$c" && ok "help documents: $c" || bad "help missing: $c"
done
grep -q -- '--json' "$ROOT/completions/moav.bash" && grep -q 'status|users)' "$ROOT/completions/moav.bash" && ok "bash completion knows --json" || bad "completions/moav.bash lacks --json"
# cmd_test: with --json the progress + build must be on stderr (the app used to
# scan backwards through docker build chatter for the last decodable object).
body=$(sed -n '/^cmd_test()/,/^}/p' "$ROOT/lib/menu.sh")
grep -q 'compose_build --profile client build client >&2' <<<"$body" && ok "moav test --json: image build routed to stderr" || bad "moav test --json: build output still on stdout"

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"

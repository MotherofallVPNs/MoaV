#!/bin/bash
# Regression test for the state<->.env Reality short_id desync guard (E4-4).
#
# The generated short_id lives in state/keys/reality.env, but docker-compose
# injects REALITY_SHORT_ID from .env (usually empty) into the bootstrap
# container. A render that reads the empty injected value writes an empty
# short_id, and EVERY Reality client is silently rejected (PR #152). The guard:
# assert_reality_in_render aborts the render if state has a short_id the
# rendered config does not contain. This test exercises that function in
# isolation against good and desynced configs.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "reality short_id desync guard tests"

# The guard must be wired into bootstrap at BOTH renders.
grep -q 'assert_reality_in_render /configs/sing-box/config.json' "$ROOT/scripts/bootstrap.sh" \
    && ok "sing-box render asserts short_id vs state" \
    || bad "sing-box render has no assert_reality_in_render"
grep -q 'assert_reality_in_render /configs/xray/config.json' "$ROOT/scripts/bootstrap.sh" \
    && ok "xray render asserts short_id vs state" \
    || bad "xray render has no assert_reality_in_render"
grep -q 'load_state_secrets' "$ROOT/scripts/bootstrap.sh" \
    && ok "renders re-source the whole secret class from state" \
    || bad "load_state_secrets not wired"
grep -q 'Reality short_id from state is ABSENT in config.json' "$ROOT/lib/doctor.sh" \
    && ok "doctor has the config<->state short_id check" \
    || bad "doctor missing the short_id desync check"

# Behavioural: extract assert_reality_in_render from bootstrap and run it against
# a good and a desynced config with a fake state dir.
STATE_DIR=$(mktemp -d); export STATE_DIR
trap 'rm -rf "$STATE_DIR" "$WORK"' EXIT
mkdir -p "$STATE_DIR/keys"
cat > "$STATE_DIR/keys/reality.env" <<EOF
REALITY_SHORT_ID=deadbeef
REALITY_PRIVATE_KEY=PRIVKEYVALUE123
EOF

log_error() { :; }   # silence
ENABLE_REALITY=true
# Pull the function body out of bootstrap.sh so we test the real code.
eval "$(awk '/^assert_reality_in_render\(\) \{/,/^\}/' "$ROOT/scripts/bootstrap.sh")"

WORK=$(mktemp -d)
good="$WORK/good.json"; bad_cfg="$WORK/bad.json"
# Pretty-printed (multi-line) like the REAL rendered config — the array spans
# lines ("short_id": [\n "deadbeef"\n]). A single-line fixture hid a bug where
# a line-based grep false-aborted bootstrap on the real (jq-formatted) config.
printf '{"inbounds":[{"tls":{"reality":{"short_id":["deadbeef"],"private_key":"PRIVKEYVALUE123"}}}]}\n' | jq . > "$good"
printf '{"inbounds":[{"tls":{"reality":{"short_id":[""],"private_key":""}}}]}\n' > "$bad_cfg"

( assert_reality_in_render "$good" ) && ok "good config passes the assert" \
    || bad "good config wrongly rejected"

# The desynced config must abort (non-zero). Run in a subshell so the exit
# doesn't kill the test.
if ( assert_reality_in_render "$bad_cfg" ) 2>/dev/null; then
    bad "desynced config (empty short_id) was NOT caught — the #152 outage would ship"
else
    ok "desynced config (empty short_id) is caught and aborts"
fi

# Base64url secret starting with '-': grep must treat it as a pattern, not an
# option (grep -qF --). This false-positived in e2e and aborted a healthy
# bootstrap — the short_id is hex so it never tripped, but the private key can
# start with '-'.
cat > "$STATE_DIR/keys/reality.env" <<EOF
REALITY_SHORT_ID=abcd1234
REALITY_PRIVATE_KEY=-Xleadingdashkey123
EOF
dash="$WORK/dash.json"
printf '{"inbounds":[{"tls":{"reality":{"short_id":["abcd1234"],"private_key":"-Xleadingdashkey123"}}}]}\n' > "$dash"
if ( assert_reality_in_render "$dash" ) 2>/dev/null; then
    ok "leading-dash private key present → passes (grep -qF -- honored)"
else
    bad "leading-dash private key wrongly rejected — grep parsed it as an option (missing --)"
fi

# The short_id check is anchored to the short_id/shortIds JSON field, not a bare
# substring: a config whose real short_id field is blank but where the 8-hex
# value coincidentally appears elsewhere (e.g. inside a UUID) must still ABORT.
cat > "$STATE_DIR/keys/reality.env" <<EOF
REALITY_SHORT_ID=deadbeef
REALITY_PRIVATE_KEY=PRIVKEYVALUE123
EOF
fp="$WORK/falsepos.json"
printf '{"inbounds":[{"users":[{"uuid":"deadbeef-1111-2222"}],"tls":{"reality":{"short_id":[""],"private_key":"PRIVKEYVALUE123"}}}]}\n' > "$fp"
if ( assert_reality_in_render "$fp" ) 2>/dev/null; then
    bad "short_id in a UUID gave a false PASS — the check is an unanchored substring"
else
    ok "short_id present only outside its field is caught (anchored check)"
fi

# When state short_id is empty (deliberate empty-short_id setup), no false abort.
echo "REALITY_SHORT_ID=" > "$STATE_DIR/keys/reality.env"
if ( assert_reality_in_render "$bad_cfg" ) 2>/dev/null; then
    ok "empty state short_id → no false positive"
else
    bad "empty state short_id wrongly aborted (false positive)"
fi

echo ""
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]

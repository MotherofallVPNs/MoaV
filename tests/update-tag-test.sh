#!/bin/bash
# Regression: `moav update -b <ref>` must accept a TAG (e.g. a release candidate
# like v2.3.0-rc.1), not only a branch.
#
# The bug (found testing an RC on a live box): `moav update -b v2.3.0-rc.1` failed
# with "Branch 'v2.3.0-rc.1' does not exist" because the switch only checked
# refs/heads and refs/remotes/origin. A tag lands in detached HEAD and must not be
# pulled, so it needs its own path.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
U="$ROOT/lib/update.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "moav update: -b accepts a tag (release candidate)"

grep -q 'refs/tags/\$target_branch' "$U" \
    && ok "resolves the target against refs/tags too" \
    || bad "does not recognize tags — an rc tag is rejected as a missing branch"
grep -q 'fetch --tags' "$U" \
    && ok "fetches tags first (a freshly-pushed rc tag would be unknown otherwise)" \
    || bad "does not fetch tags before resolving the target"
if grep -q 'switched_to_tag' "$U"; then
    ok "has a tag path (detached HEAD) that skips the pull"
else
    bad "no tag-specific path — it would try to 'git pull' a tag"
fi

# Functional: a tag checkout lands in detached HEAD and is not a branch you pull.
if command -v git >/dev/null 2>&1; then
    d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
    (
        cd "$d" && git init -q && git config user.email t@t && git config user.name t
        printf 'v1\n' > f && git add f && git commit -qm v1
        git tag v0.0.1-rc.1
        # the old check: is the tag a branch ref? (must be NO -> that was the bug)
        git show-ref --verify --quiet refs/heads/v0.0.1-rc.1 && echo "ISBRANCH" || echo "NOTBRANCH"
        # the new check: is it a tag ref? (must be YES)
        git show-ref --verify --quiet refs/tags/v0.0.1-rc.1 && echo "ISTAG" || echo "NOTAG"
        git checkout -q v0.0.1-rc.1 2>/dev/null && git symbolic-ref -q HEAD >/dev/null && echo "ONBRANCH" || echo "DETACHED"
    ) > "$d/o" 2>/dev/null
    grep -q '^NOTBRANCH$' "$d/o" && ok "a tag is not a branch ref (why the old check failed)" || bad "tag unexpectedly matched a branch ref"
    grep -q '^ISTAG$'     "$d/o" && ok "a tag IS a refs/tags ref (what the fix checks)"       || bad "tag did not match refs/tags"
    grep -q '^DETACHED$'  "$d/o" && ok "checking out a tag detaches HEAD (so we skip the pull)" || bad "tag checkout did not detach HEAD"
else
    printf '  SKIP  git unavailable for the functional check\n'
fi

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"

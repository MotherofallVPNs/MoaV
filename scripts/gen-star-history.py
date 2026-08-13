#!/usr/bin/env python3
"""Render assets/star-history.svg from this repo's own stargazer timestamps.

Why we generate it instead of embedding star-history.com: on 2026-06-30 GitHub
restricted /repos/{owner}/{repo}/stargazers to a repo's own admins and
collaborators, because the data was being harvested for spam. The hosted embed
still answers HTTP 200 for any repo, but the image it returns is now a notice
reading "GitHub restricted access to star data", not a chart. Their token
workaround does work, but it means handing a third party a credential that reads
this repo, embedded in a public README, and they describe it as temporary.

Building it here is the durable answer, but NOT from /stargazers: that endpoint
now wants an admin or collaborator, and a fine-grained PAT does not satisfy it at
any permission level. So the history lives in a committed JSON that grows from the
repo object's `stargazers_count` -- public, unauthenticated, and unaffected by the
restriction. /stargazers is used opportunistically, only to backfill history from
before that file existed, and its absence is not an error.

    python3 scripts/gen-star-history.py             # append today, render
    python3 scripts/gen-star-history.py --seed      # backfill true history once,
                                                    # needs a login that can read
                                                    # /stargazers (yours, not a PAT)
    python3 scripts/gen-star-history.py --check     # CI: fail if stale/missing

The layout deliberately mirrors star-history.com's -- 800x533 white card, "Star
History" title, "Date" axis, abbreviated star counts, repo legend -- because that
chart is what readers recognise. The one thing not copied is their xkcd webfont,
which is 58 KB of base64 and would be most of the file; FONT below is a
hand-drawn stack that falls back cleanly.

"""
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

# Comma-separated. A repo we cannot read is skipped with a warning rather than
# failing the run -- see fetch_stars().
REPOS = [r.strip() for r in os.environ.get(
    "STAR_REPOS", "MotherofallVPNs/MoaV,MotherofallVPNs/moav-client").split(",") if r.strip()]
# Pinned explicitly: without this header the stargazers call 403s for a token
# that can read the repo perfectly well, which cost an afternoon of adding
# permissions to a token that was never the problem. Bump it deliberately.
API_VERSION = os.environ.get("STAR_API_VERSION", "2026-03-10")
FAILED_REPOS = []   # unreadable repos, reported once at the end
OUT = os.environ.get("STAR_OUT", "assets/star-history.svg")
LOGO = os.environ.get("STAR_LOGO", "branding/favicon-56.png")
# Committed history. The chart no longer depends on being able to read
# /stargazers at run time: see fetch_count() and main().
DATA = os.environ.get("STAR_DATA", "assets/star-history.json")
# An additional store to fold in before appending. The chart branch is reset from
# the default branch on every run, so points accumulated while its PR sat unmerged
# would be dropped; the workflow points this at the branch's copy.
MERGE = os.environ.get("STAR_DATA_MERGE", "")
# The rendered chart is published to its own branch rather than committed to the
# default one: a generated file that changes daily is noise in main's history, and
# a branch needs no PR. The README embeds it by raw URL.
CHART_BRANCH = os.environ.get("STAR_BRANCH", "chart")
REPO_SLUG = os.environ.get("STAR_REPO_SLUG", "MotherofallVPNs/MoaV")

W, H = 800, 533
PAD_L, PAD_R, PAD_T, PAD_B = 84, 30, 62, 76
# Dark card in the site's register rather than star-history's white one: the
# layout is what readers recognise, and the palette is what makes it ours.
BG_TOP, BG_BOTTOM = "#1f1b33", "#14111f"
INK = "#e6e1f5"      # titles + axis names
MUTED = "#9a92b8"    # tick labels
GRID = "#ffffff"     # drawn at low opacity
AXIS = "#4a4266"
# MoaV's own accent purple leads; the logo cyan follows, so the two series read
# as the brand rather than as arbitrary chart colours.
SERIES = ["#a371f7", "#00d4ff"]
# Hand-drawn feel without embedding a webfont. Resolves per viewer, so the last
# entry matters: layout stays right even where none of the others exist.
FONT = ("'Comic Sans MS','Chalkboard SE','Marker Felt','Segoe Print',"
        "'Bradley Hand',cursive,sans-serif")


def fetch_stars(repo):
    """Every starred_at for one repo, oldest first. None if we cannot read it.

    A repo-scoped GITHUB_TOKEN is admin only on its OWN repo, so a second repo
    needs a token with access to both. Rather than fail the whole run when that
    secret is absent, skip the unreadable repo and chart the rest -- a chart
    missing one line beats no chart at all.
    """
    stamps, page = [], 1
    while True:
        try:
            out = subprocess.run(
                ["gh", "api", "-H", "Accept: application/vnd.github.star+json",
                 "-H", f"X-GitHub-Api-Version: {API_VERSION}",
                 f"repos/{repo}/stargazers?per_page=100&page={page}"],
                capture_output=True, text=True,
            )
        except FileNotFoundError:
            # No gh at all (a bare container, a stripped PATH). Timestamps are
            # optional -- the count path below carries the run.
            sys.stderr.write("skipping timestamps: gh is not installed\n")
            FAILED_REPOS.append(repo)
            return None
        if out.returncode != 0:
            err = out.stderr.strip()[:300]
            sys.stderr.write(f"skipping {repo}: {err}\n")
            FAILED_REPOS.append(repo)
            return None
        batch = json.loads(out.stdout or "[]")
        if not batch:
            break
        dated = [x["starred_at"] for x in batch if "starred_at" in x]
        if not dated:
            # The plain listing returns users with no timestamps, and a history
            # chart is nothing without them. Silently dropping them would render
            # a flat line and look like the repo stopped being starred.
            sys.stderr.write(
                f"skipping {repo}: got {len(batch)} stargazers but no starred_at field.\n"
                "  The 'application/vnd.github.star+json' media type was ignored, so this\n"
                f"  API version ({API_VERSION}) cannot return timestamps for this token.\n")
            FAILED_REPOS.append(repo)
            return None
        stamps += dated
        if len(batch) < 100:
            break
        page += 1
    return sorted(stamps)


def token_hint(repos):
    """Say what happened, once, and make clear the run did NOT fail.

    The 2026-06-30 restriction limits /stargazers to a repo's admins and
    collaborators, and a fine-grained PAT does not appear to satisfy that for any
    combination of permissions -- ticking more boxes is not the fix. A classic PAT
    or a user login works because it acts as the person. Since the only thing the
    endpoint adds is BACKFILL, this is not worth a broad credential in CI: the
    chart accumulates daily counts instead, and the past can be seeded once from
    a laptop that is already logged in.
    """
    sys.stderr.write(
        "\nnote: no star timestamps for " + ", ".join(repos) + " (see above).\n"
        "This is expected for a fine-grained token and is NOT a failure -- today's\n"
        "count was appended to " + DATA + " and the chart still renders.\n"
        "Only the history BEFORE this file existed needs /stargazers. To backfill\n"
        "it once, from a machine whose `gh auth status` shows you logged in as an\n"
        "admin of these repos:\n"
        "    python3 scripts/gen-star-history.py --seed\n"
        "then commit " + DATA + ". After that no credential is needed again.\n")


def logo_data_uri():
    """The watermark, inlined so the SVG stays self-contained."""
    try:
        import base64
        with open(LOGO, "rb") as f:
            return "data:image/png;base64," + base64.b64encode(f.read()).decode("ascii")
    except OSError:
        return ""


def fetch_count(repo):
    """Today's star total, or None.

    This is the endpoint that cannot break: stargazers_count on the repo object
    is public, needs no credential at all, and is unaffected by the 2026-06-30
    restriction on /stargazers. `gh` first so an authenticated run keeps its
    higher rate limit; plain HTTPS when gh is absent or unauthenticated.
    """
    try:
        out = subprocess.run(["gh", "api", f"repos/{repo}", "--jq", ".stargazers_count"],
                             capture_output=True, text=True)
        if out.returncode == 0 and out.stdout.strip().isdigit():
            return int(out.stdout.strip())
    except FileNotFoundError:
        pass
    try:
        import urllib.request
        with urllib.request.urlopen(f"https://api.github.com/repos/{repo}", timeout=15) as r:
            return int(json.load(r)["stargazers_count"])
    except Exception as e:                                   # noqa: BLE001
        sys.stderr.write(f"could not read the star count for {repo}: {e}\n")
        return None


def load_history():
    try:
        with open(DATA, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_history(hist):
    os.makedirs(os.path.dirname(DATA) or ".", exist_ok=True)
    with open(DATA, "w", encoding="utf-8") as f:
        json.dump(hist, f, indent=1, sort_keys=True)
        f.write("\n")


def merge_store(hist, other):
    """Union two stores by date. Cumulative counts only ever rise, so the higher
    value for a given day is the later reading and the right one to keep."""
    for repo, incoming in other.items():
        cur = hist.setdefault(repo, {"source": incoming.get("source", "counts"), "points": []})
        pts = {d: int(c) for d, c in cur.get("points", [])}
        for d, c in incoming.get("points", []):
            pts[d] = max(int(c), pts.get(d, 0))
        cur["points"] = [[d, pts[d]] for d in sorted(pts)]
        if incoming.get("source") == "timestamps":
            cur["source"] = "timestamps"
    return hist


def merge_point(points, day, count):
    """Insert or replace one (YYYY-MM-DD, count) point, keeping the list sorted."""
    kept = [p for p in points if p[0] != day]
    kept.append([day, int(count)])
    kept.sort(key=lambda p: p[0])
    return kept


def points_to_series(points):
    return [(datetime.strptime(d, "%Y-%m-%d").replace(tzinfo=timezone.utc), int(c))
            for d, c in points]


def build_series(stamps, max_points=110):
    """Cumulative (date, count), downsampled so the path stays small."""
    pts = [(datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc), i + 1)
           for i, s in enumerate(stamps)]
    if len(pts) <= max_points:
        return pts
    step = len(pts) / float(max_points)
    keep = [pts[int(i * step)] for i in range(max_points)]
    if keep[-1] != pts[-1]:
        keep.append(pts[-1])       # always land on the true current total
    return keep


def nice_ceil(n):
    if n <= 10:
        return 10
    for mult in (10, 25, 50, 100, 250, 500, 1000, 2500, 5000):
        if n <= mult * 4:
            return ((n + mult - 1) // mult) * mult
    return ((n + 9999) // 10000) * 10000


def kfmt(v):
    """1200 -> 1.2K, 2000 -> 2K, 340 -> 340. Matches star-history's tick style."""
    v = int(v)
    if v < 1000:
        return str(v)
    s = f"{v / 1000:.1f}".rstrip("0").rstrip(".")
    return f"{s}K"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def render(datasets):
    """datasets: list of (repo, [(datetime, cumulative_count), ...]) in draw order."""
    datasets = [(r, pts) for r, pts in datasets if len(pts) >= 2]
    if not datasets:
        raise SystemExit("no repo had enough stars to plot")

    t0 = min(p[0][0] for _, p in datasets)
    t1 = max(p[-1][0] for _, p in datasets)
    span = max((t1 - t0).total_seconds(), 1.0)
    ymax = nice_ceil(max(p[-1][1] for _, p in datasets))

    def x(dt):
        return PAD_L + (W - PAD_L - PAD_R) * ((dt - t0).total_seconds() / span)

    def y(v):
        return H - PAD_B - (H - PAD_T - PAD_B) * (v / ymax)

    # Y gridlines + abbreviated counts, like theirs.
    grid = []
    for i in range(5):
        v = ymax * i / 4
        gy = y(v)
        grid.append(f'<line x1="{PAD_L}" y1="{gy:.1f}" x2="{W - PAD_R}" y2="{gy:.1f}" '
                    f'stroke="{GRID}" stroke-opacity="0.07" stroke-width="1"/>')
        grid.append(f'<text x="{PAD_L - 12}" y="{gy + 5:.1f}" text-anchor="end" '
                    f'font-size="14" fill="{MUTED}">{kfmt(v)}</text>')

    # X ticks: years for a long history, month+year for a short one -- the same
    # judgement star-history makes (their sample spans a decade and shows years).
    years = span / (365.25 * 86400)
    fmt = "%Y" if years >= 2.5 else "%b %Y"
    nticks = 6 if years >= 2.5 else 5
    xt, seen = [], set()
    for i in range(nticks):
        dt = datetime.fromtimestamp(t0.timestamp() + span * (i / float(nticks - 1)),
                                    tz=timezone.utc)
        lab = dt.strftime(fmt)
        if lab in seen:
            continue
        seen.add(lab)
        tx = x(dt)
        xt.append(f'<line x1="{tx:.1f}" y1="{y(0):.1f}" x2="{tx:.1f}" y2="{y(0) + 6:.1f}" '
                  f'stroke="{AXIS}" stroke-width="1.5"/>')
        xt.append(f'<text x="{tx:.1f}" y="{y(0) + 26:.1f}" text-anchor="middle" '
                  f'font-size="14" fill="{MUTED}">{lab}</text>')

    # One line + fade per repo, drawn largest-first so a small series stays visible.
    defs, paths, legend = [], [], []
    for idx, (repo, pts) in enumerate(datasets):
        colour = SERIES[idx % len(SERIES)]
        xy = [(x(d), y(v)) for d, v in pts]
        line = " ".join(f"{'M' if i == 0 else 'L'}{px:.1f},{py:.1f}"
                        for i, (px, py) in enumerate(xy))
        area = line + f" L{xy[-1][0]:.1f},{y(0):.1f} L{xy[0][0]:.1f},{y(0):.1f} Z"
        defs.append(f'<linearGradient id="fade{idx}" x1="0" y1="0" x2="0" y2="1">'
                    f'<stop offset="0%" stop-color="{colour}" stop-opacity="0.22"/>'
                    f'<stop offset="100%" stop-color="{colour}" stop-opacity="0.02"/></linearGradient>')
        paths.append(f'<path d="{area}" fill="url(#fade{idx})"/>')
        paths.append(f'<path d="{line}" fill="none" stroke="{colour}" stroke-width="3" '
                     f'stroke-linejoin="round" stroke-linecap="round" filter="url(#glow)"/>')
        paths.append(f'<circle cx="{xy[-1][0]:.1f}" cy="{xy[-1][1]:.1f}" r="9" fill="{colour}" '
                     f'fill-opacity="0.22"/>'
                     f'<circle cx="{xy[-1][0]:.1f}" cy="{xy[-1][1]:.1f}" r="4.5" fill="{colour}"/>')
        ly = PAD_T + 14 + idx * 22
        legend.append(f'<circle cx="{PAD_L + 14}" cy="{ly - 4}" r="5" fill="{colour}"/>'
                      f'<text x="{PAD_L + 26}" y="{ly}" font-size="15" fill="{INK}">'
                      f'{esc(repo)} <tspan fill="{MUTED}">({pts[-1][1]})</tspan></text>')

    # Watermark: large, upper-LEFT. A cumulative curve starts low and rises, so
    # that quadrant is the reliably empty one -- and it keeps the mark away from
    # the smaller series, which hugs the bottom.
    logo = logo_data_uri()
    mark = ""
    if logo:
        size = 112
        mx, my = PAD_L + 22, PAD_T + 34
        mark = (f'<g opacity="0.30" filter="url(#logoshadow)">'
                f'<image href="{logo}" x="{mx}" y="{my}" width="{size}" height="{size}"/>'
                f'</g>')

    summary = ", ".join(f"{r} {p[-1][1]}" for r, p in datasets)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-label="Star history: {esc(summary)}">
  <title>Star History — {esc(summary)} as of {t1.strftime('%Y-%m-%d')}</title>
  <defs>
    <linearGradient id="card" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="{BG_TOP}"/><stop offset="100%" stop-color="{BG_BOTTOM}"/>
    </linearGradient>
    <filter id="logoshadow" x="-30%" y="-30%" width="180%" height="180%">
      <feDropShadow dx="0" dy="6" stdDeviation="9" flood-color="#000000" flood-opacity="0.55"/>
    </filter>
    <filter id="glow" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="3.5" result="b"/>
      <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    {"".join(defs)}
  </defs>
  <rect width="{W}" height="{H}" rx="10" fill="url(#card)"/>
  <rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="10" fill="none"
        stroke="#ffffff" stroke-opacity="0.06"/>
  <g font-family="{FONT}">
    <text x="{W / 2:.0f}" y="34" text-anchor="middle" font-size="22" fill="{INK}">Star History</text>
    {"".join(grid)}
    {"".join(paths)}
    <line x1="{PAD_L}" y1="{PAD_T}" x2="{PAD_L}" y2="{y(0):.1f}" stroke="{AXIS}" stroke-width="1.5"/>
    <line x1="{PAD_L}" y1="{y(0):.1f}" x2="{W - PAD_R}" y2="{y(0):.1f}" stroke="{AXIS}" stroke-width="1.5"/>
    {"".join(xt)}
    <text x="{W / 2:.0f}" y="{H - 18}" text-anchor="middle" font-size="15" fill="{INK}">Date</text>
    <text transform="translate(26,{H / 2:.0f}) rotate(-90)" text-anchor="middle"
          font-size="15" fill="{INK}">GitHub Stars</text>
    {"".join(legend)}
    {mark}
  </g>
</svg>
'''


def main():
    if "--check" in sys.argv:
        # Nothing is committed to this branch any more, so there is no artifact to
        # validate. What can still rot is the link (a renamed branch or file leaves
        # a broken image in the README) and the renderer itself.
        expected = f"refs/heads/{CHART_BRANCH}/{os.path.basename(OUT)}"
        readme = "README.md"
        try:
            body = open(readme, encoding="utf-8").read()
        except OSError as e:
            raise SystemExit(f"cannot read {readme}: {e}")
        if expected not in body:
            raise SystemExit(
                f"{readme} does not embed the chart from the publish location.\n"
                f"  expected a URL containing: {expected}\n"
                f"  the workflow publishes {os.path.basename(OUT)} to the "
                f"'{CHART_BRANCH}' branch, so the README image would 404.")
        # Render a two-point series offline: proves the drawing path works without
        # a network, a token, or a stored history.
        demo = [("acme/one", points_to_series([["2026-01-01", 1], ["2026-06-01", 50]]))]
        svg = render(demo)
        for needed in ("<svg", "Star History", "GitHub Stars", "</svg>"):
            if needed not in svg:
                raise SystemExit(f"the renderer produced no {needed!r}")
        print(f"gen-star-history: README embeds {expected}; renderer OK")
        return

    seeding = "--seed" in sys.argv
    # UTC day, passed in rather than computed twice, so a run that straddles
    # midnight cannot write two points for "today".
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    hist = load_history()
    if MERGE and os.path.isfile(MERGE) and os.path.abspath(MERGE) != os.path.abspath(DATA):
        try:
            hist = merge_store(hist, json.load(open(MERGE, encoding="utf-8")))
            print(f"gen-star-history: folded in {MERGE}")
        except ValueError as e:
            sys.stderr.write(f"ignoring unreadable {MERGE}: {e}\n")
    for repo in REPOS:
        entry = hist.get(repo) or {"source": "counts", "points": []}
        stamps = fetch_stars(repo)
        if stamps:
            # Timestamps are the truth: rebuild the whole series from them, which
            # also self-heals a history that had been accumulating daily counts.
            entry = {"source": "timestamps", "updated": today,
                     "points": [[d.strftime("%Y-%m-%d"), c]
                                for d, c in build_series(stamps)]}
        else:
            count = fetch_count(repo)
            if count is None:
                hist[repo] = entry
                continue
            pts = entry.get("points", [])
            if pts and int(pts[-1][1]) == int(count):
                # Flat day. A cumulative line needs no point to stay flat, and
                # writing one anyway would open a PR every night for nothing.
                pass
            else:
                entry["points"] = merge_point(pts, today, count)
                entry["updated"] = today
        hist[repo] = entry

    if seeding and any(e.get("source") != "timestamps" for e in hist.values()):
        # A seed run exists to capture real history. Letting it write a
        # counts-only file would look like success and quietly discard the past.
        raise SystemExit(
            "--seed needs full timestamp history for every repo and did not get it.\n"
            "Run it with a credential that can read /stargazers -- your own gh login\n"
            "works if you are an admin on these repos:  gh auth status")

    save_history(hist)

    datasets = [(repo, points_to_series(e["points"]))
                for repo, e in hist.items()
                if repo in REPOS and len(e.get("points", [])) >= 2]

    if FAILED_REPOS:
        token_hint(FAILED_REPOS)
    if not datasets:
        # Not a failure worth alarming on: with counts-only history a brand new
        # store has one point per repo and simply cannot be plotted yet.
        print(f"gen-star-history: {DATA} has fewer than 2 points per repo — "
              "nothing to plot yet, run again tomorrow (or seed it: --seed)")
        return
    # Largest total first: its fade is drawn under the smaller one's line.
    datasets.sort(key=lambda d: d[1][-1][1], reverse=True)
    svg = render(datasets)
    os.makedirs(os.path.dirname(OUT) or ".", exist_ok=True)
    old = open(OUT, encoding="utf-8").read() if os.path.isfile(OUT) else ""
    if old == svg:
        print(f"gen-star-history: {OUT} unchanged")
        return
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(svg)
    print(f"gen-star-history: wrote {OUT}")


if __name__ == "__main__":
    main()

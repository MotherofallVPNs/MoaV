#!/usr/bin/env python3
"""Render assets/star-history.svg from this repo's own stargazer timestamps.

Why we generate it instead of embedding star-history.com: on 2026-06-30 GitHub
restricted /repos/{owner}/{repo}/stargazers to a repo's own admins and
collaborators, because the data was being harvested for spam. The hosted embed
still answers HTTP 200 for any repo, but the image it returns is now a notice
reading "GitHub restricted access to star data", not a chart. Their token
workaround does work, but it means handing a third party a credential that reads
this repo, embedded in a public README, and they describe it as temporary.

This repo's own GITHUB_TOKEN *is* admin here, so the durable place to build the
chart is here. Output is a single committed SVG: no credential, no vendor, no
request leaving GitHub, and immune to the next policy change.

The layout deliberately mirrors star-history.com's -- 800x533 white card, "Star
History" title, "Date" axis, abbreviated star counts, repo legend -- because that
chart is what readers recognise. The one thing not copied is their xkcd webfont,
which is 58 KB of base64 and would be most of the file; FONT below is a
hand-drawn stack that falls back cleanly.

    GITHUB_TOKEN=... python3 scripts/gen-star-history.py
    python3 scripts/gen-star-history.py --check    # CI: fail if stale/missing
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
        out = subprocess.run(
            ["gh", "api", "-H", "Accept: application/vnd.github.star+json",
             "-H", f"X-GitHub-Api-Version: {API_VERSION}",
             f"repos/{repo}/stargazers?per_page=100&page={page}"],
            capture_output=True, text=True,
        )
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
    """One actionable block, not the same two lines under every repo.

    Since 2026-06-30 the stargazers endpoint is limited to a repo's admins and
    collaborators, so this needs a token that is one of those for EVERY repo in
    STAR_REPOS -- granting it on one repo leaves the others 403ing.
    """
    sys.stderr.write(
        "\ncould not read stargazers for: " + ", ".join(repos) + "\n"
        "Check, in this order:\n"
        "  1. the API version. This call sends X-GitHub-Api-Version: " + API_VERSION + ";\n"
        "     without it the endpoint 403s even for a token with full access.\n"
        "  2. the token's 'Repository access' list -- it needs every repo in\n"
        "     STAR_REPOS, not just one.\n"
        "  3. org approval: fine-grained tokens on org repos start as pending\n"
        "     under Settings -> Personal access tokens.\n"
        "verify before re-running the workflow (must print a starred_at field):\n"
        "  GH_TOKEN=<token> gh api -H 'Accept: application/vnd.github.star+json' \\\n"
        "    -H 'X-GitHub-Api-Version: " + API_VERSION + "' \\\n"
        "    'repos/%s/stargazers?per_page=1'\n" % repos[0])


def logo_data_uri():
    """The watermark, inlined so the SVG stays self-contained."""
    try:
        import base64
        with open(LOGO, "rb") as f:
            return "data:image/png;base64," + base64.b64encode(f.read()).decode("ascii")
    except OSError:
        return ""


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
        # Structural only: no network, so CI can gate the committed file.
        if not os.path.isfile(OUT):
            raise SystemExit(f"{OUT} is missing — run scripts/gen-star-history.py")
        body = open(OUT, encoding="utf-8").read()
        for needed in ("<svg", "Star History", "GitHub Stars", "</svg>"):
            if needed not in body:
                raise SystemExit(f"{OUT} does not look like a rendered chart (missing {needed!r})")
        print(f"gen-star-history: {OUT} present and well-formed")
        return

    datasets = []
    for repo in REPOS:
        stamps = fetch_stars(repo)
        if stamps:
            datasets.append((repo, build_series(stamps)))
    if FAILED_REPOS:
        token_hint(FAILED_REPOS)
    if not datasets:
        raise SystemExit("no readable repo in STAR_REPOS")
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

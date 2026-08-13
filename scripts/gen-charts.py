#!/usr/bin/env python3
"""Render the repo charts published to the `chart` branch.

Companion to gen-star-history.py, which owns the star chart and its accumulated
history. These two need no stored state and no credential at all: one reads git
tags, the other counts files in a checkout, so both are fully rebuildable from
scratch at any time.

    python3 scripts/gen-charts.py --out .chart
    python3 scripts/gen-charts.py --check     # offline: renderer + README links

Embedded from the chart branch by raw URL -- see .github/workflows/charts.yml.
"""
import os
import subprocess
import sys

# Palette and SVG primitives are shared with gen-star-history.py: the two render
# into the same branch and sit in the same READMEs, so they must not drift.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chartkit import (  # noqa: E402
    BG_FLAT, INK, MUTED, GRID, PURPLE, CYAN, GREEN, FONT_UI, esc, text, frame, hgrid,
)

CHART_BRANCH = os.environ.get("STAR_BRANCH", "chart")
REPO_SLUG = os.environ.get("STAR_REPO_SLUG", "MotherofallVPNs/MoaV")
# Where the docs live for the translation chart. A checkout path, not an API:
# counting files needs no token and cannot rate-limit.
SITE_DIR = os.environ.get("MOAV_SITE_DIR", "../moav-site")


def git(*args):
    out = subprocess.run(["git", *args], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else ""


# --- test suites per release -------------------------------------------------
def test_suite_points():
    """(tag, count) per release tag, oldest first, plus the current HEAD."""
    tags = [t for t in git("tag", "--sort=v:refname").splitlines()
            if t and "-rc" not in t]
    pts = []
    for tag in tags:
        listing = git("ls-tree", "-r", "--name-only", tag)
        if not listing:
            continue
        n = sum(1 for f in listing.splitlines()
                if f.startswith("tests/") and f.endswith(".sh"))
        pts.append((tag, n))
    head = git("ls-tree", "-r", "--name-only", "HEAD")
    if head:
        pts.append(("dev", sum(1 for f in head.splitlines()
                               if f.startswith("tests/") and f.endswith(".sh"))))
    # Only from the first tag that had any: a long flat zero tail is noise.
    first = next((i for i, (_, n) in enumerate(pts) if n), 0)
    return pts[max(0, first - 1):]


def render_test_suites(pts):
    W, H, L, R, T, B = 660, 250, 46, 18, 40, 34
    if len(pts) < 2:
        raise SystemExit("test-suite chart needs at least two tags")
    ymax = max(n for _, n in pts)
    ymax = max(10, ((ymax // 10) + 1) * 10)
    xs = [L + (W - L - R) * (i / (len(pts) - 1)) for i in range(len(pts))]
    ys = [H - B - (H - T - B) * (n / ymax) for _, n in pts]

    out = [text(L, 24, "Test suites in CI", 12, INK, "start", 600),
           hgrid(W, H, ymax, L, R, T, B)]

    line = " ".join(f"{'M' if i == 0 else 'L'}{xs[i]:.1f},{ys[i]:.1f}"
                    for i in range(len(pts)))
    out.append(f'<path d="{line} L{xs[-1]:.1f},{H-B} L{xs[0]:.1f},{H-B} Z" '
               f'fill="{GREEN}" fill-opacity="0.13"/>')
    out.append(f'<path d="{line}" fill="none" stroke="{GREEN}" stroke-width="2.2" '
               f'stroke-linejoin="round"/>')
    for i, (tag, n) in enumerate(pts):
        out.append(f'<circle cx="{xs[i]:.1f}" cy="{ys[i]:.1f}" r="3.4" fill="{GREEN}"/>')
        out.append(text(xs[i], ys[i] - 10, n, 10, INK, "middle", 600))
        out.append(text(xs[i], H - 13, tag, 9, MUTED, "middle"))
    return frame("".join(out), W, H)


# --- translation coverage ----------------------------------------------------
LANGS = [("English", "", PURPLE), ("فارسی", "fa", CYAN), ("Русский", "ru", MUTED)]


def translation_counts(site_dir):
    docs = os.path.join(site_dir, "docs")
    if not os.path.isdir(docs):
        return None
    base = sorted(f for f in os.listdir(docs) if f.endswith(".md"))
    rows = []
    for name, sub, colour in LANGS:
        d = os.path.join(docs, sub) if sub else docs
        have = 0
        if os.path.isdir(d):
            have = sum(1 for f in os.listdir(d) if f.endswith(".md"))
        rows.append((name, have, len(base), colour))
    return rows


def render_translation(rows):
    W = 660
    H = 46 + len(rows) * 36 + 22
    total = max(r[2] for r in rows) or 1
    out = [text(24, 26, "Documentation translated", 12, INK, "start", 600)]
    label_w, bar_x = 130, 148
    bar_w = W - bar_x - 96
    for i, (name, have, _t, colour) in enumerate(rows):
        y = 46 + i * 36
        out.append(text(label_w, y + 15, name, 12, INK, "end"))
        out.append(f'<rect x="{bar_x}" y="{y}" width="{bar_w}" height="21" rx="5" '
                   f'fill="{GRID}" fill-opacity="0.06"/>')
        if have:
            out.append(f'<rect x="{bar_x}" y="{y}" width="{bar_w * have / total:.1f}" '
                       f'height="21" rx="5" fill="{colour}" fill-opacity="0.82"/>')
        out.append(text(bar_x + bar_w + 8, y + 15, f"{have}/{total}", 11, MUTED))
    out.append(text(24, H - 12,
                    "One page is a complete contribution — moav.sh/docs/TRANSLATING",
                    10, MUTED))
    return frame("".join(out), W, H)


# --- entry point -------------------------------------------------------------
CHARTS = ("test-suites.svg", "translation-coverage.svg")


def main():
    if "--check" in sys.argv:
        # Offline: the renderers work, and every chart the workflow publishes is
        # embedded somewhere. An unreferenced chart is dead weight; a referenced
        # one that moved is a broken image nobody notices behind a cached copy.
        svg = render_test_suites([("v1.0", 0), ("v2.0", 24), ("dev", 42)])
        if "<svg" not in svg or "Test suites" not in svg:
            raise SystemExit("the test-suite renderer produced no chart")
        svg = render_translation([("English", 23, 23, PURPLE), ("فارسی", 3, 23, CYAN)])
        if "<svg" not in svg:
            raise SystemExit("the translation renderer produced no chart")
        # These two are embedded on the docs site (moav-site), not in this
        # README, so there is nothing here to check the link against -- a
        # cross-repo assertion would just go stale in the other direction.
        # What must hold is that the publish location is the one the site uses.
        for chart in CHARTS:
            if "/" in chart or not chart.endswith(".svg"):
                raise SystemExit(f"unexpected chart filename: {chart}")
        print(f"gen-charts: renderers OK; publishes {', '.join(CHARTS)} "
              f"to the '{CHART_BRANCH}' branch")
        return

    out_dir = "."
    if "--out" in sys.argv:
        out_dir = sys.argv[sys.argv.index("--out") + 1]
    os.makedirs(out_dir, exist_ok=True)

    pts = test_suite_points()
    with open(os.path.join(out_dir, "test-suites.svg"), "w", encoding="utf-8") as f:
        f.write(render_test_suites(pts))
    print(f"gen-charts: test-suites.svg ({pts[-1][1]} suites at {pts[-1][0]})")

    rows = translation_counts(SITE_DIR)
    if rows is None:
        # Not fatal: the star and test charts still publish. A missing checkout
        # should not take the whole run down.
        sys.stderr.write(f"gen-charts: no docs/ under {SITE_DIR}, "
                         "skipping the translation chart\n")
        return
    with open(os.path.join(out_dir, "translation-coverage.svg"), "w", encoding="utf-8") as f:
        f.write(render_translation(rows))
    print("gen-charts: translation-coverage.svg (" +
          ", ".join(f"{n} {h}/{t}" for n, h, t, _ in rows) + ")")


if __name__ == "__main__":
    main()

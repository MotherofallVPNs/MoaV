"""Shared drawing primitives for the charts published to the `chart` branch.

Both gen-star-history.py and gen-charts.py render into the same branch and are
embedded in the same READMEs, so the palette and the frame have to match exactly.
Keeping them in one place is the only way that stays true.
"""

# MoaV's accent purple leads, the logo cyan follows, so the charts read as the
# brand rather than as arbitrary chart colours.
BG_TOP, BG_BOTTOM = "#1f1b33", "#14111f"
BG_FLAT = "#191527"
INK = "#e6e1f5"       # titles
MUTED = "#9a92b8"     # tick labels
GRID = "#ffffff"      # drawn at low opacity
AXIS = "#4a4266"
PURPLE = "#a371f7"
CYAN = "#00d4ff"
GREEN = "#4ec9a5"
AMBER = "#f7c948"
SERIES = [PURPLE, CYAN]

# Resolves per viewer, so the last entry matters: layout stays right even where
# none of the others exist.
FONT_HAND = ("'Comic Sans MS','Chalkboard SE','Marker Felt','Segoe Print',"
             "'Bradley Hand',cursive,sans-serif")
FONT_UI = "system-ui,-apple-system,'Segoe UI',sans-serif"


def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def text(x, y, s, size=10, fill=MUTED, anchor="start", weight=400, font=FONT_UI):
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-family="{font}" font-size="{size}" '
            f'fill="{fill}" text-anchor="{anchor}" font-weight="{weight}">{esc(s)}</text>')


def frame(inner, w=660, h=250, bg=BG_FLAT, label="MoaV project chart"):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
            f'width="100%" role="img" aria-label="{esc(label)}">'
            f'<rect width="{w}" height="{h}" rx="10" fill="{bg}"/>{inner}</svg>')


def hgrid(w, h, ymax, left, right, top, bottom, n=4, fmt=str):
    """Horizontal gridlines with left-hand value labels."""
    out = []
    for i in range(n + 1):
        y = h - bottom - (h - top - bottom) * (i / n)
        out.append(f'<line x1="{left}" y1="{y:.1f}" x2="{w-right}" y2="{y:.1f}" '
                   f'stroke="{GRID}" stroke-opacity="0.06"/>')
        out.append(text(left - 8, y + 4, fmt(int(ymax * i / n)), 10, MUTED, "end"))
    return "".join(out)

#!/usr/bin/env python3
"""Format a Telegram message for the MoaV notifier from the GitHub event env.

Emits the message body to stdout (Telegram HTML parse_mode), or NOTHING when the
event shouldn't be announced (e.g. an issue labeled with something other than the
configured announce label) — the workflow skips sending on empty output.

Env in: EVENT, REPO, ANNOUNCE_LABEL, LABEL_ADDED, and event-specific vars.
"""
import html
import os
import re

# Release-notes bodies are typically 1–3 KB; Telegram's hard cap is 4096 chars
# (raw text incl. HTML tags). 3500 leaves ample room for the header + footer
# links while fitting a full release section without truncation.
MAX_BODY = 3500
HEADER_EMOJI = "🛡️"  # release header icon — change here (or set to "" for none)


def esc(s: str) -> str:
    return html.escape(s or "", quote=False)


def demarkdown(s: str) -> str:
    """Light-touch: strip markdown that renders as literal noise in HTML mode."""
    s = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", s)         # [text](url) -> text
    s = re.sub(r"^```[a-zA-Z0-9]*[ \t]*$", "", s, flags=re.M)  # code-fence lines
    s = re.sub(r"^#{1,6}[ \t]*", "", s, flags=re.M)        # # headers -> plain
    s = re.sub(r"^[ \t]*[-*_]{3,}[ \t]*$", "", s, flags=re.M)  # --- hr rules
    s = s.replace("**", "").replace("`", "")               # bold / code spans
    s = re.sub(r"\n{3,}", "\n\n", s)                       # collapse blank runs
    return s


def trim(s: str, limit: int = MAX_BODY) -> str:
    s = s.strip()
    if len(s) <= limit:
        return s
    cut = s[:limit]
    # Prefer to end on a newline, but only if one is near the end — otherwise a
    # long single-line bullet would collapse the whole body back to its header.
    nl = cut.rfind("\n")
    if nl >= limit - 300:
        cut = cut[:nl]
    return cut.rstrip() + "\n…"


def link(url: str, text: str) -> str:
    return f'<a href="{esc(url)}">{esc(text)}</a>'


def release() -> str:
    name = os.environ.get("REL_NAME") or os.environ.get("REL_TAG") or "New release"
    url = os.environ.get("REL_URL", "")
    body = trim(demarkdown(os.environ.get("REL_BODY", "")))
    head = f"{HEADER_EMOJI} " if HEADER_EMOJI else ""
    # Both repos post to the same channel — prefix the product so a release is
    # unambiguous. PRODUCT env wins; else the repo short-name. Skip if the
    # release name already leads with it (avoids "MoaV MoaV v1.9.1").
    product = os.environ.get("PRODUCT") or os.environ.get("REPO", "").split("/")[-1]
    label = name if (product and name.lower().startswith(product.lower())) else f"{product} {name}".strip()
    out = [f"{head}<b>{esc(label)}</b> is out"]
    if body:
        # Render the notes in a monospace code box (Telegram <pre>).
        out += ["", f"<pre>{esc(body)}</pre>"]
    out += ["", f"📦 {link(url, 'Release notes & downloads')}",
            f"🌐 {link('https://moav.sh', 'moav.sh')}"]
    return "\n".join(out)


def issue() -> str:
    announce = os.environ.get("ANNOUNCE_LABEL", "announce")
    if os.environ.get("LABEL_ADDED", "") != announce:
        return ""  # not an announce label -> skip
    repo = os.environ.get("REPO", "")
    num = os.environ.get("ISSUE_NUM", "")
    title = os.environ.get("ISSUE_TITLE", "")
    url = os.environ.get("ISSUE_URL", "")
    return (f"📣 <b>{esc(repo)} #{esc(num)}</b>\n{esc(title)}\n\n"
            f"🔗 {link(url, 'View on GitHub')}")


def main() -> None:
    event = os.environ.get("EVENT", "")
    if event == "release":
        msg = release()
    elif event == "issues":
        msg = issue()
    elif event == "workflow_dispatch":
        msg = esc(os.environ.get("DISPATCH_TEXT", "MoaV Telegram notifier test ✅"))
    else:
        msg = ""
    if msg:
        print(msg)


if __name__ == "__main__":
    main()

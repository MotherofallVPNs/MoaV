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

MAX_BODY = 900  # keep the whole message well under Telegram's 4096-char cap


def esc(s: str) -> str:
    return html.escape(s or "", quote=False)


def demarkdown(s: str) -> str:
    """Light-touch: strip markdown that renders as noise in HTML mode."""
    s = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", s)  # [text](url) -> text
    s = s.replace("**", "").replace("`", "")
    return s


def trim(s: str, limit: int = MAX_BODY) -> str:
    s = s.strip()
    if len(s) <= limit:
        return s
    return s[:limit].rsplit("\n", 1)[0].rstrip() + "\n…"


def link(url: str, text: str) -> str:
    return f'<a href="{esc(url)}">{esc(text)}</a>'


def release() -> str:
    name = os.environ.get("REL_NAME") or os.environ.get("REL_TAG") or "New release"
    url = os.environ.get("REL_URL", "")
    body = trim(demarkdown(os.environ.get("REL_BODY", "")))
    out = [f"🧅 <b>{esc(name)}</b> is out"]
    if body:
        out += ["", esc(body)]
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

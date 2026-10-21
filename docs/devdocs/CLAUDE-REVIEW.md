# Automated PR review & issue triage with Claude

Two GitHub Actions workflows run Claude Code on this repo:

- **`.github/workflows/claude-review.yml`** — the official
  [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action)
  with the `code-review` plugin. It reads the PR diff, reviews it against
  [`REVIEW.md`](../../REVIEW.md), and posts inline comments plus a grouped
  summary. **Review-only** — it never commits, pushes, or merges.
- **`.github/workflows/claude-issue-triage.yml`** — a custom prompt driving the
  `gh` CLI. It reads an issue, applies labels from the repo's **existing** label
  set, and posts one triage comment following [`TRIAGE.md`](../../TRIAGE.md).
  **Triage-only** — it never edits code, opens a PR, or closes issues.

Both are **advisory** (they don't block a merge) and augment human review — they
don't replace it. The rubric points the reviewer at `AGENTS.md` for repo context
(this repo uses `AGENTS.md`, not `CLAUDE.md`).

## One-time setup: the token

Auth is via a **Claude subscription** OAuth token (no API key needed):

1. On a machine with Claude Code, run:
   ```bash
   claude setup-token
   ```
2. Add it in GitHub under **Settings → Secrets and variables → Actions**:
   - Name: `CLAUDE_CODE_OAUTH_TOKEN`
   - Value: the token

   The MoaV org already sets this **at the org level**, so this repo inherits it
   — no per-repo secret needed unless you want to override it.
3. Approve the **Claude GitHub App** for the repo if prompted (the workflows
   authenticate as that app to post comments/labels — no personal token).

Usage counts against the subscriber's account.

## How to trigger it (admin-only for now)

Both run only when a maintainer asks — intentionally not on every PR/issue yet:

- **Review:** comment `@claude review` on a PR, or Actions → *Claude PR Review* →
  *Run workflow* → PR number. Re-comment after pushing to get a fresh pass.
- **Triage:** comment `@claude triage` on an issue, or Actions → *Claude Issue
  Triage* → *Run workflow* → issue number.

Only org members with write access (`OWNER` / `MEMBER` / `COLLABORATOR`) can
trigger via comment; other people's comments are ignored (the `author_association`
gate in each workflow's `if:`).

## Where to tweak

### Turn on automatic review / triage (the "hybrid" model)

Once the rubric is tuned and the signal-to-noise is good:

- **Review:** uncomment the `pull_request` trigger in `claude-review.yml`. The
  job's `if:` already carries a **diff-size guard** (`additions < 800`) on that
  branch, so very large PRs skip auto-review (a maintainer can still run them on
  demand). Adjust the threshold there.
- **Triage:** uncomment the `issues` trigger in `claude-issue-triage.yml` to
  triage every new issue.

Keep the comment and manual triggers so a maintainer can still re-run on demand.
Auto-on-open + on-demand is the hybrid model.

### Split into per-dimension review agents

`REVIEW.md` is written so each dimension (Security & opsec, Correctness & bash
safety, Tests, Docker & deploy) is self-contained. To run them as separate,
focused reviewers — e.g. a stricter security pass and a lighter style pass —
duplicate the `review` job per dimension and scope each prompt to its section
("review only the **Security & opsec** dimension of REVIEW.md"). Give each its
own summary heading. Start with one combined pass (current setup); split only
where a dimension earns its own cadence or gating.

## Cost and noise

- A run costs subscription usage; admin-gating keeps volume bounded while we
  calibrate.
- Nits are capped (see `REVIEW.md`); tighten severity there if reviews feel
  noisy.
- The check never blocks a merge. To gate on Important findings later, use a
  branch-protection rule against the review output, not a failing job.

## Sibling repos

The same two workflows run on **moav-client** (Go/TypeScript rubric) and
**moav-site** (docs/translation rubric). Each repo carries its own `REVIEW.md` /
`TRIAGE.md`; the `CLAUDE_CODE_OAUTH_TOKEN` secret is shared at the org level.

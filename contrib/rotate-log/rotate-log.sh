#!/bin/bash
# rotate-log.sh <log_path> <archive_prefix> — generic weekly archive+truncate
# for any append-mode log file that never rotates on its own. Archives go to
# a log_archive/ dir alongside the log file, named <prefix>_YYMMDD_HHMM.log.gz
#
# Generalized from rotate-conduit-log.sh (260804), which only handled
# conduit.log. Same logic, parameterized so router-log-data.log (added
# 260807, capture-router-log.py) can reuse it instead of duplicating the
# script — see conduit.md "Router log capture" and "conduit.log rotation".
#
# REVISION HISTORY (newest first):
#   260824 1557 - Fixed a real portability bug found while writing this
#            script's export README (checking testing claims before making
#            them, rather than after): the archive-age check used
#            `stat -f%m`, BSD/macOS-only syntax — Linux's `stat` needs
#            `-c%Y` for the same value. As written, this would have
#            silently misbehaved on Linux (either erroring or reading the
#            wrong field, depending on the exact stat implementation), not
#            failed loudly. Branched on `uname` so both platforms read the
#            correct field. Nothing else in this script is OS-specific —
#            it's plain file operations plus gzip throughout.
#   260824 1254 - Switched gzip from backgrounded (`nohup ... &`) to
#            synchronous + verified. The background version had been
#            silently failing on conduit.log's largest archives for weeks
#            (8/11, 8/18 both left a truncated .gz and an un-deleted
#            multi-GB raw copy, ~11GB wasted total) — see this same date's
#            note further down for the full story. A real timed test
#            showed synchronous gzip only takes 16-17s even on a ~5GB
#            file, so the backgrounding was solving a problem that barely
#            existed while creating a much worse one silently.
#   260807 - Generalized from rotate-conduit-log.sh to take log path +
#            archive prefix as arguments, so both conduit.log and the new
#            router-log-data.log can share one rotation script instead of
#            duplicating the copy-then-truncate-in-place logic. Jeff asked
#            directly whether router-log-data.log had the same rollover
#            protection as conduit.log — it didn't yet; this closes that gap.
#   260804 - Initial version (as rotate-conduit-log.sh), conduit.log only.
#            Uses copy-then-truncate-in-place, NOT rename: renaming would
#            break the writer's already-open append-mode file descriptor
#            (O_APPEND), requiring a restart of whatever's writing to it.
#            Truncating in place is safe — the next write just lands at the
#            new (zero) end-of-file. gzip runs in the background so a large
#            one-time archive doesn't block the caller.

LOG="$1"
PREFIX="$2"
ROTATE_DAYS=7

if [ -z "$LOG" ] || [ -z "$PREFIX" ]; then
    echo "Usage: rotate-log.sh <log_path> <archive_prefix>" >&2
    exit 1
fi

ARCHIVE_DIR="$(dirname "$LOG")/log_archive"
mkdir -p "$ARCHIVE_DIR"

latest_archive=$(ls -t "$ARCHIVE_DIR"/${PREFIX}_*.log.gz 2>/dev/null | head -1)

should_rotate=0
if [ -z "$latest_archive" ]; then
    should_rotate=1
else
    if [ "$(uname)" = "Darwin" ]; then
        archive_mtime=$(stat -f%m "$latest_archive")
    else
        archive_mtime=$(stat -c%Y "$latest_archive")
    fi
    age_seconds=$(( $(date +%s) - archive_mtime ))
    age_days=$(( age_seconds / 86400 ))
    if [ "$age_days" -ge "$ROTATE_DAYS" ]; then
        should_rotate=1
    fi
fi

if [ "$should_rotate" -eq 0 ]; then
    exit 0
fi

if [ ! -f "$LOG" ] || [ ! -s "$LOG" ]; then
    exit 0
fi

ts=$(date +%y%m%d_%H%M)
archive_path="$ARCHIVE_DIR/${PREFIX}_${ts}.log"

cp "$LOG" "$archive_path"
: > "$LOG"

# 260824: gzip used to run backgrounded (`nohup gzip ... &`) so a large
# one-time archive wouldn't block the caller. In practice this silently
# failed on conduit.log's multi-GB archives — the background gzip got cut
# off (most likely: this script is invoked from conduit-monitor.sh, itself
# a launchd StartCalendarInterval job that exits at the end of each 30-min
# cycle; nohup only blocks SIGHUP, it doesn't protect a child from launchd
# reaping the whole job's process group once the main script exits), 8/11
# and 8/18's rotations both left a truncated, corrupt .gz sitting next to
# an un-deleted multi-GB raw copy — 11GB of silent waste, only found when
# Jeff asked how log sizes were being managed. Timed a real synchronous
# gzip on one of those actual files: 16-17 seconds for ~5GB. That's a
# trivial one-time cost once a week, nowhere near enough to justify the
# fragile backgrounding. Running synchronously now, plus verifying the
# result before declaring success, so a bad archive can never look fine.
if gzip "$archive_path" && gzip -t "${archive_path}.gz"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Rotated $(basename "$LOG") -> ${archive_path}.gz (verified)"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: gzip of $archive_path failed or produced a corrupt archive — raw copy left in place at $archive_path for manual recovery, not deleted"
fi

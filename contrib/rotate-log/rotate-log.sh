#!/bin/bash
# rotate-log.sh <log_path> <archive_prefix> — generic weekly archive+truncate
# for any append-mode log file that never rotates on its own. Archives go to a
# log_archive/ dir alongside the log file, named <prefix>_YYMMDD_HHMM.log.gz.
# Copy-then-truncate-in-place, not rename: a rename would break the writer's
# open O_APPEND fd; truncating is transparent to an already-running writer.

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

# gzip synchronously and verify with `gzip -t` before declaring success. An
# earlier backgrounded (`nohup ... &`) version was silently reaped mid-run when
# the caller exited, leaving truncated .gz files next to un-deleted raw copies.
if gzip "$archive_path" && gzip -t "${archive_path}.gz"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Rotated $(basename "$LOG") -> ${archive_path}.gz (verified)"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: gzip of $archive_path failed or produced a corrupt archive — raw copy left in place at $archive_path for manual recovery, not deleted"
fi

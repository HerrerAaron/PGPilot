#!/bin/bash
set -euo pipefail

# Run from the project root regardless of where this script is invoked from.
cd "$(dirname "$0")/.."

# In CI, credentials come from the environment directly; .env is not committed.
if [ -f .env ]; then
    set -a; source .env; set +a
fi

BACKUP_DIR="./backups"
LOG_FILE="./logs/backup.log"
BACKUP_RETAIN_DAYS=7    # how long to keep old .dump files (backup rotation)
LOG_MAX_BYTES=1048576   # rotate backup.log once it exceeds 1MB
LOG_RETAIN_DAYS=30      # how long to keep rotated (archived) log files
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/${DB_NAME}_$TIMESTAMP.dump"

mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

# Log rotation: archive backup.log once it gets too large, and prune
# archived logs past their own retention window. Distinct from backup
# rotation below, which prunes old .dump files, not the log file itself.
rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
        mv "$LOG_FILE" "$LOG_FILE.$(date +%Y%m%d_%H%M%S).old"
    fi
    find "$(dirname "$LOG_FILE")" -name "$(basename "$LOG_FILE").*.old" -mtime "+$LOG_RETAIN_DAYS" -delete
}
rotate_log

log "Starting backup of $DB_NAME..."
# Network dump against $DB_HOST (local container, or the RDS endpoint) —
# PGSSLMODE from .env makes this encrypted automatically when DB_HOST is RDS.
PGPASSWORD="$DB_PASSWORD" pg_dump -h "${DB_HOST:-localhost}" -U "$DB_USER" -d "$DB_NAME" -Fc > "$BACKUP_FILE"
log "Backup complete: $BACKUP_FILE ($(du -sh "$BACKUP_FILE" | cut -f1))"

# Backup rotation: delete .dump files older than BACKUP_RETAIN_DAYS.
find "$BACKUP_DIR" -name '*.dump' -mtime "+$BACKUP_RETAIN_DAYS" -delete
log "Cleaned up backups older than $BACKUP_RETAIN_DAYS days"

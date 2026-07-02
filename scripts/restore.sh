#!/bin/bash
set -euo pipefail

# Run from the project root regardless of where this script is invoked from.
cd "$(dirname "$0")/.."

# In CI, credentials come from the environment directly; .env is not committed.
if [ -f .env ]; then
    set -a; source .env; set +a
fi

CONTAINER_NAME="taxidb-postgres"
LOG_FILE="./logs/backup.log"
LOG_MAX_BYTES=1048576   # rotate backup.log once it exceeds 1MB
LOG_RETAIN_DAYS=30      # how long to keep rotated (archived) log files

if [ $# -ne 1 ]; then
    echo "Usage: $0 <path/to/backup.dump>" >&2
    exit 1
fi

BACKUP_FILE="$1"
if [ ! -f "$BACKUP_FILE" ]; then
    echo "Backup file not found: $BACKUP_FILE" >&2
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

# Log rotation: archive backup.log once it gets too large, and prune
# archived logs past their own retention window.
rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
        mv "$LOG_FILE" "$LOG_FILE.$(date +%Y%m%d_%H%M%S).old"
    fi
    find "$(dirname "$LOG_FILE")" -name "$(basename "$LOG_FILE").*.old" -mtime "+$LOG_RETAIN_DAYS" -delete
}
rotate_log

log "Starting restore of $DB_NAME from $BACKUP_FILE..."
# --clean drops existing objects before recreating them from the dump;
# --if-exists avoids erroring on objects (e.g. a manually dropped table)
# that are already missing.
if [ "${CI:-}" = "true" ]; then
    PGPASSWORD="$DB_PASSWORD" pg_restore -h "${DB_HOST:-localhost}" -U "$DB_USER" -d "$DB_NAME" --clean --if-exists -Fc < "$BACKUP_FILE"
else
    docker exec -i "$CONTAINER_NAME" pg_restore -U "$DB_USER" -d "$DB_NAME" --clean --if-exists -Fc < "$BACKUP_FILE"
fi
log "Restore complete from $BACKUP_FILE"

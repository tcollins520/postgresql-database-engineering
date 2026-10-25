#!/usr/bin/env bash
#
# Script: lyris_prod-incremental-backup.sh
# Purpose: Create a daily incremental physical backup based on the latest
#          successful backup manifest in the active weekly chain.
#
# Schedule: Monday through Saturday at 02:00 server-local time (cron configured
#           separately). A successful full backup must exist before this runs.
#
# What this script does:
#   1. Enables restrictive default permissions for backup files.
#   2. Acquires the same non-blocking lock as the full backup script.
#   3. Reads and validates the current backup_state file.
#   4. Uses the most recent manifest as --incremental's parent.
#   5. Checks the new manifest and verifies the incremental backup files.
#   6. Updates backup_state only after the incremental backup succeeds.
#
# Safety notes:
#   - It does not delete older backups or backup chains.
#   - An incremental backup is not a standalone restore image.
#   - To prepare a complete backup for restore, use pg_combinebackup with the
#     full backup and every incremental in order, then verify the combined output.
#   - Test the complete restore process before relying on scheduled backups.
#
set -Eeuo pipefail
umask 077

# Backup locations and PostgreSQL connection settings.
BACKUP_ROOT="/var/lib/pgsql/backups/physical"
LOG_DIR="${BACKUP_ROOT}/logs"
STATE_FILE="${BACKUP_ROOT}/backup_state"
LOCK_FILE="${BACKUP_ROOT}/.lyris_prod_backup.lock"
PGHOST="${PGHOST:-/var/run/postgresql}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGBIN="${PGBIN:-/usr/pgsql-18/bin}"

# Use a unique timestamp for this run's log and backup directory.
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/incremental_${STAMP}.log"

# Create directories and acquire the same lock used by the full backup.
# This prevents the full and incremental scripts from running at the same time.
mkdir -p "$BACKUP_ROOT" "$LOG_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another physical backup is already running; exiting." >&2
  exit 1
fi

# Log both normal output and errors to a timestamped file.
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'rc=$?; echo "ERROR: incremental backup failed (exit ${rc}) at $(date -Is)"; exit "$rc"' ERR

echo "Starting PostgreSQL incremental backup at $(date -Is)"

# Confirm required PostgreSQL 18 backup utilities are present.
for cmd in "$PGBIN/pg_basebackup" "$PGBIN/pg_verifybackup"; do
  [[ -x "$cmd" ]] || { echo "Required executable not found: $cmd" >&2; exit 1; }
done

# An incremental cannot start a new chain: require a successful full backup's state.
[[ -s "$STATE_FILE" ]] || {
  echo "No backup state file found. Run a successful Sunday full backup first." >&2
  exit 1
}

# Load the state file written by these scripts.
# It is a local root/postgres-controlled file, not external user input.
# shellcheck disable=SC1090
source "$STATE_FILE"

# Confirm the active chain directory and most recent manifest still exist.
[[ -n "${chain_dir:-}" && -d "$chain_dir" ]] || {
  echo "State does not point to an existing backup chain directory." >&2
  exit 1
}
[[ -n "${last_manifest:-}" && -s "$last_manifest" ]] || {
  echo "Latest backup manifest is missing: ${last_manifest:-not set}" >&2
  exit 1
}

# Ensure the state file's manifest corresponds to the latest backup directory.
[[ "$last_manifest" == "$last_backup_dir/backup_manifest" ]] || {
  echo "State file paths are inconsistent; refusing to continue." >&2
  exit 1
}

# Check local PostgreSQL connectivity before creating backup files.
"$PGBIN/psql" -X -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres \
  -v ON_ERROR_STOP=1 -Atqc "SELECT 1" >/dev/null

# Store this incremental inside the current full-backup chain.
CHAIN_DIR="$chain_dir"
NEW_DIR="${CHAIN_DIR}/incremental_${STAMP}"
mkdir -m 700 "$NEW_DIR"

# Create an incremental whose parent is the most recent successful manifest.
# On each successful run, the next incremental will use this one as its parent.
"$PGBIN/pg_basebackup" \
  --host="$PGHOST" \
  --port="$PGPORT" \
  --username="$PGUSER" \
  --pgdata="$NEW_DIR" \
  --format=plain \
  --checkpoint=fast \
  --wal-method=stream \
  --manifest-checksums=SHA256 \
  --incremental="$last_manifest" \
  --progress

# Ensure the incremental manifest exists before considering state changes.
[[ -s "${NEW_DIR}/backup_manifest" ]] || {
  echo "Incremental backup manifest was not created; refusing to update state." >&2
  exit 1
}

# Verify the incremental backup files and their manifest.
# A full restore chain still needs pg_combinebackup to assemble the backups.
"$PGBIN/pg_verifybackup" "$NEW_DIR"

# Advance the state only after the new incremental has been created and verified.
# This makes the next run use this backup's manifest as its parent.
TMP_STATE="${STATE_FILE}.tmp.$$"
{
  printf 'chain_dir=%s\n' "$CHAIN_DIR"
  printf 'last_backup_dir=%s\n' "$NEW_DIR"
  printf 'last_manifest=%s\n' "${NEW_DIR}/backup_manifest"
  printf 'last_backup_type=incremental\n'
  printf 'last_success_epoch=%s\n' "$(date +%s)"
} > "$TMP_STATE"
chmod 600 "$TMP_STATE"
mv -f "$TMP_STATE" "$STATE_FILE"

echo "Incremental backup completed at $(date -Is)"
echo "Chain directory: $CHAIN_DIR"
echo "Latest incremental: $NEW_DIR"
echo "State updated: $STATE_FILE"
echo "Reminder: restore testing must combine the full backup and incrementals in order with pg_combinebackup."

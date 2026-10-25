#!/usr/bin/env bash
#
# Script: lyris_prod-full-backup.sh
# Purpose: Create and verify the weekly full physical backup for lyris_prod's
#          PostgreSQL instance. Intended to run as the postgres OS account.
#
# Schedule: Sunday at 02:00 server-local time (configured separately in cron).
#
# What this script does:
#   1. Enables restrictive default permissions for backup files.
#   2. Creates the backup and log directories if they do not exist.
#   3. Obtains a non-blocking shared lock so backups cannot overlap.
#   4. Checks that required PostgreSQL utilities and local connectivity work.
#   5. Runs pg_basebackup with streamed WAL and a SHA-256 backup manifest.
#   6. Checks for the manifest and runs pg_verifybackup.
#   7. Atomically updates backup_state only after the backup verifies.
#
# Safety notes:
#   - It does not delete older backups or backup chains.
#   - It does not configure cron, PostgreSQL, WAL archiving, or TLS.
#   - Test the backup and a restore procedure before relying on it in production.
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

# Use a unique timestamp for this run's directory and log file.
STAMP="$(date +%Y%m%d_%H%M%S)"
CHAIN_DIR="${BACKUP_ROOT}/full_${STAMP}"
LOG_FILE="${LOG_DIR}/full_${STAMP}.log"

# Create directories and acquire a lock shared with the incremental script.
mkdir -p "$BACKUP_ROOT" "$LOG_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another physical backup is already running; exiting." >&2
  exit 1
fi

# Send standard output and errors to the run log while also displaying them.
exec > >(tee -a "$LOG_FILE") 2>&1

# Record a clear error in the log if a command fails.
trap 'rc=$?; echo "ERROR: full backup failed (exit ${rc}) at $(date -Is)"; exit "$rc"' ERR

echo "Starting PostgreSQL full backup at $(date -Is)"
echo "Backup directory: $CHAIN_DIR"

# Fail early if PostgreSQL 18 backup utilities are missing.
for cmd in "$PGBIN/pg_basebackup" "$PGBIN/pg_verifybackup"; do
  [[ -x "$cmd" ]] || { echo "Required executable not found: $cmd" >&2; exit 1; }
done

# Confirm the configured local PostgreSQL connection works before starting.
"$PGBIN/psql" -X -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres \
  -v ON_ERROR_STOP=1 -Atqc "SELECT 1" >/dev/null

# Create a private directory for this full backup.
mkdir -m 700 "$CHAIN_DIR"

# Capture the data directory and stream required WAL into the backup.
# The manifest uses SHA-256 checksums for later integrity verification.
"$PGBIN/pg_basebackup" \
  --host="$PGHOST" \
  --port="$PGPORT" \
  --username="$PGUSER" \
  --pgdata="$CHAIN_DIR" \
  --format=plain \
  --checkpoint=fast \
  --wal-method=stream \
  --manifest-checksums=SHA256 \
  --progress

# Do not accept a backup that lacks its backup manifest.
[[ -s "${CHAIN_DIR}/backup_manifest" ]] || {
  echo "backup_manifest was not created; refusing to update state." >&2
  exit 1
}

# Verify the full backup files against the generated manifest.
"$PGBIN/pg_verifybackup" "$CHAIN_DIR"

# Update the state file only after successful backup and verification.
# Write to a temporary file first so an interruption does not leave partial state.
TMP_STATE="${STATE_FILE}.tmp.$$"
{
  printf 'chain_dir=%s\n' "$CHAIN_DIR"
  printf 'last_backup_dir=%s\n' "$CHAIN_DIR"
  printf 'last_manifest=%s\n' "${CHAIN_DIR}/backup_manifest"
  printf 'last_backup_type=full\n'
  printf 'last_success_epoch=%s\n' "$(date +%s)"
} > "$TMP_STATE"
chmod 600 "$TMP_STATE"
mv -f "$TMP_STATE" "$STATE_FILE"

echo "Full backup completed and verified at $(date -Is)"
echo "State updated: $STATE_FILE"

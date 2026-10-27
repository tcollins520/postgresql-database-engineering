# PostgreSQL 18 V2 --- Complete Implementation Runbook
PostgreSQL 18.6, repmgr 5.5.0\
**Project directory:** `~/Documents/postgres-centos-v2`\
**Purpose:** one end-to-end record of the PostgreSQL V2 work:
installation, database objects and RBAC, TLS/auditing, logical and
physical backups, recovery/PITR, streaming replication, manual failover
and rejoin, repmgr registration, controlled switchover, and the current
three-VM expansion.

> **Status discipline:** This runbook combines commands and results
> documented in the project notes. It separates completed work from
> validations that were not captured or are now stale. Do not rerun
> destructive historical commands just to reproduce an old result.
> Always inspect current roles, service status, paths, and backup
> locations first.

## 1. Architecture and current status

  -----------------------------------------------------------------------
  Node                    Private IP              Role / latest recorded
                                                  state
  ----------------------- ----------------------- -----------------------
  `postgres-v2-cs1`       `192.168.56.30`         Original primary; later
                                                  promoted back to
                                                  primary by successful
                                                  repmgr switchover.
                                                  Fresh post-switchover
                                                  streaming validation
                                                  was still required in
                                                  the last detailed
                                                  switchover runbook.

  `postgres-v2-cs2`       `192.168.56.31`         Original standby;
                                                  manual promotion and
                                                  later rejoin were
                                                  performed in the
                                                  earlier failover
                                                  exercise. In the latest
                                                  repmgr switchover
                                                  record, cs2 was shown
                                                  as primary and cs1 as
                                                  standby at that moment;
                                                  a subsequent documented
                                                  switchover promoted cs1
                                                  back. Verify live roles
                                                  before acting.

  `postgres-v2-cs3`       `192.168.56.32`         Third Vagrant VM is
                                                  running. PostgreSQL 18
                                                  installation was still
                                                  being resolved; do not
                                                  treat this as a
                                                  registered standby yet.
  -----------------------------------------------------------------------

Shared configuration:

-   PostgreSQL binaries: `/usr/pgsql-18/bin`
-   Data directory: `/var/lib/pgsql/18/data`
-   PostgreSQL service: `postgresql-18`
-   repmgr config: `/etc/repmgr/18/repmgr.conf`
-   repmgr service: `repmgr-18.service`
-   PostgreSQL port: `5432`
-   Guest OS: CentOS Stream 9 ARM64
-   Vagrant box: `bento/centos-stream-9`, version `202510.26.0`
-   Each VM: 1 vCPU, 1024 MiB RAM
-   **Intentional setting:** `failover='manual'` remains in place until
    the additional standby is installed and validated. Automatic
    failover is not yet considered implemented.

### Status summary

**Documented completed:** PostgreSQL 18.6 installation on cs1/cs2; RBAC
exercise and privilege verification; TLS and pgaudit setup/checks;
logical and physical backup work; physical-backup verification; isolated
restore on port 5433; PITR test on port 5434; migration of selected
`retail` objects into `lyris_prod`; physical streaming replication;
manual promotion/failover and former-primary rejoin; repmgr 5.5.0
registration; a successful repmgr-controlled switchover.

**Needs fresh validation / still in progress:** final streaming health
after the most recent switchover; cs3 PostgreSQL install and standby
clone/registration; three-node replication; automatic failover;
post-failover former-primary rejoin in the final repmgr-managed
topology; final tuning and end-to-end security review. The existence of
a historical command or screenshot does not prove the current VM still
has that state.

------------------------------------------------------------------------

## 2. Start and inspect the environment

Run on the Mac host:

``` bash
cd "$HOME/Documents/postgres-centos-v2"
vagrant status
vagrant validate
```

Start the VMs only if needed:

``` bash
vagrant up
vagrant status
```

Connect to a node:

``` bash
vagrant ssh postgres-v2-cs1
vagrant ssh postgres-v2-cs2
vagrant ssh postgres-v2-cs3
```

On each guest, verify identity, OS, resources, addresses, and PostgreSQL
status:

``` bash
hostname
cat /etc/centos-release
hostname -I
free -h
nproc
ip route
systemctl is-active postgresql-18
/usr/pgsql-18/bin/psql --version
```

Connectivity checks from the guest:

``` bash
ping -c 3 192.168.56.30
ping -c 3 192.168.56.31
ping -c 3 192.168.56.32
```

## 3. Provisioning and PostgreSQL 18 installation

### 3.1 OS preparation

The project used CentOS Stream 9 and the PGDG PostgreSQL packages. The
earlier two-node environment had the following base tools/services
installed:

``` bash
sudo dnf makecache
sudo dnf update -y
sudo dnf install -y curl vim chrony dnf-plugins-core
sudo systemctl enable --now chronyd
```

### 3.2 Install PGDG and PostgreSQL 18 on cs1/cs2

The PGDG repository RPM used on the ARM64 guests:

``` bash
sudo dnf install -y \
  https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-aarch64/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql
sudo dnf config-manager --set-enabled pgdg18
sudo dnf install -y postgresql18-server postgresql18
```

Verify:

``` bash
/usr/pgsql-18/bin/postgres --version
/usr/pgsql-18/bin/psql --version
rpm -q postgresql18-server postgresql18
```

On the **initial primary cs1**, initialize only if the cluster does not
already exist:

``` bash
sudo /usr/pgsql-18/bin/postgresql-18-setup initdb
sudo systemctl enable --now postgresql-18
sudo systemctl status postgresql-18 --no-pager
```

Do **not** initialize an independent cluster on a node intended to
become a physical standby. The standby must be seeded from the active
primary.

### 3.3 PGDG repository troubleshooting on cs3

On cs3, the repository RPM installed successfully, but some generated
repo URLs were malformed (for example, `rhel-9.-aarch64`) because of
release-variable expansion. The working repo URL corrections documented
for the `pgdg-common` and `pgdg18` sections were:

``` bash
sudo sed -i '/^\[pgdg-common\]/,/^\[/ s|^baseurl=.*|baseurl=https://download.postgresql.org/pub/repos/yum/common/redhat/rhel-9-aarch64|' /etc/yum.repos.d/pgdg-redhat-all.repo
sudo dnf --disablerepo='*' --enablerepo=pgdg-common makecache

sudo sed -i '/^\[pgdg18\]/,/^\[/ s|^baseurl=.*|baseurl=https://download.postgresql.org/pub/repos/yum/18/redhat/rhel-9-aarch64|' /etc/yum.repos.d/pgdg-redhat-all.repo
sudo dnf --disablerepo='*' --enablerepo=pgdg18 makecache
```

The next attempted install was:

``` bash
sudo dnf --disablerepo='pgdg*' \
  --enablerepo=pgdg-common \
  --enablerepo=pgdg18 \
  install -y postgresql18-server postgresql18
```

**Confirm its result before proceeding.** After installation:

``` bash
/usr/pgsql-18/bin/postgres --version
rpm -q postgresql18-server postgresql18
```

Do not initialize cs3 or start an independent database cluster. Its
planned role is a cloned standby.

------------------------------------------------------------------------

## 4. PostgreSQL administration and baseline checks

Run as the `postgres` OS account unless a command requires root:

``` bash
sudo -iu postgres
/usr/pgsql-18/bin/psql -X -d postgres
```

Useful checks:

``` sql
SELECT version();
SHOW data_directory;
SHOW config_file;
SHOW hba_file;
SHOW port;
SHOW listen_addresses;
SHOW ssl;
SHOW password_encryption;
SELECT pg_is_in_recovery();
```

Service checks (as root):

``` bash
sudo systemctl status postgresql-18 --no-pager -l
sudo journalctl -u postgresql-18 --no-pager -n 100
```

Role meaning:

-   `pg_is_in_recovery() = false`: the instance is acting as a primary.
-   `pg_is_in_recovery() = true`: the instance is in standby/recovery
    mode.

Always run this role check on both nodes before failover, switchover,
rejoin, or any data-directory operation.

## 5. Network access, firewall, authentication, and TLS

The two original nodes were configured for private-network connectivity,
PostgreSQL access through `pg_hba.conf`, and self-signed TLS. Firewall
state/rules and TLS certificate/key paths were inspected during the
implementation.

Inspect the active firewall and listeners:

``` bash
sudo firewall-cmd --state
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --list-all
sudo ss -lntp | grep 5432
```

Inspect effective PostgreSQL network/TLS settings:

``` sql
SHOW listen_addresses;
SHOW ssl;
SHOW ssl_cert_file;
SHOW ssl_key_file;
SHOW password_encryption;
```

Review HBA parsing errors after any edit:

``` sql
SELECT line_number, type, database, user_name, address, auth_method, error
FROM pg_hba_file_rules
WHERE error IS NOT NULL;
```

Reload after a safe `pg_hba.conf` edit:

``` sql
SELECT pg_reload_conf();
```

For replication, the documented narrow rule for the original standby
was:

``` text
hostssl replication replicator 192.168.56.31/32 scram-sha-256
```

During repmgr switchover troubleshooting, direction-specific `hostssl`
rules for role `repmgr` were also required. Check the current node roles
and addresses before applying these historical examples:

``` text
# On cs2, recorded for cs2-to-primary promotion testing
hostssl replication repmgr 192.168.56.30/32 scram-sha-256

# On cs1, reverse-direction counterpart
hostssl replication repmgr 192.168.56.31/32 scram-sha-256
```

Never copy private keys, passwords, `.pgpass`, or backup contents into
the repository.

## 6. Administrative and application roles

The installation/security exercise created an administrative login role
(`dba_admin`) and tested remote/local authenticated connections.
Passwords are intentionally omitted from this runbook.

Use `\du+` and catalog queries to verify roles rather than displaying
secrets:

``` sql
\du+
SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolcanlogin
FROM pg_roles
ORDER BY rolname;
```

For a new role password, use an interactive prompt such as
`\password role_name` rather than putting the password into shell
history.

------------------------------------------------------------------------

## 7. RBAC implementation and verification

RBAC was implemented and tested in the `lyris_prod` database with
separate owner, application, reporting, read-only, and read-write
responsibilities. Documented role names include:

-   `lyris_owner` --- object owner, `NOLOGIN`
-   `lyris_app` --- application login
-   `lyris_report` --- reporting/read-only login
-   `retail_app_ro` --- read-only role for migrated retail tables
-   `retail_app_rw` --- read/write role for migrated retail tables

The recorded validation showed `retail_app_ro` had `SELECT` on the
migrated tables; `retail_app_rw` had `SELECT`, `INSERT`, `UPDATE`, and
`DELETE`; and read-write `USAGE` on the four relevant sequences was
verified. The separate `lyris_app` / `lyris_report` exercise verified
successful read/write operations for the application login and denied
write operations for the reporting login.

### 7.1 Inspect roles and grants

Connect to the correct database:

``` bash
psql -X -d lyris_prod
```

``` sql
\du+
\dn+
\dp sales.*
\dp inventory.*
SELECT grantee, table_schema, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema IN ('sales', 'inventory', 'reporting')
ORDER BY table_schema, table_name, grantee, privilege_type;
```

Check sequence privileges:

``` sql
SELECT grantee, object_schema, object_name, privilege_type
FROM information_schema.usage_privileges
WHERE object_schema IN ('sales', 'inventory', 'reporting')
ORDER BY object_schema, object_name, grantee;
```

Check owner/login separation:

``` sql
SELECT rolname, rolcanlogin, rolsuper, rolcreatedb, rolcreaterole
FROM pg_roles
WHERE rolname IN ('lyris_owner', 'lyris_app', 'lyris_report',
                  'retail_app_ro', 'retail_app_rw')
ORDER BY rolname;
```

Expected design: `lyris_owner` is `NOLOGIN`; application and reporting
accounts can log in; application/reporting users do not receive
superuser privileges.

### 7.2 Reusable least-privilege grant pattern

The exact original SQL transcript is not fully preserved in the project
notes, so treat this as a **reproducible grant pattern**, not a claim
that every line below was typed verbatim during the earlier session.
Apply only after checking current schemas, objects, owners, and existing
grants.

``` sql
-- Run as the object owner or authorized DBA, in lyris_prod.
GRANT USAGE ON SCHEMA sales, inventory, reporting TO retail_app_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA sales, inventory, reporting TO retail_app_ro;

GRANT USAGE ON SCHEMA sales, inventory, reporting TO retail_app_rw;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON ALL TABLES IN SCHEMA sales, inventory, reporting TO retail_app_rw;

-- Sequence privileges are required for inserts that use generated IDs.
GRANT USAGE, SELECT
  ON ALL SEQUENCES IN SCHEMA sales, inventory, reporting TO retail_app_rw;
```

For future objects, default privileges must be set by the role that will
create those objects. Example:

``` sql
ALTER DEFAULT PRIVILEGES FOR ROLE lyris_owner IN SCHEMA sales, inventory, reporting
  GRANT SELECT ON TABLES TO retail_app_ro;

ALTER DEFAULT PRIVILEGES FOR ROLE lyris_owner IN SCHEMA sales, inventory, reporting
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO retail_app_rw;

ALTER DEFAULT PRIVILEGES FOR ROLE lyris_owner IN SCHEMA sales, inventory, reporting
  GRANT USAGE, SELECT ON SEQUENCES TO retail_app_rw;
```

### 7.3 Permission exercise

Use a known test table and disposable test row. The prior exercise
confirmed read-only `SELECT` succeeds while `INSERT`, `UPDATE`, and
`DELETE` are denied; the read-write role successfully read and changed
test data.

``` sql
-- As a read-only account:
SELECT * FROM sales.customers LIMIT 5;
-- These should fail with permission denied:
-- INSERT INTO sales.customers (...) VALUES (...);
-- UPDATE sales.customers SET ... WHERE ...;
-- DELETE FROM sales.customers WHERE ...;

-- As a read-write account, use a disposable row and clean it up after testing.
```

Do not execute example write statements with guessed columns or
production data. Substitute the actual table definition and test record.

------------------------------------------------------------------------

## 8. Database objects, sample data, and migration

The project used a `retail` source database and migrated selected
objects into `lyris_prod`. The custom-format dump covered the `sales`,
`inventory`, and `reporting` schemas. The restore used `--no-owner` and
`--no-acl`, preserving pre-existing `etk` objects in the destination.

Recorded row counts after migration:

  Object                   Expected row count
  ---------------------- --------------------
  `sales.customers`                        10
  `sales.orders`                           10
  `sales.order_items`                      20
  `inventory.products`                     10

Inspect objects and counts:

``` sql
\l
\dn+
\dt sales.*
\dt inventory.*
SELECT count(*) FROM sales.customers;
SELECT count(*) FROM sales.orders;
SELECT count(*) FROM sales.order_items;
SELECT count(*) FROM inventory.products;
```

The counts were checked on the primary and standby. After validation,
`retail` was retired on the primary using:

``` sql
DROP DATABASE retail WITH (FORCE);
```

A later standby check confirmed `retail` was absent and `lyris_prod`
remained available. This is destructive; do not rerun it. Keep migration
archives until the acceptance and rollback window has passed.

------------------------------------------------------------------------

## 9. Auditing with pgaudit

The PostgreSQL 18 `pgaudit` package/extension and audit logging were
configured and checked on both nodes. `pgaudit` was also included in
`shared_preload_libraries`.

Verify the loaded setting:

``` sql
SHOW shared_preload_libraries;
```

The corrected value used with repmgr was:

``` text
pgaudit,repmgr
```

**Do not put a space after the comma** in the setting as tested in this
environment: `pgaudit, repmgr` caused a library-load problem.

Check installed extension and logs:

``` sql
SELECT extname, extversion FROM pg_extension ORDER BY extname;
SHOW log_destination;
SHOW logging_collector;
```

``` bash
sudo journalctl -u postgresql-18 --no-pager -n 100
sudo find /var/lib/pgsql/18/data/log -maxdepth 1 -type f -print 2>/dev/null
```

Confirm that the relevant audited statements actually appear in
PostgreSQL logs; configuration alone is not proof of successful audit
capture.

------------------------------------------------------------------------

## 10. WAL archiving and archive checks

The backup/recovery work included WAL archive directory preparation,
restrictive permissions, archiver-statistics checks, and archived-WAL
inspection. Confirm actual paths in the current configuration before
using a path from old notes.

``` sql
SHOW archive_mode;
SHOW archive_command;
SHOW wal_level;
SELECT * FROM pg_stat_archiver;
```

On the guest, inspect filesystem and archive size (replace the path only
after checking `archive_command`):

``` bash
df -h
sudo du -sh /var/lib/pgsql/18/data
sudo find /var/lib/pgsql/18/data -maxdepth 2 -type d -name '*archive*' -print
```

WAL archiving validation included checking `pg_stat_archiver` counters
and listing archived WAL segments. A configured archive command is not
sufficient by itself: verify that archived files are appearing and that
the failure counter is not increasing.

------------------------------------------------------------------------

## 11. Logical backup and restore validation

The project created a logical baseline dump and tested restoring it to a
test database. A logical-backup script was installed under
`/usr/local/bin`, with a dedicated backup/log directory, restrictive
permissions, retention/error handling, and a daily cron schedule. The
physical-backup script was also installed and its schedule inspected.

### 11.1 Manual logical backup pattern

Use the actual database name and destination path from the installed
script. A custom-format dump pattern is:

``` bash
sudo -iu postgres
pg_dump -Fc -d retail -f /path/to/approved/backup/retail_$(date +%Y%m%d_%H%M%S).dump
pg_restore --list /path/to/approved/backup/retail_YYYYMMDD_HHMMSS.dump
```

`/path/to/approved/backup` and the timestamped filename above are
placeholders, not literal paths from the historical run. Do not
overwrite an existing backup.

Restore to an isolated test database only after confirming it does not
already exist:

``` bash
createdb retail_restore_test
pg_restore --no-owner --no-acl \
  -d retail_restore_test \
  /path/to/approved/backup/retail_YYYYMMDD_HHMMSS.dump
```

Validate object and row counts, then remove the test database only after
confirming it is the disposable test target:

``` bash
psql -d retail_restore_test -c '\dn+'
psql -d retail_restore_test -c '\dt *.*'
```

### 11.2 Backup script, permissions, and schedule checks

The earlier work installed scripts in `/usr/local/bin`; use these
non-destructive checks to discover the exact filenames and inspect
schedules without exposing passwords:

``` bash
sudo find /usr/local/bin -maxdepth 1 -type f -iname '*backup*' -ls
sudo ls -ld /path/to/backup /path/to/backup/logs
sudo crontab -u postgres -l
sudo stat -c '%U %G %a %n' /usr/local/bin/*backup* 2>/dev/null
```

Check the actual script before executing it. Never print `.pgpass`
contents into a transcript or commit them.

------------------------------------------------------------------------

## 12. Physical backup, verification, and isolated restore

Physical backup work included `pg_basebackup`, manifest verification
with `pg_verifybackup`, inspection with `pg_controldata`, and launching
a restored copy on port `5433` to validate its data without replacing
the active cluster.

### 12.1 Verify the backup

Use the real backup directory from the configured script/cron entry:

``` bash
sudo -iu postgres
/usr/pgsql-18/bin/pg_verifybackup /path/to/physical/backup
/usr/pgsql-18/bin/pg_controldata /path/to/physical/backup
```

The physical backup's manifest was checked with `pg_verifybackup`; the
backup's control metadata was inspected.

### 12.2 Isolated physical restore on port 5433

The historical exercise copied a verified physical backup to an isolated
recovery-demo directory, reviewed its configuration, prepared a separate
socket directory, and started it on port `5433`. Do not point this at
the live PGDATA.

First verify the port is unused and inspect paths:

``` bash
ss -lntp | grep ':5433' || true
ls -ld /path/to/recovery-demo
```

Use the actual recorded recovery-demo path and configuration. The
instance must have a separate data directory, separate Unix-socket
directory, and `port = 5433`. Start and validate using the chosen
configuration, then stop the isolated instance after the test.

``` bash
/usr/pgsql-18/bin/pg_ctl -D /path/to/recovery-demo -l /path/to/recovery-demo/server.log start
/usr/pgsql-18/bin/pg_isready -p 5433
psql -p 5433 -d postgres -c 'SHOW data_directory;'
psql -p 5433 -d postgres -c 'SELECT pg_is_in_recovery();'
psql -p 5433 -d lyris_prod -c '\dn+'
```

After validating the recovered objects and row counts:

``` bash
/usr/pgsql-18/bin/pg_ctl -D /path/to/recovery-demo -m fast stop
```

The paths above are placeholders because the exact historical
recovery-demo directory is not present in the summary text. Resolve it
from the actual script/history before running commands.

------------------------------------------------------------------------

## 13. Point-in-time recovery (PITR)

The documented PITR exercise prepared a separate data directory from a
physical backup, verified the backup manifest, configured
`recovery.signal`, a recovery target timestamp, and `restore_command`,
then launched an isolated instance on port `5434`. The recovered data
was queried to validate the recovery target.

PITR configuration concepts used:

``` text
# In the isolated PITR instance's configuration only:
restore_command = '...'
recovery_target_time = 'YYYY-MM-DD HH:MI:SS'
recovery_target_action = 'pause'
```

The exact `restore_command`, target timestamp, archive directory, and
data-directory paths must come from the actual saved
configuration/script; do not invent them. A generic command is not safe
to run until the real WAL archive and backup locations are known.

Validation commands after starting the isolated instance:

``` bash
/usr/pgsql-18/bin/pg_isready -p 5434
psql -p 5434 -d postgres -c 'SHOW data_directory;'
psql -p 5434 -d postgres -c 'SELECT pg_is_in_recovery();'
psql -p 5434 -d lyris_prod -c '\dn+'
psql -p 5434 -d lyris_prod -c 'SELECT count(*) FROM sales.customers;'
```

The project notes record recovery/PITR testing and validation of
restored application objects/rows. Do not treat a successful PITR test
as a substitute for checking backup freshness, WAL continuity, and
actual recovery objectives.

------------------------------------------------------------------------

## 14. Configure physical streaming replication

The original two-node cluster used asynchronous streaming replication
over TLS. Recorded settings included:

``` text
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 0
max_wal_size = 1GB
min_wal_size = 80MB
hot_standby = on
```

Verify current effective values on each node:

``` sql
SHOW wal_level;
SHOW max_wal_senders;
SHOW max_replication_slots;
SHOW wal_keep_size;
SHOW max_wal_size;
SHOW min_wal_size;
SHOW hot_standby;
```

### 14.1 Replication role and HBA

The `replicator` role was created with `LOGIN` and `REPLICATION`, not
`SUPERUSER`. Verify:

``` sql
SELECT rolname, rolcanlogin, rolreplication, rolsuper
FROM pg_roles
WHERE rolname = 'replicator';
```

The recorded `pg_hba.conf` rule on the primary allowed the standby at
`192.168.56.31` using TLS and SCRAM:

``` text
hostssl replication replicator 192.168.56.31/32 scram-sha-256
```

Reload and inspect HBA errors after any approved edit:

``` sql
SELECT pg_reload_conf();
SELECT line_number, type, database, user_name, address, auth_method, error
FROM pg_hba_file_rules
WHERE error IS NOT NULL;
```

### 14.2 Seed cs2 from cs1 with pg_basebackup

This is the **historical command pattern** used to initialize cs2. Do
not rerun it against the existing PGDATA unless intentionally rebuilding
the standby after confirming the active primary and preserving anything
needed.

``` bash
pg_basebackup \
  -D /var/lib/pgsql/18/data \
  -h 192.168.56.30 \
  -p 5432 \
  -U replicator \
  -d "host=192.168.56.30 port=5432 user=replicator dbname=replication sslmode=require" \
  -w -F plain -X stream -P -R \
  --manifest-checksums=SHA256
```

The command reached 100% and completed in the recorded session. `-R`
writes standby connection settings and creates `standby.signal`;
`-X stream` streams WAL during the base backup; the manifest uses
SHA-256 checksums.

The `postgres` OS account used `/var/lib/pgsql/.pgpass` with mode
`0600`. A duplicate matching entry with an empty password previously
caused a "no password supplied" error. Never print the actual password
file.

### 14.3 Physical replication slot

The initial slot on cs1 was `cs2_standby`; cs2 was configured with
`primary_slot_name = 'cs2_standby'`.

Inspect current slots first:

``` sql
SELECT slot_name, slot_type, active, restart_lsn
FROM pg_replication_slots;
```

Historical creation command, only if the correct current primary is
confirmed and the slot is absent:

``` sql
SELECT pg_create_physical_replication_slot('cs2_standby');
```

Historical standby setting:

``` sql
ALTER SYSTEM SET primary_slot_name = 'cs2_standby';
```

After a role change, slot direction/names change. The earlier rejoin
exercise used `cs1_standby` on the then-current primary. Do not create
or change slots until current roles and `primary_slot_name` have been
inspected.

### 14.4 Verify streaming and data consistency

On the current primary:

``` sql
SELECT application_name, client_addr, state, sync_state,
       sent_lsn, write_lsn, flush_lsn, replay_lsn
FROM pg_stat_replication;

SELECT slot_name, slot_type, active, restart_lsn
FROM pg_replication_slots;
```

On the current standby:

``` sql
SELECT pg_is_in_recovery();

SELECT status, sender_host, sender_port, slot_name,
       written_lsn, flushed_lsn, latest_end_lsn
FROM pg_stat_wal_receiver;

SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();
```

The recorded initial validation showed cs2 streaming from
`192.168.56.30`, the `cs2_standby` slot active, matching
received/replayed LSNs at a later check, and lag reaching `0 bytes`. A
temporary `public.replication_validation` table was inserted and checked
on the standby, then dropped. Migrated table counts were also compared
on both nodes.

------------------------------------------------------------------------

## 15. Manual failover and former-primary rejoin

A manual role transition was performed before the repmgr-controlled
switchover exercise. The documented sequence stopped PostgreSQL on cs1,
promoted cs2, created a slot for cs1 on the new primary, rebuilt cs1
from cs2 using `pg_basebackup`, restored required PostgreSQL/TLS
configuration, and rejoined cs1 as standby.

**Split-brain warning:** never promote the standby while the old primary
is still writable. Confirm the old primary is stopped/fenced and
establish which node is authoritative before any promotion. These are
historical commands, not a suggestion to repeat the transition now.

### 15.1 Preflight

On both nodes:

``` bash
sudo systemctl is-active postgresql-18
sudo -iu postgres /usr/pgsql-18/bin/psql -X -d postgres \
  -c 'SELECT pg_is_in_recovery();'
```

On the current primary:

``` sql
SELECT application_name, client_addr, state, sync_state
FROM pg_stat_replication;
SELECT slot_name, slot_type, active, restart_lsn
FROM pg_replication_slots;
```

Compare current flush/replay positions before proceeding. Stop if
replication is unhealthy or the roles are ambiguous.

### 15.2 Historical manual promotion pattern

The earlier exercise stopped PostgreSQL on cs1 and promoted cs2. The
recorded promotion pattern was:

``` bash
# Only on a confirmed standby after the former primary has been safely stopped:
 /usr/pgsql-18/bin/pg_ctl promote -D /var/lib/pgsql/18/data -w
```

Verify on cs2:

``` sql
SELECT pg_is_in_recovery(); -- expected false after promotion
```

### 15.3 Rejoin former primary as a standby

On the new primary, the documented rejoin slot was `cs1_standby`. Verify
roles and slots before creating it:

``` sql
SELECT pg_create_physical_replication_slot('cs1_standby');
SELECT slot_name, slot_type, active FROM pg_replication_slots;
```

The historical rebuild of cs1 included stopping PostgreSQL, moving the
former data directory to a timestamped pre-switchover path, creating a
fresh data directory with restrictive permissions, running
`pg_basebackup` from `192.168.56.31` with TLS required and SHA-256
manifest checksums, restoring saved PostgreSQL configuration/TLS files,
removing conflicting old `primary_conninfo`/slot settings, setting the
new upstream and slot, then starting PostgreSQL.

The key base-backup pattern recorded for the former primary was:

``` bash
# Historical only; DESTINATION must be empty and the old PGDATA preserved first.
pg_basebackup \
  -D /var/lib/pgsql/18/data \
  -h 192.168.56.31 \
  -p 5432 \
  -U replicator \
  -d "host=192.168.56.31 port=5432 user=replicator dbname=replication sslmode=require" \
  -w -F plain -X stream -P -R \
  --slot=cs1_standby \
  --manifest-checksums=SHA256
```

Do not run against a live or populated data directory. Restore the
actual saved TLS/configuration files and validate paths before starting.

Verify the rejoined node:

``` sql
SELECT pg_is_in_recovery();
SELECT status, sender_host, sender_port, slot_name
FROM pg_stat_wal_receiver;
```

On the new primary:

``` sql
SELECT application_name, client_addr, state, sync_state
FROM pg_stat_replication;
```

The project notes record reverse streaming after rejoin and the same
four table counts (`customers=10`, `products=10`, `orders=10`,
`order_items=20`).

------------------------------------------------------------------------

## 16. Install and configure repmgr 5.5.0

repmgr 5.5.0 was installed on cs1/cs2, the `repmgr` database and login
role were created, node configuration was written, and both nodes were
registered. The service is `repmgr-18`, not `repmgrd`.

Verify package, config, and service:

``` bash
rpm -q repmgr_18
/usr/pgsql-18/bin/repmgr --version
ls -l /etc/repmgr/18/repmgr.conf
sudo systemctl status repmgr-18 --no-pager -l
```

Check the `repmgr` database and role without exposing credentials:

``` sql
SELECT datname FROM pg_database WHERE datname = 'repmgr';
SELECT rolname, rolcanlogin, rolsuper FROM pg_roles WHERE rolname = 'repmgr';
```

The repmgr configuration excerpts recorded were:

``` ini
# cs1: /etc/repmgr/18/repmgr.conf
node_id=1
node_name='postgres-v2-cs1'
conninfo='host=192.168.56.30 user=repmgr dbname=repmgr port=5432 sslmode=require'

# cs2: /etc/repmgr/18/repmgr.conf
node_id=2
node_name='postgres-v2-cs2'
conninfo='host=192.168.56.31 user=repmgr dbname=repmgr port=5432 sslmode=require'

# Common settings on each node
data_directory='/var/lib/pgsql/18/data'
pg_bindir='/usr/pgsql-18/bin/'
failover='manual'
monitoring_history=yes
connection_check_type='ping'
reconnect_attempts=6
reconnect_interval=10
```

Each node must have its own unique `node_id`, `node_name`, and
`conninfo`. Manual failover was intentional.

### 16.1 SSH and `.pgpass`

The documented workflow configured SSH key-based access between nodes
and checked `.pgpass` permissions:

``` bash
chmod 600 /var/lib/pgsql/.pgpass
stat -c '%U %G %a %n' /var/lib/pgsql/.pgpass
ssh -o BatchMode=yes postgres@192.168.56.30 'hostname'
ssh -o BatchMode=yes postgres@192.168.56.31 'hostname'
```

Do not `cat` `.pgpass`, and never publish SSH private keys.

### 16.2 Restricted sudo for repmgr

A remote shutdown-confirmation error was traced to missing systemctl
permission for the `postgres` OS account. The recorded restricted
sudoers entry was:

``` text
# /etc/sudoers.d/postgres-repmgr
Defaults:postgres !requiretty
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl start postgresql-18, /usr/bin/systemctl stop postgresql-18, /usr/bin/systemctl restart postgresql-18, /usr/bin/systemctl reload postgresql-18
```

Validate as root on each node:

``` bash
sudo chmod 440 /etc/sudoers.d/postgres-repmgr
sudo visudo -cf /etc/sudoers.d/postgres-repmgr
sudo -l -U postgres
```

Do not test the permission by actually stopping the service.

### 16.3 repmgr registration and cluster view

The nodes were registered with repmgr; the cluster view was used to
confirm membership. Use current output rather than assuming the last
recorded roles remain current:

``` bash
/usr/pgsql-18/bin/repmgr \
  -f /etc/repmgr/18/repmgr.conf cluster show
```

Check the daemon service and logs:

``` bash
sudo systemctl is-enabled repmgr-18
sudo systemctl is-active repmgr-18
sudo journalctl -u repmgr-18 --no-pager -n 100
```

The service was found disabled/inactive in one earlier check and active
in later checks; verify live status. Monitoring-related settings do not
alone prove that monitoring/failover is operational.

------------------------------------------------------------------------

## 17. repmgr-controlled switchover

A successful repmgr-controlled switchover was recorded on **October 21,
2026**. The dry run was performed, and the actual command output
included `STANDBY PROMOTE successful`, confirmation that cs1 was
promoted, and `STANDBY SWITCHOVER has completed successfully`. A
transient startup warning appeared while cs2 rejoined. The detailed
runbook explicitly said fresh post-switchover streaming validation still
needed to be captured.

### 17.1 Preflight

``` bash
/usr/pgsql-18/bin/repmgr \
  -f /etc/repmgr/18/repmgr.conf cluster show
```

Also verify `pg_is_in_recovery()` on both nodes, `pg_stat_replication`
on the primary, `pg_stat_wal_receiver` on the standby, acceptable lag,
matching physical slots, SSH, `.pgpass`, and restricted sudo.

### 17.2 Dry run

Run on the standby intended for promotion as the `postgres` OS user:

``` bash
/usr/pgsql-18/bin/repmgr \
  -f /etc/repmgr/18/repmgr.conf standby switchover --dry-run
```

Proceed only when the dry run says the prerequisites for
`STANDBY SWITCHOVER` are met. The dry run had exposed missing
`hostssl replication repmgr` HBA access and a missing physical slot in
earlier attempts; these were investigated during the work.

### 17.3 Execute the documented switchover

Historical successful command:

``` bash
/usr/pgsql-18/bin/repmgr \
  -f /etc/repmgr/18/repmgr.conf standby switchover
```

Do not rerun just to reproduce the old output.

### 17.4 Post-switchover verification

On either node:

``` bash
/usr/pgsql-18/bin/repmgr \
  -f /etc/repmgr/18/repmgr.conf cluster show
```

On the current primary:

``` sql
SELECT application_name, client_addr, state, sync_state
FROM pg_stat_replication;
```

On the current standby:

``` sql
SELECT pg_is_in_recovery();
SELECT status, sender_host, sender_port, slot_name
FROM pg_stat_wal_receiver;
```

The target steady state for the last documented switchback was cs1
primary and cs2 streaming as standby, but the runbook required a fresh
query to prove that final state. Do not label it verified until the
output is captured.

------------------------------------------------------------------------

## 18. Third node and remaining three-node work

The Vagrantfile now includes:

``` ruby
config.vm.define "postgres-v2-cs3" do |node|
  node.vm.hostname = "postgres-v2-cs3"
  node.vm.network "private_network", ip: "192.168.56.32"
  node.vm.provider "virtualbox" do |vb|
    vb.name = "postgres-v2-cs3"
    vb.memory = 1024
    vb.cpus = 1
  end
end
```

The third VM is running, but PostgreSQL installation/registration was
not yet confirmed in the latest notes. Continue only after package
installation verifies successfully:

1.  Fix/verify PGDG metadata and install PostgreSQL 18 packages on cs3.
2.  Configure TLS, `pg_hba.conf`, replication authentication, `.pgpass`,
    and the intended repmgr node configuration.
3.  Do not initialize an unrelated cluster on cs3.
4.  Clone cs3 from the confirmed current primary and register it with
    repmgr.
5.  Verify all three nodes, slots, receive/replay LSNs, and table
    counts.
6.  Only after the three-node topology is healthy, deliberately review
    the design and change `failover='manual'` if automatic failover is
    to be enabled.
7.  Test controlled failover, then rejoin the former primary as a
    standby.
8.  Repeat replication, data, RBAC, TLS, backup, and recovery checks.

### Final three-node validation commands

On every node:

``` bash
hostname
systemctl is-active postgresql-18
sudo -iu postgres /usr/pgsql-18/bin/psql -X -d postgres \
  -c 'SELECT pg_is_in_recovery();'
```

From the repmgr node:

``` bash
/usr/pgsql-18/bin/repmgr \
  -f /etc/repmgr/18/repmgr.conf cluster show
```

On the primary:

``` sql
SELECT application_name, client_addr, state, sync_state,
       sent_lsn, write_lsn, flush_lsn, replay_lsn
FROM pg_stat_replication;
SELECT slot_name, slot_type, active, restart_lsn
FROM pg_replication_slots;
```

On each standby:

``` sql
SELECT status, sender_host, sender_port, slot_name
FROM pg_stat_wal_receiver;
SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();
```

## 19. Troubleshooting history

  ----------------------------------------------------------------------------------------------------------
  Symptom                                                    Cause / resolution recorded
  ---------------------------------------------------------- -----------------------------------------------
  PGDG metadata HTTP 404 on cs3                              Some generated base URLs were malformed; fixed
                                                             `pgdg-common` and `pgdg18` URLs to explicit
                                                             `rhel-9-aarch64` paths and refreshed those
                                                             repos. Other enabled PGDG repos may still need
                                                             disabling during the cs3 install.

  `no password supplied`                                     A duplicate matching `.pgpass` entry with an
                                                             empty password was present; inspect entries
                                                             without exposing secret values and retain mode
                                                             `0600`.

  repmgr switchover dry run rejected by HBA                  Add/verify narrow `hostssl replication repmgr`
                                                             rule for the correct source IP and reload
                                                             PostgreSQL; check `pg_hba_file_rules` errors.

  repmgr couldn't confirm remote PostgreSQL shutdown         The `postgres` OS user lacked the required
                                                             restricted sudo permission; validate
                                                             `/etc/sudoers.d/postgres-repmgr` with `visudo`.

  Former standby could not rejoin                            The expected physical replication slot was
                                                             missing on the new primary; inspect
                                                             `primary_slot_name` and `pg_replication_slots`,
                                                             then configure the correct slot only after
                                                             confirming roles.

  PostgreSQL library load failure                            Use
                                                             `shared_preload_libraries = 'pgaudit,repmgr'`
                                                             exactly; avoid the tested invalid spacing after
                                                             the comma.

  Vagrant                                                    The cs3 block had been placed after the final
  `NameError: undefined local variable or method 'config'`   `end`; it was moved inside
                                                             `Vagrant.configure("2") do |config| ... end`.

  Service naming confusion                                   repmgr daemon is managed through
                                                             `repmgr-18.service`; it is not
                                                             `repmgrd.service`.

  `repmgrd --version` as root failed                         Run repmgrd as the `postgres` OS account; it
                                                             refuses to run as root.
  ----------------------------------------------------------------------------------------------------------

## 20. Final checklist

-   [x] Vagrant/VirtualBox CentOS Stream 9 environment provisioned for
    the original two nodes.
-   [x] PostgreSQL 18.6 and repmgr 5.5.0 installed/configured on
    cs1/cs2.
-   [x] RBAC roles and read-only/read-write permissions exercised and
    verified.
-   [x] TLS/network access and pgaudit configuration checks performed.
-   [x] Logical backup and restore exercise documented.
-   [x] Physical backup, `pg_verifybackup`, isolated port-5433 restore,
    and PITR/port-5434 exercise documented.
-   [x] `retail` object migration into `lyris_prod` and row-count checks
    recorded.
-   [x] Physical streaming replication and replication-slot checks
    performed.
-   [x] Manual failover/promotion and former-primary rejoin performed in
    the earlier exercise.
-   [x] repmgr registration and a repmgr-controlled switchover
    successfully executed.
-   [ ] Capture fresh current roles and streaming status after the
    latest switchover.
-   [ ] Finish PostgreSQL install/configuration on cs3 and register it
    as the second standby.
-   [ ] Validate stable three-node replication.
-   [ ] Enable automatic failover only after the three-node validation
    and an explicit configuration change.
-   [ ] Test automatic/controlled failover and former-primary rejoin in
    the final topology.
-   [ ] Re-run final TLS, RBAC, audit, backup, recovery, and
    data-consistency checks on the final topology.

## 21. Secret and destructive-command handling

Never commit or share:

-   Passwords, `.pgpass` contents, private SSH keys, TLS private keys.
-   Database dump files, raw physical backup directories, WAL segments,
    or production data.
-   Full logs if they contain secrets or sensitive data.

Historical `DROP DATABASE`, `pg_basebackup -D`, data-directory moves,
`pg_ctl promote`, and service-stop commands are documented to preserve
the implementation history. Confirm roles, targets, paths, and recovery
plans before executing any of them again.

# PostgreSQL 18 DBA Engineering

Hands-on PostgreSQL 18 project on CentOS Stream 9 covering database installation and configuration, Role-Base Access Control, administration, streaming replication, high availability, backup and recovery, and security.

## Technologies
- PostgreSQL 18.6
- Linux (CentOS)
- Vagrant and VirtualBox
- Streaming replication and physical replication slots
- repmgr 5.5.0
- TLS, Linux administration, and Bash scripting

## Implemented
- Installed and configured PostgreSQL 18 on two nodes.
- Configured TLS-encrypted streaming replication.
- Validated replication status, WAL positions, and replicated data.
- Created and verified physical replication slots.
- Performed manual failover, promoted the standby, and rejoined the former primary.
- Installed and configured repmgr and tested switchover.
- Implemented logical backup automation, archive validation, logging, temporary-file handling, and seven-day retention cleanup.

## Planned
- Add a third PostgreSQL node.
- Automate and test failover.
- Perform performance tuning.
- Complete final TLS and access-control validation.

## Project Structure

```text
postgresql-18-dba-engineering/
├── scripts/
├── backups/
├── configs/
└── README.md
```

*Directory contents may vary as the project evolves.*

## Goal

Demonstrate practical PostgreSQL administration, replication, high availability, recovery, security, and automation skills through a documented, hands-on project.

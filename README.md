# Cinema-Backup-Disaster-Recovery

Automated backup, disaster recovery and self-healing for the Cinema system on Windows Server (VMware VM).

## Components
| Item | Details |
|---|---|
| Protected data | C:\CinemaData (bookings.sql, movies.csv) |
| Backup target | dedicated 20 GB virtual disk, E: (NTFS) |
| Daily backup | wbadmin, every day at 23:00 |
| Self-healing | scripts\SelfHealing.ps1, every 5 minutes + at startup |
| Scheduled task | Cinema-SelfHealing-Monitor (SYSTEM, highest privileges, single instance) |
| Validation | existence, size, SHA-256 |
| Recovery | trusted copy in backups\, 3 attempts, 10 s apart, wbadmin fallback |
| Quarantine | quarantine\YYYY-MM-DD\ |
| Log | logs\self_healing.log (rotate at 5 MB, keep 30 days) |

## Phases
1. 01-setup-storage-and-data.ps1: folders, Windows Server Backup, E: disk
2. 02-configure-automated-backup.ps1: daily backup at 23:00 and first backup
3. 03-disaster-recovery-test.ps1: delete and restore test
4. 04-init-selfhealing.ps1: trusted copies and config with real hashes
5. 06-selfhealing-test.ps1: tests T01-T05 (all PASS)
6. 05-register-task.ps1: register the scheduled task

## Run order
Run 01, 02, 03, 04, 06, then 05 in an elevated PowerShell inside the VM.

## Evidence
See logs\ (phase-6a, 6b, 7, 8a, 8b, 8c, self_healing.log, self_healing_tests.txt) and screenshots\.

## Note
The self-healing values (5 minutes, 3 attempts, 10 s delay, SHA-256, 30-day log retention) follow a proposed specification; confirm them against the instructor's official sheet.

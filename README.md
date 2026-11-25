# Cinema-Backup-Disaster-Recovery
Automated daily backup and disaster recovery for a Cinema Management system on Windows Server (VMware VM) using wbadmin.

- Protected data: C:\CinemaData (bookings.sql, movies.csv)
- Backup target: dedicated 20 GB virtual disk (E:, NTFS)
- Schedule: daily at 23:00

Scripts: 01 (setup), 02 (backup), 03 (disaster test), then Self-Healing Operations.
Logs of every phase are in the logs/ folder.

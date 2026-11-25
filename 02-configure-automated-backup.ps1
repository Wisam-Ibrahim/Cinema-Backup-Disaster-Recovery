# Phase 6b - Daily backup at 23:00 to E: and immediate on-demand backup
wbadmin enable backup -addtarget:E: -include:C:\CinemaData -schedule:23:00 -quiet
wbadmin start backup -backupTarget:E: -include:C:\CinemaData -quiet
Get-WBPolicy
wbadmin get versions -backupTarget:E:

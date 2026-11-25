# Phase 7 - Simulate disaster and list versions (restore line is commented on purpose)
Remove-Item -Path "C:\CinemaData\*" -Force
wbadmin get versions -backupTarget:E:
# wbadmin start recovery -version:<VERSION_ID> -itemType:File -items:C:\CinemaData -backupTarget:E: -quiet

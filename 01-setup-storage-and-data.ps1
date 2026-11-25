# Phase 6a - Create CinemaData, install Windows Server Backup, format 20GB disk as E:
New-Item -Path "C:\CinemaData" -ItemType Directory -Force
New-Item -Path "C:\CinemaData\bookings.sql" -ItemType File -Value "cinema bookings" -Force
New-Item -Path "C:\CinemaData\movies.csv" -ItemType File -Value "movie1 , 20:00" -Force

Install-WindowsFeature -Name Windows-Server-Backup

# Select the backup disk by size (20GB) - never touch the OS disk
$disk = Get-Disk | Where-Object { [math]::Round($_.Size/1GB) -eq 20 } | Select-Object -First 1
if (-not $disk) { throw "20GB disk not found" }
if (-not (Get-Volume -DriveLetter E -ErrorAction SilentlyContinue)) {
    $disk | New-Partition -UseMaximumSize -DriveLetter E | Format-Volume -FileSystem NTFS -Confirm:$false
}

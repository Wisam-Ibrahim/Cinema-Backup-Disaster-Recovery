# Phase 8a - Create folders, trusted backup copies and config with REAL SHA-256 hashes.
# Run this only while C:\CinemaData files are healthy (they become the "known-good" baseline).
$Root = $PSScriptRoot

foreach ($d in 'scripts', 'config', 'backups', 'logs', 'quarantine', 'temp') {
    New-Item -ItemType Directory -Path (Join-Path $Root $d) -Force | Out-Null
}

$targets = @(
    @{ name = 'bookings'; target = 'C:\CinemaData\bookings.sql' },
    @{ name = 'movies';   target = 'C:\CinemaData\movies.csv'   }
)

$list = @()
foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t.target)) {
        throw "Missing $($t.target). Restore it first, then run this script again."
    }
    $leaf = Split-Path -Leaf $t.target
    Copy-Item -LiteralPath $t.target -Destination (Join-Path $Root "backups\$leaf") -Force
    $list += [ordered]@{
        name            = $t.name
        target          = $t.target
        backup          = "backups\$leaf"
        expected_sha256 = (Get-FileHash -LiteralPath $t.target -Algorithm SHA256).Hash
        expected_size   = (Get-Item -LiteralPath $t.target).Length
    }
}

$cfg = [ordered]@{
    check_interval_minutes = 5
    max_recovery_attempts  = 3
    retry_delay_seconds    = 10
    verify_sha256          = $true
    log_path               = 'logs\self_healing.log'
    quarantine_path        = 'quarantine'
    log_max_mb             = 5
    log_retention_days     = 30
    wbadmin_fallback       = [ordered]@{ enabled = $true; backup_target = 'E:' }
    monitored_files        = $list
}

$json = $cfg | ConvertTo-Json -Depth 6
$cfgPath = Join-Path $Root 'config\monitored_files.json'
[System.IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Config written: $cfgPath"
Get-Content -LiteralPath $cfgPath
Get-ChildItem (Join-Path $Root 'backups')

# Phase 8b - Self-healing tests T01..T05 (run manually before enabling the Scheduled Task).
$Root    = $PSScriptRoot
$Heal    = Join-Path $Root 'scripts\SelfHealing.ps1'
$LogFile = Join-Path $Root 'logs\self_healing.log'
$cfg     = Get-Content -LiteralPath (Join-Path $Root 'config\monitored_files.json') -Raw | ConvertFrom-Json
$f       = $cfg.monitored_files[0]
$target  = $f.target
$backup  = Join-Path $Root $f.backup
$away    = "$backup.away"
$results = New-Object System.Collections.ArrayList

function Invoke-Heal([switch]$NoFallback) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Heal)
    if ($NoFallback) { $a += '-DisableWbadminFallback' }
    & powershell.exe @a | Out-Null
    return $LASTEXITCODE
}
function Get-H([string]$p) {
    if (Test-Path -LiteralPath $p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
    return $null
}
function Add-Result([string]$id, [string]$desc, [bool]$pass) {
    $res = 'FAIL'
    if ($pass) { $res = 'PASS' }
    [void]$results.Add([pscustomobject]@{ Test = $id; Scenario = $desc; Result = $res })
}

try {
    # T01 - healthy file: nothing must be modified
    $t0   = (Get-Item -LiteralPath $target).LastWriteTimeUtc
    $code = Invoke-Heal
    Add-Result 'T01' 'Healthy file: FILE_OK, file not modified' (($code -eq 0) -and ((Get-H $target) -eq $f.expected_sha256) -and ((Get-Item -LiteralPath $target).LastWriteTimeUtc -eq $t0))

    # T02 - missing file is restored from the trusted backup
    Remove-Item -LiteralPath $target -Force
    $code = Invoke-Heal
    Add-Result 'T02' 'Missing file restored from backup' (($code -eq 0) -and ((Get-H $target) -eq $f.expected_sha256))

    # T03 - corrupted content: quarantine + restore + hash verified
    Set-Content -LiteralPath $target -Value 'CORRUPTED DATA'
    $code = Invoke-Heal
    $leaf = Split-Path -Leaf $target
    $q = @(Get-ChildItem -LiteralPath (Join-Path $Root 'quarantine') -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$leaf*" })
    Add-Result 'T03' 'Corrupted file quarantined and restored (SHA-256 verified)' (($code -eq 0) -and ($q.Count -gt 0) -and ((Get-H $target) -eq $f.expected_sha256))

    # T04 / T05 - backup copy missing
    Move-Item -LiteralPath $backup -Destination $away -Force
    Remove-Item -LiteralPath $target -Force

    $code = Invoke-Heal -NoFallback
    $tail = @(Get-Content -LiteralPath $LogFile -Tail 40 | Where-Object { $_ -match 'BACKUP_UNAVAILABLE' })
    Add-Result 'T04' 'Backup missing, fallback off: no fake file, BACKUP_UNAVAILABLE logged' (($code -eq 1) -and (-not (Test-Path -LiteralPath $target)) -and ($tail.Count -gt 0))

    $code = Invoke-Heal
    Add-Result 'T05' 'Backup missing, wbadmin fallback restores file (SHA-256 verified)' (($code -eq 0) -and ((Get-H $target) -eq $f.expected_sha256))
}
finally {
    if (Test-Path -LiteralPath $away) { Move-Item -LiteralPath $away -Destination $backup -Force }
    if ((Get-H $target) -ne $f.expected_sha256) { Copy-Item -LiteralPath $backup -Destination $target -Force }
}

$table = ($results | Format-Table -AutoSize | Out-String -Width 200)
Write-Host $table
Set-Content -LiteralPath (Join-Path $Root 'logs\self_healing_tests.txt') -Value $table -Encoding UTF8
Write-Host '--- last log lines ---'
Get-Content -LiteralPath $LogFile -Tail 30

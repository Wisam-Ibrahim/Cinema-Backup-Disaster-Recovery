<#
 SelfHealing.ps1 - Cinema self-healing monitor (Phase 8)
 Checks monitored files (exists, size, SHA-256), quarantines bad copies,
 restores from the trusted backup (3 attempts, 10 s apart), falls back to
 wbadmin, logs every step, and allows only one running instance.
 Exit codes: 0 = all OK/healed, 1 = at least one file could not be healed,
             2 = unexpected exception.
#>
[CmdletBinding()]
param(
    [switch]$DisableWbadminFallback
)

$ErrorActionPreference = 'Stop'
$ProjectRoot    = Split-Path -Parent $PSScriptRoot
$ConfigPath     = Join-Path $ProjectRoot 'config\monitored_files.json'
$RunId          = [guid]::NewGuid().ToString().Substring(0, 8)
$script:LogPath = Join-Path $ProjectRoot 'logs\self_healing.log'

function Resolve-P([string]$p) {
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return (Join-Path $ProjectRoot $p)
}

function Write-EventLogFallback([string]$msg) {
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists('CinemaSelfHealing')) {
            New-EventLog -LogName Application -Source 'CinemaSelfHealing'
        }
        Write-EventLog -LogName Application -Source 'CinemaSelfHealing' -EntryType Error -EventId 9001 -Message $msg
    } catch {
        [Console]::Error.WriteLine($msg)
    }
}

function Write-Log([string]$Level, [string]$Event, [string]$Detail = '') {
    $line = '{0} | {1} | {2} | {3} | run_id={4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Event, $Detail, $RunId
    try {
        $dir = Split-Path -Parent $script:LogPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch {
        Write-EventLogFallback ("LOG_WRITE_FAILED: " + $_.Exception.Message + " | original: " + $line)
    }
    Write-Host $line
}

function Invoke-LogMaintenance {
    try {
        $maxBytes = $script:LogMaxMB * 1MB
        if ((Test-Path -LiteralPath $script:LogPath) -and ((Get-Item -LiteralPath $script:LogPath).Length -gt $maxBytes)) {
            $arch = Join-Path (Split-Path -Parent $script:LogPath) ('self_healing_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Move-Item -LiteralPath $script:LogPath -Destination $arch -Force
            Write-Log 'INFO' 'LOG_ROTATED' "archive=$arch"
        }
        Get-ChildItem -LiteralPath (Split-Path -Parent $script:LogPath) -Filter 'self_healing_*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$script:LogKeepDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log 'WARNING' 'LOG_MAINTENANCE_FAILED' $_.Exception.Message
    }
}

function Test-Target($f) {
    $t = Resolve-P $f.target
    if (-not (Test-Path -LiteralPath $t -PathType Leaf)) {
        return @{ Status = 'MISSING'; Detail = "file=$t" }
    }
    try {
        $len = (Get-Item -LiteralPath $t).Length
        if ($len -eq 0 -and $f.expected_size -gt 0) {
            return @{ Status = 'ZERO_BYTE'; Detail = "file=$t | size=0" }
        }
        if ($f.expected_size -gt 0 -and $len -ne $f.expected_size) {
            return @{ Status = 'SIZE_MISMATCH'; Detail = "file=$t | expected_size=$($f.expected_size) | actual_size=$len" }
        }
        if ($script:VerifyHash -and $f.expected_sha256) {
            $h = (Get-FileHash -LiteralPath $t -Algorithm SHA256).Hash
            if ($h -ne $f.expected_sha256) {
                return @{ Status = 'CHECKSUM_MISMATCH'; Detail = "file=$t | expected=$($f.expected_sha256) | actual=$h" }
            }
        }
        return @{ Status = 'OK'; Detail = "file=$t | size=$len" }
    } catch {
        return @{ Status = 'ACCESS_OR_LOCK_ERROR'; Detail = "file=$t | error=$($_.Exception.Message)" }
    }
}

function Save-ToQuarantine($f) {
    $t = Resolve-P $f.target
    if (-not (Test-Path -LiteralPath $t -PathType Leaf)) { return }
    try {
        $qdir = Join-Path (Resolve-P $script:QuarantinePath) (Get-Date -Format 'yyyy-MM-dd')
        New-Item -ItemType Directory -Path $qdir -Force | Out-Null
        $dest = Join-Path $qdir ('{0}_{1}.bad' -f (Split-Path -Leaf $t), (Get-Date -Format 'HHmmss'))
        Copy-Item -LiteralPath $t -Destination $dest -Force
        Write-Log 'INFO' 'QUARANTINED' "file=$t | copy=$dest"
    } catch {
        Write-Log 'WARNING' 'QUARANTINE_FAILED' "file=$t | error=$($_.Exception.Message)"
    }
}

function Restore-FromWbadmin($f) {
    $t  = Resolve-P $f.target
    $bt = $script:WbTarget
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Write-Log 'INFO' 'WBADMIN_FALLBACK_STARTED' "file=$($f.name) | backup_target=$bt"
        $out = (& wbadmin.exe get versions "-backupTarget:$bt" 2>&1 | Out-String)
        $ci = [System.Globalization.CultureInfo]::InvariantCulture
        $versions = @()
        foreach ($m in [regex]::Matches($out, 'Version identifier:\s*(\S+)')) {
            try {
                $versions += [pscustomobject]@{
                    Id   = $m.Groups[1].Value
                    Time = [datetime]::ParseExact($m.Groups[1].Value, 'MM/dd/yyyy-HH:mm', $ci)
                }
            } catch { }
        }
        if ($versions.Count -eq 0) {
            Write-Log 'ERROR' 'WBADMIN_NO_VERSION' "file=$($f.name) | backup_target=$bt"
            return $false
        }
        $latest = ($versions | Sort-Object Time -Descending | Select-Object -First 1).Id
        & wbadmin.exe start recovery "-version:$latest" '-itemType:File' "-items:$t" "-backupTarget:$bt" '-overwrite:Overwrite' '-quiet' 2>&1 | Out-Null
        $code = $LASTEXITCODE
        $r = Test-Target $f
        if ($r.Status -eq 'OK') {
            Write-Log 'INFO' 'RECOVERY_SUCCESS' "file=$($f.name) | source=wbadmin | version=$latest"
            return $true
        }
        Write-Log 'WARNING' 'WBADMIN_VERIFY_FAILED' "file=$($f.name) | version=$latest | exit=$code | status=$($r.Status)"
        return $false
    } catch {
        Write-Log 'WARNING' 'WBADMIN_FALLBACK_ERROR' "file=$($f.name) | error=$($_.Exception.Message)"
        return $false
    } finally {
        $ErrorActionPreference = $oldPref
    }
}

function Restore-File($f) {
    $t    = Resolve-P $f.target
    $b    = Resolve-P $f.backup
    $name = $f.name

    # 1) Is the backup source available and trustworthy?
    $backupOk = $false
    if (-not (Test-Path -LiteralPath $b -PathType Leaf)) {
        Write-Log 'CRITICAL' 'BACKUP_UNAVAILABLE' "file=$name | backup=$b"
    } else {
        $bh = (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash
        if ($f.expected_sha256 -and ($bh -ne $f.expected_sha256)) {
            Write-Log 'CRITICAL' 'BACKUP_HASH_MISMATCH' "file=$name | backup=$b | actual=$bh"
        } else {
            $backupOk = $true
        }
    }

    $wbAllowed = ($script:WbEnabled -and (-not $DisableWbadminFallback))

    # 2) Preserve evidence only if we are actually going to replace the file
    if ($backupOk -or $wbAllowed) { Save-ToQuarantine $f }

    # 3) Copy from backup: temp file in target folder, verify, then rename
    if ($backupOk) {
        for ($i = 1; $i -le $script:MaxAttempts; $i++) {
            Write-Log 'INFO' 'RECOVERY_STARTED' "file=$name | source=backup | attempt=$i"
            $tmp = "$t.healing.tmp"
            try {
                $tdir = Split-Path -Parent $t
                if (-not (Test-Path -LiteralPath $tdir)) { New-Item -ItemType Directory -Path $tdir -Force | Out-Null }
                Copy-Item -LiteralPath $b -Destination $tmp -Force
                if ($f.expected_sha256) {
                    $th = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
                    if ($th -ne $f.expected_sha256) { throw 'temporary copy hash mismatch' }
                }
                Move-Item -LiteralPath $tmp -Destination $t -Force
                $post = Test-Target $f
                if ($post.Status -eq 'OK') {
                    Write-Log 'INFO' 'RECOVERY_SUCCESS' "file=$name | source=backup | attempt=$i"
                    return $true
                }
                throw "verification failed: $($post.Status)"
            } catch {
                Write-Log 'WARNING' 'RECOVERY_ATTEMPT_FAILED' "file=$name | attempt=$i | error=$($_.Exception.Message)"
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                if ($i -lt $script:MaxAttempts) { Start-Sleep -Seconds $script:RetryDelay }
            }
        }
    }

    # 4) Fallback: latest Windows Server Backup version (verified by hash afterwards)
    if ($wbAllowed) {
        if (Restore-FromWbadmin $f) { return $true }
    }

    Write-Log 'ERROR' 'RECOVERY_FAILED' "file=$name | target=$t"
    return $false
}

# ------------------------------- main -------------------------------
$mutex    = $null
$hasLock  = $false
$exitCode = 0
try {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $script:LogPath        = Resolve-P $config.log_path
    $script:QuarantinePath = $config.quarantine_path
    $script:MaxAttempts    = [int]$config.max_recovery_attempts
    $script:RetryDelay     = [int]$config.retry_delay_seconds
    $script:VerifyHash     = [bool]$config.verify_sha256
    $script:LogMaxMB       = [int]$config.log_max_mb
    $script:LogKeepDays    = [int]$config.log_retention_days
    $script:WbEnabled      = [bool]$config.wbadmin_fallback.enabled
    $script:WbTarget       = [string]$config.wbadmin_fallback.backup_target

    $mutex   = New-Object System.Threading.Mutex($false, 'Global\Cinema-SelfHealing-Monitor')
    $hasLock = $mutex.WaitOne(0)
    if (-not $hasLock) {
        Write-Log 'WARNING' 'INSTANCE_ALREADY_RUNNING' 'another run is active, exiting'
        exit 0
    }

    Invoke-LogMaintenance
    $files = @($config.monitored_files)
    Write-Log 'INFO' 'CHECK_STARTED' "files=$($files.Count)"
    $ok = 0; $healed = 0; $failed = 0

    foreach ($f in $files) {
        $r = Test-Target $f
        if ($r.Status -eq 'OK') {
            Write-Log 'INFO' 'FILE_OK' $r.Detail
            $ok++
            continue
        }
        Write-Log 'WARNING' $r.Status $r.Detail

        if ($r.Status -eq 'ACCESS_OR_LOCK_ERROR') {
            $cleared = $false
            for ($i = 1; $i -le $script:MaxAttempts; $i++) {
                Start-Sleep -Seconds $script:RetryDelay
                if ((Test-Target $f).Status -ne 'ACCESS_OR_LOCK_ERROR') { $cleared = $true; break }
            }
            if (-not $cleared) {
                Write-Log 'ERROR' 'RECOVERY_FAILED' "file=$($f.name) | reason=locked or access denied, left unchanged"
                $failed++
                continue
            }
            $r = Test-Target $f
            if ($r.Status -eq 'OK') { Write-Log 'INFO' 'FILE_OK' $r.Detail; $ok++; continue }
        }

        if (Restore-File $f) {
            $healed++
        } else {
            Write-Log 'ERROR' 'MANUAL_REVIEW_REQUIRED' "file=$($f.name)"
            $failed++
        }
    }

    Write-Log 'INFO' 'CHECK_COMPLETED' "ok=$ok | healed=$healed | failed=$failed"
    if ($failed -gt 0) { $exitCode = 1 }
}
catch {
    Write-Log 'ERROR' 'UNEXPECTED_EXCEPTION' $_.Exception.Message
    $exitCode = 2
}
finally {
    if ($hasLock) { $mutex.ReleaseMutex() }
    if ($mutex)   { $mutex.Dispose() }
}
exit $exitCode

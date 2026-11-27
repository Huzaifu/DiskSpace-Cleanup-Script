<#
.SYNOPSIS
    Controls event log (.evtx) disk usage on domain controllers through size and archiving settings,
    instead of deleting .evtx files.

.DESCRIPTION
    Event logs are live files held open by the Event Log service, so deleting them directly is unsafe
    (Clean-OldLogs.ps1 deliberately skips C:\Windows). The supported way to bound their disk use is:
      1. a maximum size per log, and
      2. a retention mode:
           AutoBackup = when a log fills up it is saved as Archive-<name>-<timestamp>.evtx and a new log starts
                        (nothing is overwritten - use this if the client must keep history)
           Circular   = oldest events are overwritten (disk use stays at the max size; history is lost)
    With AutoBackup the archive files pile up, so this script can also delete ARCHIVED files
    (Archive-*.evtx only, never the live logs) older than -ArchiveRetentionDays.

    DRY RUN BY DEFAULT: it only shows current vs. target settings and which archives would be removed.
    Add -Apply to change settings / delete archives.

.PARAMETER LogName
    Logs to manage. Default: the logs that matter on a domain controller.

.PARAMETER MaxSizeMB
    Target maximum size per log (default 1024 MB for Security, 256 MB for the others - see $sizeFor below).
    Pass a single number to use it for every log.

.PARAMETER Mode
    AutoBackup (default) or Circular.

.PARAMETER ArchiveRetentionDays
    Delete Archive-*.evtx older than this many days (default 0 = do not delete archives).

.EXAMPLE
    # Show what would change on the domain controllers (nothing is modified)
    .\Set-EventLogPolicy.ps1 -ComputerName DC01,DC02 -Credential (Get-Credential)

.EXAMPLE
    # Apply: 1 GB Security log, archive when full, keep archives 90 days
    .\Set-EventLogPolicy.ps1 -ComputerName DC01 -ArchiveRetentionDays 90 -Credential (Get-Credential) -Apply

.NOTES
    Uses PowerShell remoting (WinRM). Account must be admin on the targets.
    Agree the retention period with the client first: some compliance rules require the Security log
    to be kept (or forwarded to a central collector) for a set time.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]$ServerListPath,
    [System.Management.Automation.PSCredential]$Credential,
    [string[]]$LogName = @('Security', 'System', 'Application', 'Directory Service', 'DNS Server', 'DFS Replication'),
    [ValidateRange(20,102400)][int]$MaxSizeMB,
    [ValidateSet('AutoBackup', 'Circular')][string]$Mode = 'AutoBackup',
    [ValidateRange(0,3650)][int]$ArchiveRetentionDays = 0,
    [switch]$Apply,
    [string]$OutputFolder = (Join-Path $PSScriptRoot 'EventLogReports')
)

$ErrorActionPreference = 'Stop'

$servers = @()
if ($ComputerName)   { $servers += $ComputerName }
if ($ServerListPath) {
    if (-not (Test-Path $ServerListPath)) { throw "Server list not found: $ServerListPath" }
    $servers += Get-Content $ServerListPath |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
}
$servers = $servers | Sort-Object -Unique
if (-not $servers) { throw 'No servers given. Use -ComputerName or -ServerListPath.' }

if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }
$stamp   = Get-Date
$runMode = if ($Apply) { 'APPLY' } else { 'DRYRUN' }
$logFile = Join-Path $OutputFolder ('EventLogPolicy_{0}_{1:yyyy-MM-dd_HHmm}.log' -f $runMode, $stamp)
$csvFile = Join-Path $OutputFolder ('EventLogPolicy_{0}_{1:yyyy-MM-dd_HHmm}.csv' -f $runMode, $stamp)
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    Add-Content -Path $logFile -Value ('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message)
}

# Default sizes: Security is the one that grows fastest on a DC.
$sizes = @{}
foreach ($n in $LogName) {
    $sizes[$n] = if ($MaxSizeMB) { $MaxSizeMB } elseif ($n -eq 'Security') { 1024 } else { 256 }
}

if ($Apply) { Write-Host "*** APPLY MODE: event log settings will be changed. ***" -ForegroundColor Red }
else        { Write-Host 'DRY RUN: nothing will be changed. Add -Apply after reviewing.' -ForegroundColor Green }
Write-Log "Run started. Mode=$runMode Servers=$($servers -join ',') Logs=$($LogName -join ',') LogMode=$Mode ArchiveRetentionDays=$ArchiveRetentionDays"

# ---- Work done ON the remote server -------------------------------------
$scriptBlock = {
    param($logNames, $sizes, $mode, $archiveDays, $apply)

    $cutoff  = (Get-Date).AddDays(-$archiveDays)
    $folders = @{}

    foreach ($name in $logNames) {
        $cfg = Get-WinEvent -ListLog $name -ErrorAction SilentlyContinue
        if (-not $cfg) {
            [pscustomobject]@{ Kind = 'Log'; Log = $name; Note = 'log not present on this server' }
            continue
        }

        $targetBytes = [int64]$sizes[$name] * 1MB
        $needSize = ($cfg.MaximumSizeInBytes -ne $targetBytes)
        $needMode = ($cfg.LogMode.ToString() -ne $mode)
        $before   = '{0} MB, {1}' -f [math]::Round($cfg.MaximumSizeInBytes / 1MB), $cfg.LogMode
        $result   = 'NoChange'

        if ($needSize -or $needMode) {
            $result = 'WouldChange'
            if ($apply) {
                try {
                    $cfg.MaximumSizeInBytes = $targetBytes
                    $cfg.LogMode = $mode
                    $cfg.SaveChanges()
                    $result = 'Changed'
                } catch { $result = 'FAILED: ' + $_.Exception.Message }
            }
        }

        $path = [Environment]::ExpandEnvironmentVariables($cfg.LogFilePath)
        $dir  = Split-Path $path -Parent
        $folders[$dir] = $true

        [pscustomobject]@{
            Kind = 'Log'; Log = $name; Before = $before
            After = ('{0} MB, {1}' -f $sizes[$name], $mode)
            CurrentFileMB = if (Test-Path -LiteralPath $path) { [math]::Round((Get-Item -LiteralPath $path).Length / 1MB, 1) } else { 0 }
            Result = $result; Note = ''
        }
    }

    # Archived logs (only files named Archive-*.evtx - never the live logs)
    foreach ($dir in $folders.Keys) {
        $arch = @(Get-ChildItem -LiteralPath $dir -Filter 'Archive-*.evtx' -File -ErrorAction SilentlyContinue)
        $totalMB = [math]::Round((($arch | Measure-Object Length -Sum).Sum) / 1MB, 1)
        [pscustomobject]@{ Kind = 'ArchiveInfo'; Folder = $dir; Files = $arch.Count; SizeMB = $totalMB }

        if ($archiveDays -gt 0) {
            foreach ($f in ($arch | Where-Object { $_.LastWriteTime -lt $cutoff })) {
                $action = 'WouldDelete'
                if ($apply) {
                    try   { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $action = 'Deleted' }
                    catch { $action = 'FAILED: ' + $_.Exception.Message }
                }
                [pscustomobject]@{
                    Kind = 'Archive'; Path = $f.FullName; SizeMB = [math]::Round($f.Length / 1MB, 1)
                    LastWrite = $f.LastWriteTime; Action = $action
                }
            }
        }
    }
}

# ---- Run against each server --------------------------------------------
$report = New-Object System.Collections.Generic.List[object]
$failed = New-Object System.Collections.Generic.List[string]

foreach ($server in $servers) {
    Write-Host "`n=== $server ===" -ForegroundColor Cyan
    try {
        $ic = @{
            ComputerName = $server; ErrorAction = 'Stop'; ScriptBlock = $scriptBlock
            ArgumentList = @($LogName, $sizes, $Mode, $ArchiveRetentionDays, [bool]$Apply)
        }
        if ($Credential) { $ic.Credential = $Credential }
        $out = @(Invoke-Command @ic)

        $logs = @($out | Where-Object Kind -eq 'Log')
        foreach ($l in ($logs | Where-Object Note)) { Write-Warning "$server $($l.Log): $($l.Note)" }
        $logs = @($logs | Where-Object { -not $_.Note })
        if ($logs) {
            $logs | Select-Object Log, Before, After, CurrentFileMB, Result | Format-Table -AutoSize | Out-Host
            foreach ($l in $logs) {
                $report.Add([pscustomobject]@{
                    Server = $server; Item = $l.Log; Detail = ('{0} -> {1}' -f $l.Before, $l.After); Result = $l.Result
                })
                Write-Log ("{0} {1}: {2} -> {3} [{4}]" -f $server, $l.Log, $l.Before, $l.After, $l.Result)
            }
        }

        foreach ($a in ($out | Where-Object Kind -eq 'ArchiveInfo')) {
            Write-Host ("Archive files in {0}: {1} file(s), {2} MB" -f $a.Folder, $a.Files, $a.SizeMB)
            Write-Log  ("{0} archives in {1}: {2} file(s), {3} MB" -f $server, $a.Folder, $a.Files, $a.SizeMB)
        }
        $arch = @($out | Where-Object Kind -eq 'Archive')
        foreach ($f in $arch) {
            $report.Add([pscustomobject]@{
                Server = $server; Item = $f.Path; Detail = ('{0} MB, last write {1:yyyy-MM-dd}' -f $f.SizeMB, $f.LastWrite); Result = $f.Action
            })
            Write-Log ("{0} {1} -> {2}" -f $server, $f.Path, $f.Action)
        }
        if ($ArchiveRetentionDays -gt 0) {
            $mb = [math]::Round((($arch | Measure-Object SizeMB -Sum).Sum), 1)
            Write-Host ("Archives older than {0} days: {1} file(s), {2} MB ({3})" -f $ArchiveRetentionDays, $arch.Count, $mb, $runMode)
        }
    }
    catch {
        $failed.Add($server)
        Write-Warning "$server : $($_.Exception.Message)"
        Write-Log "$server FAILED: $($_.Exception.Message)" 'ERROR'
    }
}

if ($report.Count) { $report | Export-Csv -Path $csvFile -NoTypeInformation }
Write-Host ("`n{0}: {1} item(s) across {2} server(s); {3} server(s) failed." -f $runMode, $report.Count, $servers.Count, $failed.Count) -ForegroundColor Cyan
if ($report.Count) { Write-Host "Report: $csvFile" }
Write-Host "Log: $logFile"
Write-Log ("Run finished. items={0} failedServers={1}" -f $report.Count, $failed.Count)

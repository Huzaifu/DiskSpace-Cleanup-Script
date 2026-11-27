<#
.SYNOPSIS
    Checks disk usage on one or more Windows servers and flags drives over 80% / 90%.

.DESCRIPTION
    Replaces the manual routine of RDP-ing into each server and opening File Explorer > This PC
    to read the drive bars (C:, D: Apps, E: EnvDB, G: EnvLogs, H: AppLogs, M: MasterDB, T: Temp,
    Y: AllBackups ...). Connects to each server over WinRM (falls back to DCOM) - no RDP needed.
    Explorer turns a bar red at 90% used; this script flags the same drives (and 80% as a warning).
    Only local fixed disks are listed; mapped network drives belong to a user session and are not visible remotely.
    REPORT ONLY: this script never deletes anything.
    For every fixed drive it records size, free space and % used, assigns a status
    (OK / WARNING / CRITICAL), prints a table, appends to a CSV history file and
    writes a log file. Exit code: 0 = all OK, 1 = warnings, 2 = critical, 3 = a server was unreachable.

.PARAMETER ComputerName
    One or more server names.

.PARAMETER ServerListPath
    Text file with one server name per line (lines starting with # are ignored).

.PARAMETER Credential
    Account to use on the remote servers. Omit to use the account running the script.

.PARAMETER WarningThreshold
    % used that triggers WARNING (default 80).

.PARAMETER CriticalThreshold
    % used that triggers CRITICAL (default 90).

.PARAMETER OutputFolder
    Where the CSV history and log file are written (default .\DiskReports).

.PARAMETER MailTo / SmtpServer / MailFrom
    Optional. If MailTo and SmtpServer are given, an email is sent when anything is
    WARNING, CRITICAL or unreachable.

.EXAMPLE
    .\Check-DiskSpace.ps1 -ComputerName SQL01,DC01 -Credential (Get-Credential)

.EXAMPLE
    .\Check-DiskSpace.ps1 -ServerListPath .\servers.txt

.NOTES
    Schedule 4x/day (every 6 hours), run once in an elevated prompt:

    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
               -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Check-DiskSpace.ps1" -ServerListPath "C:\Scripts\servers.txt"'
    $trigger = New-ScheduledTaskTrigger -Once -At 00:00 -RepetitionInterval (New-TimeSpan -Hours 6)
    Register-ScheduledTask -TaskName 'Disk Space Check' -Action $action -Trigger $trigger `
               -User 'DOMAIN\svc-diskcheck' -Password '<password>' -RunLevel Highest

    The account needs local admin (or Remote Management Users + WMI read rights) on the targets.
    Target servers need WinRM enabled:  Enable-PSRemoting -Force   (TCP 5985/5986).
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]$ServerListPath,
    [System.Management.Automation.PSCredential]$Credential,
    [ValidateRange(1,100)][int]$WarningThreshold  = 80,
    [ValidateRange(1,100)][int]$CriticalThreshold = 90,
    [string]$OutputFolder = (Join-Path $PSScriptRoot 'DiskReports'),
    [string]$MailTo,
    [string]$MailFrom = 'diskcheck@localhost',
    [string]$SmtpServer
)

$ErrorActionPreference = 'Stop'

if ($WarningThreshold -ge $CriticalThreshold) {
    throw "WarningThreshold ($WarningThreshold) must be lower than CriticalThreshold ($CriticalThreshold)."
}

# ---- Build server list --------------------------------------------------
$servers = @()
if ($ComputerName)    { $servers += $ComputerName }
if ($ServerListPath)  {
    if (-not (Test-Path $ServerListPath)) { throw "Server list not found: $ServerListPath" }
    $servers += Get-Content $ServerListPath |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
}
$servers = $servers | Sort-Object -Unique
if (-not $servers) { throw 'No servers given. Use -ComputerName or -ServerListPath.' }

# ---- Output setup -------------------------------------------------------
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }
$stamp    = Get-Date
$logFile  = Join-Path $OutputFolder ('DiskCheck_{0:yyyy-MM-dd}.log' -f $stamp)
$csvFile  = Join-Path $OutputFolder 'DiskCheck_History.csv'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -Path $logFile -Value $line
    Write-Verbose $line
}

Write-Log "Run started. Servers: $($servers -join ', '). Thresholds: warn $WarningThreshold%, crit $CriticalThreshold%."

# ---- Collect ------------------------------------------------------------
$results     = New-Object System.Collections.Generic.List[object]
$unreachable = New-Object System.Collections.Generic.List[string]

foreach ($server in $servers) {
    $session = $null
    try {
        $sessParams = @{ ComputerName = $server; ErrorAction = 'Stop' }
        if ($Credential) { $sessParams.Credential = $Credential }

        # Try WinRM first; if it is not enabled on the server, fall back to DCOM (RPC),
        # which is often reachable where RDP is. Same data either way.
        try {
            $session = New-CimSession @sessParams
            # New-CimSession is lazy for WinRM - force a real connection test
            $null = Get-CimInstance -CimSession $session -ClassName Win32_OperatingSystem -ErrorAction Stop
        }
        catch {
            Write-Log "$server WinRM failed ($($_.Exception.Message)) - trying DCOM." 'WARN'
            if ($session) { Remove-CimSession $session -ErrorAction SilentlyContinue }
            $sessParams.SessionOption = New-CimSessionOption -Protocol Dcom
            $session = New-CimSession @sessParams
        }

        # DriveType 3 = local fixed disk
        $disks = Get-CimInstance -CimSession $session -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop

        foreach ($d in $disks) {
            if (-not $d.Size) { continue }
            $usedPct = [math]::Round((($d.Size - $d.FreeSpace) / $d.Size) * 100, 1)
            $status  = if     ($usedPct -ge $CriticalThreshold) { 'CRITICAL' }
                       elseif ($usedPct -ge $WarningThreshold)  { 'WARNING'  }
                       else                                     { 'OK' }

            $row = [pscustomobject]@{
                Timestamp = $stamp.ToString('yyyy-MM-dd HH:mm:ss')
                Server    = $server
                Drive     = $d.DeviceID
                Label     = $d.VolumeName
                SizeGB    = [math]::Round($d.Size / 1GB, 1)
                FreeGB    = [math]::Round($d.FreeSpace / 1GB, 1)
                UsedPct   = $usedPct
                Status    = $status
            }
            $results.Add($row)
            if ($status -ne 'OK') {
                Write-Log ("{0} {1} is {2}% used ({3} GB free) -> {4}" -f $server, $d.DeviceID, $usedPct, $row.FreeGB, $status) 'WARN'
            }
        }
        Write-Log "$server checked OK ($($disks.Count) drive(s))."
    }
    catch {
        $unreachable.Add($server)
        Write-Log "$server UNREACHABLE / query failed: $($_.Exception.Message)" 'ERROR'
        Write-Warning "$server : $($_.Exception.Message)"
    }
    finally {
        if ($session) { Remove-CimSession $session -ErrorAction SilentlyContinue }
    }
}

# ---- Report -------------------------------------------------------------
if ($results.Count) {
    $results | Export-Csv -Path $csvFile -Append -NoTypeInformation
    $results | Sort-Object @{e='Status';Descending=$false}, @{e='UsedPct';Descending=$true} |
        Format-Table Server, Drive, Label, SizeGB, FreeGB, UsedPct, Status -AutoSize | Out-Host
}

$crit = @($results | Where-Object Status -eq 'CRITICAL')
$warn = @($results | Where-Object Status -eq 'WARNING')

Write-Host ("Summary: {0} drives checked | {1} CRITICAL | {2} WARNING | {3} server(s) unreachable" -f `
    $results.Count, $crit.Count, $warn.Count, $unreachable.Count)
Write-Log ("Run finished. critical={0} warning={1} unreachable={2}" -f $crit.Count, $warn.Count, $unreachable.Count)

# ---- Optional email -----------------------------------------------------
if ($MailTo -and $SmtpServer -and ($crit.Count -or $warn.Count -or $unreachable.Count)) {
    try {
        $body = ($results | Where-Object Status -ne 'OK' |
                 Format-Table Server, Drive, SizeGB, FreeGB, UsedPct, Status -AutoSize | Out-String)
        if ($unreachable.Count) { $body += "`nUnreachable: $($unreachable -join ', ')" }
        Send-MailMessage -To $MailTo -From $MailFrom -SmtpServer $SmtpServer `
            -Subject ("Disk space alert: {0} critical, {1} warning" -f $crit.Count, $warn.Count) -Body $body
        Write-Log "Alert email sent to $MailTo."
    }
    catch { Write-Log "Email failed: $($_.Exception.Message)" 'ERROR' }
}

# ---- Exit code (useful for Task Scheduler / GitLab) ---------------------
if     ($unreachable.Count) { exit 3 }
elseif ($crit.Count)        { exit 2 }
elseif ($warn.Count)        { exit 1 }
else                        { exit 0 }

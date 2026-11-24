<#
.SYNOPSIS
    Checks every fixed drive on one or more servers and flags anything over the
    warning (default 80%) or critical (default 90%) usage threshold.

.DESCRIPTION
    - Works locally (default) or against remote servers via CIM/WinRM.
    - Writes a timestamped CSV report plus an appended log file.
    - Returns an exit code so GitLab can mark the job:
        0 = all drives OK
        1 = at least one drive over the warning threshold
        2 = at least one drive over the critical threshold, or a server was unreachable

.EXAMPLE
    # Quick local test
    .\Check-DiskSpace.ps1

.EXAMPLE
    # Test with lower thresholds so something gets flagged
    .\Check-DiskSpace.ps1 -WarningThreshold 10 -CriticalThreshold 20

.EXAMPLE
    # Several servers from a text file (one name per line)
    .\Check-DiskSpace.ps1 -ServerListPath .\servers.txt
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = $env:COMPUTERNAME,
    [string]$ServerListPath,
    [ValidateRange(1, 99)][int]$WarningThreshold  = 80,
    [ValidateRange(1, 100)][int]$CriticalThreshold = 90,
    [string]$OutputDir = (Join-Path (Get-Location) 'DiskReports'),
    [switch]$ShowAll   # also print drives that are OK
)

$ErrorActionPreference = 'Stop'

if ($WarningThreshold -ge $CriticalThreshold) {
    throw "WarningThreshold ($WarningThreshold) must be lower than CriticalThreshold ($CriticalThreshold)."
}

# Build server list
if ($ServerListPath) {
    if (-not (Test-Path $ServerListPath)) { throw "Server list not found: $ServerListPath" }
    $ComputerName = Get-Content $ServerListPath |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
}

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$runTime = Get-Date
$stamp   = $runTime.ToString('yyyyMMdd_HHmmss')
$csvPath = Join-Path $OutputDir "DiskReport_$stamp.csv"
$logPath = Join-Path $OutputDir 'DiskCheck.log'

function Write-Log {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $logPath -Value $line
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($computer in $ComputerName) {
    try {
        $isLocal = $computer -in @($env:COMPUTERNAME, 'localhost', '.', '127.0.0.1')
        $params  = @{ ClassName = 'Win32_LogicalDisk'; Filter = 'DriveType = 3' }  # fixed disks only
        if (-not $isLocal) { $params.ComputerName = $computer }

        $disks = Get-CimInstance @params

        foreach ($d in $disks) {
            if (-not $d.Size) { continue }
            $usedPct = [math]::Round((($d.Size - $d.FreeSpace) / $d.Size) * 100, 1)

            $status = if     ($usedPct -gt $CriticalThreshold) { 'CRITICAL' }
                      elseif ($usedPct -gt $WarningThreshold)  { 'WARNING'  }
                      else                                      { 'OK'       }

            $results.Add([pscustomobject]@{
                Timestamp = $runTime.ToString('yyyy-MM-dd HH:mm:ss')
                Server    = $computer
                Drive     = $d.DeviceID
                Label     = $d.VolumeName
                SizeGB    = [math]::Round($d.Size / 1GB, 1)
                UsedGB    = [math]::Round(($d.Size - $d.FreeSpace) / 1GB, 1)
                FreeGB    = [math]::Round($d.FreeSpace / 1GB, 1)
                UsedPct   = $usedPct
                Status    = $status
            })
        }
    }
    catch {
        $results.Add([pscustomobject]@{
            Timestamp = $runTime.ToString('yyyy-MM-dd HH:mm:ss')
            Server    = $computer
            Drive     = 'N/A'
            Label     = ''
            SizeGB    = $null
            UsedGB    = $null
            FreeGB    = $null
            UsedPct   = $null
            Status    = 'UNREACHABLE'
        })
        Write-Log "ERROR  $computer : $($_.Exception.Message)"
        Write-Warning "Could not query $computer : $($_.Exception.Message)"
    }
}

# Save report
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

# Log every flagged drive
$flagged = $results | Where-Object { $_.Status -ne 'OK' }
foreach ($f in $flagged) {
    Write-Log ("{0,-11} {1} {2} {3}% used ({4} GB free of {5} GB)" -f $f.Status, $f.Server, $f.Drive, $f.UsedPct, $f.FreeGB, $f.SizeGB)
}
Write-Log ("Run complete: {0} drives checked, {1} flagged" -f $results.Count, @($flagged).Count)

# Console output (shows up in the GitLab job log)
$toShow = if ($ShowAll) { $results } else { $flagged }
Write-Host ""
Write-Host "Disk check $($runTime.ToString('yyyy-MM-dd HH:mm')) | Warning > $WarningThreshold% | Critical > $CriticalThreshold%"
Write-Host ("Servers: {0} | Drives checked: {1}" -f @($ComputerName).Count, $results.Count)
if ($toShow) {
    $toShow | Sort-Object @{Expression = 'UsedPct'; Descending = $true} |
        Format-Table Server, Drive, Label, SizeGB, UsedGB, FreeGB, UsedPct, Status -AutoSize |
        Out-String | Write-Host
} else {
    Write-Host "All drives are under the warning threshold."
}
Write-Host "Report: $csvPath"

# Exit code
$exitCode = 0
if ($results | Where-Object Status -eq 'WARNING')  { $exitCode = 1 }
if ($results | Where-Object { $_.Status -in 'CRITICAL', 'UNREACHABLE' }) { $exitCode = 2 }

# In GitLab CI use a real exit code. In an interactive session, don't use `exit`
# because it would close your PowerShell window while testing.
if ($env:GITLAB_CI) {
    exit $exitCode
} else {
    $global:LASTEXITCODE = $exitCode
    Write-Host "Exit code would be: $exitCode (0 = OK, 1 = warning, 2 = critical/unreachable)"
}

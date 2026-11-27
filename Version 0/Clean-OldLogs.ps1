<#
.SYNOPSIS
    Finds (and optionally deletes) log files older than N days on whole drives of remote servers.

.DESCRIPTION
    DRY RUN BY DEFAULT: nothing is deleted unless you add -Delete.
    You do not need to know the folder paths. The script scans the given drives
    (default G:, H:, L:) recursively and only looks at files whose extension is in -Extensions
    (default .log) AND whose last-modified date is older than -OlderThanDays (default 30).

    Output:
      - on-screen summary per server/drive (files, GB, biggest folders)
      - a list of OTHER file types older than N days that were NOT touched (so you can decide
        whether they should be added to -Extensions)
      - CSV of every matching file (and the action taken) in the output folder

    Never touched: $RECYCLE.BIN, System Volume Information, and anything under -ExcludePath.

.PARAMETER Delete
    Actually delete the matching files. Review the dry-run CSV first and get client sign-off.

.EXAMPLE
    # Dry run on the ECE machines (nothing deleted)
    .\Clean-OldLogs.ps1 -ServerListPath .\servers.txt -Credential (Get-Credential)

.EXAMPLE
    # Include more extensions, exclude a folder, then delete for real
    .\Clean-OldLogs.ps1 -ComputerName ece-v1-032 -Extensions .log,.txt -ExcludePath 'G:\EnvLogs\Keep' -Credential (Get-Credential) -Delete

.NOTES
    Uses PowerShell remoting (WinRM, TCP 5985/5986). Account must be admin on the targets.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]$ServerListPath,
    [System.Management.Automation.PSCredential]$Credential,
    [string[]]$Drives = @('G:', 'H:', 'L:'),
    [ValidateRange(1,3650)][int]$OlderThanDays = 30,
    [string[]]$Extensions = @('.log'),
    [string[]]$ExcludePath = @(),
    [switch]$Delete,
    [string]$OutputFolder = (Join-Path $PSScriptRoot 'CleanupReports')
)

$ErrorActionPreference = 'Stop'

# ---- Server list --------------------------------------------------------
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
$mode    = if ($Delete) { 'DELETE' } else { 'DRYRUN' }
$logFile = Join-Path $OutputFolder ('CleanLogs_{0}_{1:yyyy-MM-dd_HHmm}.log' -f $mode, $stamp)
$csvFile = Join-Path $OutputFolder ('CleanLogs_{0}_{1:yyyy-MM-dd_HHmm}.csv' -f $mode, $stamp)

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    Add-Content -Path $logFile -Value ('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message)
}

# normalise extensions to ".log" form
$Extensions = $Extensions | ForEach-Object { if ($_.StartsWith('.')) { $_.ToLower() } else { ('.' + $_).ToLower() } }

if ($Delete) {
    Write-Host "*** DELETE MODE: files older than $OlderThanDays days with extension(s) $($Extensions -join ', ') on $($Drives -join ', ') will be removed. ***" -ForegroundColor Red
} else {
    Write-Host "DRY RUN: nothing will be deleted. Add -Delete after reviewing the results." -ForegroundColor Green
}
Write-Log "Run started. Mode=$mode Servers=$($servers -join ',') Drives=$($Drives -join ',') Days=$OlderThanDays Ext=$($Extensions -join ',')"

# ---- Work done ON the remote server -------------------------------------
$scriptBlock = {
    param($drives, $days, $exts, $exclude, $doDelete)

    $cutoff = (Get-Date).AddDays(-$days)
    $skipDirs = @('\$RECYCLE.BIN\', '\System Volume Information\')

    foreach ($drv in $drives) {
        $root = $drv.TrimEnd('\') + '\'
        if (-not (Test-Path -LiteralPath $root)) {
            [pscustomobject]@{ Kind = 'Note'; Drive = $drv; Message = 'drive not found' }
            continue
        }

        $other = @{}   # extension -> @(count, bytes) for old files we do NOT touch

        Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                $f = $_
                $path = $f.FullName

                $skip = $false
                foreach ($s in $skipDirs) { if ($path -like "*$s*") { $skip = $true; break } }
                foreach ($e in $exclude)  { if ($e -and $path -like ($e.TrimEnd('\') + '*')) { $skip = $true; break } }
                if ($skip) { return }

                $ext = $f.Extension.ToLower()
                if ($exts -contains $ext) {
                    $action = 'WouldDelete'
                    if ($doDelete) {
                        try   { Remove-Item -LiteralPath $path -Force -ErrorAction Stop; $action = 'Deleted' }
                        catch { $action = 'FAILED: ' + $_.Exception.Message }
                    }
                    [pscustomobject]@{
                        Kind      = 'File'
                        Drive     = $drv
                        Folder    = $f.DirectoryName
                        Name      = $f.Name
                        Extension = $ext
                        SizeBytes = $f.Length
                        LastWrite = $f.LastWriteTime
                        Action    = $action
                    }
                }
                else {
                    $key = if ($ext) { $ext } else { '(none)' }
                    if (-not $other.ContainsKey($key)) { $other[$key] = @(0, 0L) }
                    $other[$key][0] += 1
                    $other[$key][1] += $f.Length
                }
            }

        foreach ($k in $other.Keys) {
            [pscustomobject]@{ Kind = 'OtherExt'; Drive = $drv; Extension = $k; Count = $other[$k][0]; SizeBytes = $other[$k][1] }
        }
    }
}

# ---- Run against each server --------------------------------------------
$allFiles = New-Object System.Collections.Generic.List[object]
$failed   = New-Object System.Collections.Generic.List[string]

foreach ($server in $servers) {
    Write-Host "`n=== $server ===" -ForegroundColor Cyan
    try {
        $ic = @{
            ComputerName = $server
            ErrorAction  = 'Stop'
            ScriptBlock  = $scriptBlock
            ArgumentList = @($Drives, $OlderThanDays, $Extensions, $ExcludePath, [bool]$Delete)
        }
        if ($Credential) { $ic.Credential = $Credential }
        $out = @(Invoke-Command @ic)

        foreach ($n in ($out | Where-Object Kind -eq 'Note')) {
            Write-Warning "$server $($n.Drive): $($n.Message)"
            Write-Log "$server $($n.Drive): $($n.Message)" 'WARN'
        }

        $files = @($out | Where-Object Kind -eq 'File')
        foreach ($f in $files) {
            $allFiles.Add([pscustomobject]@{
                Server = $server; Drive = $f.Drive; Folder = $f.Folder; Name = $f.Name
                Extension = $f.Extension; SizeMB = [math]::Round($f.SizeBytes / 1MB, 2)
                LastWrite = $f.LastWrite; Action = $f.Action
            })
            if ($Delete) { Write-Log ("{0} {1} -> {2}" -f $server, (Join-Path $f.Folder $f.Name), $f.Action) }
        }

        # per-drive summary
        foreach ($g in ($files | Group-Object Drive)) {
            $gb = [math]::Round((($g.Group | Measure-Object SizeBytes -Sum).Sum) / 1GB, 2)
            Write-Host ("{0}  {1} file(s), {2} GB older than {3} days" -f $g.Name, $g.Count, $gb, $OlderThanDays)
            Write-Log  ("{0} {1}: {2} matching file(s), {3} GB" -f $server, $g.Name, $g.Count, $gb)

            Write-Host '  Biggest folders:'
            $g.Group | Group-Object Folder |
                Select-Object @{n='Folder';e={$_.Name}}, @{n='Files';e={$_.Count}},
                              @{n='GB';e={[math]::Round((($_.Group | Measure-Object SizeBytes -Sum).Sum)/1GB,2)}} |
                Sort-Object GB -Descending | Select-Object -First 10 | Format-Table -AutoSize | Out-Host
        }
        if (-not $files) { Write-Host 'No matching files older than the limit.' }

        # other old file types left alone
        $other = @($out | Where-Object Kind -eq 'OtherExt')
        if ($other) {
            Write-Host "  Other file types older than $OlderThanDays days (NOT touched):" -ForegroundColor Yellow
            $other | Sort-Object SizeBytes -Descending | Select-Object -First 10 |
                Select-Object Drive, Extension, Count, @{n='GB';e={[math]::Round($_.SizeBytes/1GB,2)}} |
                Format-Table -AutoSize | Out-Host
        }
    }
    catch {
        $failed.Add($server)
        Write-Warning "$server : $($_.Exception.Message)"
        Write-Log "$server FAILED: $($_.Exception.Message)" 'ERROR'
    }
}

# ---- Save + final summary -----------------------------------------------
if ($allFiles.Count) { $allFiles | Export-Csv -Path $csvFile -NoTypeInformation }

$totalGB = [math]::Round((($allFiles | Measure-Object SizeMB -Sum).Sum) / 1024, 2)
Write-Host ("`n{0}: {1} file(s), {2} GB across {3} server(s); {4} server(s) failed." -f `
    $mode, $allFiles.Count, $totalGB, $servers.Count, $failed.Count) -ForegroundColor Cyan
if ($allFiles.Count) { Write-Host "File list: $csvFile" }
Write-Host "Log: $logFile"
Write-Log ("Run finished. files={0} GB={1} failedServers={2}" -f $allFiles.Count, $totalGB, $failed.Count)

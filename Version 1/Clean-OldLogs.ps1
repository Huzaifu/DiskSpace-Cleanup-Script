<#
.SYNOPSIS
    Finds (and optionally deletes) log files older than N days on ALL local drives of remote servers.

.DESCRIPTION
    DRY RUN BY DEFAULT: nothing is deleted unless you add -Delete.

    By default the script discovers every local fixed drive on each server (C:, D:, E:, F:, G:, H:, L:, M:, T:, Y: ...)
    and scans each one recursively. Use -Drives to limit it, or -ExcludeDrives to skip some.
    It only touches files whose extension is in -Extensions (default .log) AND whose last-modified date
    is older than -OlderThanDays (default 30).

    Output:
      - on-screen summary per server/drive (usage, files, GB, biggest folders)
      - a list of OTHER file types older than N days that were NOT touched (e.g. .bak/.trn on the backup drive),
        so you can see what is really filling a drive and decide whether to add extensions
      - CSV of every matching file (and the action taken) plus a log file, in the output folder

    Never touched, on any drive:
      - $RECYCLE.BIN, System Volume Information
      - the folders in -ProtectedFolder (default: Windows, Program Files, Program Files (x86)) at the drive root
      - anything under -ExcludePath
    Never allowed as -Extensions (script refuses): .mdf .ndf .ldf .bak .trn .bacpac .dacpac .vhd .vhdx

.PARAMETER Drives
    Drives to scan, e.g. G:,H:. Omit to scan all local fixed drives.

.PARAMETER ExcludeDrives
    Drives to skip when scanning all drives, e.g. C:,M:.

.PARAMETER Delete
    Actually delete the matching files. Review the dry-run CSV first and get client sign-off.
    Asks you to type DELETE to confirm, unless -Unattended is used (for scheduled runs).

.EXAMPLE
    # Dry run, all drives on the servers in the list (nothing deleted)
    .\Clean-OldLogs.ps1 -ServerListPath .\servers.txt -Credential (Get-Credential)

.EXAMPLE
    # Dry run, all drives except the system drive
    .\Clean-OldLogs.ps1 -ServerListPath .\servers.txt -ExcludeDrives C: -Credential (Get-Credential)

.EXAMPLE
    # Delete for real on one server, keeping one folder
    .\Clean-OldLogs.ps1 -ComputerName ece-v1-032 -ExcludePath 'G:\EnvLogs\Keep' -Credential (Get-Credential) -Delete

.NOTES
    Uses PowerShell remoting (WinRM, TCP 5985/5986). Account must be admin on the targets.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]$ServerListPath,
    [System.Management.Automation.PSCredential]$Credential,
    [string[]]$Drives = @(),
    [string[]]$ExcludeDrives = @(),
    [ValidateRange(1,3650)][int]$OlderThanDays = 30,
    [string[]]$Extensions = @('.log'),
    [string[]]$ExcludePath = @(),
    [string[]]$ProtectedFolder = @('Windows', 'Program Files', 'Program Files (x86)'),
    [switch]$Delete,
    [switch]$Unattended,
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

# ---- Normalise inputs ---------------------------------------------------
$Extensions = $Extensions | ForEach-Object { if ($_.StartsWith('.')) { $_.ToLower() } else { ('.' + $_).ToLower() } }
$neverExt   = @('.mdf', '.ndf', '.ldf', '.bak', '.trn', '.bacpac', '.dacpac', '.vhd', '.vhdx')
$blocked    = @($Extensions | Where-Object { $neverExt -contains $_ })
if ($blocked) { throw "Refusing to delete database/backup/disk-image extensions: $($blocked -join ', ')" }

$normDrive = { param($d) ($d.Trim().TrimEnd('\').TrimEnd(':') + ':').ToUpper() }
$Drives        = @($Drives        | ForEach-Object { & $normDrive $_ })
$ExcludeDrives = @($ExcludeDrives | ForEach-Object { & $normDrive $_ })

if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }
$stamp   = Get-Date
$mode    = if ($Delete) { 'DELETE' } else { 'DRYRUN' }
$logFile = Join-Path $OutputFolder ('CleanLogs_{0}_{1:yyyy-MM-dd_HHmm}.log' -f $mode, $stamp)
$csvFile = Join-Path $OutputFolder ('CleanLogs_{0}_{1:yyyy-MM-dd_HHmm}.csv' -f $mode, $stamp)

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    Add-Content -Path $logFile -Value ('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message)
}

$driveText = if ($Drives.Count) { $Drives -join ', ' } else { 'ALL local fixed drives' }
if ($ExcludeDrives.Count) { $driveText += " (except $($ExcludeDrives -join ', '))" }

if ($Delete) {
    Write-Host "*** DELETE MODE: files older than $OlderThanDays days with extension(s) $($Extensions -join ', ') on $driveText will be removed. ***" -ForegroundColor Red
    if (-not $Unattended) {
        $answer = Read-Host 'Type DELETE to continue'
        if ($answer -cne 'DELETE') { throw 'Cancelled - nothing deleted.' }
    }
} else {
    Write-Host "DRY RUN: nothing will be deleted. Add -Delete after reviewing the results." -ForegroundColor Green
}
Write-Log "Run started. Mode=$mode Servers=$($servers -join ',') Drives=$driveText Days=$OlderThanDays Ext=$($Extensions -join ',') Protected=$($ProtectedFolder -join ',') ExcludePath=$($ExcludePath -join ',')"

# ---- Work done ON the remote server -------------------------------------
$scriptBlock = {
    param($drives, $excludeDrives, $days, $exts, $exclude, $protectedFolders, $doDelete)

    $cutoff = (Get-Date).AddDays(-$days)
    $always = @('$RECYCLE.BIN', 'System Volume Information')
    $prot   = @($always + @($protectedFolders) | Where-Object { $_ })

    # Which drives? Given list, or every local fixed drive.
    $drives = @($drives | Where-Object { $_ })
    if ($drives.Count -eq 0) {
        $drives = @([System.IO.DriveInfo]::GetDrives() |
            Where-Object { $_.DriveType -eq 'Fixed' } |
            ForEach-Object { $_.Name.TrimEnd('\') })
    }
    $drives = @($drives | Where-Object { $excludeDrives -notcontains $_.ToUpper() })

    foreach ($drv in $drives) {
        $root = $drv.TrimEnd('\') + '\'
        if (-not (Test-Path -LiteralPath $root)) {
            [pscustomobject]@{ Kind = 'Note'; Drive = $drv; Message = 'drive not found' }
            continue
        }

        try {
            $di = New-Object System.IO.DriveInfo($drv)
            [pscustomobject]@{
                Kind    = 'DriveInfo'
                Drive   = $drv
                SizeGB  = [math]::Round($di.TotalSize / 1GB, 1)
                FreeGB  = [math]::Round($di.AvailableFreeSpace / 1GB, 1)
                UsedPct = [math]::Round((($di.TotalSize - $di.AvailableFreeSpace) / $di.TotalSize) * 100, 1)
            }
        } catch { }

        $other = @{}   # extension -> @(count, bytes) for old files we do NOT touch

        Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                $f    = $_
                $path = $f.FullName

                # protected top-level folders (relative to the drive root)
                $rel  = $path.Substring($root.Length)
                $skip = $false
                foreach ($p in $prot) {
                    if ($rel.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
                }
                # excluded paths (full paths, prefix match)
                if (-not $skip) {
                    foreach ($e in $exclude) {
                        if ($e -and $path.StartsWith($e.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
                    }
                }
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
            ArgumentList = @($Drives, $ExcludeDrives, $OlderThanDays, $Extensions, $ExcludePath, $ProtectedFolder, [bool]$Delete)
        }
        if ($Credential) { $ic.Credential = $Credential }
        $out = @(Invoke-Command @ic)

        foreach ($n in ($out | Where-Object Kind -eq 'Note')) {
            Write-Warning "$server $($n.Drive): $($n.Message)"
            Write-Log "$server $($n.Drive): $($n.Message)" 'WARN'
        }

        # which drives were scanned, and how full they are
        $infos = @($out | Where-Object Kind -eq 'DriveInfo')
        if ($infos) {
            Write-Host 'Drives scanned:'
            $infos | Select-Object Drive, SizeGB, FreeGB, UsedPct | Format-Table -AutoSize | Out-Host
            foreach ($i in $infos) { Write-Log ("{0} {1}: {2} GB, {3} GB free, {4}% used" -f $server, $i.Drive, $i.SizeGB, $i.FreeGB, $i.UsedPct) }
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
            $other | Sort-Object SizeBytes -Descending | Select-Object -First 15 |
                Select-Object Drive, Extension, Count, @{n='GB';e={[math]::Round($_.SizeBytes/1GB,2)}} |
                Format-Table -AutoSize | Out-Host
            foreach ($o in $other) {
                Write-Log ("{0} {1}: NOT touched {2} {3} file(s), {4} GB" -f $server, $o.Drive, $o.Count, $o.Extension, [math]::Round($o.SizeBytes/1GB,2))
            }
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

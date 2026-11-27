<#
.SYNOPSIS
    Builds a single-file HTML dashboard from DiskCheck_History.csv.

.DESCRIPTION
    Reads the history written by Check-DiskSpace.ps1 and produces Dashboard.html:
      - summary tiles (CRITICAL / WARNING / OK / stale data)
      - one row per server + drive from the LATEST run, worst first
      - usage bar, free space, change over the last 7 days, and a trend sparkline
      - "Last checked" per drive, flagged STALE if older than -StaleHours
        (a server that stops answering stops appearing in new runs, so this catches it)
    No internet, no modules - open the file in any browser or attach it to an email.
    Check-DiskSpace.ps1 calls this script automatically after every run.

.EXAMPLE
    .\New-DiskDashboard.ps1
#>
[CmdletBinding()]
param(
    [string]$HistoryPath = (Join-Path $PSScriptRoot 'DiskReports\DiskCheck_History.csv'),
    [string]$OutputPath  = (Join-Path $PSScriptRoot 'DiskReports\Dashboard.html'),
    [int]$TrendPoints = 28,    # 28 points = 7 days at 4 runs/day
    [int]$StaleHours  = 12
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $HistoryPath)) { throw "History file not found: $HistoryPath" }

$inv  = [System.Globalization.CultureInfo]::InvariantCulture
$enc  = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }

$rows = @(Import-Csv $HistoryPath | ForEach-Object {
    [pscustomobject]@{
        Time    = [datetime]::ParseExact($_.Timestamp, 'yyyy-MM-dd HH:mm:ss', $inv)
        Server  = $_.Server
        Drive   = $_.Drive
        Label   = $_.Label
        SizeGB  = [double]$_.SizeGB
        FreeGB  = [double]$_.FreeGB
        UsedPct = [double]$_.UsedPct
        Status  = $_.Status
    }
})
if (-not $rows.Count) { throw 'History file is empty.' }

$now = Get-Date
$order = @{ CRITICAL = 0; WARNING = 1; OK = 2 }
$view = New-Object System.Collections.Generic.List[object]

foreach ($g in ($rows | Group-Object Server, Drive)) {
    $series = @($g.Group | Sort-Object Time)
    $last   = $series[-1]
    $stale  = (($now - $last.Time).TotalHours -gt $StaleHours)

    # change vs. the first reading inside the last 7 days
    $ref   = $series | Where-Object { $_.Time -ge $last.Time.AddDays(-7) } | Select-Object -First 1
    $delta = [math]::Round($last.UsedPct - $ref.UsedPct, 1)

    # sparkline (auto-scaled, at least a 5-point range so noise is not exaggerated)
    $pts   = @($series | Select-Object -Last $TrendPoints)
    $vals  = @($pts | ForEach-Object { $_.UsedPct })
    $min = ($vals | Measure-Object -Minimum).Minimum
    $max = ($vals | Measure-Object -Maximum).Maximum
    if (($max - $min) -lt 5) { $mid = ($max + $min) / 2; $min = $mid - 2.5; $max = $mid + 2.5 }
    $w = 120; $h = 28
    $poly = ''
    if ($vals.Count -ge 2) {
        $poly = (0..($vals.Count - 1) | ForEach-Object {
            $x = [math]::Round($_ * $w / ($vals.Count - 1), 1)
            $y = [math]::Round($h - 2 - (($vals[$_] - $min) / ($max - $min)) * ($h - 4), 1)
            '{0},{1}' -f $x.ToString($inv), $y.ToString($inv)
        }) -join ' '
    }

    $view.Add([pscustomobject]@{
        Server = $last.Server; Drive = $last.Drive; Label = $last.Label
        SizeGB = $last.SizeGB; FreeGB = $last.FreeGB; UsedPct = $last.UsedPct
        Status = $last.Status; Time = $last.Time; Stale = $stale
        Delta = $delta; Poly = $poly; Sort = $order[$last.Status]
    })
}

$view  = @($view | Sort-Object Sort, @{e = 'UsedPct'; Descending = $true}, Server, Drive)
$nCrit = @($view | Where-Object Status -eq 'CRITICAL').Count
$nWarn = @($view | Where-Object Status -eq 'WARNING').Count
$nOk   = @($view | Where-Object Status -eq 'OK').Count
$nStale = @($view | Where-Object Stale).Count
$servers = @($view | Select-Object -ExpandProperty Server -Unique).Count

$body = New-Object System.Text.StringBuilder
foreach ($v in $view) {
    $cls    = $v.Status.ToLower()
    $barW   = [math]::Min(100, $v.UsedPct).ToString($inv)
    $deltaT = if ($v.Delta -gt 0) { '+{0}' -f $v.Delta.ToString($inv) } else { $v.Delta.ToString($inv) }
    $stale  = if ($v.Stale) { ' <span class="stale">STALE</span>' } else { '' }
    $spark  = if ($v.Poly) { "<svg width='120' height='28' viewBox='0 0 120 28'><polyline points='$($v.Poly)' fill='none' stroke='#475569' stroke-width='1.6'/></svg>" } else { '' }
    [void]$body.AppendLine(@"
<tr class="$cls">
  <td>$(& $enc $v.Server)</td>
  <td>$(& $enc $v.Drive) <span class="muted">$(& $enc $v.Label)</span></td>
  <td><div class="bar"><div class="fill $cls" style="width:$barW%"></div></div></td>
  <td class="num">$($v.UsedPct.ToString($inv))%</td>
  <td class="num">$($v.FreeGB.ToString($inv)) / $($v.SizeGB.ToString($inv)) GB</td>
  <td class="num">$deltaT pts</td>
  <td>$spark</td>
  <td><span class="pill $cls">$($v.Status)</span></td>
  <td class="muted">$($v.Time.ToString('yyyy-MM-dd HH:mm'))$stale</td>
</tr>
"@)
}

$html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Disk Space Dashboard</title>
<style>
  body{font-family:Segoe UI,Arial,sans-serif;margin:24px;background:#f8fafc;color:#0f172a}
  h1{margin:0 0 4px;font-size:22px} .sub{color:#64748b;margin-bottom:18px;font-size:13px}
  .tiles{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:18px}
  .tile{background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:12px 18px;min-width:110px}
  .tile b{display:block;font-size:26px} .tile span{font-size:12px;color:#64748b}
  .tile.critical b{color:#b91c1c} .tile.warning b{color:#b45309} .tile.ok b{color:#15803d}
  .wrap{overflow-x:auto}
  table{border-collapse:collapse;width:100%;background:#fff;border:1px solid #e2e8f0}
  th,td{padding:8px 10px;border-bottom:1px solid #e2e8f0;text-align:left;font-size:13px;white-space:nowrap}
  th{background:#f1f5f9;font-weight:600} .num{text-align:right} .muted{color:#64748b}
  .bar{width:140px;height:10px;background:#e2e8f0;border-radius:5px;overflow:hidden}
  .fill{height:100%} .fill.ok{background:#22c55e} .fill.warning{background:#f59e0b} .fill.critical{background:#dc2626}
  .pill{padding:2px 8px;border-radius:10px;font-size:11px;font-weight:600;color:#fff}
  .pill.ok{background:#16a34a} .pill.warning{background:#d97706} .pill.critical{background:#dc2626}
  .stale{background:#64748b;color:#fff;border-radius:4px;padding:1px 5px;font-size:10px;margin-left:4px}
  tr.critical td:first-child{border-left:4px solid #dc2626} tr.warning td:first-child{border-left:4px solid #f59e0b}
</style></head><body>
<h1>Disk Space Dashboard</h1>
<div class="sub">Generated $($now.ToString('yyyy-MM-dd HH:mm')) &middot; $servers server(s), $($view.Count) drive(s) &middot; source: latest run per drive in $(& $enc (Split-Path $HistoryPath -Leaf))</div>
<div class="tiles">
  <div class="tile critical"><b>$nCrit</b><span>Critical (&ge; 90%)</span></div>
  <div class="tile warning"><b>$nWarn</b><span>Warning (&ge; 80%)</span></div>
  <div class="tile ok"><b>$nOk</b><span>OK</span></div>
  <div class="tile"><b>$nStale</b><span>Stale (&gt; $StaleHours h old)</span></div>
</div>
<div class="wrap"><table>
<thead><tr><th>Server</th><th>Drive</th><th>Usage</th><th>Used</th><th>Free / Size</th><th>7-day change</th><th>Trend</th><th>Status</th><th>Last checked</th></tr></thead>
<tbody>
$($body.ToString())
</tbody></table></div>
</body></html>
"@

$dir = Split-Path $OutputPath -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
Set-Content -Path $OutputPath -Value $html -Encoding UTF8
Write-Host "Dashboard written: $OutputPath"

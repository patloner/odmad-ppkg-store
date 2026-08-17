#Requires -Version 5.1
<#
.SYNOPSIS
    Admin workstation script - pulls PreCutoverState logs from GitHub and
    generates a color-coded HTML fleet readiness report.

.DESCRIPTION
    Companion to Get-PreCutoverState.ps1 (Quest ODM Custom Action).
    Fetches all PreCutoverState_*_<date>_*.txt logs from odm-reports/logs/,
    parses them, and renders a fleet-level HTML report showing:
      - Which machines are READY, REVIEW, or HOLD (blocked from cutover)
      - Pending reboot and TPM failures (must fix before proceeding)
      - MAM/Workplace enrollment counts (will be auto-cleared)
      - Disk space warnings
      - NGC presence across fleet

    Run this on the admin workstation BEFORE starting Quest ODM cutover tasks.
    Use -LatestOnly to deduplicate when a machine has multiple pre-cutover scans.

.PARAMETER Date
    Date to pull logs for. Defaults to today. Matches YYYYMMDD in filename.

.PARAMETER GitHubToken
    GitHub PAT with contents:read on odm-reports. Also accepts $env:ODMAD_GH_TOKEN or $env:GITHUB_TOKEN.

.PARAMETER LatestOnly
    Keep only the most recent log per machine when multiple exist for the same date.

.PARAMETER NoBrowser
    Write HTML file but do not auto-open it.

.PARAMETER OutputPath
    Path for the HTML report. Defaults to .\PreCutoverSummary_<date>.html.

.EXAMPLE
    .\Get-PreCutoverSummary.ps1 -GitHubToken "ghp_..." -LatestOnly

.NOTES
    Marco Technologies - Migration Engineering
    Companion: Get-PreCutoverState.ps1, Bootstrap-PreCutoverState.ps1
#>

param(
    [Parameter()]
    [datetime]$Date = (Get-Date),

    [Parameter()]
    [string]$GitHubToken,

    [Parameter()]
    [string]$RepoOwner = 'patloner',

    [Parameter()]
    [string]$RepoName = 'odm-reports',

    [Parameter()]
    [string]$Branch = 'main',

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$NoBrowser,

    [Parameter()]
    [switch]$LatestOnly
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Required for [System.Web.HttpUtility]::HtmlEncode on Windows PowerShell 5.1.
# Not auto-loaded, and with $ErrorActionPreference='Stop' an unresolved type
# would abort the whole report on the first table row.
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

# Accept either env var. The device-side scripts and both bootstraps use
# ODMAD_GH_TOKEN, so falling back only to GITHUB_TOKEN was an easy trap.
$token = $GitHubToken
if (-not $token) { $token = $env:ODMAD_GH_TOKEN }
if (-not $token) { $token = $env:GITHUB_TOKEN }
if (-not $token) {
    Write-Error "No GitHub token supplied. Pass -GitHubToken or set `$env:ODMAD_GH_TOKEN."
}

$dateStamp = $Date.ToString('yyyyMMdd')
if (-not $OutputPath) {
    $OutputPath = ".\PreCutoverSummary_$dateStamp.html"
}

Write-Host ""
Write-Host "  Get-PreCutoverSummary" -ForegroundColor Cyan
Write-Host "  Marco Technologies - Migration Engineering" -ForegroundColor Gray
Write-Host "  Date    : $($Date.ToString('yyyy-MM-dd'))" -ForegroundColor White
Write-Host "  Repo    : $RepoOwner/$RepoName" -ForegroundColor White
Write-Host ""

# ---------------------------------------------------------------------------
# GitHub API helpers
# ---------------------------------------------------------------------------

function Invoke-GhApi {
    param([string]$Path)
    $uri = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/$Path"
    $h   = @{
        'Authorization'        = "Bearer $token"
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'Marco-ODMAD-Toolkit'
    }
    Invoke-RestMethod -Uri $uri -Headers $h -ErrorAction Stop
}

function Get-RawContent {
    param([string]$ApiUrl)
    $h = @{
        'Authorization'        = "Bearer $token"
        'Accept'               = 'application/vnd.github.raw+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'Marco-ODMAD-Toolkit'
    }
    Invoke-RestMethod -Uri $ApiUrl -Headers $h -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Fetch log listing
# ---------------------------------------------------------------------------

Write-Host "  Fetching log listing from GitHub..." -ForegroundColor Gray
$allFiles    = @(Invoke-GhApi -Path 'logs')
$stateFiles  = @($allFiles | Where-Object {
    $_.name -match "^PreCutoverState_.*_${dateStamp}_\d{6}\.txt$"
})
$ngcFiles    = @($allFiles | Where-Object {
    $_.name -match "^Clear-NGC_.*_${dateStamp}_\d{6}\.txt$"
})

Write-Host "  Found $($stateFiles.Count) PreCutoverState log(s) for $dateStamp" `
    -ForegroundColor $(if ($stateFiles.Count -gt 0) { 'Green' } else { 'Yellow' })

if ($stateFiles.Count -eq 0) {
    Write-Warning "No PreCutoverState logs found for $dateStamp."
    Write-Host "  Available PreCutoverState logs (all dates):" -ForegroundColor Gray
    $allFiles | Where-Object { $_.name -match 'PreCutoverState' } |
        Select-Object -Last 10 | ForEach-Object { Write-Host "    $($_.name)" -ForegroundColor Gray }
    exit 0
}

# ---------------------------------------------------------------------------
# Parse a PreCutoverState log
# ---------------------------------------------------------------------------

function Parse-PreCutoverLog {
    param([string]$Content, [string]$FileName)

    $machineName = 'Unknown'
    $logTime     = ''
    $passCount   = 0
    $warnCount   = 0
    $failCount   = 0
    $overall     = 'UNKNOWN'
    $failChecks  = [System.Collections.Generic.List[object]]::new()
    $warnChecks  = [System.Collections.Generic.List[object]]::new()
    $infoChecks  = [System.Collections.Generic.List[object]]::new()
    $mamCount    = 0
    $wpCount     = 0
    $ngcPresent  = $false
    $tpmReady    = 'unknown'
    $diskFreeGB  = $null
    $domJoined   = 'unknown'
    $tenantName  = 'unknown'

    if ($FileName -match '^PreCutoverState_(.+?)_(\d{8})_(\d{6})\.txt$') {
        $machineName = $matches[1]
        $logTime     = "$($matches[2].Substring(0,4))-$($matches[2].Substring(4,2))-$($matches[2].Substring(6,2)) $($matches[3].Substring(0,2)):$($matches[3].Substring(2,2)):$($matches[3].Substring(4,2))"
    }

    foreach ($line in ($Content -split "`n")) {
        $line = $line.TrimEnd("`r")

        if ($line -match '^\s+\[PASS\]\s+(\S+)\s+(.+)$')  {
            $passCount++
        } elseif ($line -match '^\s+\[WARN\]\s+(\S+)\s+(.+)$') {
            $warnCount++
            [void]$warnChecks.Add([PSCustomObject]@{ Name = $matches[1]; Detail = $matches[2].Trim() })
        } elseif ($line -match '^\s+\[FAIL\]\s+(\S+)\s+(.+)$') {
            $failCount++
            [void]$failChecks.Add([PSCustomObject]@{ Name = $matches[1]; Detail = $matches[2].Trim() })
        } elseif ($line -match '^\s+\[INFO\]\s+(\S+)\s+(.+)$') {
            # Deliberately counted nowhere - INFO must not affect the verdict.
            # Captured only so notes like Pending-FileRename still surface in
            # the detail box instead of vanishing from the report.
            [void]$infoChecks.Add([PSCustomObject]@{ Name = $matches[1]; Detail = $matches[2].Trim() })
        }

        if ($line -match 'OVERALL:\s+(READY|HOLD|REVIEW)') { $overall = $matches[1] }
        if ($line -match 'Found (\d+) MAM enrollment') { $mamCount = [int]$matches[1] }
        if ($line -match 'Found (\d+) Workplace') { $wpCount = [int]$matches[1] }
        if ($line -match 'NGC folder has content') { $ngcPresent = $true }
        if ($line -match 'TPM present, enabled, and ready') { $tpmReady = 'PASS' }
        # Alternation must stay inside the group. Unparenthesised, the bare
        # 'not enabled' / 'not in Ready' branches match anywhere on any line -
        # including inside a dumped file path - and fake a fleet TPM failure.
        if ($line -match 'TPM is (not present|not enabled|not in Ready)') { $tpmReady = 'FAIL' }
        if ($line -match '(\d+[\.,]\d+) GB free on C:') { $diskFreeGB = $matches[1] }
        if ($line -match 'DomainJoined=(\w+)') { $domJoined = $matches[1] }
        # Tenant is the last field on the JoinState line, and tenant names
        # contain spaces - [^\s]+ silently truncated "Marco Technologies" to
        # "Marco".
        if ($line -match 'Tenant=(.+)$') { $tenantName = $matches[1].Trim() }
    }

    if ($overall -eq 'UNKNOWN') {
        if (($passCount + $warnCount + $failCount) -eq 0) {
            # Nothing parsed at all. Do NOT infer READY from an absence of
            # findings - a truncated, empty or wrong-type log would otherwise be
            # reported as ready to cut over. Absence of evidence is not evidence.
            $overall = 'UNKNOWN'
        } else {
            $overall = if ($failCount -gt 0) { 'HOLD' } elseif ($warnCount -gt 0) { 'REVIEW' } else { 'READY' }
        }
    }

    return [PSCustomObject]@{
        MachineName = $machineName
        LogTime     = $logTime
        PassCount   = $passCount
        WarnCount   = $warnCount
        FailCount   = $failCount
        Overall     = $overall
        FailChecks  = $failChecks
        WarnChecks  = $warnChecks
        InfoChecks  = $infoChecks
        MamCount    = $mamCount
        WpCount     = $wpCount
        NgcPresent  = $ngcPresent
        TpmReady    = $tpmReady
        DiskFreeGB  = $diskFreeGB
        DomJoined   = $domJoined
        TenantName  = $tenantName
        FileName    = $FileName
    }
}

# ---------------------------------------------------------------------------
# Fetch and parse
# ---------------------------------------------------------------------------

$machineResults = [System.Collections.Generic.List[object]]::new()

foreach ($file in ($stateFiles | Sort-Object name)) {
    # Defensive: only PreCutoverState logs belong here. Anything else parses to
    # MachineName='Unknown', and -LatestOnly would then collapse every unrelated
    # file into one bogus row.
    if ($file.name -notmatch '^PreCutoverState_.+_\d{8}_\d{6}\.txt$') {
        Write-Host "  Skipping $($file.name) - not a PreCutoverState log." -ForegroundColor DarkGray
        continue
    }
    Write-Host "  Fetching $($file.name)..." -ForegroundColor Gray
    try {
        $content = Get-RawContent -ApiUrl $file.url
        $parsed  = Parse-PreCutoverLog -Content $content -FileName $file.name
        $machineResults.Add($parsed)
        $color = switch ($parsed.Overall) {
            'HOLD'    { 'Red' }
            'REVIEW'  { 'Yellow' }
            'READY'   { 'Green' }
            default   { 'Magenta' }   # UNKNOWN - nothing parsed, needs a look
        }
        Write-Host ("    {0,-30} {1,-8} PASS={2,2}  WARN={3,2}  FAIL={4,2}" -f `
            $parsed.MachineName, $parsed.Overall, $parsed.PassCount, $parsed.WarnCount, $parsed.FailCount) `
            -ForegroundColor $color
    } catch {
        Write-Warning "Failed to fetch $($file.name): $_"
    }
}

# Deduplicate by machine name if -LatestOnly
if ($LatestOnly -and $machineResults.Count -gt 0) {
    $deduped = [System.Collections.Generic.List[object]]::new()
    $grouped = $machineResults | Group-Object -Property MachineName
    foreach ($grp in $grouped) {
        $latest = $grp.Group | Sort-Object { $_.LogTime } -Descending | Select-Object -First 1
        [void]$deduped.Add($latest)
    }
    $dupeCount = $machineResults.Count - $deduped.Count
    if ($dupeCount -gt 0) {
        Write-Host "  -LatestOnly: removed $dupeCount older run(s)." -ForegroundColor Cyan
    }
    $machineResults = $deduped
}

# ---------------------------------------------------------------------------
# Fleet totals
# ---------------------------------------------------------------------------

$fleetTotal  = $machineResults.Count
$fleetReady  = @($machineResults | Where-Object { $_.Overall -eq 'READY' }).Count
$fleetReview = @($machineResults | Where-Object { $_.Overall -eq 'REVIEW' }).Count
$fleetHold   = @($machineResults | Where-Object { $_.Overall -eq 'HOLD' }).Count
$fleetUnknown= @($machineResults | Where-Object { $_.Overall -eq 'UNKNOWN' }).Count
$fleetMAM    = ($machineResults | Measure-Object -Property MamCount -Sum).Sum
$fleetNGC    = @($machineResults | Where-Object { $_.NgcPresent }).Count
$fleetTPMFail= @($machineResults | Where-Object { $_.TpmReady -eq 'FAIL' }).Count

$allFailNames = $machineResults | ForEach-Object { $_.FailChecks } | ForEach-Object { $_.Name }
$allWarnNames = $machineResults | ForEach-Object { $_.WarnChecks } | ForEach-Object { $_.Name }
$topFails = @($allFailNames | Group-Object | Sort-Object Count -Descending | Select-Object -First 5)
$topWarns = @($allWarnNames | Group-Object | Sort-Object Count -Descending | Select-Object -First 5)

$generatedAt  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
# An UNKNOWN machine is an unanswered question, not a pass - it must not be able
# to sit inside a green fleet verdict.
$fleetVerdict = if ($fleetHold -gt 0 -or $fleetUnknown -gt 0) { 'HOLD' }
                elseif ($fleetReview -gt 0) { 'REVIEW' }
                else { 'READY' }

# ---------------------------------------------------------------------------
# Build HTML
# ---------------------------------------------------------------------------

$tableRows     = [System.Text.StringBuilder]::new()
$detailSections = [System.Text.StringBuilder]::new()
$sortedResults  = @($machineResults | Sort-Object @{E={$_.FailCount};Desc=$true}, MachineName)
$rowIndex = 0

foreach ($m in $sortedResults) {
    $rowClass = switch ($m.Overall) {
        'HOLD'   { 'row-hold' }
        'REVIEW' { 'row-review' }
        default  { 'row-ready' }
    }
    $badge = switch ($m.Overall) {
        'HOLD'    { "<span class='badge badge-hold'>HOLD</span>" }
        'REVIEW'  { "<span class='badge badge-review'>REVIEW</span>" }
        'READY'   { "<span class='badge badge-ready'>READY</span>" }
        # Never let an unrecognised verdict fall through to a green READY badge.
        default   { "<span class='badge badge-hold'>UNKNOWN</span>" }
    }
    $tpmBadge = if ($m.TpmReady -eq 'FAIL') { "<span class='pill pill-fail'>TPM FAIL</span>" } else { '' }
    $mamBadge = if ($m.MamCount -gt 0) { "<span class='pill pill-warn'>MAM:$($m.MamCount)</span>" } else { '' }
    $ngcBadge = if ($m.NgcPresent) { "<span class='pill pill-info'>NGC</span>" } else { '' }

    $failTags = ($m.FailChecks | ForEach-Object { "<span class='pill pill-fail'>FAIL: $($_.Name)</span>" }) -join ' '
    # Known-benign warnings are suppressed from the triage pills - they are
    # still shown in the expanded detail box. Pending-FileRename is NOT in this
    # list on purpose: routine PFRO churn is graded INFO by the collector, so
    # anything that reaches WARN hit Windows servicing and needs the pill.
    $warnTags = ($m.WarnChecks | Where-Object { $_.Name -notmatch 'MAM|Workplace' } |
        ForEach-Object { "<span class='pill pill-warn'>WARN: $($_.Name)</span>" }) -join ' '

    [void]$tableRows.AppendLine("<tr class='$rowClass'>")
    [void]$tableRows.AppendLine("  <td class='machine-name'>$([System.Web.HttpUtility]::HtmlEncode($m.MachineName))</td>")
    # LogTime is '' whenever the filename did not match the PreCutoverState
    # pattern, and Substring(11) on that throws. Format defensively.
    $timeCell = if ($m.LogTime -and $m.LogTime.Length -ge 12) { $m.LogTime.Substring(11) } else { '-' }
    [void]$tableRows.AppendLine("  <td>$timeCell</td>")
    [void]$tableRows.AppendLine("  <td class='num-pass'>$($m.PassCount)</td>")
    [void]$tableRows.AppendLine("  <td class='num-warn'>$($m.WarnCount)</td>")
    [void]$tableRows.AppendLine("  <td class='num-fail'>$($m.FailCount)</td>")
    [void]$tableRows.AppendLine("  <td>$badge</td>")
    [void]$tableRows.AppendLine("  <td>$failTags $warnTags $tpmBadge $mamBadge $ngcBadge</td>")
    [void]$tableRows.AppendLine("  <td><button class='btn-detail' onclick='toggleDetail($rowIndex)'>Details</button></td>")
    [void]$tableRows.AppendLine("</tr>")
    [void]$tableRows.AppendLine("<tr id='detail-$rowIndex' class='detail-row' style='display:none'>")
    [void]$tableRows.AppendLine("  <td colspan='8'>")
    [void]$tableRows.AppendLine("    <div class='detail-box'>")
    [void]$tableRows.AppendLine("      <div class='detail-header'>$([System.Web.HttpUtility]::HtmlEncode($m.MachineName)) - Pre-Cutover State</div>")
    [void]$tableRows.AppendLine("      <div class='detail-meta'>Tenant: $([System.Web.HttpUtility]::HtmlEncode($m.TenantName)) &nbsp;|&nbsp; DomainJoined: $($m.DomJoined) &nbsp;|&nbsp; Log: $([System.Web.HttpUtility]::HtmlEncode($m.FileName))</div>")

    if ($m.FailChecks.Count -gt 0) {
        [void]$tableRows.AppendLine("      <div class='detail-section-title'>Blockers (resolve before cutover)</div>")
        foreach ($fc in $m.FailChecks) {
            [void]$tableRows.AppendLine("      <div class='detail-item fail-item'><strong>$([System.Web.HttpUtility]::HtmlEncode($fc.Name))</strong>  -- $([System.Web.HttpUtility]::HtmlEncode($fc.Detail))</div>")
        }
    }
    if ($m.WarnChecks.Count -gt 0) {
        [void]$tableRows.AppendLine("      <div class='detail-section-title'>Warnings</div>")
        foreach ($wc in $m.WarnChecks) {
            # Annotate the warnings that are known-benign so a REVIEW row can be
            # cleared at a glance instead of being chased machine by machine.
            $autoNote = ''
            if ($wc.Name -match 'MAM|Workplace') {
                $autoNote = ' <em>(auto-cleared by Remove-ConflictingEnrollments)</em>'
            } elseif ($wc.Name -match 'Pending-FileRename') {
                # Routine PFRO churn is graded INFO by the collector, so if it
                # reached WARN the queued paths hit Windows servicing.
                $autoNote = ' <em>(queued paths hit Windows servicing - check these before cutting this machine over)</em>'
            }
            [void]$tableRows.AppendLine("      <div class='detail-item warn-item'><strong>$([System.Web.HttpUtility]::HtmlEncode($wc.Name))</strong>  -- $([System.Web.HttpUtility]::HtmlEncode($wc.Detail))$autoNote</div>")
        }
    }
    if ($m.NgcPresent) {
        [void]$tableRows.AppendLine("      <div class='detail-item info-item'><strong>NGC-Keys</strong>  -- Windows Hello keys present. Will be cleared by Clear-NGC Custom Action.</div>")
    }
    # Notes carry INFO checks - non-blocking by definition, but they belong in
    # the audit record. NGC-Keys is skipped; it already has its own line above.
    $notes = @($m.InfoChecks | Where-Object { $_.Name -notmatch 'NGC-Keys' })
    if ($notes.Count -gt 0) {
        [void]$tableRows.AppendLine("      <div class='detail-section-title'>Notes</div>")
        foreach ($ic in $notes) {
            [void]$tableRows.AppendLine("      <div class='detail-item info-item'><strong>$([System.Web.HttpUtility]::HtmlEncode($ic.Name))</strong>  -- $([System.Web.HttpUtility]::HtmlEncode($ic.Detail))</div>")
        }
    }

    [void]$tableRows.AppendLine("    </div>")
    [void]$tableRows.AppendLine("  </td>")
    [void]$tableRows.AppendLine("</tr>")
    $rowIndex++
}

$statusBarClass = switch ($fleetVerdict) { 'HOLD' { 'status-hold' } 'REVIEW' { 'status-review' } default { 'status-ready' } }
$statusMsg = switch ($fleetVerdict) {
    'HOLD'   { "$fleetHold machine(s) BLOCKED - resolve before starting ODM" }
    'REVIEW' { "$fleetReview machine(s) have warnings - review before proceeding" }
    default  { "All $fleetTotal machine(s) ready for cutover" }
}

$commonIssuesHtml = ''
if ($topFails.Count -gt 0) {
    $rows = ($topFails | ForEach-Object { "<tr><td>$($_.Name)</td><td>$($_.Count) machine(s)</td><td><span class='pill pill-fail'>BLOCKER</span></td></tr>" }) -join ''
    $commonIssuesHtml += "<h3>Common Blockers</h3><table class='issues-table'><tr><th>Check</th><th>Machines</th><th>Status</th></tr>$rows</table>"
}
if ($topWarns.Count -gt 0) {
    $rows = ($topWarns | ForEach-Object { "<tr><td>$($_.Name)</td><td>$($_.Count) machine(s)</td><td><span class='pill pill-warn'>WARN</span></td></tr>" }) -join ''
    $commonIssuesHtml += "<h3>Common Warnings</h3><table class='issues-table'><tr><th>Check</th><th>Machines</th><th>Status</th></tr>$rows</table>"
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Pre-Cutover Readiness - $dateStamp</title>
<style>
  :root {
    --marco-blue: #003087;
    --marco-mid:  #0057b8;
    --marco-light:#e8f0fb;
    --hold:   #c0392b; --hold-bg:   #fdf0ef;
    --review: #d68910; --review-bg: #fef9e7;
    --ready:  #1e8449; --ready-bg:  #eafaf1;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Segoe UI', Arial, sans-serif; font-size: 13px; background: #f4f6f9; color: #222; }
  .header { background: linear-gradient(135deg, var(--marco-blue), var(--marco-mid)); color: #fff; padding: 20px 30px 14px; }
  .header h1 { font-size: 20px; font-weight: 700; }
  .subtitle { font-size: 11px; opacity: .8; margin-top: 4px; }
  .status-bar { padding: 10px 30px; font-weight: 700; font-size: 13px; color: #fff; }
  .status-hold   { background: var(--hold); }
  .status-review { background: var(--review); }
  .status-ready  { background: var(--ready); }
  .content { padding: 20px 30px; }
  .cards { display: flex; gap: 14px; margin-bottom: 20px; flex-wrap: wrap; }
  .card { background: #fff; border-radius: 6px; padding: 14px 18px; flex: 1; min-width: 130px;
          box-shadow: 0 1px 4px rgba(0,0,0,.08); text-align: center; }
  .card .num { font-size: 28px; font-weight: 700; }
  .card .lbl { font-size: 11px; color: #666; margin-top: 2px; }
  .card.hold   .num { color: var(--hold); }
  .card.review .num { color: var(--review); }
  .card.ready  .num { color: var(--ready); }
  .card.neutral .num { color: var(--marco-blue); }
  .section { background: #fff; border-radius: 6px; padding: 16px 18px; margin-bottom: 16px;
             box-shadow: 0 1px 4px rgba(0,0,0,.08); }
  .section h2 { font-size: 14px; color: var(--marco-blue); margin-bottom: 12px; border-bottom: 1px solid #e0e6f0; padding-bottom: 6px; }
  .section h3 { font-size: 12px; margin: 10px 0 6px; color: #444; }
  table { width: 100%; border-collapse: collapse; }
  th { background: var(--marco-blue); color: #fff; padding: 7px 10px; text-align: left; font-size: 11px; font-weight: 600; }
  td { padding: 6px 10px; border-bottom: 1px solid #eee; vertical-align: middle; }
  .machine-name { font-weight: 600; font-family: monospace; font-size: 12px; }
  .num-pass { color: var(--ready);  font-weight: 700; }
  .num-warn { color: var(--review); font-weight: 700; }
  .num-fail { color: var(--hold);   font-weight: 700; }
  .row-hold   td { background: var(--hold-bg); }
  .row-review td { background: var(--review-bg); }
  .row-ready  td { background: var(--ready-bg); }
  .badge { padding: 3px 8px; border-radius: 10px; font-size: 10px; font-weight: 700; color: #fff; }
  .badge-hold   { background: var(--hold); }
  .badge-review { background: var(--review); }
  .badge-ready  { background: var(--ready); }
  .pill { display: inline-block; padding: 2px 6px; border-radius: 8px; font-size: 10px; font-weight: 600; margin: 1px; }
  .pill-fail { background: #fde8e6; color: var(--hold); }
  .pill-warn { background: #fef3cd; color: #7d5a00; }
  .pill-info { background: #e8f0fb; color: var(--marco-blue); }
  .btn-detail { background: var(--marco-mid); color: #fff; border: none; border-radius: 4px;
                padding: 3px 10px; font-size: 11px; cursor: pointer; }
  .btn-detail:hover { background: var(--marco-blue); }
  .detail-row td { padding: 0; background: #fff !important; }
  .detail-box { padding: 12px 16px; border-left: 3px solid var(--marco-mid); margin: 4px 8px; }
  .detail-header { font-weight: 700; font-size: 13px; color: var(--marco-blue); margin-bottom: 4px; }
  .detail-meta { font-size: 10px; color: #888; margin-bottom: 8px; }
  .detail-section-title { font-size: 11px; font-weight: 700; color: #555; margin: 8px 0 4px; text-transform: uppercase; }
  .detail-item { font-size: 11px; padding: 3px 0; }
  .fail-item { color: var(--hold); }
  .warn-item { color: #7d5a00; }
  .info-item { color: var(--marco-blue); }
  .issues-table { width: auto; min-width: 400px; margin-bottom: 8px; }
  .issues-table td, .issues-table th { padding: 4px 12px; }
  .footer { text-align: center; font-size: 10px; color: #999; padding: 16px; }
  .footer a { color: var(--marco-mid); }
</style>
<script>
function toggleDetail(i) {
  var r = document.getElementById('detail-' + i);
  r.style.display = r.style.display === 'none' ? 'table-row' : 'none';
}
</script>
</head>
<body>
<div class="header">
  <h1>Pre-Cutover Readiness Report</h1>
  <div class="subtitle">Date: $($Date.ToString('yyyy-MM-dd')) &nbsp;&bull;&nbsp; Generated: $generatedAt &nbsp;&bull;&nbsp; Source: $RepoOwner/$RepoName/logs/</div>
</div>
<div class="status-bar $statusBarClass">$statusMsg</div>
<div class="content">
  <div class="cards">
    <div class="card neutral"><div class="num">$fleetTotal</div><div class="lbl">Total Machines</div></div>
    <div class="card ready"><div class="num">$fleetReady</div><div class="lbl">Ready</div></div>
    <div class="card review"><div class="num">$fleetReview</div><div class="lbl">Review</div></div>
    <div class="card hold"><div class="num">$fleetHold</div><div class="lbl">Hold (Blocked)</div></div>
    <div class="card neutral"><div class="num">$fleetMAM</div><div class="lbl">MAM Enrollments (auto-cleared)</div></div>
    <div class="card neutral"><div class="num">$fleetNGC</div><div class="lbl">NGC Present (auto-cleared)</div></div>
    <div class="card hold"><div class="num">$fleetTPMFail</div><div class="lbl">TPM Failures</div></div>
  </div>
  $(if ($commonIssuesHtml) { "<div class='section'><h2>Common Issues Across Fleet</h2>$commonIssuesHtml</div>" })
  <div class="section">
    <h2>Machine Results</h2>
    <table>
      <tr>
        <th>Machine</th><th>Time</th><th>PASS</th><th>WARN</th><th>FAIL</th>
        <th>Status</th><th>Issues</th><th></th>
      </tr>
      $($tableRows.ToString())
    </table>
  </div>
</div>
<div class="footer">
  Quest ODMAD Pre-Cutover Readiness &bull; Marco Technologies Migration Engineering &bull;
  <a href="https://github.com/$RepoOwner/$RepoName/tree/$Branch/logs" target="_blank">View raw logs on GitHub</a> &bull;
  Reference: Quest ODMAD Entra-Joined Devices QSG TOPIC-2311203
</div>
</body>
</html>
"@

# ---------------------------------------------------------------------------
# Write and open
# ---------------------------------------------------------------------------

$html | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
$fullPath = (Resolve-Path $OutputPath).Path
Write-Host ""
Write-Host "  Report written: $fullPath" -ForegroundColor Green
Write-Host ""
Write-Host "  Fleet summary:" -ForegroundColor White
Write-Host "    Ready  : $fleetReady" -ForegroundColor Green
Write-Host "    Review : $fleetReview" -ForegroundColor Yellow
Write-Host "    HOLD   : $fleetHold" -ForegroundColor Red
if ($fleetUnknown -gt 0) {
    Write-Host "    UNKNOWN: $fleetUnknown  (log parsed to zero checks - investigate, do NOT treat as ready)" -ForegroundColor Magenta
}
Write-Host "    MAM enrollments (auto-clear): $fleetMAM" -ForegroundColor Gray
Write-Host "    NGC present (auto-clear)    : $fleetNGC" -ForegroundColor Gray
Write-Host "    TPM failures                : $fleetTPMFail" -ForegroundColor $(if ($fleetTPMFail -gt 0) { 'Red' } else { 'Gray' })
Write-Host ""

if (-not $NoBrowser) {
    try { Start-Process $fullPath } catch { }
}

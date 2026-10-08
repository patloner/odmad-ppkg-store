#Requires -Version 5.1
<#
.SYNOPSIS
    Quest ODMAD Custom Action - Clear IdentityStore cache to prevent black screen
    on first target-user logon after Domain-to-Entra cutover.
    Optionally uploads the run log to GitHub for centralized review.

.DESCRIPTION
    After an ODMAD in-place Entra join, the IdentityStore cache (HKLM:\SOFTWARE\
    Microsoft\IdentityStore\Cache) may contain identity entries from the source domain
    or source tenant. When the target user signs in for the first time, Windows attempts
    to resolve these stale identity references, causing:
      - Black screen at logon (Win10/Win11)
      - Taskbar flickering or not loading
      - Delayed desktop load or apparent hang

    This script removes ALL subkeys under the IdentityStore\Cache root. The cache
    rebuilds automatically and correctly when the target user signs in.

    MUST RUN BEFORE THE TARGET USER'S FIRST LOGON post-cutover. If they have already
    signed in, the cache is already rebuilt and the black screen has either already
    occurred or may still occur on the NEXT sign-in with a stale entry - clear it anyway.

    Reference:
      Quest ODMAD Entra-Joined Devices Quick Start Guide FAQ TOPIC-2293745:
      "After Cutover, why is the Windows screen flickering or displaying a black
       screen on some devices?"
      Resolution: Remove HKLM\SOFTWARE\Microsoft\IdentityStore\Cache subfolders
      before the target user first logs in.

    Safe to run on machines that have no stale entries - the script detects and logs
    the count found before removal. Always exits 0 (never aborts an ODM task).

.NOTES
    Marco Technologies - Migration Engineering
    Paste into Quest ODM -> Custom Actions -> PowerShell.
    Set to run AFTER the Entra join / device reboot step.
    Also usable as a remediation Custom Action on already-migrated machines:
      Create an ODM task targeting flagged machines and run before users arrive.
    Exit 0 = success. READ and REMOVE only on IdentityStore\Cache - no other state touched.
#>

# ===========================================================================
# CONFIG: update these per engagement
# ===========================================================================
# PAT comes from the generic bootstrap ($env:ODMAD_GH_TOKEN); empty = skip upload (stdout/ODM log only)
$GitHubToken = if ($env:ODMAD_GH_TOKEN) { $env:ODMAD_GH_TOKEN } else { '' }
$RepoOwner   = 'patloner'
$RepoName    = 'odm-reports'
$Branch      = 'main'
# ===========================================================================

$ErrorActionPreference = 'Continue'

$logBuffer    = [System.Text.StringBuilder]::new()
$runTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

function Write-Log {
    param([string]$Message)
    Write-Output $Message
    [void]$logBuffer.AppendLine($Message)
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

Write-Log "===================================================="
Write-Log " Repair-IdentityStoreCache - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log " Host: $env:COMPUTERNAME"
Write-Log " Reference: Quest ODMAD QSG FAQ TOPIC-2293745"
Write-Log "===================================================="
Write-Log ""
Write-Log " Purpose: Clear stale identity cache to prevent black screen"
Write-Log "          on first target-user logon post-cutover."
Write-Log ""

# ---------------------------------------------------------------------------
# Confirm Entra join state before touching anything
# ---------------------------------------------------------------------------

$aadJoined  = 'unknown'
$tenantName = 'unknown'
$deviceId   = 'unknown'

try {
    foreach ($line in @(& dsregcmd.exe /status 2>$null)) {
        if ($line -match '^\s*AzureAdJoined\s*:\s*(.+)$')  { $aadJoined  = $matches[1].Trim() }
        if ($line -match '^\s*TenantName\s*:\s*(.+)$')     { $tenantName = $matches[1].Trim() }
        if ($line -match '^\s*DeviceId\s*:\s*(.+)$')       { $deviceId   = $matches[1].Trim() }
    }
} catch { Write-Log "  Warning: dsregcmd failed - $($_.Exception.Message)" }

Write-Log " AzureAdJoined : $aadJoined"
Write-Log " TenantName    : $tenantName"
Write-Log " DeviceId      : $deviceId"
Write-Log ""

if ($aadJoined -ne 'YES') {
    Write-Log " WARNING: AzureAdJoined is not YES. Proceeding anyway - the cache should"
    Write-Log "          still be cleared so it does not interfere with the join retry."
    Write-Log ""
}

# ---------------------------------------------------------------------------
# IdentityStore cache clear
# Reference: Quest ODMAD QSG FAQ TOPIC-2293745
# ---------------------------------------------------------------------------

$cacheRoot   = 'HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache'
$keysRemoved = 0
$keysFailed  = 0
$keysFound   = 0

Write-Log "[1/1] Clearing IdentityStore\Cache..."

if (-not (Test-Path $cacheRoot)) {
    Write-Log "  Cache root key not present - nothing to clear."
    Write-Log "  (This is expected on machines that have never had a user sign in"
    Write-Log "   or where the cache was already cleared.)"
} else {
    # Enumerate direct children of the Cache key (these are the identity SID/GUID subkeys)
    $cacheSubkeys = @(Get-ChildItem -Path $cacheRoot -ErrorAction SilentlyContinue)
    $keysFound    = $cacheSubkeys.Count

    Write-Log "  Found $keysFound subkey(s) under IdentityStore\Cache."

    if ($keysFound -eq 0) {
        Write-Log "  Cache is already empty - no action needed."
    } else {
        foreach ($sk in $cacheSubkeys) {
            $skName = $sk.PSChildName
            try {
                # Count entries within each subkey for the log
                $entryCount = @(Get-ChildItem -Path $sk.PSPath -Recurse -ErrorAction SilentlyContinue).Count
                Remove-Item -Path $sk.PSPath -Recurse -Force -ErrorAction Stop
                Write-Log "  REMOVED: $skName ($entryCount child item(s))"
                $keysRemoved++
            } catch {
                Write-Log "  FAILED:  $skName - $($_.Exception.Message)"
                $keysFailed++
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Log ""
Write-Log "===================================================="
if ($keysFound -eq 0) {
    Write-Log " Result: Cache was already empty. No action taken."
} elseif ($keysFailed -eq 0) {
    Write-Log " Result: Cleared $keysRemoved of $keysFound cache subkey(s). Clean."
    Write-Log " The cache will rebuild correctly on the target user's first sign-in."
} else {
    Write-Log " Result: Found $keysFound | Removed $keysRemoved | Failed $keysFailed"
    Write-Log " Warning: $keysFailed subkey(s) could not be removed."
    Write-Log " The user may still experience black screen for the failed entries."
    Write-Log " Try removing manually: HKLM\SOFTWARE\Microsoft\IdentityStore\Cache"
}
Write-Log ""
Write-Log " IMPORTANT: This script must run BEFORE the target user's first logon."
Write-Log " Reference : Quest ODMAD Entra-Joined Devices QSG FAQ TOPIC-2293745"
Write-Log "===================================================="
# ===========================================================================
# Local copy - written BEFORE the upload and OUTSIDE the token guard.
# The ODM custom action stdout is otherwise the only record of this run, so if
# the PAT is dead or the network blips this file is the evidence you collect
# off the box. Never let a reporting failure destroy the report.
# ===========================================================================

try {
    $localLogDir  = Join-Path $env:ProgramData 'Marco\ODMAD'
    $localLogPath = Join-Path $localLogDir "Repair-IdentityStoreCache_${env:COMPUTERNAME}_${runTimestamp}.txt"
    if (-not (Test-Path -LiteralPath $localLogDir)) {
        New-Item -Path $localLogDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    # UTF8 without BOM - byte-identical to what the upload sends, so the local
    # copy and the GitHub copy never diverge. Set-Content -Encoding ASCII would
    # silently substitute '?' for localized error text or non-ASCII tenant names,
    # and PS 5.1's -Encoding UTF8 would prepend a BOM.
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($localLogPath, ($logBuffer.ToString()), $utf8NoBom)
    Write-Output "Local copy saved: $localLogPath"
} catch {
    Write-Output "Local copy FAILED: $($_.Exception.Message)"
    Write-Output "(Log content is still in the ODM task output above.)"
}


# ---------------------------------------------------------------------------
# GitHub log upload (optional)
# ---------------------------------------------------------------------------

if ($GitHubToken) {
    Write-Output ""
    Write-Output "Uploading log to $RepoOwner/$RepoName/logs/ ..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $logFileName = "logs/Repair-IdentityStoreCache_${env:COMPUTERNAME}_${runTimestamp}.txt"
        $apiUrl      = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/$logFileName"
        $encoded     = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($logBuffer.ToString()))
        $headers = @{
            'Authorization'        = "Bearer $GitHubToken"
            'Accept'               = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent'           = 'Marco-ODMAD-Toolkit'
        }
        $body = @{
            message = "IdentityStore cache clear: $env:COMPUTERNAME ($runTimestamp) Found=$keysFound Removed=$keysRemoved Failed=$keysFailed"
            content = $encoded
            branch  = $Branch
        } | ConvertTo-Json -Depth 3
        $response = Invoke-RestMethod -Uri $apiUrl -Method Put -Headers $headers -Body $body `
            -ContentType 'application/json' -ErrorAction Stop
        Write-Output "LOG UPLOAD OK  -> $logFileName  (commit: $($response.commit.sha.Substring(0,8)))"
    } catch {
        Write-Output "LOG UPLOAD FAILED: $($_.Exception.Message)"
    }
} else {
    Write-Output ""
    Write-Output "(Log upload skipped - set GitHubToken in config block to enable.)"
}

exit 0

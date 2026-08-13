#Requires -Version 5.1
<#
.SYNOPSIS
    Quest ODMAD Custom Action - Clear NGC (Next Generation Credentials) folder
    before Entra join to prevent TPM/Windows Hello errors at first target-user logon.

.DESCRIPTION
    Removes contents of C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\NGC.
    This folder contains Windows Hello for Business keys and PIN data tied to the source
    domain identity. If not cleared before the Entra join, the first logon after cutover
    produces a TPM error or "Something went wrong" PIN prompt that confuses end users.

    Uses takeown + icacls to gain access before removal (SYSTEM does not own this folder
    by default). Non-fatal if removal fails - logs the error and exits 0.

    Reference:
      Quest ODMAD Entra-Joined Devices QSG - pre-join cleanup guidance
      Symptom: TPM chip error / Windows Hello prompt fails at first logon post-cutover

.NOTES
    Marco Technologies - Migration Engineering
    Paste Bootstrap-ClearNGC.ps1 into Quest ODM (it downloads and runs THIS file
    from odmad-ppkg-store/scripts/Clear-NGC.ps1).
    Run AFTER Remove-ConflictingEnrollments and BEFORE ppkg download / Entra join.
    Nothing reboots in between, so this may sit inside the cutover action ahead of
    the ppkg download.
    Always exits 0 - NGC clear failure must not abort the cutover. Which also means
    a failure looks like SUCCESS in ODM; read the task output.

    This does NOT clear the TPM. A TPM clear needs physical presence at the UEFI
    screen and the BitLocker recovery key first - see TPM-Clear-EndUser-Steps.md.
#>

# ===========================================================================
# CONFIG - injected by bootstrap via environment variables.
#   $env:ODMAD_GH_TOKEN = 'PASTE_PAT_HERE'
# ===========================================================================
$GitHubToken = if ($env:ODMAD_GH_TOKEN) { $env:ODMAD_GH_TOKEN } else { '' }
$RepoOwner   = 'patloner'
$RepoName    = 'odm-reports'
$Branch      = 'main'
# ===========================================================================

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

$logBuffer    = [System.Text.StringBuilder]::new()
$runTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

function Write-Log {
    param([string]$Message)
    Write-Output $Message
    [void]$logBuffer.AppendLine($Message)
}

Write-Log "===================================================="
Write-Log " Clear-NGC - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log " Host: $env:COMPUTERNAME"
Write-Log " Purpose: Remove source-domain Windows Hello/PIN keys"
Write-Log "          before Entra join to prevent TPM error at first logon."
Write-Log "===================================================="
Write-Log ""

$ngcPath    = 'C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\NGC'
$itemsFound = 0
$cleared    = $false

if (-not (Test-Path $ngcPath)) {
    Write-Log " NGC path not present - no action needed."
    Write-Log " (Expected on machines where Windows Hello was never configured.)"
} else {
    try {
        $items = @(Get-ChildItem -Path $ngcPath -Force -ErrorAction SilentlyContinue)
        $itemsFound = $items.Count
        Write-Log " NGC path present - found $itemsFound item(s)."
    } catch {
        Write-Log " Could not enumerate NGC: $_"
    }

    if ($itemsFound -eq 0) {
        Write-Log " NGC folder already empty - no action needed."
    } else {
        Write-Log " Taking ownership and clearing..."
        try {
            $null = & takeown.exe /f $ngcPath /r /d y 2>&1
            Write-Log "   takeown: OK"
        } catch {
            Write-Log "   takeown warning: $_"
        }

        try {
            $null = & icacls.exe $ngcPath /grant "Administrators:(F)" /t /q 2>&1
            Write-Log "   icacls:  OK"
        } catch {
            Write-Log "   icacls warning: $_"
        }

        $removed = 0
        $failed  = 0
        foreach ($item in $items) {
            try {
                Remove-Item -Path $item.FullName -Recurse -Force -ErrorAction Stop
                $removed++
            } catch {
                Write-Log "   FAILED to remove $($item.Name): $_"
                $failed++
            }
        }

        if ($failed -eq 0) {
            Write-Log " CLEARED: removed $removed item(s). Windows Hello keys from source domain gone."
            $cleared = $true
        } else {
            Write-Log " PARTIAL: removed $removed, failed $failed. Remaining items may cause TPM prompt."
        }
    }
}

Write-Log ""
Write-Log "===================================================="
Write-Log " Clear-NGC complete - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
if ($itemsFound -eq 0) {
    Write-Log " Result: Nothing to clear."
} elseif ($cleared) {
    Write-Log " Result: NGC cleared successfully. First logon TPM error prevented."
} else {
    Write-Log " Result: Partial clear - review log above."
}
Write-Log "===================================================="
# ===========================================================================
# Local copy - written BEFORE the upload and OUTSIDE the token guard.
# The ODM custom action stdout is otherwise the only record of this run, so if
# the PAT is dead or the network blips this file is the evidence you collect
# off the box. Never let a reporting failure destroy the report.
# ===========================================================================

try {
    $localLogDir  = Join-Path $env:ProgramData 'Marco\ODMAD'
    $localLogPath = Join-Path $localLogDir "Clear-NGC_${env:COMPUTERNAME}_${runTimestamp}.txt"
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


if ($GitHubToken) {
    Write-Output ""
    Write-Output "Uploading log to $RepoOwner/$RepoName/logs/ ..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $logFileName = "logs/Clear-NGC_${env:COMPUTERNAME}_${runTimestamp}.txt"
        $apiUrl      = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/$logFileName"
        $encoded     = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($logBuffer.ToString()))
        $headers = @{
            'Authorization'        = "Bearer $GitHubToken"
            'Accept'               = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent'           = 'Marco-ODMAD-Toolkit'
        }
        $body = @{
            message = "Clear-NGC: $env:COMPUTERNAME ($runTimestamp) Found=$itemsFound Cleared=$cleared"
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
    Write-Output "(Log upload skipped - set ODMAD_GH_TOKEN to enable.)"
}

exit 0

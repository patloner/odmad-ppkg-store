#Requires -Version 5.1
<#
.SYNOPSIS
    Quest ODMAD Custom Action - Remove MAM and Workplace enrollments that block Entra join.
    Optionally uploads the run log to GitHub for centralized review.

.DESCRIPTION
    Removes conflicting device enrollments that cause provisioning package AAD join to fail
    with error 0x8018000A (MENROLL_E_DEVICE_ALREADY_ENROLLED).

    Targets only:
      - MAM (Mobile Application Management) enrollments - EnrollmentType 5
        Typically created when a user adds a work account to an Office app or
        via Settings > Access work or school on a domain-joined machine.
      - Workplace (device registered) entries under WorkplaceJoin\JoinInfo

    Does NOT touch:
      - Domain membership or Netlogon
      - Computer account in AD
      - Any other registry state outside the two enrollment paths

    Runs as SYSTEM via Quest ODM custom action before the Entra join step.
    Always exits 0 so ODM proceeds to the join regardless of whether
    enrollments were found. Logs all actions to stdout for ODM capture.

    When $GitHubToken is set in the config block below, the full log is also
    uploaded to odm-reports/logs/ as:
        ConflictingEnrollments_<ComputerName>_<timestamp>.txt
    so you can review all machines from the admin workstation without
    needing to retrieve logs from each device.

.NOTES
    Marco Technologies - Migration Engineering
    Paste into Quest ODM -> Custom Actions -> PowerShell.
    Set this action to run BEFORE the Entra join / provisioning package step.
    Exit 0 = success (ODM proceeds). Never exits 1 - removal failure is logged
    but must not abort the cutover since the join may still succeed.
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

# ---------------------------------------------------------------------------
# Logging helper - writes to stdout (ODM task log) AND captures for upload
# ---------------------------------------------------------------------------

$logBuffer = [System.Text.StringBuilder]::new()

function Write-Log {
    param([string]$Message)
    Write-Output $Message
    [void]$logBuffer.AppendLine($Message)
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

$enrollmentRoot = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
$wpJoinRoot     = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WorkplaceJoin\JoinInfo'

$found        = 0
$removed      = 0
$errors       = 0
$runTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

Write-Log "===================================================="
Write-Log " Remove-ConflictingEnrollments - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log " Host: $env:COMPUTERNAME"
Write-Log "===================================================="

# ---------------------------------------------------------------------------
# Section 1: MAM enrollments (EnrollmentType = 5 / MAM SyncML Server)
# ---------------------------------------------------------------------------

Write-Log ""
Write-Log "[1/2] Checking HKLM:\SOFTWARE\Microsoft\Enrollments for MAM entries..."

if (Test-Path $enrollmentRoot) {
    $keys = Get-ChildItem -Path $enrollmentRoot -ErrorAction SilentlyContinue

    foreach ($key in $keys) {
        try {
            $props          = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            $enrollmentType = $props.EnrollmentType
            $providerID     = $props.ProviderID
            $upn            = $props.UPN
            $tenantId       = $props.AADTenantID

            # Target MAM by type (5) or provider string - belt and suspenders
            $isMAM = ($enrollmentType -eq 5) -or ($providerID -eq 'MAM SyncML Server')

            if ($isMAM) {
                $found++
                Write-Log "  FOUND MAM enrollment: $($key.PSChildName)"
                Write-Log "    UPN        : $upn"
                Write-Log "    TenantId   : $tenantId"
                Write-Log "    Type       : $enrollmentType"
                Write-Log "    Provider   : $providerID"

                try {
                    Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction Stop
                    Write-Log "    REMOVED OK"
                    $removed++
                } catch {
                    Write-Log "    ERROR removing key: $_"
                    $errors++
                }
            }
        } catch {
            Write-Log "  Warning: Could not read $($key.PSChildName) - $_"
        }
    }

    if ($found -eq 0) {
        Write-Log "  No MAM enrollments found."
    }
} else {
    Write-Log "  Enrollments root key not present - nothing to check."
}

# ---------------------------------------------------------------------------
# Section 2: Workplace (registered device) join entries
# ---------------------------------------------------------------------------

Write-Log ""
Write-Log "[2/2] Checking WorkplaceJoin\JoinInfo for registered device entries..."

if (Test-Path $wpJoinRoot) {
    $wpKeys = Get-ChildItem -Path $wpJoinRoot -ErrorAction SilentlyContinue

    foreach ($key in $wpKeys) {
        try {
            $props    = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            $tenantId = $props.TenantId
            $upn      = $props.UserEmail

            $found++
            Write-Log "  FOUND Workplace registration: $($key.PSChildName)"
            Write-Log "    UPN      : $upn"
            Write-Log "    TenantId : $tenantId"

            try {
                Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction Stop
                Write-Log "    REMOVED OK"
                $removed++
            } catch {
                Write-Log "    ERROR removing key: $_"
                $errors++
            }
        } catch {
            Write-Log "  Warning: Could not read $($key.PSChildName) - $_"
        }
    }

    if (($wpKeys | Measure-Object).Count -eq 0) {
        Write-Log "  No Workplace registrations found."
    }
} else {
    Write-Log "  WorkplaceJoin\JoinInfo key not present - nothing to check."
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Log ""
Write-Log "===================================================="
if ($found -eq 0) {
    Write-Log " Result: No conflicting enrollments found. Join should proceed cleanly."
} else {
    Write-Log " Result: Found $found  |  Removed $removed  |  Errors $errors"
    if ($errors -gt 0) {
        Write-Log " Warning: $errors removal(s) failed - join may still encounter conflicts."
        Write-Log " Consider running Reset-Entra.ps1 manually if join fails."
    } else {
        Write-Log " All conflicting enrollments cleared. Proceeding to Entra join."
    }
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
    $localLogPath = Join-Path $localLogDir "ConflictingEnrollments_${env:COMPUTERNAME}_${runTimestamp}.txt"
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
# GitHub log upload (optional - only if $GitHubToken is set in config block)
# ---------------------------------------------------------------------------

if ($GitHubToken) {
    Write-Output ""
    Write-Output "Uploading log to $RepoOwner/$RepoName/logs/ ..."

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $logFileName = "logs/ConflictingEnrollments_${env:COMPUTERNAME}_${runTimestamp}.txt"
        $apiUrl      = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/$logFileName"
        $logContent  = $logBuffer.ToString()
        $encoded     = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($logContent))

        $headers = @{
            'Authorization'        = "Bearer $GitHubToken"
            'Accept'               = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent'           = 'Marco-ODMAD-Toolkit'
        }

        $body = @{
            message = "Enrollment check: $env:COMPUTERNAME ($runTimestamp)"
            content = $encoded
            branch  = $Branch
        } | ConvertTo-Json -Depth 3

        $response = Invoke-RestMethod -Uri $apiUrl -Method Put `
            -Headers $headers -Body $body `
            -ContentType 'application/json' -ErrorAction Stop

        $shortSha = $response.commit.sha.Substring(0, 8)
        Write-Output "LOG UPLOAD OK  -> $logFileName  (commit: $shortSha)"
        Write-Output "Review all machines: https://github.com/$RepoOwner/$RepoName/tree/$Branch/logs"
    } catch {
        # Upload failure must never change the exit code or abort the cutover
        Write-Output "LOG UPLOAD FAILED: $($_.Exception.Message)"
        Write-Output "(Check token or network - ODM task log still captures the output above.)"
    }
} else {
    Write-Output ""
    Write-Output "(Log upload skipped - set GitHubToken in config block to enable.)"
}

# Always exit 0 - removal failure is logged but must not abort the ODM task.
# The join step will reveal whether any residual conflict remains.
exit 0

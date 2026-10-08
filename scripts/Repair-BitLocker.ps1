#Requires -Version 5.1
<#
.SYNOPSIS
    Quest ODMAD Custom Action - Combined BitLocker repair after Domain-to-Entra cutover.
    Resumes encryption, adds a RecoveryPassword protector if missing, then escrows to Entra.

.DESCRIPTION
    Addresses three distinct BitLocker failure modes detected by Get-PostCutoverHealth.ps1:

      FAIL  BitLocker-NoRecoveryKey  - No RecoveryPassword protector on the OS volume
      WARN  BitLocker-Suspended      - BitLocker protection is suspended
      WARN  BitLocker-Escrow         - Recovery key not confirmed escrowed to Entra

    Repair sequence (auto-detected, only needed steps run):
      Step 1  Resume protection  - if ProtectionStatus is Off (suspended), resume it
      Step 2  Add recovery key   - if no RecoveryPassword protector exists, generate one
      Step 3  Escrow to Entra    - call BackupToAAD-BitLockerKeyProtector with the
                                   RecoveryPassword protector's KeyProtectorId
                                   Uses the DEVICE identity (no user logon required)

    Safe to run on machines that are already fully healthy - each step is skipped if
    the condition requiring it is not present.

    Timing note:
      BitLocker escrow (Step 3) uses the device identity established during the Entra join.
      Run AFTER the join is confirmed (AzureAdJoined = YES). User logon is NOT required.
      BitLocker suspended/missing-key conditions do not depend on user logon - safe to
      run any time after the join, including same-night before users arrive.

    Reference:
      Quest ODMAD Entra-Joined Devices QSG TOPIC-2311203 (Post-Cutover Validation)
      "Verify BitLocker Recovery Key in Entra ID - run BackupToAAD-BitLockerKeyProtector"
      Microsoft Docs: BackupToAAD-BitLockerKeyProtector requires Azure AD joined device
      (device identity used, not user identity)

.PARAMETER ExpectedTenantId
    Optional. If provided and dsregcmd reports a different TenantId, the script logs
    a warning and skips the escrow step to avoid writing a key to the wrong tenant.

.NOTES
    Marco Technologies - Migration Engineering
    Paste into Quest ODM -> Custom Actions -> PowerShell.
    Set to run AFTER the Entra join / device reboot step and BEFORE user logon.
    Always exits 0 - failure is logged but must not abort the ODM task.
#>

# NO param() block (2026-09-24): Quest ODM invokes custom actions with its own named args
# (-Device_DN ...). With the old param([string]$ExpectedTenantId), the value after that
# unknown -Name could bind POSITIONALLY to $ExpectedTenantId, making the wrong-tenant guard
# compare the tenant against a device DN. Set it in CONFIG, or pass -ExpectedTenantId <guid>
# locally (scanned from $args).

# ===========================================================================
# CONFIG: update these per engagement
# ===========================================================================
$ExpectedTenantId = ''       # optional target tenant GUID guard
$odmArgs = @($args | ForEach-Object { [string]$_ })
for ($i = 0; $i -lt ($odmArgs.Count - 1); $i++) {
    if ($odmArgs[$i] -match '^-ExpectedTenantId$') { $ExpectedTenantId = $odmArgs[$i + 1]; break }
}
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
Write-Log " Repair-BitLocker - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log " Host: $env:COMPUTERNAME"
Write-Log " Reference: Quest ODMAD QSG TOPIC-2311203"
Write-Log "===================================================="
Write-Log ""

# ---------------------------------------------------------------------------
# Step 0: Confirm Entra join and optional tenant check
# ---------------------------------------------------------------------------

$aadJoined  = 'unknown'
$tenantId   = 'unknown'
$tenantName = 'unknown'
$deviceId   = 'unknown'

try {
    foreach ($line in @(& dsregcmd.exe /status 2>$null)) {
        if ($line -match '^\s*AzureAdJoined\s*:\s*(.+)$')  { $aadJoined  = $matches[1].Trim() }
        if ($line -match '^\s*TenantId\s*:\s*(.+)$')       { $tenantId   = $matches[1].Trim() }
        if ($line -match '^\s*TenantName\s*:\s*(.+)$')     { $tenantName = $matches[1].Trim() }
        if ($line -match '^\s*DeviceId\s*:\s*(.+)$')       { $deviceId   = $matches[1].Trim() }
    }
} catch { Write-Log "  Warning: dsregcmd failed - $($_.Exception.Message)" }

Write-Log "[0/3] Entra Join State:"
Write-Log "  AzureAdJoined : $aadJoined"
Write-Log "  TenantName    : $tenantName"
Write-Log "  TenantId      : $tenantId"
Write-Log "  DeviceId      : $deviceId"
Write-Log ""

$tenantMismatch = $false
if ($ExpectedTenantId -and ($tenantId -ne $ExpectedTenantId)) {
    Write-Log "  WARNING: TenantId '$tenantId' does not match expected '$ExpectedTenantId'."
    Write-Log "           Escrow step will be skipped to avoid writing key to wrong tenant."
    $tenantMismatch = $true
}

if ($aadJoined -ne 'YES') {
    Write-Log "  WARNING: AzureAdJoined is not YES. Repair steps will still run (resume/"
    Write-Log "           add-key) but escrow will fail without a valid device identity."
    Write-Log "           Run again after confirming the Entra join completes."
    Write-Log ""
}

# ---------------------------------------------------------------------------
# Determine OS volume
# ---------------------------------------------------------------------------

$osVolume = $null
try {
    $blvols = @(Get-BitLockerVolume -ErrorAction Stop)
    foreach ($vol in $blvols) {
        $role = $vol.VolumeType
        if ($role -eq 'OperatingSystem') {
            $osVolume = $vol
            break
        }
    }
    if (-not $osVolume) {
        # fallback: use $env:SystemDrive
        $osVolume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    }
} catch {
    Write-Log "ERROR: Cannot retrieve BitLocker volume info - $($_.Exception.Message)"
    Write-Log "  BitLocker may not be enabled or the BitLocker module may be unavailable."
    Write-Log "  Skipping all repair steps."
}

if (-not $osVolume) {
    Write-Log "  Could not identify OS volume. Skipping BitLocker repair."
} else {
    $mp             = $osVolume.MountPoint
    $encStatus      = $osVolume.EncryptionMethod
    $protStatus     = $osVolume.ProtectionStatus   # On / Off
    $encPct         = $osVolume.EncryptionPercentage

    Write-Log "[BitLocker OS Volume: $mp]"
    Write-Log "  EncryptionMethod     : $encStatus"
    Write-Log "  ProtectionStatus     : $protStatus  (On=protected, Off=suspended)"
    Write-Log "  EncryptionPercentage : $encPct%"
    Write-Log ""

    # Refresh protectors
    $protectors = @($osVolume.KeyProtector)

    # -----------------------------------------------------------------------
    # Step 1: Resume if suspended
    # -----------------------------------------------------------------------

    Write-Log "[1/3] Check / Resume BitLocker protection..."

    if ($protStatus -eq 'Off') {
        Write-Log "  Protection is SUSPENDED. Resuming..."
        try {
            Resume-BitLocker -MountPoint $mp -ErrorAction Stop
            Write-Log "  RESUMED OK. Protection is now On."
        } catch {
            Write-Log "  ERROR resuming BitLocker: $($_.Exception.Message)"
        }
    } elseif ($protStatus -eq 'On') {
        Write-Log "  Protection is already On. No action needed."
    } else {
        Write-Log "  Protection status: '$protStatus' - unrecognized. Attempting resume anyway..."
        try {
            Resume-BitLocker -MountPoint $mp -ErrorAction Stop
            Write-Log "  RESUMED OK."
        } catch {
            Write-Log "  ERROR: $($_.Exception.Message)"
        }
    }

    Write-Log ""

    # -----------------------------------------------------------------------
    # Step 2: Add RecoveryPassword protector if missing
    # -----------------------------------------------------------------------

    Write-Log "[2/3] Check / Add RecoveryPassword protector..."

    $rpProtector = $null
    foreach ($p in $protectors) {
        if ($p.KeyProtectorType -eq 'RecoveryPassword') {
            $rpProtector = $p
            break
        }
    }

    if ($rpProtector) {
        Write-Log "  RecoveryPassword protector already present:"
        Write-Log "    ID: $($rpProtector.KeyProtectorId)"
        Write-Log "  No action needed."
    } else {
        Write-Log "  No RecoveryPassword protector found. Adding one..."
        try {
            $addResult = Add-BitLockerKeyProtector -MountPoint $mp `
                -RecoveryPasswordProtector -ErrorAction Stop
            # Refresh to get the new protector
            $refreshed = Get-BitLockerVolume -MountPoint $mp -ErrorAction SilentlyContinue
            $newProtectors = @($refreshed.KeyProtector)
            foreach ($p in $newProtectors) {
                if ($p.KeyProtectorType -eq 'RecoveryPassword') {
                    $rpProtector = $p
                    break
                }
            }
            if ($rpProtector) {
                Write-Log "  ADDED OK. New protector ID: $($rpProtector.KeyProtectorId)"
            } else {
                Write-Log "  ADDED but could not re-read ID. Continuing to escrow step."
            }
        } catch {
            Write-Log "  ERROR adding RecoveryPassword protector: $($_.Exception.Message)"
            Write-Log "  Escrow step will be skipped (nothing to escrow)."
        }
    }

    Write-Log ""

    # -----------------------------------------------------------------------
    # Step 3: Escrow to Entra
    # Reference: BackupToAAD-BitLockerKeyProtector uses device identity,
    #            no user logon required, must be Entra joined.
    # -----------------------------------------------------------------------

    Write-Log "[3/3] Escrow RecoveryPassword to Entra ID..."

    if ($tenantMismatch) {
        Write-Log "  SKIPPED - tenant mismatch detected in Step 0."
    } elseif (-not $rpProtector) {
        Write-Log "  SKIPPED - no RecoveryPassword protector available after Step 2."
    } elseif ($aadJoined -ne 'YES') {
        Write-Log "  SKIPPED - device is not confirmed Entra joined (AzureAdJoined != YES)."
        Write-Log "  Re-run this script after the Entra join is confirmed."
    } else {
        Write-Log "  Calling BackupToAAD-BitLockerKeyProtector..."
        Write-Log "    MountPoint    : $mp"
        Write-Log "    KeyProtectorId: $($rpProtector.KeyProtectorId)"
        try {
            BackupToAAD-BitLockerKeyProtector -MountPoint $mp `
                -KeyProtectorId $rpProtector.KeyProtectorId -ErrorAction Stop
            Write-Log "  ESCROW OK. Recovery key uploaded to Entra ID for device $deviceId."
            Write-Log "  Verify in Entra portal: Devices > $env:COMPUTERNAME > BitLocker keys"
        } catch {
            Write-Log "  ERROR escrowing key: $($_.Exception.Message)"
            Write-Log "  Common causes:"
            Write-Log "    - Device identity not yet fully provisioned (retry in 5 min)"
            Write-Log "    - No network connectivity to Entra endpoints"
            Write-Log "    - BackupToAAD-BitLockerKeyProtector not available on this OS version"
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Log ""
Write-Log "===================================================="
Write-Log " Repair-BitLocker complete - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log " Host: $env:COMPUTERNAME  |  Tenant: $tenantName"
Write-Log " Run Get-PostCutoverHealth to verify all checks PASS after remediation."
Write-Log "===================================================="
# ===========================================================================
# Local copy - written BEFORE the upload and OUTSIDE the token guard.
# The ODM custom action stdout is otherwise the only record of this run, so if
# the PAT is dead or the network blips this file is the evidence you collect
# off the box. Never let a reporting failure destroy the report.
# ===========================================================================

try {
    $localLogDir  = Join-Path $env:ProgramData 'Marco\ODMAD'
    $localLogPath = Join-Path $localLogDir "Repair-BitLocker_${env:COMPUTERNAME}_${runTimestamp}.txt"
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
        $logFileName = "logs/Repair-BitLocker_${env:COMPUTERNAME}_${runTimestamp}.txt"
        $apiUrl      = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/$logFileName"
        $encoded     = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($logBuffer.ToString()))
        $headers = @{
            'Authorization'        = "Bearer $GitHubToken"
            'Accept'               = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent'           = 'Marco-ODMAD-Toolkit'
        }
        $body = @{
            message = "BitLocker repair: $env:COMPUTERNAME ($runTimestamp) Tenant=$tenantName"
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

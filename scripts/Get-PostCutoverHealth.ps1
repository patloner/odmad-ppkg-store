#Requires -Version 5.1
<#
.SYNOPSIS
    Quest ODMAD Custom Action - Post-cutover health check for Domain-to-Entra cutovers.
    Reports PASS / WARN / FAIL per check and optionally uploads the log to GitHub.

.DESCRIPTION
    Assumes the Quest ODMAD cutover has COMPLETED and the device has rebooted into
    its Entra-joined state. Checks for red flags that indicate a degraded or incomplete
    cutover before you close out for the night.

    Grounded in Quest On Demand Migration Active Directory (ODMAD) documentation:
      - Entra-Joined Devices Quick Start Guide (TOPIC-2311203: Validating your Device)
      - Entra-Joined Devices QSG FAQ (black screen / IdentityStore, Autopilot flap)
      - KB 4377117 (CloudDomainJoin registry set), KB 4377957 / 4377470 (registered vs joined)
      - Intune, Autopilot, and BitLocker Cleanup Quick Start Guide

    Checks and verdicts:
      FAIL  AzureAdJoined != YES        -- join did not complete (Quest QSG step 1)
      FAIL  Still domain-joined         -- domain leave incomplete after cutover
      FAIL  MmpcEnrollmentFlag = 2      -- known root cause for 0x80190190
      FAIL  BitLocker: no recovery key  -- encrypted with no RecoveryPassword protector (skipped if $IntuneManagesBitLocker)
      WARN  Hybrid residue              -- AzureAdJoined=YES but still PartOfDomain (WMI)
      WARN  Domain name in WMI          -- Win32_ComputerSystem still shows a domain
      WARN  GPO tattoo orphan           -- on-prem GPO history present but not domain-joined
      WARN  Stale device certificate    -- MS-Organization-Access for wrong deviceId
      WARN  Residual MAM enrollment     -- EnrollmentType=5 still present (should be cleared)
      WARN  Profile .bak SID            -- duplicate profile SID in ProfileList
      WARN  IdentityStore cache         -- source-tenant identity cache (black screen risk)
      WARN  Autopilot conflict          -- Autopilot profile assigned to a different tenant
      WARN  BitLocker suspended         -- protection disabled on OS volume
      WARN  BitLocker escrow pending    -- BackupBitlockerKeyToADD evidence not confirmed
      WARN  Connectivity                -- login.microsoftonline.com:443 unreachable
      WARN  Clock skew                  -- local time differs from NTP by more than 5 min
      PASS  Everything else             -- check completed cleanly

    Runs as SYSTEM via Quest ODM custom action AFTER the Entra cutover reboot.
    Always exits 0 -- this check must never abort a subsequent ODM step.

    When $GitHubToken is set, the log is uploaded to odmad-ppkg-store/logs/ as:
        PostCutoverHealth_<ComputerName>_<timestamp>.txt

.NOTES
    Marco Technologies - Migration Engineering
    Paste into Quest ODM -> Custom Actions -> PowerShell.
    Set this action to run AFTER the Entra cutover / device reboot step.
    Exit 0 = ODM proceeds. This script is READ-ONLY and does not modify any state.

    References:
      Quest ODMAD Entra-Joined Devices Quick Start Guide (TOPIC-2311203)
      Quest ODMAD Entra-Joined Devices QSG FAQ (TOPIC-1883733)
      Quest ODMAD Intune, Autopilot and BitLocker Cleanup Quick Start Guide
      Get-CutoverState collectors (Get-AadJoinState, Get-DomainLeaveResidue,
        Get-StaleTenantRefs, Get-BitLockerState, Get-WamTokenState)
#>

# ===========================================================================
# CONFIG - values injected by the ODM bootstrap at runtime via environment variables.
# When run standalone (not via bootstrap), set the env vars before running or
# edit the fallback values below.
#   $env:ODMAD_GH_TOKEN         = 'ghp_...'   # PAT with contents:write on odmad-ppkg-store
#   $env:ODMAD_INTUNE_BITLOCKER = 'true'       # set if client has Intune BitLocker config profile
# ===========================================================================
$GitHubToken = if ($env:ODMAD_GH_TOKEN) { $env:ODMAD_GH_TOKEN } else { '' }
$RepoOwner   = 'patloner'
$RepoName    = 'odmad-ppkg-store'
$Branch      = 'main'
$IntuneManagesBitLocker = ($env:ODMAD_INTUNE_BITLOCKER -eq 'true')
# ===========================================================================

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

$logBuffer    = [System.Text.StringBuilder]::new()
$runTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

function Write-Log {
    param([string]$Message)
    Write-Output $Message
    [void]$logBuffer.AppendLine($Message)
}

# ---------------------------------------------------------------------------
# Check result tracking
# ---------------------------------------------------------------------------

$checkResults = [System.Collections.Generic.List[object]]::new()
$passCount    = 0
$warnCount    = 0
$failCount    = 0

function Add-CheckResult {
    param(
        [string]$Name,
        [string]$Verdict,    # PASS, WARN, FAIL
        [string]$Detail,
        [string]$Action = ''
    )
    $checkResults.Add([PSCustomObject]@{
        Name    = $Name
        Verdict = $Verdict
        Detail  = $Detail
        Action  = $Action
    })

    $symbol = switch ($Verdict) {
        'PASS' { '[PASS]' }
        'WARN' { '[WARN]' }
        'FAIL' { '[FAIL]' }
        default { '[???]' }
    }

    Write-Log ("  {0,-6} {1,-35} {2}" -f $symbol, $Name, $Detail)
    if ($Action -and $Verdict -ne 'PASS') {
        Write-Log ("         {0,-35}  -> {1}" -f '', $Action)
    }

    switch ($Verdict) {
        'PASS' { $script:passCount++ }
        'WARN' { $script:warnCount++ }
        'FAIL' { $script:failCount++ }
    }
}

# ---------------------------------------------------------------------------
# Registry helper (from Get-AadJoinState pattern)
# ---------------------------------------------------------------------------

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $p = Get-ItemProperty -Path $Path -ErrorAction Stop
        if ($p -and ($p.PSObject.Properties.Name -contains $Name)) { return $p.$Name }
    } catch { }
    return $null
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

Write-Log "===================================================================="
Write-Log " Get-PostCutoverHealth - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log " Host: $env:COMPUTERNAME"
Write-Log " Quest ODMAD Post-Cutover Health Check (Domain->Entra)"
Write-Log " Reference: Quest ODMAD Entra-Joined Devices QSG TOPIC-2311203"
Write-Log "===================================================================="
Write-Log ""

# ===========================================================================
# CHECK GROUP 1: Entra Join State  (Quest QSG step 1 - primary verification)
# Reference: ODMAD Entra-Joined Devices Quick Start Guide TOPIC-2311203
# Source: dsregcmd /status + Win32_ComputerSystem
# ===========================================================================

Write-Log "[1/6] Entra Join State"
Write-Log "      (Quest ODMAD QSG TOPIC-2311203: Verify device is Microsoft Entra ID Joined)"
Write-Log ""

$kv = @{}
try {
    $dsreg = & dsregcmd.exe /status 2>$null
    if ($dsreg) {
        foreach ($line in $dsreg) {
            if ($line -match '^\s*([A-Za-z0-9_]+)\s*:\s*(.+?)\s*$') {
                $kv[$matches[1]] = $matches[2].Trim()
            }
        }
    }
} catch { }

function Get-Kv { param([string]$Key) if ($kv.ContainsKey($Key)) { return $kv[$Key] } else { return 'unknown' } }

$aadJoined    = Get-Kv 'AzureAdJoined'
$domJoined    = Get-Kv 'DomainJoined'
$tenantName   = Get-Kv 'TenantName'
$tenantId     = Get-Kv 'TenantId'
$deviceId     = Get-Kv 'DeviceId'
$azureAdPrt   = Get-Kv 'AzureAdPrt'
$wamDefaultSet = Get-Kv 'WamDefaultSet'

# Entra join: must be YES (Quest QSG primary validation step)
if ($aadJoined -eq 'YES') {
    Add-CheckResult -Name 'AzureAdJoined' -Verdict 'PASS' `
        -Detail "AzureAdJoined=YES  TenantName=$tenantName"
} elseif ($aadJoined -eq 'NO') {
    Add-CheckResult -Name 'AzureAdJoined' -Verdict 'FAIL' `
        -Detail "AzureAdJoined=NO - cutover did not complete the Entra join." `
        -Action "Verify reboot occurred. Check ODM task log for 0x8018000A/0xCAA2000C/0x801c001d. Run Get-CutoverState.ps1 for full diagnostics."
} else {
    Add-CheckResult -Name 'AzureAdJoined' -Verdict 'WARN' `
        -Detail "AzureAdJoined=$aadJoined (dsregcmd returned unexpected value)" `
        -Action "Re-run dsregcmd /status manually to confirm join state."
}

# Domain leave: should be NO post-cutover
if ($domJoined -eq 'NO') {
    Add-CheckResult -Name 'DomainJoined' -Verdict 'PASS' -Detail "DomainJoined=NO - domain leave complete."
} elseif ($domJoined -eq 'YES' -and $aadJoined -eq 'YES') {
    Add-CheckResult -Name 'DomainJoined' -Verdict 'FAIL' `
        -Detail "DomainJoined=YES AND AzureAdJoined=YES - hybrid residue, domain leave did not complete." `
        -Action "Domain leave did not complete. Contact Quest support; manual unjoin from domain may be required. See Get-DomainLeaveResidue collector."
} elseif ($domJoined -eq 'YES' -and $aadJoined -eq 'NO') {
    Add-CheckResult -Name 'DomainJoined' -Verdict 'FAIL' `
        -Detail "DomainJoined=YES AND AzureAdJoined=NO - machine is still domain-joined; cutover did not execute." `
        -Action "ODMAD cutover did not process. Verify the ODM task completed, agent is online, and retry the cutover."
} else {
    Add-CheckResult -Name 'DomainJoined' -Verdict 'WARN' `
        -Detail "DomainJoined=$domJoined (unexpected value from dsregcmd)" `
        -Action "Re-run dsregcmd /status manually to confirm."
}

# WMI domain membership check (cross-reference dsregcmd - Win32_ComputerSystem is authoritative)
$partOfDomain = $false
$wmiDomain    = ''
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $partOfDomain = [bool]$cs.PartOfDomain
    $wmiDomain    = "$($cs.Domain)"
} catch {
    try {
        $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
        $partOfDomain = [bool]$cs.PartOfDomain
        $wmiDomain    = "$($cs.Domain)"
    } catch { }
}

if ($partOfDomain) {
    Add-CheckResult -Name 'WMI-DomainMembership' -Verdict 'WARN' `
        -Detail "Win32_ComputerSystem.PartOfDomain=True, Domain=$wmiDomain" `
        -Action "WMI still shows domain membership. If dsregcmd shows DomainJoined=NO this may be stale WMI cache; reboot and re-check. If both show domain-joined, domain leave is incomplete."
} else {
    Add-CheckResult -Name 'WMI-DomainMembership' -Verdict 'PASS' -Detail "Win32_ComputerSystem.PartOfDomain=False"
}

Write-Log ""

# ===========================================================================
# CHECK GROUP 2: Enrollment State and Residual Artifacts
# Reference: Get-AadJoinState collector, MmpcEnrollmentFlag KB root cause
# ===========================================================================

Write-Log "[2/6] Enrollment State and Residual Artifacts"
Write-Log ""

# MmpcEnrollmentFlag: 2 = known blocker (0x80190190). Should be absent or 0 post-cutover.
$enrollRoot   = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
$mmpcFlag     = Get-RegValue -Path $enrollRoot -Name 'MmpcEnrollmentFlag'
if ($null -eq $mmpcFlag) {
    try {
        foreach ($sk in @(Get-ChildItem -Path $enrollRoot -ErrorAction SilentlyContinue)) {
            $v = Get-RegValue -Path $sk.PSPath -Name 'MmpcEnrollmentFlag'
            if ($null -ne $v) { $mmpcFlag = $v; break }
        }
    } catch { }
}
if ($mmpcFlag -eq 2) {
    Add-CheckResult -Name 'MmpcEnrollmentFlag' -Verdict 'FAIL' `
        -Detail "MmpcEnrollmentFlag=2 - known root cause for 0x80190190 join failure." `
        -Action "Clear flag: Remove-ItemProperty HKLM:\SOFTWARE\Microsoft\Enrollments -Name MmpcEnrollmentFlag. Or run Reset-Entra.ps1 and retry join."
} elseif ($null -ne $mmpcFlag -and $mmpcFlag -ne 0) {
    Add-CheckResult -Name 'MmpcEnrollmentFlag' -Verdict 'WARN' `
        -Detail "MmpcEnrollmentFlag=$mmpcFlag (non-standard value, expected absent/0)" `
        -Action "Investigate this value before the next cutover attempt."
} else {
    Add-CheckResult -Name 'MmpcEnrollmentFlag' -Verdict 'PASS' `
        -Detail "MmpcEnrollmentFlag absent or 0 - no 0x80190190 blocker."
}

# Residual MAM enrollments (should have been cleared by Remove-ConflictingEnrollments)
$mamCount = 0
if (Test-Path $enrollRoot) {
    try {
        foreach ($sk in @(Get-ChildItem -Path $enrollRoot -ErrorAction SilentlyContinue)) {
            $etype = Get-RegValue -Path $sk.PSPath -Name 'EnrollmentType'
            $prov  = Get-RegValue -Path $sk.PSPath -Name 'ProviderID'
            if ($etype -eq 5 -or $prov -eq 'MAM SyncML Server') { $mamCount++ }
        }
    } catch { }
}
if ($mamCount -eq 0) {
    Add-CheckResult -Name 'MAM-Enrollments' -Verdict 'PASS' -Detail "No residual MAM enrollments found."
} else {
    Add-CheckResult -Name 'MAM-Enrollments' -Verdict 'WARN' `
        -Detail "Found $mamCount MAM enrollment(s) still present (EnrollmentType=5)." `
        -Action "MAM enrollments should have been removed by Remove-ConflictingEnrollments pre-flight. Remove manually from HKLM:\SOFTWARE\Microsoft\Enrollments."
}

Write-Log ""

# ===========================================================================
# CHECK GROUP 3: Domain Leave Residue
# Reference: Get-DomainLeaveResidue collector, Quest ODMAD cleanup guidance
# ===========================================================================

Write-Log "[3/6] Domain Leave Residue"
Write-Log ""

# GPO tattoo check: on-prem GPO history present but device no longer domain-joined
$gpoHistoryRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\History'
$gpoCount       = 0
$gpoDomains     = [System.Collections.Generic.List[string]]::new()

if (-not $partOfDomain -and (Test-Path $gpoHistoryRoot)) {
    try {
        foreach ($k in @(Get-ChildItem -Path $gpoHistoryRoot -Recurse -ErrorAction SilentlyContinue)) {
            $ds = Get-RegValue -Path $k.PSPath -Name 'DSPath'
            $fs = Get-RegValue -Path $k.PSPath -Name 'FileSysPath'
            if ($ds -or $fs) {
                $gpoCount++
                $dom = ''
                if ($ds -and ("$ds" -match '((?:DC=[^,]+,?)+)')) {
                    $parts = ($matches[1] -split ',') | Where-Object { $_ -match '^DC=' }
                    $dom = ($parts | ForEach-Object { $_ -replace '^DC=','' }) -join '.'
                } elseif ($fs -and ("$fs" -match '^\\\\([^\\]+)\\')) {
                    $dom = $matches[1]
                }
                if ($dom -and -not $gpoDomains.Contains($dom)) { [void]$gpoDomains.Add($dom) }
            }
        }
    } catch { }
}

$domainLabel = if ($gpoDomains.Count -gt 0) { ($gpoDomains -join ', ') } else { '' }

if (-not $partOfDomain -and $gpoCount -gt 0) {
    Add-CheckResult -Name 'GPO-Tattoo-Orphan' -Verdict 'WARN' `
        -Detail "On-prem GPO settings tattooed from $domainLabel ($gpoCount polic(ies)) - no longer updating." `
        -Action "Stale GPO registry settings persist. Baseline via Intune/Autopilot policy or clean manually. No immediate blocker but may cause configuration drift."
} elseif ($partOfDomain) {
    Add-CheckResult -Name 'GPO-Tattoo-Orphan' -Verdict 'WARN' `
        -Detail "Still domain-joined - GPO tattoo check deferred (domain leave must complete first)." `
        -Action "Re-run this check after the domain leave is complete."
} else {
    Add-CheckResult -Name 'GPO-Tattoo-Orphan' -Verdict 'PASS' -Detail "No orphaned GPO tattoo (no GPO history or still domain-managed)."
}

# OnPremTgt / CloudTgt from dsregcmd (Entra Kerberos state)
$onPremTgt = Get-Kv 'OnPremTgt'
$cloudTgt  = Get-Kv 'CloudTgt'
if ($onPremTgt -ne 'unknown' -or $cloudTgt -ne 'unknown') {
    Add-CheckResult -Name 'Entra-Kerberos' -Verdict 'PASS' `
        -Detail "OnPremTgt=$onPremTgt  CloudTgt=$cloudTgt (informational)"
}

Write-Log ""

# ===========================================================================
# CHECK GROUP 4: Stale Identity Artifacts
# Reference: Get-StaleTenantRefs, Get-IdentityProfile, Quest QSG FAQ (black screen)
# Quest ODMAD QSG FAQ TOPIC-2293745: black screen after cutover = IdentityStore cache
# ===========================================================================

Write-Log "[4/6] Stale Identity Artifacts"
Write-Log ""

# Stale MS-Organization-Access device certificate (deviceId mismatch)
$staleCertCount = 0
if ($deviceId -ne 'unknown' -and $deviceId -ne '') {
    try {
        foreach ($c in @(Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue)) {
            if ("$($c.Issuer)" -match 'MS-Organization-Access') {
                $cn = ''
                if ("$($c.Subject)" -match 'CN=([0-9a-fA-F\-]{36})') { $cn = $matches[1] }
                if ($cn -ne '' -and $cn -ine $deviceId) { $staleCertCount++ }
            }
        }
    } catch { }
}
if ($staleCertCount -gt 0) {
    Add-CheckResult -Name 'Stale-Device-Cert' -Verdict 'WARN' `
        -Detail "$staleCertCount MS-Organization-Access cert(s) with non-matching deviceId found." `
        -Action "Remove stale cert(s) from Cert:\LocalMachine\My (keep the one with CN=$deviceId). May appear in Quest Intune/BitLocker Cleanup QSG cleanup phase."
} elseif ($deviceId -eq 'unknown' -or $deviceId -eq '') {
    Add-CheckResult -Name 'Stale-Device-Cert' -Verdict 'WARN' `
        -Detail "Cannot check - DeviceId unknown from dsregcmd (AzureAdJoined may be NO)." `
        -Action "Resolve the join state first, then re-check certificates."
} else {
    Add-CheckResult -Name 'Stale-Device-Cert' -Verdict 'PASS' -Detail "No stale MS-Organization-Access certificates found."
}

# IdentityStore cache - only flag SIDs from foreign domains/machines
# Quest ODMAD Entra-Joined Devices QSG FAQ TOPIC-2293745: black screen on first logon
# after cutover is caused by source-domain user SIDs in the cache, not SYSTEM entries.
# SYSTEM (S-1-5-18) and other well-known SIDs rebuild immediately after the cache is cleared
# and are harmless. Only flag S-1-5-21-* SIDs that belong to a DIFFERENT machine/domain.
$idStoreRoot = 'HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache'
$staleCacheSids = [System.Collections.Generic.List[string]]::new()
$systemOnlySids = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')

# Determine local machine SID prefix to exclude local-account entries
$machineSidPrefix = $null
try {
    $localAcct = Get-WmiObject -Class Win32_UserAccount `
        -Filter "LocalAccount=True AND SID LIKE 'S-1-5-21-%'" `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($localAcct) {
        $machineSidPrefix = $localAcct.SID -replace '-\d+$', ''
    }
} catch { }

if (Test-Path $idStoreRoot) {
    try {
        foreach ($sk in @(Get-ChildItem -Path $idStoreRoot -ErrorAction SilentlyContinue)) {
            $sid = $sk.PSChildName
            if ($systemOnlySids -contains $sid) { continue }
            if ($machineSidPrefix -and $sid.StartsWith($machineSidPrefix)) { continue }
            if ($sid -like 'S-1-5-21-*') {
                [void]$staleCacheSids.Add($sid)
            }
        }
    } catch { }
}

if ($staleCacheSids.Count -gt 0) {
    Add-CheckResult -Name 'IdentityStore-Cache' -Verdict 'WARN' `
        -Detail "Cache contains $($staleCacheSids.Count) foreign-domain SID(s): $($staleCacheSids -join ', '). Black screen risk on first target-user logon." `
        -Action "Per Quest ODMAD QSG TOPIC-2293745: run Repair-IdentityStoreCache.ps1 BEFORE the target user first logs in."
} else {
    Add-CheckResult -Name 'IdentityStore-Cache' -Verdict 'PASS' `
        -Detail "No foreign-domain SIDs in IdentityStore cache (SYSTEM entries are normal and harmless)."
}

# Profile .bak SID check (Quest QSG: verify profile is same as source user - TOPIC-2311203 step 3)
$profileListRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$bakSids         = [System.Collections.Generic.List[string]]::new()
$orphanProfiles  = [System.Collections.Generic.List[string]]::new()
if (Test-Path $profileListRoot) {
    try {
        foreach ($sk in @(Get-ChildItem -Path $profileListRoot -ErrorAction SilentlyContinue)) {
            $sid = $sk.PSChildName
            if ($sid -match '\.bak$') {
                [void]$bakSids.Add($sid)
            } else {
                $pip = Get-RegValue -Path $sk.PSPath -Name 'ProfileImagePath'
                if ($pip -and -not (Test-Path -LiteralPath "$pip")) {
                    [void]$orphanProfiles.Add($sid)
                }
            }
        }
    } catch { }
}

if ($bakSids.Count -gt 0) {
    Add-CheckResult -Name 'Profile-BakSid' -Verdict 'WARN' `
        -Detail "Found $($bakSids.Count) .bak SID(s) in ProfileList - profile was not cleanly remapped." `
        -Action "Quest ODMAD ReACL/DUA should remap the profile. If .bak persists, resolve manually: rename SID in ProfileList so the migrated user gets the correct profile."
} else {
    Add-CheckResult -Name 'Profile-BakSid' -Verdict 'PASS' -Detail "No .bak SIDs in ProfileList."
}

if ($orphanProfiles.Count -gt 0) {
    Add-CheckResult -Name 'Profile-Orphan' -Verdict 'WARN' `
        -Detail "Found $($orphanProfiles.Count) ProfileList entry(ies) with no matching folder on disk." `
        -Action "Stale profile registration. Verify the profile path; clean up the orphan if stale."
} else {
    Add-CheckResult -Name 'Profile-Orphan' -Verdict 'PASS' -Detail "No orphaned ProfileList entries."
}

# Autopilot preload flap check (Quest QSG FAQ: device joined then removed)
# Quest: if a pre-staged Autopilot profile points to a DIFFERENT tenant, it flaps the join (0x801c03f2)
$apAssignedTenant = ''
$apCacheFiles = @(
    (Join-Path $env:WINDIR 'ServiceState\wmansvc\AutopilotDDSZTDFile.json'),
    (Join-Path $env:WINDIR 'Provisioning\Autopilot\AutopilotDDSZTDFile.json')
)
foreach ($f in $apCacheFiles) {
    if (Test-Path -LiteralPath $f) {
        try {
            $j = (Get-Content -LiteralPath $f -Raw -ErrorAction Stop) | ConvertFrom-Json
            $jt = $null
            if ($j.PSObject.Properties.Name -contains 'CloudAssignedTenantId') { $jt = $j.CloudAssignedTenantId }
            elseif ($j.PSObject.Properties.Name -contains 'CloudAssignedTenantDomain') { $jt = $j.CloudAssignedTenantDomain }
            if ($jt) { $apAssignedTenant = "$jt"; break }
        } catch { }
    }
}

if ($apAssignedTenant -ne '') {
    $apMatch = ($tenantId -ne 'unknown' -and $tenantId -ne '' -and ($apAssignedTenant -ieq $tenantId -or $apAssignedTenant -ieq $tenantName))
    if ($apMatch) {
        Add-CheckResult -Name 'Autopilot-Cache' -Verdict 'PASS' `
            -Detail "Autopilot profile cached for the CURRENT tenant ($apAssignedTenant) - benign."
    } else {
        Add-CheckResult -Name 'Autopilot-Cache' -Verdict 'WARN' `
            -Detail "Autopilot profile cached for a DIFFERENT tenant ($apAssignedTenant) - 0x801c03f2 risk." `
            -Action "Per Quest: delete ODMAD-Cutover-tagged device object in Entra before any re-join attempt. Never pre-stage target Autopilot hashes on in-place Quest cutovers."
    }
} else {
    Add-CheckResult -Name 'Autopilot-Cache' -Verdict 'PASS' -Detail "No assigned Autopilot profile cached."
}

Write-Log ""

# ===========================================================================
# CHECK GROUP 5: BitLocker
# Reference: Quest ODMAD Intune, Autopilot and BitLocker Cleanup Quick Start Guide
# Get-BitLockerState collector: OsVolumeRisk, EscrowEvidence
# ===========================================================================

Write-Log "[5/6] BitLocker State"
if ($IntuneManagesBitLocker) {
    Write-Log "  [INFO] IntuneManagesBitLocker=true - BitLocker checks suppressed."
    Write-Log "         Intune configuration profile will handle resume, key protectors,"
    Write-Log "         and escrow via MDM channel. Verify in Entra portal after first sync."
    Add-CheckResult -Name 'BitLocker-Intune' -Verdict 'PASS' `
        -Detail "Intune manages BitLocker for this engagement. Policy will apply on next MDM sync." `
        -Action "Verify escrow in Entra portal: Devices -> machine -> BitLocker keys tab after sync."
} else {
Write-Log ""

$blStatus       = 'unknown'
$blProtectors   = @()
$hasRecoveryPw  = $false
$blSuspended    = $false

# Try Get-BitLockerVolume (available on Win10/11 with BitLocker feature, PS5.1+)
try {
    $blVol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    $blStatus = "$($blVol.VolumeStatus)"
    $blSuspended = ($blVol.ProtectionStatus -eq 'Off')
    $blProtectors = @($blVol.KeyProtector)
    $hasRecoveryPw = ($blProtectors | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }).Count -gt 0
} catch {
    # Fallback: manage-bde status parsing
    try {
        $mbde = & manage-bde.exe -status $env:SystemDrive 2>$null
        if ($mbde) {
            $blStatus = ($mbde | Where-Object { $_ -match 'Conversion Status' } | Select-Object -First 1)
            $blStatus = if ($blStatus) { ($blStatus -replace '.*:\s*','').Trim() } else { 'unknown' }
            $isSuspended = ($mbde | Where-Object { $_ -match 'Protection\s+Status.*Off' }).Count -gt 0
            $blSuspended = $isSuspended
            $hasRecoveryPw = ($mbde | Where-Object { $_ -match 'Numerical Password' }).Count -gt 0
        }
    } catch { }
}

$isEncrypted = $blStatus -match 'FullyEncrypted|EncryptionInProgress|EncryptedWithXtsAes'

if (-not $isEncrypted -and $blStatus -ne 'unknown') {
    Add-CheckResult -Name 'BitLocker-Encrypted' -Verdict 'PASS' `
        -Detail "OS volume not encrypted ($blStatus) - no BitLocker escrow required."
} elseif ($blStatus -eq 'unknown') {
    Add-CheckResult -Name 'BitLocker-Encrypted' -Verdict 'WARN' `
        -Detail "Could not determine BitLocker status (manage-bde and Get-BitLockerVolume unavailable)." `
        -Action "Verify BitLocker status manually: manage-bde -status C:"
} elseif ($isEncrypted -and -not $hasRecoveryPw) {
    Add-CheckResult -Name 'BitLocker-NoRecoveryKey' -Verdict 'FAIL' `
        -Detail "OS volume ENCRYPTED with NO RecoveryPassword protector - lockout risk." `
        -Action "Add a recovery password: manage-bde -protectors -add -RecoveryPassword $env:SystemDrive, then escrow to Entra: BackupToAAD-BitLockerKeyProtector."
} else {
    Add-CheckResult -Name 'BitLocker-Encrypted' -Verdict 'PASS' `
        -Detail "OS volume encrypted with RecoveryPassword protector present."
}

if ($isEncrypted -and $blSuspended) {
    Add-CheckResult -Name 'BitLocker-Suspended' -Verdict 'WARN' `
        -Detail "BitLocker protection is suspended (off) on the OS volume." `
        -Action "Resume protection: manage-bde -protectors -enable $env:SystemDrive. May occur if Intune device object was deleted during cutover."
}

# BitLocker escrow evidence: Quest BackupBitlockerKeyToADD log + BitlockerBackupToEntraID scheduled task
$escrowLogPath  = "$env:WINDIR\Logs\BackupBitlockerKeyToADD.log"
$escrowTaskName = 'BitlockerBackupToEntraID'
$escrowEvidence = 'no-evidence'

if (Test-Path -LiteralPath $escrowLogPath) {
    try {
        $logLines = @(Get-Content -LiteralPath $escrowLogPath -ErrorAction Stop | Select-Object -Last 20)
        if ($logLines | Where-Object { $_ -match 'Success|succeeded|backed up|complete' }) {
            $escrowEvidence = 'confirmed'
        } elseif ($logLines | Where-Object { $_ -match 'fail|error|0x' }) {
            $escrowEvidence = 'failed'
        } else {
            $escrowEvidence = 'log-present'
        }
    } catch { }
}

$taskPresent = $false
try {
    $taskPresent = ($null -ne (Get-ScheduledTask -TaskName $escrowTaskName -ErrorAction Stop))
} catch { }

if ($taskPresent -and $escrowEvidence -ne 'confirmed') {
    $escrowEvidence = 'pending'
}

if ($isEncrypted) {
    switch ($escrowEvidence) {
        'confirmed' {
            Add-CheckResult -Name 'BitLocker-Escrow' -Verdict 'PASS' `
                -Detail "BitLocker key escrow to Entra confirmed (BackupBitlockerKeyToADD.log shows success)."
        }
        'failed' {
            Add-CheckResult -Name 'BitLocker-Escrow' -Verdict 'FAIL' `
                -Detail "BitLocker escrow log shows FAILURE - recovery key may not be in the target Entra tenant." `
                -Action "Re-trigger escrow at next user logon, or escrow manually: BackupToAAD-BitLockerKeyProtector."
        }
        'pending' {
            Add-CheckResult -Name 'BitLocker-Escrow' -Verdict 'WARN' `
                -Detail "BitlockerBackupToEntraID scheduled task still present - escrow pending first target-user logon." `
                -Action "Have the target user log in to trigger the escrow task. Confirm it self-cleans after success."
        }
        'no-evidence' {
            Add-CheckResult -Name 'BitLocker-Escrow' -Verdict 'WARN' `
                -Detail "No escrow log or task found. Cannot confirm key was escrowed to the target Entra tenant." `
                -Action "Verify recovery key exists on the device object in the TARGET Entra portal. If absent, escrow manually."
        }
        default {
            Add-CheckResult -Name 'BitLocker-Escrow' -Verdict 'WARN' `
                -Detail "Escrow log present but result indeterminate ($escrowEvidence)." `
                -Action "Check $escrowLogPath manually to confirm success or failure."
        }
    }
}

} # end if -not $IntuneManagesBitLocker

Write-Log ""

# ===========================================================================
# CHECK GROUP 6: Network and Clock
# Reference: Get-Connectivity collector - endpoints required for Entra auth
# ===========================================================================

Write-Log "[6/6] Network and Clock"
Write-Log ""

# Connectivity: login.microsoftonline.com:443 must be reachable post-join
$loginEndpoint   = 'login.microsoftonline.com'
$loginReachable  = $false
try {
    $tcp = [System.Net.Sockets.TcpClient]::new()
    $ar  = $tcp.BeginConnect($loginEndpoint, 443, $null, $null)
    $ok  = $ar.AsyncWaitHandle.WaitOne(3000, $false)
    if ($ok -and $tcp.Connected) { $loginReachable = $true }
    $tcp.Close()
} catch { }

if ($loginReachable) {
    Add-CheckResult -Name 'Connectivity-Login' -Verdict 'PASS' `
        -Detail "login.microsoftonline.com:443 reachable."
} else {
    Add-CheckResult -Name 'Connectivity-Login' -Verdict 'WARN' `
        -Detail "login.microsoftonline.com:443 NOT reachable within 3 seconds." `
        -Action "Check network/proxy/firewall. Device cannot authenticate to Entra without this endpoint. May explain a failed PRT or sign-in failure on first logon."
}

# Clock skew: >300 seconds (5 min) breaks Kerberos and token validation
$skewSeconds = $null
try {
    $w32 = & w32tm.exe /query /status 2>$null
    if ($w32) {
        $offsetLine = $w32 | Where-Object { $_ -match '^Last Successful.*:|^Source:|Offset' } | Select-Object -Last 1
        if ($offsetLine -and $offsetLine -match '([-+]?\d+[\.,]\d+)s') {
            $skewSeconds = [Math]::Abs([double]($matches[1] -replace ',', '.'))
        }
    }
} catch { }

if ($null -eq $skewSeconds) {
    Add-CheckResult -Name 'Clock-Skew' -Verdict 'PASS' `
        -Detail "Clock skew check inconclusive (w32tm output not parseable) - informational."
} elseif ($skewSeconds -gt 300) {
    Add-CheckResult -Name 'Clock-Skew' -Verdict 'WARN' `
        -Detail "Clock skew is approximately $([Math]::Round($skewSeconds,1)) seconds (>300s threshold)." `
        -Action "Resync time: w32tm /resync /force. Excessive skew breaks token validation and Kerberos auth."
} else {
    Add-CheckResult -Name 'Clock-Skew' -Verdict 'PASS' `
        -Detail "Clock skew approximately $([Math]::Round($skewSeconds,1)) seconds (within 5-minute threshold)."
}

Write-Log ""

# ===========================================================================
# Summary
# ===========================================================================

Write-Log "===================================================================="
Write-Log " SUMMARY  Host: $env:COMPUTERNAME"
Write-Log " $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log ""

$totalChecks = $passCount + $warnCount + $failCount
Write-Log ("  PASS: {0,3}   WARN: {1,3}   FAIL: {2,3}   Total: {3,3}" -f $passCount, $warnCount, $failCount, $totalChecks)
Write-Log ""

if ($failCount -gt 0) {
    Write-Log " OVERALL: ACTION REQUIRED - $failCount check(s) need resolution before closing out."
    $checkResults | Where-Object { $_.Verdict -eq 'FAIL' } | ForEach-Object {
        Write-Log "   FAIL -> $($_.Name): $($_.Detail)"
        if ($_.Action) { Write-Log "           -> $($_.Action)" }
    }
} elseif ($warnCount -gt 0) {
    Write-Log " OVERALL: REVIEW RECOMMENDED - $warnCount warning(s) flagged for follow-up."
} else {
    Write-Log " OVERALL: CLEAN - No issues detected. Cutover appears healthy."
}

Write-Log ""
Write-Log " Entra Join State  : AzureAdJoined=$aadJoined  DomainJoined=$domJoined"
Write-Log " Target Tenant     : $tenantName ($tenantId)"
Write-Log " DeviceId (Entra)  : $deviceId"
Write-Log ""
Write-Log " Reference: Quest ODMAD Entra-Joined Devices QSG TOPIC-2311203"
Write-Log " For full diagnostics on failed machines: run Get-CutoverState.ps1 (SinceHours 12)"
Write-Log "===================================================================="

# ===========================================================================
# GitHub log upload
# ===========================================================================

if ($GitHubToken) {
    Write-Output ""
    Write-Output "Uploading log to $RepoOwner/$RepoName/logs/ ..."

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $logFileName = "logs/PostCutoverHealth_${env:COMPUTERNAME}_${runTimestamp}.txt"
        $apiUrl      = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/$logFileName"
        $encoded     = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($logBuffer.ToString()))

        $headers = @{
            'Authorization'        = "Bearer $GitHubToken"
            'Accept'               = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent'           = 'Marco-ODMAD-Toolkit'
        }

        $body = @{
            message = "Post-cutover health: $env:COMPUTERNAME ($runTimestamp) PASS=$passCount WARN=$warnCount FAIL=$failCount"
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
        Write-Output "LOG UPLOAD FAILED: $($_.Exception.Message)"
        Write-Output "(Check token or network - ODM task log still captures the output above.)"
    }
} else {
    Write-Output ""
    Write-Output "(Log upload skipped - set GitHubToken in config block to enable.)"
}

# Always exit 0 - this is a read-only health check and must not abort any subsequent ODM step.
exit 0

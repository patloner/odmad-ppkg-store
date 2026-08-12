#Requires -Version 5.1
<#
.SYNOPSIS
    Quest ODMAD Custom Action - Pre-cutover snapshot and readiness checks.
    Runs FIRST in the ODM sequence before any state is changed.
    Uploads results to GitHub for fleet-level review via Get-PreCutoverSummary.ps1.

.DESCRIPTION
    READ-ONLY snapshot of the machine's current state immediately before cutover.
    Serves two purposes:
      1. Readiness gate - flags blockers that will cause the cutover to fail
      2. Audit record - documents pre-cutover enrollment and join state

    Checks and verdicts:
      FAIL  Pending reboot detected      -- OS has a pending reboot; domain leave may behave
                                            unpredictably if a reboot is already queued
      FAIL  TPM not present/enabled      -- Entra device identity is TPM-backed; join will fail
      WARN  Disk space low (<2GB free)   -- May cause issues during domain leave or PPKG apply
      WARN  MAM enrollment present       -- Will be cleared by Remove-ConflictingEnrollments
      WARN  Workplace registration found -- Will be cleared by Remove-ConflictingEnrollments
      WARN  NGC folder has content       -- Will be cleared by Clear-NGC before join
      INFO  dsregcmd snapshot            -- Current join state for audit record
      INFO  Enrollment registry dump     -- Full enrollment details for audit record

    Always exits 0 - readiness failures are flagged but do not abort ODM.
    The engineer reviews Get-PreCutoverSummary.ps1 before proceeding.

    Upload path: odm-reports/logs/PreCutoverState_<ComputerName>_<timestamp>.txt

.NOTES
    Marco Technologies - Migration Engineering
    Paste Bootstrap-PreCutoverState.ps1 into Quest ODM (avoids character limit).
    Set this action to run FIRST - before Remove-ConflictingEnrollments, Clear-NGC, and ppkg download.
    Reference: Quest ODMAD Entra-Joined Devices Quick Start Guide (TOPIC-2311203)
#>

# ===========================================================================
# CONFIG - injected by bootstrap via environment variables.
#   $env:ODMAD_GH_TOKEN = 'ghp_...'   # PAT with contents:write on odm-reports
# ===========================================================================
$GitHubToken = if ($env:ODMAD_GH_TOKEN) { $env:ODMAD_GH_TOKEN } else { 'PASTE_PAT_HERE' }
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

$checkResults = [System.Collections.Generic.List[object]]::new()
$passCount    = 0
$warnCount    = 0
$failCount    = 0

function Add-CheckResult {
    param(
        [string]$Name,
        [string]$Verdict,
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
        'INFO' { '[INFO]' }
        default { '[????]' }
    }
    Write-Log ("  {0,-6} {1,-35} {2}" -f $symbol, $Name, $Detail)
    if ($Action -and $Verdict -ne 'PASS' -and $Verdict -ne 'INFO') {
        Write-Log ("         {0,-35}  -> {1}" -f '', $Action)
    }
    switch ($Verdict) {
        'PASS' { $script:passCount++ }
        'WARN' { $script:warnCount++ }
        'FAIL' { $script:failCount++ }
    }
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
Write-Log "===================================================================="
Write-Log " Get-PreCutoverState - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log " Host: $env:COMPUTERNAME"
Write-Log " Quest ODMAD Pre-Cutover Snapshot (Domain->Entra)"
Write-Log " READ-ONLY: no state is changed by this script"
Write-Log "===================================================================="
Write-Log ""

# ===========================================================================
# SECTION 1: dsregcmd snapshot (audit record)
# ===========================================================================
Write-Log "[1/5] Current Join State (dsregcmd snapshot)"
Write-Log ""

$kv = @{}
try {
    foreach ($line in @(& dsregcmd.exe /status 2>$null)) {
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*:\s*(.+?)\s*$') {
            $kv[$matches[1]] = $matches[2].Trim()
        }
    }
} catch { }

$keyFields = @('AzureAdJoined','EnterpriseJoined','DomainJoined','WorkplaceJoined',
               'AzureAdPrt','TenantName','TenantId','DeviceId','MdmUrl')
foreach ($f in $keyFields) {
    $v = if ($kv.ContainsKey($f)) { $kv[$f] } else { 'not present' }
    Write-Log ("  {0,-30} {1}" -f $f, $v)
}

$domJoined  = if ($kv.ContainsKey('DomainJoined'))  { $kv['DomainJoined'] }  else { 'unknown' }
$aadJoined  = if ($kv.ContainsKey('AzureAdJoined')) { $kv['AzureAdJoined'] } else { 'unknown' }
$tenantName = if ($kv.ContainsKey('TenantName'))    { $kv['TenantName'] }    else { 'unknown' }

Add-CheckResult -Name 'JoinState-Snapshot' -Verdict 'INFO' `
    -Detail "DomainJoined=$domJoined  AzureAdJoined=$aadJoined  Tenant=$tenantName"

Write-Log ""

# ===========================================================================
# SECTION 2: Enrollment registry scan
# ===========================================================================
Write-Log "[2/5] MDM Enrollment Registry"
Write-Log ""

$enrollRoot = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
$mamCount   = 0
$totalEnroll = 0

if (Test-Path $enrollRoot) {
    try {
        $enrollKeys = @(Get-ChildItem -Path $enrollRoot -ErrorAction SilentlyContinue)
        $totalEnroll = $enrollKeys.Count
        foreach ($key in $enrollKeys) {
            $props    = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            $etype    = $props.EnrollmentType
            $prov     = $props.ProviderID
            $upn      = $props.UPN
            $mdmUrl   = $props.MDMUrl
            $isMAM    = ($etype -eq 5 -or $prov -eq 'MAM SyncML Server')
            $typeLabel = if ($isMAM) { 'MAM' } elseif ($etype) { "Type=$etype" } else { 'unknown' }
            Write-Log ("  GUID: {0}" -f $key.PSChildName)
            if ($upn)    { Write-Log ("    UPN          : {0}" -f $upn) }
            if ($prov)   { Write-Log ("    ProviderID   : {0}" -f $prov) }
            if ($etype)  { Write-Log ("    Type         : {0} {1}" -f $etype, $(if ($isMAM) { '[MAM - will be cleared]' } else { '' })) }
            if ($mdmUrl) { Write-Log ("    MDMUrl       : {0}" -f $mdmUrl) }
            if ($isMAM) { $mamCount++ }
        }
    } catch {
        Write-Log "  Could not read enrollment registry: $_"
    }
} else {
    Write-Log "  Enrollments root key not present."
}

# WorkplaceJoin
$wpRoot   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WorkplaceJoin\JoinInfo'
$wpCount  = 0
if (Test-Path $wpRoot) {
    try {
        $wpKeys = @(Get-ChildItem -Path $wpRoot -ErrorAction SilentlyContinue)
        $wpCount = $wpKeys.Count
        foreach ($key in $wpKeys) {
            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            Write-Log ("  Workplace: {0}" -f $key.PSChildName)
            if ($props.UserEmail)  { Write-Log ("    UPN      : {0}" -f $props.UserEmail) }
            if ($props.TenantId)   { Write-Log ("    TenantId : {0}" -f $props.TenantId) }
        }
    } catch { }
}

Write-Log ""
if ($mamCount -gt 0) {
    Add-CheckResult -Name 'MAM-Enrollments' -Verdict 'WARN' `
        -Detail "Found $mamCount MAM enrollment(s) (EnrollmentType=5)." `
        -Action "Remove-ConflictingEnrollments Custom Action will clear these before the join."
} else {
    Add-CheckResult -Name 'MAM-Enrollments' -Verdict 'PASS' -Detail "No MAM enrollments found."
}
if ($wpCount -gt 0) {
    Add-CheckResult -Name 'Workplace-Registrations' -Verdict 'WARN' `
        -Detail "Found $wpCount Workplace registration(s)." `
        -Action "Remove-ConflictingEnrollments Custom Action will clear these before the join."
} else {
    Add-CheckResult -Name 'Workplace-Registrations' -Verdict 'PASS' -Detail "No Workplace registrations found."
}

Write-Log ""

# ===========================================================================
# SECTION 3: Pending reboot check
# ===========================================================================
Write-Log "[3/5] Pending Reboot"
Write-Log ""

$rebootReasons = [System.Collections.Generic.List[string]]::new()

$cbsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
if (Test-Path $cbsPath) { [void]$rebootReasons.Add('CBS RebootPending key present') }

$wuPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
if (Test-Path $wuPath) { [void]$rebootReasons.Add('Windows Update RebootRequired key present') }

$pfroPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
try {
    $pfro = Get-ItemProperty -Path $pfroPath -Name 'PendingFileRenameOperations' -ErrorAction Stop
    if ($pfro.PendingFileRenameOperations) { [void]$rebootReasons.Add('PendingFileRenameOperations set') }
} catch { }

$vuPath = 'HKLM:\SOFTWARE\Microsoft\Updates\UpdateExeVolatile'
try {
    $vu = Get-ItemProperty -Path $vuPath -Name 'Flags' -ErrorAction Stop
    if ($vu.Flags -ne 0) { [void]$rebootReasons.Add("UpdateExeVolatile Flags=$($vu.Flags)") }
} catch { }

if ($rebootReasons.Count -gt 0) {
    Write-Log ("  Pending reboot indicators: {0}" -f ($rebootReasons -join '; '))
    Add-CheckResult -Name 'Pending-Reboot' -Verdict 'FAIL' `
        -Detail "Pending reboot detected: $($rebootReasons -join '; ')" `
        -Action "Reboot the machine and allow it to complete before starting the cutover. A pending reboot can cause unpredictable domain-leave behavior."
} else {
    Write-Log "  No pending reboot indicators found."
    Add-CheckResult -Name 'Pending-Reboot' -Verdict 'PASS' -Detail "No pending reboot detected."
}

Write-Log ""

# ===========================================================================
# SECTION 4: Disk space
# ===========================================================================
Write-Log "[4/5] Disk Space"
Write-Log ""

$freeGB = $null
try {
    $disk = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
    $freeGB = [Math]::Round($disk.FreeSpace / 1GB, 1)
    $totalGB = [Math]::Round($disk.Size / 1GB, 1)
    Write-Log ("  C: drive: {0} GB free of {1} GB total" -f $freeGB, $totalGB)
} catch {
    Write-Log "  Could not query disk space: $_"
}

if ($null -eq $freeGB) {
    Add-CheckResult -Name 'Disk-Space' -Verdict 'WARN' `
        -Detail "Could not determine free disk space on C:." `
        -Action "Verify manually before proceeding."
} elseif ($freeGB -lt 1.0) {
    Add-CheckResult -Name 'Disk-Space' -Verdict 'FAIL' `
        -Detail "Only $freeGB GB free on C: - critically low." `
        -Action "Free at least 2GB before cutover. Delete temp files, run Disk Cleanup."
} elseif ($freeGB -lt 2.0) {
    Add-CheckResult -Name 'Disk-Space' -Verdict 'WARN' `
        -Detail "$freeGB GB free on C: (recommended: 2GB+)." `
        -Action "Consider freeing additional space before cutover to avoid issues during PPKG apply."
} else {
    Add-CheckResult -Name 'Disk-Space' -Verdict 'PASS' -Detail "$freeGB GB free on C:."
}

Write-Log ""

# ===========================================================================
# SECTION 5: TPM readiness
# ===========================================================================
Write-Log "[5/5] TPM Readiness"
Write-Log ""

$tpmPresent   = $false
$tpmEnabled   = $false
$tpmReady     = $false
$tpmActivated = $false
$tpmVersion   = 'unknown'

try {
    $tpm = Get-Tpm -ErrorAction Stop
    $tpmPresent   = [bool]$tpm.TpmPresent
    $tpmEnabled   = [bool]$tpm.TpmEnabled
    $tpmReady     = [bool]$tpm.TpmReady
    $tpmActivated = [bool]$tpm.TpmActivated
} catch {
    Write-Log "  Get-Tpm failed: $_"
}

# Try WMI for TPM version
try {
    $tpmWmi = Get-WmiObject -Namespace 'root\CIMV2\Security\MicrosoftTpm' `
        -Class 'Win32_Tpm' -ErrorAction Stop | Select-Object -First 1
    if ($tpmWmi -and $tpmWmi.SpecVersion) {
        $tpmVersion = $tpmWmi.SpecVersion.Split(',')[0].Trim()
    }
} catch { }

Write-Log ("  TpmPresent   : {0}" -f $tpmPresent)
Write-Log ("  TpmEnabled   : {0}" -f $tpmEnabled)
Write-Log ("  TpmReady     : {0}" -f $tpmReady)
Write-Log ("  TpmActivated : {0}" -f $tpmActivated)
Write-Log ("  SpecVersion  : {0}" -f $tpmVersion)

if (-not $tpmPresent) {
    Add-CheckResult -Name 'TPM-Readiness' -Verdict 'FAIL' `
        -Detail "TPM is not present. Entra device identity requires TPM. Join will fail." `
        -Action "Verify TPM in BIOS/UEFI. If this is a VM, enable vTPM. Contact hardware vendor if TPM is absent on a physical machine."
} elseif (-not $tpmEnabled) {
    Add-CheckResult -Name 'TPM-Readiness' -Verdict 'FAIL' `
        -Detail "TPM is present but NOT enabled (version: $tpmVersion)." `
        -Action "Enable TPM in BIOS/UEFI firmware settings before cutover."
} elseif (-not $tpmReady) {
    Add-CheckResult -Name 'TPM-Readiness' -Verdict 'WARN' `
        -Detail "TPM is present and enabled but not in Ready state (version: $tpmVersion)." `
        -Action "TPM may need to be initialized. Run tpm.msc and check for pending actions. Cutover may still succeed but watch for join errors."
} else {
    Add-CheckResult -Name 'TPM-Readiness' -Verdict 'PASS' `
        -Detail "TPM present, enabled, and ready (version: $tpmVersion)."
}

# NGC check (INFO only - will be cleared by Clear-NGC Custom Action)
$ngcPath       = 'C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\NGC'
$ngcHasContent = $false
if (Test-Path $ngcPath) {
    try {
        $ngcItems = @(Get-ChildItem -Path $ngcPath -Force -ErrorAction SilentlyContinue)
        $ngcHasContent = ($ngcItems.Count -gt 0)
    } catch { }
}

if ($ngcHasContent) {
    Add-CheckResult -Name 'NGC-Keys' -Verdict 'INFO' `
        -Detail "NGC folder has content (Windows Hello/PIN keys from source domain)." `
        -Action "Clear-NGC Custom Action will remove these before the Entra join."
} else {
    Add-CheckResult -Name 'NGC-Keys' -Verdict 'INFO' `
        -Detail "NGC folder is empty or not present. No action needed."
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
    Write-Log " OVERALL: HOLD - $failCount blocker(s) must be resolved before cutover."
    $checkResults | Where-Object { $_.Verdict -eq 'FAIL' } | ForEach-Object {
        Write-Log "   FAIL -> $($_.Name): $($_.Detail)"
        if ($_.Action) { Write-Log "           -> $($_.Action)" }
    }
} elseif ($warnCount -gt 0) {
    Write-Log " OVERALL: REVIEW - $warnCount warning(s). MAM/Workplace enrollments will be cleared"
    Write-Log "          automatically by Remove-ConflictingEnrollments. Review others before proceeding."
} else {
    Write-Log " OVERALL: READY - Machine is clear to proceed with cutover."
}
Write-Log ""
Write-Log " DomainJoined  : $domJoined"
Write-Log " AzureAdJoined : $aadJoined"
Write-Log " Tenant        : $tenantName"
Write-Log " Reference: Quest ODMAD Entra-Joined Devices QSG TOPIC-2311203"
Write-Log "===================================================================="
# ===========================================================================
# Local copy - written BEFORE the upload and OUTSIDE the token guard.
# The ODM custom action stdout is otherwise the only record of this run, so if
# the PAT is dead or the network blips this file is the evidence you collect
# off the box. Never let a reporting failure destroy the report.
# ===========================================================================

try {
    $localLogDir  = Join-Path $env:ProgramData 'Marco\ODMAD'
    $localLogPath = Join-Path $localLogDir "PreCutoverState_${env:COMPUTERNAME}_${runTimestamp}.txt"
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


# ===========================================================================
# GitHub log upload
# ===========================================================================
if ($GitHubToken) {
    Write-Output ""
    Write-Output "Uploading pre-cutover state to $RepoOwner/$RepoName/logs/ ..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $logFileName = "logs/PreCutoverState_${env:COMPUTERNAME}_${runTimestamp}.txt"
        $apiUrl      = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/$logFileName"
        $encoded     = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($logBuffer.ToString()))
        $headers = @{
            'Authorization'        = "Bearer $GitHubToken"
            'Accept'               = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent'           = 'Marco-ODMAD-Toolkit'
        }
        $body = @{
            message = "Pre-cutover: $env:COMPUTERNAME ($runTimestamp) PASS=$passCount WARN=$warnCount FAIL=$failCount"
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
    Write-Output "(Log upload skipped - set ODMAD_GH_TOKEN env var or GitHubToken to enable.)"
}

exit 0

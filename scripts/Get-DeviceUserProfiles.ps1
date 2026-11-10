#Requires -Version 5.1
<#
.SYNOPSIS
    ODMAD custom action (device side): inventory the REAL user profiles on this machine
    and upload the list to GitHub. Read-only on the device.

.DESCRIPTION
    ReACL results often show unresolved SIDs, and you sometimes need to see which
    profiles are really on a computer (e.g. no matching account in the mapping).
    This builds one row per profile from three sources and merges them:
      - ProfileList registry (SID, ProfileImagePath, State, and .bak entries)
      - Win32_UserProfile (LastUseTime, Loaded, Special)
      - Folders under %SystemDrive%\Users with NO ProfileList entry (FolderOnly)
    Columns: ComputerName, SID, SidKind (Entra/Domain/Local/System/Service/Other),
    EntraObjectId (decoded from S-1-12-1-* SIDs - matches the Entra user's object ID),
    Account (translated name, or UNRESOLVED), ProfilePath, FolderExists, FolderOwner,
    LastUseTime (WMI), NtuserLastWrite (more reliable than WMI on current Windows),
    Loaded, Special, RegState, BakEntry, Source.

    Writes a local copy FIRST to %ProgramData%\Marco\ODMAD\, then uploads to:
        <RepoOwner>/<RepoName> (private)  profiles/<Client>/<Computer>_<ts>.csv
    Kept separate from logs/ (summary readers parse logs/) and quest-logs/.

    Inputs (set by Bootstrap-OdmadAction.ps1):
      ODMAD_GH_TOKEN   PAT, contents:write on odm-reports ONLY (empty = local copy only)
      ODMAD_CLIENT     folder name under profiles/
    Always exits 0 so it never aborts an ODM sequence. Read the task output.
    Run as SYSTEM (ODM) or an elevated admin: non-elevated runs cannot read other users' NTUSER.DAT
    or protected profile folders, so NtuserLastWrite/FolderOwner come back blank and FolderExists
    shows AccessDenied for those rows. FolderOnly 'TEMP' = a temporary profile was used (failed load).

.NOTES
    Marco Technologies - Migration Engineering. Host in odmad-ppkg-store/scripts/ (public).
    Replaces the old copy-to-UNC-share profile listing script. Pure ASCII.
#>
# NO param()/[CmdletBinding()] block, by design: ODM invokes custom actions with its own named
# arguments (-Device_DN ...), and a param block makes the action fail before it starts with
# "A parameter cannot be found that matches parameter name 'Device_DN'". Config comes from env vars.
$Client      = $env:ODMAD_CLIENT
$GitHubToken = $env:ODMAD_GH_TOKEN
$RepoOwner   = 'patloner'
$RepoName    = 'odm-reports'
$Branch      = 'main'
$RepoFolder  = 'profiles'

$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ts         = Get-Date -Format 'yyyyMMdd_HHmmss'
$computer   = $env:COMPUTERNAME
$clientSafe = if ($Client) { ($Client -replace '[^A-Za-z0-9_-]', '') } else { '' }
if (-not $clientSafe) { $clientSafe = '_unassigned' }

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
$machineSid = ''
try {
    $la = Get-CimInstance -ClassName Win32_UserAccount -Filter 'LocalAccount=True' -ErrorAction Stop | Select-Object -First 1
    if ($la) { $machineSid = $la.SID -replace '-\d+$', '' }
} catch { }

function Get-SidKind([string]$sid) {
    if ($sid -match '^S-1-12-1-') { return 'Entra' }
    if ($sid -match '^S-1-5-21-') {
        if (-not $machineSid) { return 'Domain/Local' }
        if ($sid.StartsWith($machineSid + '-')) { return 'Local' } else { return 'Domain' }
    }
    if ($sid -match '^S-1-5-(18|19|20)$') { return 'System' }
    if ($sid -match '^S-1-5-(80|82|83|90|96)-') { return 'Service' }
    return 'Other'
}

# S-1-12-1-a-b-c-d  ->  object ID GUID (four uint32 sub-authorities, little-endian bytes)
function ConvertTo-EntraObjectId([string]$sid) {
    if ($sid -notmatch '^S-1-12-1-(\d+)-(\d+)-(\d+)-(\d+)$') { return '' }
    $bytes = @()
    foreach ($i in 1..4) { $bytes += [BitConverter]::GetBytes([uint32]$Matches[$i]) }
    return ([guid]::new([byte[]]$bytes)).ToString()
}

function Resolve-SidName([string]$sid) {
    try { return ([Security.Principal.SecurityIdentifier]$sid).Translate([Security.Principal.NTAccount]).Value }
    catch { return 'UNRESOLVED' }
}

function Get-FolderOwner([string]$path) {
    try { return (Get-Acl -LiteralPath $path -ErrorAction Stop).Owner } catch { return '' }
}

function Format-Time($t) { if ($t) { return ([datetime]$t).ToString('yyyy-MM-dd HH:mm') } else { return '' } }

# ---------------------------------------------------------------------------
# collect
# ---------------------------------------------------------------------------
$wmi = @{}
try { Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop | ForEach-Object { $wmi[$_.SID] = $_ } }
catch { Write-Output "Win32_UserProfile query failed: $($_.Exception.Message)" }

$rows = New-Object System.Collections.Generic.List[object]
$seen = @{}

$plKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
Get-ChildItem -Path $plKey -ErrorAction SilentlyContinue | ForEach-Object {
    $child = $_.PSChildName
    $sid   = $child -replace '\.bak$', ''
    $p     = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
    $path  = [string]$p.ProfileImagePath
    $w     = $wmi[$sid]
    # Test-Path raises access-denied on protected profiles (e.g. systemprofile) when not run as SYSTEM/admin
    $exists = $false; $denied = $false
    if ($path) { try { $exists = [bool](Test-Path -LiteralPath $path -ErrorAction Stop) } catch { $denied = $true } }
    $ntuser = ''
    if ($exists) { $nt = Get-Item -LiteralPath (Join-Path $path 'NTUSER.DAT') -Force -ErrorAction SilentlyContinue; if ($nt) { $ntuser = Format-Time $nt.LastWriteTime } }
    if ($path) { $seen[$path.ToLower()] = $true }
    $rows.Add([pscustomobject][ordered]@{
        ComputerName    = $computer
        SID             = $sid
        SidKind         = Get-SidKind $sid
        EntraObjectId   = ConvertTo-EntraObjectId $sid
        Account         = Resolve-SidName $sid
        ProfilePath     = $path
        FolderExists    = $(if ($denied) { 'AccessDenied' } else { $exists })
        FolderOwner     = $(if ($exists) { Get-FolderOwner $path } else { '' })
        LastUseTime     = $(if ($w) { Format-Time $w.LastUseTime } else { '' })
        NtuserLastWrite = $ntuser
        Loaded          = $(if ($w) { $w.Loaded } else { '' })
        Special         = $(if ($w) { $w.Special } else { '' })
        RegState        = $p.State
        BakEntry        = ($child -like '*.bak')
        Source          = 'ProfileList'
    })
}

# Folders on disk with no ProfileList entry (orphaned/leftover profiles)
$skip = 'Public', 'Default', 'Default User', 'All Users', 'desktop.ini'
Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $skip -notcontains $_.Name -and $_.Name -notmatch '^(UMFD|DWM)-\d+$' -and -not $seen.ContainsKey($_.FullName.ToLower()) } |
    ForEach-Object {
        $nt = Get-Item -LiteralPath (Join-Path $_.FullName 'NTUSER.DAT') -Force -ErrorAction SilentlyContinue
        $rows.Add([pscustomobject][ordered]@{
            ComputerName = $computer; SID = ''; SidKind = ''; EntraObjectId = ''; Account = ''
            ProfilePath = $_.FullName; FolderExists = $true; FolderOwner = (Get-FolderOwner $_.FullName)
            LastUseTime = ''; NtuserLastWrite = $(if ($nt) { Format-Time $nt.LastWriteTime } else { '' })
            Loaded = ''; Special = ''; RegState = ''; BakEntry = ''; Source = 'FolderOnly'
        })
    }

Write-Output "Profiles on $computer (client $clientSafe): $($rows.Count) row(s)"
Write-Output ($rows | Select-Object SID, SidKind, Account, ProfilePath, NtuserLastWrite, Source | Format-Table -AutoSize | Out-String -Width 250)

# ---------------------------------------------------------------------------
# local copy FIRST (byte-identical to the upload), then upload
# ---------------------------------------------------------------------------
$utf8     = [Text.UTF8Encoding]::new($false)
$csv      = (($rows | ConvertTo-Csv -NoTypeInformation) -join "`r`n") + "`r`n"
$fileName = "${computer}_${ts}.csv"
$localDir = Join-Path $env:ProgramData 'Marco\ODMAD'
try {
    New-Item -ItemType Directory -Path $localDir -Force -ErrorAction Stop | Out-Null
    $localPath = Join-Path $localDir "UserProfiles_$fileName"
    [IO.File]::WriteAllText($localPath, $csv, $utf8)
    Write-Output "Local copy saved: $localPath"
} catch { Write-Output "Local copy FAILED: $($_.Exception.Message)" }

if (-not $GitHubToken) {
    Write-Output '(Upload skipped - ODMAD_GH_TOKEN not set.)'
    exit 0
}

try {
    $repoPath = "$RepoFolder/$clientSafe/$fileName"
    $api  = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/$repoPath"
    $hdr  = @{ Authorization = "Bearer $GitHubToken"; Accept = 'application/vnd.github+json'
               'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'Marco-ODMAD-Toolkit' }
    $body = @{ message = "User profiles: $computer ($ts) client=$clientSafe rows=$($rows.Count)"
               content = [Convert]::ToBase64String($utf8.GetBytes($csv)); branch = $Branch } | ConvertTo-Json
    foreach ($try in 1..3) {   # concurrent fleet PUTs to one branch can 409
        try {
            $r = Invoke-RestMethod -Uri $api -Method Put -Headers $hdr -Body $body -ContentType 'application/json' -ErrorAction Stop
            Write-Output "PROFILE UPLOAD OK -> $repoPath (commit $($r.commit.sha.Substring(0,8)))"
            break
        } catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($code -eq 409 -and $try -lt 3) { Start-Sleep -Seconds (3 * $try + (Get-Random -Maximum 5)); continue }
            throw
        }
    }
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    $hint = switch ($code) { 401 { 'PAT expired/revoked' } 403 { 'PAT lacks Contents:write' } 404 { 'repo not on PAT (or wrong name)' } default { '' } }
    Write-Output "PROFILE UPLOAD FAILED: $($_.Exception.Message) $hint"
    Write-Output "Local copy remains at $localDir"
}
exit 0

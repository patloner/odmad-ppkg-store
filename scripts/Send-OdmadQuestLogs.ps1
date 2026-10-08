#Requires -Version 5.1
<#
.SYNOPSIS
    ODMAD custom action (device side): collect Quest agent logs and upload them
    to GitHub. Replaces Quest's built-in "Upload Logs", which only supports UNC.

.DESCRIPTION
    Runs as SYSTEM from the ODM custom action (via Bootstrap-SendQuestLogs.ps1).
    Collects, read-only:
      - ODMAD agent folder: Files\ (everything), map.usr, map.gg
      - ODMAD_AD registry export
      - DUA install folder log-like files
      - C:\ProgramData\Quest log-like files
      - Marco logs: %ProgramData%\Marco\ODMAD, C:\Windows\Temp\MarcoMigration
      - Snapshot: services, dsregcmd /status, OS/agent versions
    Zips them (files opened with FileShare.ReadWrite, so in-use logs are fine),
    saves a local copy FIRST, then uploads to:
        <RepoOwner>/<RepoName> (private)  quest-logs/<Client>/<Computer>_<ts>.zip
    Same repo/folder as Publish-OdmadQuestLogs.ps1, so both paths land together.

    Inputs (environment variables, set by the bootstrap):
      ODMAD_GH_TOKEN   PAT, contents:write on odm-reports ONLY (required to upload)
      ODMAD_CLIENT     client short name, used as the quest-logs/<Client> folder

    Always exits 0 so it never aborts the ODM sequence. Read the task output.
    The GitHub Contents API is capped (~100 MB incl. base64). The zip is limited to
    -MaxZipMB; if over, the oldest files are dropped and listed in the output.

.NOTES
    Marco Technologies - Migration Engineering
    Host in odmad-ppkg-store/scripts/ (public). Pure ASCII - keep it that way.
#>
[CmdletBinding()]
param(
    [string]$Client      = $env:ODMAD_CLIENT,
    [string]$GitHubToken = $env:ODMAD_GH_TOKEN,
    [string]$RepoOwner   = 'patloner',
    [string]$RepoName    = 'odm-reports',
    [string]$Branch      = 'main',
    [string]$RepoFolder  = 'quest-logs',
    [int]$MaxZipMB       = 40,
    [int]$MaxFileMB      = 15
)

$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ts       = Get-Date -Format 'yyyyMMdd_HHmmss'
$computer = $env:COMPUTERNAME
$clientSafe = if ($Client) { ($Client -replace '[^A-Za-z0-9_-]', '') } else { '' }
if (-not $clientSafe) { $clientSafe = '_unassigned' }

$work     = Join-Path $env:SystemRoot "Temp\QuestLogs_$ts"
$localDir = Join-Path $env:ProgramData 'Marco\ODMAD'
$zipName  = "${computer}_${ts}.zip"
$zipLocal = Join-Path $localDir $zipName

function Out-Line([string]$m) { Write-Output $m }

# ---------------------------------------------------------------------------
# 1. Snapshot (small text file that rides inside the zip)
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Path $work -Force | Out-Null
New-Item -ItemType Directory -Path $localDir -Force -ErrorAction SilentlyContinue | Out-Null
$snap = New-Object System.Text.StringBuilder
[void]$snap.AppendLine("Computer : $computer")
[void]$snap.AppendLine("Client   : $clientSafe")
[void]$snap.AppendLine("Captured : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
[void]$snap.AppendLine("OS       : $([Environment]::OSVersion.VersionString)")
foreach ($s in 'ODMActiveDirectory','OnDemandMSLicenseService') {
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    [void]$snap.AppendLine(("Service  : {0} = {1}" -f $s, $(if ($svc) { "$($svc.Status)/$($svc.StartType)" } else { 'NotFound' })))
}
try { [void]$snap.AppendLine("--- dsregcmd /status ---"); [void]$snap.AppendLine((& dsregcmd.exe /status 2>&1 | Out-String)) } catch {}
$snapFile = Join-Path $work '_snapshot.txt'
[IO.File]::WriteAllText($snapFile, $snap.ToString(), [Text.UTF8Encoding]::new($false))

$regFile = Join-Path $work 'ODMAD_AD.reg'
try { & reg.exe export 'HKLM\SOFTWARE\WOW6432Node\Quest\On Demand Migration For Active Directory\ODMAD_AD' $regFile /y 2>$null | Out-Null } catch {}

# ---------------------------------------------------------------------------
# 2. Build the candidate file list: @{Path; Entry}
# ---------------------------------------------------------------------------
$odmad = 'C:\Program Files (x86)\Quest\On Demand Migration Active Directory Agent'
$dua   = 'C:\Program Files (x86)\Quest\On Demand Migration Desktop Update Agent'
$logExt = '.log','.txt','.xml','.json','.csv','.reg','.usr','.gg','.etl'
$maxFile = $MaxFileMB * 1MB
$cand = New-Object System.Collections.Generic.List[object]

function Add-Tree([string]$Root, [string]$Prefix, [bool]$AllTypes) {
    if (-not (Test-Path -LiteralPath $Root)) { return }
    Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $AllTypes -and ($logExt -notcontains $_.Extension.ToLower())) { return }
        $rel = $_.FullName.Substring($Root.TrimEnd('\').Length).TrimStart('\')
        $cand.Add([pscustomobject]@{ Path = $_.FullName; Entry = "$Prefix/$($rel -replace '\\','/')"; Time = $_.LastWriteTime; Len = $_.Length })
    }
}
function Add-One([string]$P, [string]$Entry) {
    if (Test-Path -LiteralPath $P) {
        $i = Get-Item -LiteralPath $P
        $cand.Add([pscustomobject]@{ Path = $i.FullName; Entry = $Entry; Time = $i.LastWriteTime; Len = $i.Length })
    }
}

Add-Tree (Join-Path $odmad 'Files') 'ODMAD/Files' $true
Add-One  (Join-Path $odmad 'map.usr') 'ODMAD/map.usr'
Add-One  (Join-Path $odmad 'map.gg')  'ODMAD/map.gg'
Add-Tree $dua 'DUA' $false
Add-Tree 'C:\ProgramData\Quest' 'ProgramData-Quest' $false
Add-Tree (Join-Path $env:ProgramData 'Marco\ODMAD') 'Marco/ODMAD' $false
Add-Tree (Join-Path $env:SystemRoot 'Temp\MarcoMigration') 'Marco/MarcoMigration' $false
Add-One $snapFile '_snapshot.txt'
Add-One $regFile  'ODMAD_AD.reg'

# Drop previous collection zips (Marco/ODMAD may hold earlier ones) and oversize files
$skipped = New-Object System.Collections.Generic.List[string]
$sel = $cand | Where-Object {
    if ($_.Path -like '*.zip') { return $false }
    if ($_.Len -gt $maxFile) { $skipped.Add("too large ($([int]($_.Len/1MB)) MB): $($_.Entry)"); return $false }
    $true
}

# Cap total input at ~MaxZipMB*2 (logs compress ~5-10x; zip size is re-checked after)
$budget = [long]$MaxZipMB * 2MB
$sel = @($sel | Sort-Object Time -Descending)
$total = 0L; $keep = New-Object System.Collections.Generic.List[object]
foreach ($f in $sel) {
    $isCore = $f.Entry -in '_snapshot.txt','ODMAD_AD.reg','ODMAD/map.usr','ODMAD/map.gg'
    if ($isCore -or ($total + $f.Len) -le $budget) { $keep.Add($f); $total += $f.Len }
    else { $skipped.Add("over budget: $($f.Entry)") }
}

Out-Line "Collected $($keep.Count) file(s), $([math]::Round($total/1MB,1)) MB raw; skipped $($skipped.Count)."

# ---------------------------------------------------------------------------
# 3. Zip (FileShare.ReadWrite so in-use logs do not fail the run)
# ---------------------------------------------------------------------------
$zipOk = $false
try {
    if (Test-Path $zipLocal) { Remove-Item $zipLocal -Force }
    $fs  = [IO.File]::Open($zipLocal, [IO.FileMode]::Create)
    $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    $n = 0
    foreach ($f in $keep) {
        try {
            $in = [IO.File]::Open($f.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            $e  = $zip.CreateEntry($f.Entry, [IO.Compression.CompressionLevel]::Optimal)
            $e.LastWriteTime = $f.Time
            $out = $e.Open(); $in.CopyTo($out); $out.Dispose(); $in.Dispose(); $n++
        } catch { $skipped.Add("unreadable: $($f.Entry) - $($_.Exception.Message)") }
    }
    if ($skipped.Count -gt 0) {
        $e = $zip.CreateEntry('_skipped.txt'); $w = New-Object IO.StreamWriter($e.Open(), [Text.UTF8Encoding]::new($false))
        $w.Write(($skipped -join "`r`n")); $w.Dispose()
    }
    $zip.Dispose(); $fs.Dispose()
    $zipOk = ($n -gt 0)
    $zipMB = [math]::Round((Get-Item $zipLocal).Length / 1MB, 2)
    Out-Line "Local copy saved: $zipLocal ($n files, $zipMB MB)"
} catch {
    Out-Line "ZIP FAILED: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 4. Upload (never fatal)
# ---------------------------------------------------------------------------
if (-not $zipOk) {
    Out-Line "Nothing to upload."
} elseif (-not $GitHubToken) {
    Out-Line "Upload skipped - ODMAD_GH_TOKEN not set. Collect from $zipLocal."
} elseif ((Get-Item $zipLocal).Length -gt ($MaxZipMB * 1MB)) {
    Out-Line "Upload skipped - zip is $zipMB MB, over the $MaxZipMB MB cap. Collect from $zipLocal or lower -MaxFileMB."
} else {
    try {
        $repoPath = "$RepoFolder/$clientSafe/$zipName"
        $api  = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/$repoPath"
        $hdr  = @{ Authorization = "Bearer $GitHubToken"; Accept = 'application/vnd.github+json'
                   'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'Marco-ODMAD-Toolkit' }
        $body = @{ message = "Quest logs: $computer ($ts) client=$clientSafe"
                   content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zipLocal))
                   branch  = $Branch } | ConvertTo-Json
        $done = $false
        foreach ($try in 1..3) {   # concurrent fleet PUTs to one branch can 409
            try {
                $r = Invoke-RestMethod -Uri $api -Method Put -Headers $hdr -Body $body -ContentType 'application/json' -ErrorAction Stop
                Out-Line "LOG UPLOAD OK -> $repoPath (commit $($r.commit.sha.Substring(0,8)))"
                $done = $true; break
            } catch {
                $code = $_.Exception.Response.StatusCode.value__
                if ($code -eq 409 -and $try -lt 3) { Start-Sleep -Seconds (3 * $try + (Get-Random -Max 5)); continue }
                throw
            }
        }
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        $hint = switch ($code) { 403 { 'PAT lacks Contents:write' } 404 { 'repo not on PAT (or wrong name)' } 401 { 'PAT expired/revoked' } default { '' } }
        Out-Line "LOG UPLOAD FAILED: $($_.Exception.Message) $hint"
        Out-Line "Local copy remains at $zipLocal"
    }
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
exit 0

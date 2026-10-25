<#
.SYNOPSIS
  Updates CS2 Bot Improver (plugins, CounterStrikeSharp, Metamod, configs) in place.

.DESCRIPTION
  Downloads the latest release of this fork, checks it, and updates the files in
  game/csgo without a full reinstall.

  Safety:
  - latest.json must carry a valid RSA signature from the release key embedded below.
  - The package zip must match the SHA-256 listed in latest.json, and every file in it
    must match the install manifest inside the zip.
  - Files you (or the Panel) changed since the last install are kept if they are
    settings (cfg, ini, vdf, gameinfo.gi, configs, botprofile.vpk). Code and game
    data (dll, gamedata, runtime) are always brought up to date.
  - Every file that is replaced or removed is backed up first, and a failed update
    is rolled back.

  The Panel .exe is not touched.

.PARAMETER CsgoPath
  The game/csgo folder. Defaults to the folder this script was installed into.
.PARAMETER Check
  Only report what would change.
.PARAMETER Yes
  Do not ask for confirmation.
.PARAMETER Force
  Reinstall even if this build is already installed.
.PARAMETER Variant
  Package to follow (e.g. CS2BotImprover or CS2BotImprover_rules_unchanged).
  Defaults to the one currently installed.
.PARAMETER Feed
  Where to find latest.json: a URL or a local folder (for testing).
#>
[CmdletBinding()]
param(
    [string]$CsgoPath,
    [switch]$Check,
    [switch]$Yes,
    [switch]$Force,
    [string]$Variant,
    [string]$Feed = '__UPDATE_FEED__'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
trap {
    Write-Host ''
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Filled in by the release workflow.
$PublicKeyXml = '__UPDATE_PUBLIC_KEY_XML__'

$StateRel = 'addons/cs2botimprover/install.json'
$BackupRel = 'addons/cs2botimprover/backups'
$KeepBackups = 3
# Top-level entries the updater may write into game/csgo.
$AllowedRoots = @('addons', 'backup', 'cfg', 'overrides', 'gameinfo.gi', 'CS2BotImprover-Update.cmd')

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Note([string]$Text) { Write-Host "    $Text" }
function Fail([string]$Text) { throw $Text }

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function ConvertTo-Map($Object) {
    # JSON object -> case-insensitive hashtable (Windows paths are case-insensitive)
    $map = @{}
    if ($null -ne $Object) {
        foreach ($p in $Object.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
    }
    return $map
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Join-Rel([string]$Root, [string]$Rel) {
    return [System.IO.Path]::Combine($Root, ($Rel -replace '/', [System.IO.Path]::DirectorySeparatorChar))
}

function Test-SafeRel([string]$Rel) {
    if ([string]::IsNullOrWhiteSpace($Rel)) { return $false }
    if ($Rel.StartsWith('/') -or $Rel.StartsWith('\') -or $Rel.Contains(':') -or $Rel.Contains('\')) { return $false }
    foreach ($part in $Rel.Split('/')) {
        if ($part -eq '' -or $part -eq '.' -or $part -eq '..') { return $false }
    }
    if ($Rel -like "$BackupRel/*" -or $Rel -eq $StateRel) { return $false }
    $top = $Rel.Split('/')[0]
    return ($AllowedRoots -contains $top)
}

function Test-UserSetting([string]$Rel) {
    # Files people (or the Panel) are expected to edit. If changed locally they are kept.
    $r = $Rel.ToLowerInvariant()
    $name = [System.IO.Path]::GetFileName($r)
    if ($r.StartsWith('addons/counterstrikesharp/configs/')) { return $true }
    if ($r -eq 'overrides/botprofile.vpk' -or $r -eq 'gameinfo.gi' -or $r.StartsWith('backup/')) { return $true }
    foreach ($ext in @('.cfg', '.ini', '.vdf', '.txt')) { if ($r.EndsWith($ext)) { return $true } }
    if ($r.EndsWith('.json')) {
        if ($name -like 'gamedata*.json' -or $name -like '*.deps.json' -or $name -like '*.runtimeconfig.json') { return $false }
        if ($r.StartsWith('addons/counterstrikesharp/dotnet/') -or $r.StartsWith('addons/counterstrikesharp/gamedata/')) { return $false }
        return $true
    }
    return $false
}

function Test-IsUrl([string]$Value) { return $Value -match '^https?://' }

function New-WebClient {
    $wc = New-Object System.Net.WebClient
    $wc.Headers['User-Agent'] = 'CS2BotImprover-Updater'
    return $wc
}

function Get-FeedBytes([string]$Name) {
    if (Test-IsUrl $Feed) {
        return (New-WebClient).DownloadData("$($Feed.TrimEnd('/'))/$Name")
    }
    return [System.IO.File]::ReadAllBytes((Join-Path $Feed $Name))
}

function Test-Signature([byte[]]$Data, [string]$SignatureText) {
    if ($PublicKeyXml -notlike '<RSAKeyValue>*') { Fail 'This updater was built without a release key.' }
    $sig = [Convert]::FromBase64String($SignatureText.Trim())
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $rsa.FromXmlString($PublicKeyXml)
        return $rsa.VerifyData($Data, $sig,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally { $rsa.Dispose() }
}

function Format-Size([long]$Bytes) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }

# ------------------------------------------------------------------ main
if (Test-IsUrl $Feed) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} elseif ($Feed -like '__*__') {
    Fail 'This updater was built without a feed URL. Pass -Feed.'
}

if (-not $CsgoPath) { $CsgoPath = [System.IO.Path]::Combine($PSScriptRoot, '..', '..') }
$CsgoPath = (Resolve-Path -LiteralPath $CsgoPath).Path
if (-not (Test-Path -LiteralPath (Join-Path $CsgoPath 'gameinfo.gi'))) {
    Fail "Not a CS2 game/csgo folder: $CsgoPath"
}

Write-Host ''
Write-Host 'CS2 Bot Improver updater' -ForegroundColor White
Write-Note "game/csgo: $CsgoPath"

$statePath = Join-Rel $CsgoPath $StateRel
$state = $null
if (Test-Path -LiteralPath $statePath) {
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
}
$installedBuild = [int](0 + (Get-Prop $state 'build'))
$installedVersion = Get-Prop $state 'version'
if (-not $Variant) { $Variant = Get-Prop $state 'variant' }
if (-not $Variant) {
    Fail ("No install record found ($StateRel). Install the latest release zip by hand once, " +
          "or pass -Variant CS2BotImprover (or CS2BotImprover_rules_unchanged).")
}
if ($installedVersion) { Write-Note "Installed: $installedVersion ($Variant)" } else { Write-Note "Installed: unknown ($Variant)" }

if (Get-Process -Name cs2 -ErrorAction SilentlyContinue) { Fail 'Close CS2 before updating.' }

# ---------------------------------------------------------------- feed
Write-Step 'Checking for updates'
$feedBytes = Get-FeedBytes 'latest.json'
$sigText = [System.Text.Encoding]::ASCII.GetString((Get-FeedBytes 'latest.json.sig'))
if (-not (Test-Signature $feedBytes $sigText)) { Fail 'latest.json signature is invalid. Nothing was changed.' }
$latest = [System.Text.Encoding]::UTF8.GetString($feedBytes).TrimStart([char]0xFEFF) | ConvertFrom-Json
if ((Get-Prop $latest 'schema') -ne 1) { Fail 'Unsupported update feed format. Download the latest release by hand.' }
$latestBuild = [int](Get-Prop $latest 'build')
$pkg = Get-Prop (Get-Prop $latest 'packages') $Variant
if ($null -eq $pkg) { Fail "The latest release has no '$Variant' package." }
$published = Get-Prop $latest 'published'
if ($published -is [datetime]) { $published = $published.ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC' }
elseif ($published) { $published = ([string]$published).Replace('T', ' ').Replace('Z', ' UTC') }
Write-Note "Latest:    $($latest.version) (published $published)"

if ($latestBuild -le $installedBuild -and -not $Force) {
    Write-Host ''
    Write-Host 'You already have the latest version.' -ForegroundColor Green
    exit 0
}

# ------------------------------------------------------------ download
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("cs2bi-update-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $zipPath = Join-Path $work $pkg.asset
    if (Test-IsUrl $Feed) {
        Write-Step "Downloading $($pkg.asset) ($(Format-Size $pkg.size))"
        (New-WebClient).DownloadFile($pkg.url, $zipPath)
    } else {
        Copy-Item -LiteralPath (Join-Path $Feed $pkg.asset) -Destination $zipPath
    }
    if ((Get-Sha256 $zipPath) -ne ([string]$pkg.sha256).ToLowerInvariant()) {
        Fail 'Downloaded package does not match its checksum. Nothing was changed.'
    }

    Write-Step 'Checking package contents'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $extract = Join-Path $work 'pkg'
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extract)
    $root = $extract
    if (-not (Test-Path -LiteralPath (Join-Path $root 'addons'))) {
        $inner = Get-ChildItem -LiteralPath $extract -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'addons') } | Select-Object -First 1
        if ($null -eq $inner) { Fail 'Package has no addons folder.' }
        $root = $inner.FullName
    }
    $newStatePath = Join-Rel $root $StateRel
    if (-not (Test-Path -LiteralPath $newStatePath)) { Fail 'Package has no install manifest.' }
    $newState = Get-Content -LiteralPath $newStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int](Get-Prop $newState 'build') -ne $latestBuild -or (Get-Prop $newState 'variant') -ne $Variant) {
        Fail 'Package does not match latest.json. Nothing was changed.'
    }

    $newFiles = ConvertTo-Map (Get-Prop $newState 'files')
    $oldFiles = ConvertTo-Map (Get-Prop $state 'files')
    foreach ($rel in $newFiles.Keys) {
        if (-not (Test-SafeRel $rel)) { Fail "Package lists an unexpected path: $rel" }
        $src = Join-Rel $root $rel
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { Fail "Package is missing $rel" }
        if ((Get-Sha256 $src) -ne $newFiles[$rel]) { Fail "Package file does not match its manifest: $rel" }
    }

    # ------------------------------------------------------------- plan
    Write-Step 'Comparing with your installation'
    $actions = New-Object System.Collections.ArrayList   # @{ Kind; Rel }
    $kept = New-Object System.Collections.ArrayList
    $unchanged = 0
    foreach ($rel in ($newFiles.Keys | Sort-Object)) {
        $dst = Join-Rel $CsgoPath $rel
        if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) {
            [void]$actions.Add(@{ Kind = 'add'; Rel = $rel }); continue
        }
        $local = Get-Sha256 $dst
        if ($local -eq $newFiles[$rel]) { $unchanged++; continue }
        $untouched = $oldFiles.ContainsKey($rel) -and $oldFiles[$rel] -eq $local
        if ($untouched -or -not (Test-UserSetting $rel)) {
            [void]$actions.Add(@{ Kind = 'update'; Rel = $rel })
        } elseif ($oldFiles.ContainsKey($rel) -and $oldFiles[$rel] -eq $newFiles[$rel]) {
            $unchanged++   # your edit; this release does not change the file
        } else {
            [void]$kept.Add($rel)
        }
    }
    foreach ($rel in ($oldFiles.Keys | Sort-Object)) {
        if ($newFiles.ContainsKey($rel) -or -not (Test-SafeRel $rel)) { continue }
        $dst = Join-Rel $CsgoPath $rel
        if ((Test-Path -LiteralPath $dst -PathType Leaf) -and (Get-Sha256 $dst) -eq $oldFiles[$rel]) {
            [void]$actions.Add(@{ Kind = 'remove'; Rel = $rel })
        }
    }

    $counts = @{ add = 0; update = 0; remove = 0 }
    foreach ($a in $actions) { $counts[$a.Kind]++ }
    Write-Note ("{0} to update, {1} new, {2} to remove, {3} already current" -f $counts.update, $counts.add, $counts.remove, $unchanged)
    if ($kept.Count -gt 0) {
        Write-Note "This release changes $($kept.Count) settings file(s) you edited. Your versions are kept:"
        foreach ($rel in $kept) { Write-Note "  $rel" }
    }
    $notes = Get-Prop $latest 'notes_url'
    if ($notes) { Write-Note "Release notes: $notes" }

    if ($Check) { Write-Host ''; Write-Host 'Check only: nothing was changed.'; exit 0 }
    if ($actions.Count -eq 0) {
        Write-Step 'Nothing to copy; recording the new version'
    } elseif (-not $Yes) {
        $answer = Read-Host "Update to $($latest.version) now? [Y/n]"
        if ($answer -and $answer -notmatch '^(y|yes)$') { Write-Host 'Cancelled: nothing was changed.'; exit 0 }
    }

    # ------------------------------------------------------------ apply
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $backupDir = Join-Rel $CsgoPath "$BackupRel/$stamp"
    $journal = New-Object System.Collections.ArrayList   # @{ Rel; Backup }
    if ($actions.Count -gt 0) { Write-Step "Updating files (backup: $BackupRel/$stamp)" }
    try {
        foreach ($a in $actions) {
            $dst = Join-Rel $CsgoPath $a.Rel
            $backup = $null
            if (Test-Path -LiteralPath $dst -PathType Leaf) {
                $backup = Join-Rel $backupDir $a.Rel
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
                Copy-Item -LiteralPath $dst -Destination $backup -Force
            }
            [void]$journal.Add(@{ Rel = $a.Rel; Backup = $backup })
            if ($a.Kind -eq 'remove') {
                Remove-Item -LiteralPath $dst -Force
            } else {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
                Copy-Item -LiteralPath (Join-Rel $root $a.Rel) -Destination $dst -Force
            }
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $statePath) | Out-Null
        if (Test-Path -LiteralPath $statePath) {
            New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
            Copy-Item -LiteralPath $statePath -Destination (Join-Path $backupDir 'install.json') -Force
        }
        Copy-Item -LiteralPath $newStatePath -Destination $statePath -Force
    } catch {
        $err = $_
        Write-Host "Update failed: $($err.Exception.Message)" -ForegroundColor Red
        Write-Step 'Rolling back'
        for ($i = $journal.Count - 1; $i -ge 0; $i--) {
            $j = $journal[$i]
            $dst = Join-Rel $CsgoPath $j.Rel
            try {
                if ($j.Backup) { Copy-Item -LiteralPath $j.Backup -Destination $dst -Force }
                elseif (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }
            } catch { Write-Host "  could not restore $($j.Rel): $($_.Exception.Message)" -ForegroundColor Red }
        }
        $savedState = Join-Path $backupDir 'install.json'
        if (Test-Path -LiteralPath $savedState) { Copy-Item -LiteralPath $savedState -Destination $statePath -Force }
        Fail "Update rolled back. Your files are as they were. Backup copies: $backupDir"
    }

    # Keep the newest few backups
    $backupRoot = Join-Rel $CsgoPath $BackupRel
    if (Test-Path -LiteralPath $backupRoot) {
        Get-ChildItem -LiteralPath $backupRoot -Directory | Sort-Object Name -Descending |
            Select-Object -Skip $KeepBackups | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Host "Updated to $($latest.version)." -ForegroundColor Green
    exit 0
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

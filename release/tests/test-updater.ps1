<#
  End-to-end test of the packaged content updater.

  Installs a built package into a fake game/csgo folder, makes it look like an
  older install with some user edits, then runs the updater from that install
  against a local feed folder (latest.json, latest.json.sig and the zips).

  Usage: test-updater.ps1 -Dist <folder with latest.json and zips> [-Variant CS2BotImprover]
#>
param(
    [Parameter(Mandatory = $true)][string]$Dist,
    [string]$Variant = 'CS2BotImprover'
)

$ErrorActionPreference = 'Stop'
$Dist = (Resolve-Path -LiteralPath $Dist).Path
$shell = (Get-Process -Id $PID).Path
$onWindows = $env:OS -eq 'Windows_NT'
$failures = 0

function Check([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host "  ok   $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL $Message" -ForegroundColor Red; $script:failures++ }
}
function P([string]$Rel) { return [System.IO.Path]::Combine($csgo, ($Rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)) }
function Sha([string]$Rel) { return (Get-FileHash -LiteralPath (P $Rel) -Algorithm SHA256).Hash.ToLowerInvariant() }
function ShaText([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return (($sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '')
}
function Run-Updater([string[]]$Arguments) {
    # Windows PowerShell 5.1 turns child stderr into errors; don't let that end the test
    $ErrorActionPreference = 'Continue'
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (P 'addons/cs2botimprover/update.ps1') -CsgoPath $csgo @Arguments 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}
function Read-State { return Get-Content -LiteralPath (P 'addons/cs2botimprover/install.json') -Raw | ConvertFrom-Json }
function Write-State($State) {
    [System.IO.File]::WriteAllText((P 'addons/cs2botimprover/install.json'), ($State | ConvertTo-Json -Depth 5))
}
function Set-Old([string]$Rel, [string]$Content, $State) {
    # Make a file look like an untouched copy from an older release
    [System.IO.File]::WriteAllText((P $Rel), $Content)
    $State.files.$Rel = ShaText $Content
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('cs2bi-test-' + [guid]::NewGuid().ToString('N'))
$csgo = Join-Path $work 'csgo'
New-Item -ItemType Directory -Force -Path $csgo | Out-Null
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $Dist "$Variant.zip"), $csgo)
    $pkgState = Read-State
    $build = [int]$pkgState.build
    Write-Host "Package $($pkgState.version) build $build, $(@($pkgState.files.PSObject.Properties).Count) files"

    $dll = 'addons/counterstrikesharp/plugins/BotAI/BotAI.dll'
    $lateDll = 'addons/counterstrikesharp/plugins/RoundDamageRecap/RoundDamageRecap.dll'
    $cfg = 'cfg/my_bot_normal_config.cfg'        # edited by the user AND changed by the release
    $quietCfg = 'cfg/my_bot_ffa_config.cfg'      # edited by the user, not changed by the release
    $gamedata = 'addons/counterstrikesharp/gamedata/gamedata.json'
    $missing = 'addons/counterstrikesharp/plugins/NadeSystem/NadeSystem.dll'
    $oldPlugin = 'addons/counterstrikesharp/plugins/OldPlugin/OldPlugin.dll'
    $oldEdited = 'addons/counterstrikesharp/plugins/OldPlugin/OldPlugin.json'

    Write-Host '1. Already up to date'
    $r = Run-Updater @('-Feed', $Dist, '-Yes')
    Check ($r.Code -eq 0) 'exit code 0'
    Check ($r.Out -match 'already have the latest') 'reports up to date'

    Write-Host '2. Older install with user edits'
    $state = Read-State
    $state.build = $build - 1
    $state.version = 'old'
    Set-Old $dll 'old BotAI' $state
    Add-Content -LiteralPath (P $cfg) -Value 'bot_quota 7 // my edit'
    $state.files.$cfg = ShaText 'cfg from an older release'
    Add-Content -LiteralPath (P $quietCfg) -Value 'bot_quota 9 // my edit'
    [System.IO.File]::WriteAllText((P $gamedata), '{"edited": true}')
    Remove-Item -LiteralPath (P $missing)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent (P $oldPlugin)) | Out-Null
    [System.IO.File]::WriteAllText((P $oldPlugin), 'dropped plugin')
    $state.files | Add-Member -NotePropertyName $oldPlugin -NotePropertyValue (ShaText 'dropped plugin')
    [System.IO.File]::WriteAllText((P $oldEdited), '{"mine": 1}')
    $state.files | Add-Member -NotePropertyName $oldEdited -NotePropertyValue (ShaText '{"original": 1}')
    Write-State $state
    $cfgEdited = Sha $cfg
    $quietEdited = Sha $quietCfg

    $r = Run-Updater @('-Feed', $Dist, '-Check')
    Check ($r.Code -eq 0) '-Check exit code 0'
    Check ((Get-Content -LiteralPath (P $dll) -Raw) -eq 'old BotAI') '-Check changes nothing'
    Check ($r.Out -match [regex]::Escape($cfg)) '-Check lists the edited cfg the release changes'
    Check ($r.Out -notmatch [regex]::Escape($quietCfg)) '-Check does not list an edited cfg the release leaves alone'

    Write-Host '3. Tampered feed is rejected'
    $bad = Join-Path $work 'badfeed'
    New-Item -ItemType Directory -Path $bad | Out-Null
    Get-ChildItem -LiteralPath $Dist -File | Copy-Item -Destination $bad
    $json = [System.IO.File]::ReadAllText((Join-Path $bad 'latest.json')) -replace '"build": \d+', ('"build": ' + ($build + 100))
    [System.IO.File]::WriteAllText((Join-Path $bad 'latest.json'), $json)
    $r = Run-Updater @('-Feed', $bad, '-Yes')
    Check ($r.Code -eq 1) 'exit code 1'
    Check ($r.Out -match 'signature is invalid') 'reports bad signature'
    Check ((Get-Content -LiteralPath (P $dll) -Raw) -eq 'old BotAI') 'nothing changed'

    if ($onWindows) {
        Write-Host '4. Failure part-way is rolled back'
        $state = Read-State
        Set-Old $lateDll 'old RDR' $state
        Write-State $state
        # Readable (so it can be hashed and backed up) but not writable, so the copy fails mid-update
        $lock = [System.IO.File]::Open((P $lateDll), 'Open', 'Read', 'Read')
        try { $r = Run-Updater @('-Feed', $Dist, '-Yes') } finally { $lock.Dispose() }
        Check ($r.Code -eq 1) 'exit code 1'
        Check ($r.Out -match 'rolled back') 'reports rollback'
        Check ((Get-Content -LiteralPath (P $dll) -Raw) -eq 'old BotAI') 'earlier file restored'
        Check ((Read-State).build -eq ($build - 1)) 'install record unchanged'
        Check (-not (Test-Path -LiteralPath (P $missing))) 'added file removed again'
    } else {
        Write-Host '4. (rollback test needs Windows file locking; skipped)'
    }

    Write-Host '5. Update'
    $r = Run-Updater @('-Feed', $Dist, '-Yes')
    Write-Host $r.Out
    Check ($r.Code -eq 0) 'exit code 0'
    Check ((Sha $dll) -eq $pkgState.files.$dll) 'untouched old dll updated'
    Check ((Sha $gamedata) -eq $pkgState.files.$gamedata) 'locally edited gamedata replaced'
    Check ((Sha $cfg) -eq $cfgEdited) 'user-edited cfg kept'
    Check ((Sha $quietCfg) -eq $quietEdited) 'user-edited cfg the release leaves alone kept'
    Check ((Test-Path -LiteralPath (P $missing)) -and (Sha $missing) -eq $pkgState.files.$missing) 'missing file restored'
    Check (-not (Test-Path -LiteralPath (P $oldPlugin))) 'file dropped from the package removed'
    Check (Test-Path -LiteralPath (P $oldEdited)) 'edited file dropped from the package kept'
    Check ((Read-State).build -eq $build) 'install record updated'
    $backup = Get-ChildItem -LiteralPath (P 'addons/cs2botimprover/backups') -Directory | Sort-Object Name | Select-Object -Last 1
    $backedUp = [System.IO.Path]::Combine($backup.FullName, ($dll -replace '/', [System.IO.Path]::DirectorySeparatorChar))
    Check ((Test-Path -LiteralPath $backedUp) -and (Get-Content -LiteralPath $backedUp -Raw) -eq 'old BotAI') 'replaced file backed up'

    Write-Host '6. Second run is a no-op'
    $r = Run-Updater @('-Feed', $Dist, '-Yes')
    Check ($r.Code -eq 0 -and $r.Out -match 'already have the latest') 'reports up to date'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All updater checks passed' -ForegroundColor Green

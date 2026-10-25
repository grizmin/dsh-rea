<#
    setup-rea-tools.ps1
    Portable reverse-engineering toolchain for REA / dsh-rea, all under one root.
    Run in PowerShell on the DSH host (Windows x64). No admin installers, nothing
    added to the system PATH. Remove everything by deleting $Root.

    Usage:
        powershell -ExecutionPolicy Bypass -File .\scripts\setup-rea-tools.ps1
        powershell -ExecutionPolicy Bypass -File .\scripts\setup-rea-tools.ps1 -Root D:\re\tools
        powershell -ExecutionPolicy Bypass -File .\scripts\setup-rea-tools.ps1 -SkipIda -SkipAndroid -SkipCutter

    REA version:
        $REA_VER is read from the `rea-agents` pin in this repository's
        package.json, so the Cutter bridge and the optional CLI always match the
        REA the plugin actually bridges. Override it with -ReaVersion only when
        intentionally preparing tools for a different REA release.

    REA tools that are Linux-only in REA (not installed here): TShark/capinfos
    packet inspection, sigrok signal decoding, GDB sessions. Kuna is caller-supplied
    (REA_KUNA_COMMAND, verified 1.833) with no public download, so it is not bundled.

    The Ghidra / JADX / WABT / JDK pins below are asserted against the installed
    `rea-agents` release by test/toolchain.test.mjs; a REA bump that changes a pin
    fails that test until this script is updated to match.
#>

[CmdletBinding()]
param(
    [string]$Root = 'C:\re\tools',
    [switch]$SkipAndroid,          # skip adb + apktool + jadx
    [switch]$SkipIda,              # don't scaffold ida-mcp.json
    [switch]$SkipCutter,           # skip Cutter + REA's Cutter bridge plugin
    [switch]$InstallReaCli,        # also `npm i -g rea-agents@<pin>` so `rea doctor` works
    [switch]$Force,                # re-download even if a tool dir already exists
    [string]$GhidraTag,            # override the Ghidra release tag (default Ghidra_<ver>_build)
    [string]$ReaVersion            # override the REA version taken from package.json
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---- pins ---------------------------------------------------------------
$GHIDRA_VER   = '12.1.4'
$JADX_VER     = '0.7.1'
$JADX_SHA256  = '6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75'
$WABT_VER     = '1.0.42'
$JDK_MAJOR    = '21'

# The REA version follows the rea-agents pin in this repository's package.json.
# The script may be run from anywhere, so locate package.json by walking up from
# this file rather than trusting the working directory.
function Get-RepoReaVersion {
    $dir = Split-Path -Parent $PSCommandPath
    while ($dir) {
        $candidate = Join-Path $dir 'package.json'
        if (Test-Path $candidate) {
            try {
                $pkg = Get-Content $candidate -Raw | ConvertFrom-Json
                if ($pkg.name -eq 'dsh-rea' -and $pkg.dependencies.'rea-agents') {
                    $spec = [string]$pkg.dependencies.'rea-agents'
                    # Accept an exact semver pin; reject ranges and tags we cannot
                    # turn into a download URL.
                    if ($spec -match '^\d+\.\d+\.\d+$') { return $spec }
                    throw "rea-agents in $candidate is '$spec'; expected an exact version like 6.7.0."
                }
            } catch [System.Management.Automation.MethodInvocationException] {
                throw
            }
        }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

if ($ReaVersion) {
    $REA_VER = $ReaVersion
} else {
    $REA_VER = Get-RepoReaVersion
    if (-not $REA_VER) {
        throw "Could not find the dsh-rea package.json above '$PSCommandPath' to read the rea-agents pin. Run the script from the repository, or pass -ReaVersion <x.y.z>."
    }
}
$REA_PKG      = "rea-agents@$REA_VER"

# forbid characters REA rejects in a Ghidra path
if ($Root -match '[ &^%!()]') { throw "Root '$Root' contains a space or cmd metacharacter; pick a plain path like C:\re\tools." }

function Say($m)  { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }

function Get-File($Url, $Out) {
    Say "download $([IO.Path]::GetFileName($Out))"
    Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing
}

# Extract an archive (.zip / .tar.gz / .7z / 7z-SFX .exe) into $Dest.
# Prefers tar.exe (ships with Windows 10+) for gzip, Expand-Archive for zip,
# and 7z.exe when present for the w64devkit 7z-SFX; falls back to running the
# SFX itself with -o.
function Expand-Tool($Archive, $Dest) {
    New-Item -ItemType Directory -Force $Dest | Out-Null
    if ($Archive -like '*.tar.gz' -or $Archive -like '*.tgz') {
        & tar.exe -xzf $Archive -C $Dest
        if ($LASTEXITCODE -ne 0) { throw "tar extraction failed for $Archive (exit $LASTEXITCODE)" }
        return
    }
    if ($Archive -like '*.zip') {
        Expand-Archive $Archive -DestinationPath $Dest -Force
        return
    }
    # .7z or 7z self-extracting .exe
    $7z = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
    if (-not $7z) {
        foreach ($p in 'C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe') {
            if (Test-Path $p) { $7z = $p; break }
        }
    }
    if ($7z) {
        & $7z x $Archive "-o$Dest" -y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7z extraction failed for $Archive (exit $LASTEXITCODE)" }
        return
    }
    if ($Archive -like '*.exe') {
        Push-Location $Dest
        try { & $Archive -y "-o$Dest" 2>&1 | Out-Null } finally { Pop-Location }
        if (-not (Get-ChildItem $Dest -Force | Select-Object -First 1)) { throw "self-extraction of $Archive produced nothing; install 7-Zip and re-run." }
        return
    }
    throw "Unsupported archive type: $Archive (install 7-Zip and re-run)."
}

# Move the single top-level directory of an extracted archive into $Dest,
# or the whole extraction if it is already flat.
function Flatten-Into($From, $Dest) {
    if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
    $kids = @(Get-ChildItem $From -Force)
    if ($kids.Count -eq 1 -and $kids[0].PSIsContainer) { Move-Item $kids[0].FullName $Dest }
    else { Move-Item $From $Dest }
}

# Resolve one asset download URL from a GitHub release.
#   $Repo   = 'owner/name'
#   $Tag    = exact tag, or $null for latest
#   $Match  = wildcard the asset name must match
function Get-GhAsset($Repo, $Tag, $Match) {
    $api = if ($Tag) { "https://api.github.com/repos/$Repo/releases/tags/$Tag" }
           else      { "https://api.github.com/repos/$Repo/releases/latest" }
    $hdr = @{ 'User-Agent' = 'rea-setup'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $hdr['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    $rel = Invoke-RestMethod -Uri $api -Headers $hdr
    $asset = $rel.assets | Where-Object { $_.name -like $Match } | Select-Object -First 1
    if (-not $asset) { throw "No asset matching '$Match' in $Repo $Tag" }
    return $asset.browser_download_url
}

function Fresh($Dir) {
    if (Test-Path $Dir) {
        if ($Force) { Remove-Item $Dir -Recurse -Force }
        else { return $false }  # already present, skip
    }
    return $true
}

New-Item -ItemType Directory -Force $Root | Out-Null
$tmp = Join-Path $env:TEMP ("rea-setup-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
Say "root: $Root"
Say "REA version: $REA_VER$(if ($ReaVersion) { ' (from -ReaVersion)' } else { ' (from package.json rea-agents pin)' })"

# ---- JDK 21 (Temurin) ---------------------------------------------------
$jdkDir = Join-Path $Root 'jdk-21'
if (Fresh $jdkDir) {
    $z = Join-Path $tmp 'jdk21.zip'
    Get-File "https://api.adoptium.net/v3/binary/latest/$JDK_MAJOR/ga/windows/x64/jdk/hotspot/normal/eclipse?project=jdk" $z
    Expand-Tool $z (Join-Path $tmp 'jdk_x')
    Flatten-Into (Join-Path $tmp 'jdk_x') $jdkDir
    Ok "jdk -> $jdkDir"
} else { Ok "jdk present (skip)" }

# ---- Ghidra 12.1.4 ------------------------------------------------------
# REA pins EXACTLY this version; rea doctor checks it. Resolve the dated asset
# from the specific release tag (NOT /latest, which now points at 12.2 and has
# no 12.1.4 asset). Override the tag with -GhidraTag if the naming ever changes.
$ghDir = Join-Path $Root "ghidra_${GHIDRA_VER}_PUBLIC"
if (Fresh $ghDir) {
    $ghTag = if ($GhidraTag) { $GhidraTag } else { "Ghidra_${GHIDRA_VER}_build" }
    try {
        $url = Get-GhAsset 'NationalSecurityAgency/ghidra' $ghTag "ghidra_${GHIDRA_VER}_PUBLIC_*.zip"
    } catch {
        throw "Could not resolve the Ghidra $GHIDRA_VER asset from tag '$ghTag'. REA requires exactly $GHIDRA_VER. Check the tag at https://github.com/NationalSecurityAgency/ghidra/releases and re-run with -GhidraTag <tag>, or download the ghidra_${GHIDRA_VER}_PUBLIC zip manually into $Root and re-run. ($($_.Exception.Message))"
    }
    $z = Join-Path $tmp 'ghidra.zip'
    Get-File $url $z
    Expand-Tool $z $Root                        # extracts ghidra_12.1.4_PUBLIC\ into $Root
    if (-not (Test-Path $ghDir)) {
        $g = Get-ChildItem $Root -Directory | Where-Object { $_.Name -like "ghidra_${GHIDRA_VER}_PUBLIC*" } | Select-Object -First 1
        if ($g) { $ghDir = $g.FullName }
    }
    Ok "ghidra -> $ghDir"
} else { Ok "ghidra present (skip)" }

# ---- objdump (portable binutils via w64devkit) --------------------------
$binDir = Join-Path $Root 'binutils'
if (Fresh $binDir) {
    # w64devkit releases are 7z self-extracting .exe files (not .zip). Extract with
    # 7z.exe when available, otherwise run the SFX with -o; only objdump.exe is
    # kept because it is a static binary with no DLL dependencies (~2 MB on disk).
    $url = Get-GhAsset 'skeeto/w64devkit' $null 'w64devkit-x64-*.exe'
    $z = Join-Path $tmp 'w64dk.7z.exe'
    Get-File $url $z
    $wkTmp = Join-Path $tmp 'w64dk_x'
    Expand-Tool $z $wkTmp
    $od = Get-ChildItem $wkTmp -Recurse -Filter 'objdump.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $od) { throw "objdump.exe not found after extracting w64devkit into $wkTmp" }
    New-Item -ItemType Directory -Force (Join-Path $binDir 'bin') | Out-Null
    Copy-Item $od.FullName (Join-Path $binDir 'bin\objdump.exe') -Force
    Ok "objdump -> $binDir\bin\objdump.exe"
} else { Ok "objdump present (skip)" }

# ---- rizin --------------------------------------------------------------
$rzDir = Join-Path $Root 'rizin'
if (Fresh $rzDir) {
    # Portable build is named rizin-windows-shared64-vX.Y.Z.zip (the exact spelling
    # is "shared64", not "share64") and nests everything under one folder.
    $url = $null
    foreach ($pat in 'rizin-windows-shared64-*.zip', 'rizin-windows-*.zip') {
        try { $url = Get-GhAsset 'rizinorg/rizin' $null $pat; break } catch { }
    }
    if (-not $url) { throw "No Rizin portable Windows zip found in rizinorg/rizin latest release; check https://github.com/rizinorg/rizin/releases/latest" }
    $z = Join-Path $tmp 'rizin.zip'
    $rzTmp = Join-Path $tmp 'rizin_x'
    Get-File $url $z
    Expand-Tool $z $rzTmp
    Flatten-Into $rzTmp $rzDir
    Ok "rizin -> $rzDir"
} else { Ok "rizin present (skip)" }
$rizinExe = Get-ChildItem $rzDir -Recurse -Filter 'rizin.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (-not $rizinExe) { throw "rizin.exe not found under $rzDir" }
Ok "rizin.exe = $rizinExe"

# ---- WABT 1.0.42 --------------------------------------------------------
$wabtDir = Join-Path $Root 'wabt'
if (Fresh $wabtDir) {
    # Windows asset is wabt-<ver>-windows-x64.tar.gz (tar.gz, not zip). tar.exe ships with Windows 10+.
    $url = Get-GhAsset 'WebAssembly/wabt' $WABT_VER "wabt-${WABT_VER}-windows-x64.tar.gz"
    $z = Join-Path $tmp 'wabt.tar.gz'
    $wTmp = Join-Path $tmp 'wabt_x'
    New-Item -ItemType Directory -Force $wTmp | Out-Null
    Get-File $url $z
    Expand-Tool $z $wTmp
    Flatten-Into $wTmp $wabtDir
    if (-not (Get-ChildItem $wabtDir -Recurse -Filter 'wasm2wat.exe' -ErrorAction SilentlyContinue)) { throw "wasm2wat.exe not found under $wabtDir" }
    Ok "wabt -> $wabtDir\bin"
} else { Ok "wabt present (skip)" }

# ---- Android: adb + apktool + jadx -------------------------------------
if (-not $SkipAndroid) {
    $ptDir = Join-Path $Root 'platform-tools'
    if (Fresh $ptDir) {
        $z = Join-Path $tmp 'pt.zip'
        Get-File 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' $z
        Expand-Archive $z -DestinationPath $Root -Force   # extracts platform-tools\
        Ok "adb -> $ptDir\adb.exe"
    } else { Ok "platform-tools present (skip)" }

    $atDir = Join-Path $Root 'apktool'
    if (Fresh $atDir) {
        New-Item -ItemType Directory -Force $atDir | Out-Null
        $url = Get-GhAsset 'iBotPeaches/Apktool' $null 'apktool_*.jar'
        Get-File $url (Join-Path $atDir 'apktool.jar')
        Get-File 'https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/windows/apktool.bat' (Join-Path $atDir 'apktool.bat')
        Ok "apktool -> $atDir"
    } else { Ok "apktool present (skip)" }

    $jxDir = Join-Path $Root 'jadx'
    $jar = Join-Path $jxDir "jadx-headless-mcp-$JADX_VER-all.jar"
    if (Fresh $jxDir) {
        New-Item -ItemType Directory -Force $jxDir | Out-Null
        Get-File "https://github.com/1013503897/jadx-headless-mcp/releases/download/v$JADX_VER/jadx-headless-mcp-$JADX_VER-all.jar" $jar
        $h = (Get-FileHash -Algorithm SHA256 $jar).Hash.ToLower()
        if ($h -ne $JADX_SHA256) { throw "JADX JAR SHA-256 mismatch: got $h expected $JADX_SHA256" }
        Ok "jadx -> $jar (sha256 ok)"
    } else { Ok "jadx present (skip)" }
}

# ---- Cutter + REA bridge plugin (Windows supported by REA 6.7.0) ---------
# REA drives an already-running Cutter through its own Python plugin
# (bridge/cutter/rea_bridge.py, shipped in the rea-agents package). The plugin
# must live in Cutter's user plugin dir; the bridge descriptor dir defaults to
# %LOCALAPPDATA% so no REA env var is needed.
if (-not $SkipCutter) {
    $ctDir = Join-Path $Root 'cutter'
    if (Fresh $ctDir) {
        $url = Get-GhAsset 'rizinorg/cutter' $null 'Cutter-*-Windows-x86_64.zip'
        $z = Join-Path $tmp 'cutter.zip'
        $ctTmp = Join-Path $tmp 'cutter_x'
        Get-File $url $z
        Expand-Tool $z $ctTmp
        Flatten-Into $ctTmp $ctDir
        Ok "cutter -> $ctDir"
    } else { Ok "cutter present (skip)" }
    $cutterExe = Get-ChildItem $ctDir -Recurse -Filter 'cutter.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if (-not $cutterExe) { throw "cutter.exe not found under $ctDir" }
    Ok "cutter.exe = $cutterExe"

    # rea_bridge.py from the pinned rea-agents npm tarball (matches the REA version DSH runs)
    $plugDir = Join-Path $env:APPDATA 'rizin\cutter\plugins\python'
    $plugFile = Join-Path $plugDir 'rea_bridge.py'
    if ($Force -or -not (Test-Path $plugFile)) {
        $tgz = Join-Path $tmp 'rea.tgz'
        $rTmp = Join-Path $tmp 'rea_x'
        New-Item -ItemType Directory -Force $rTmp | Out-Null
        Get-File "https://registry.npmjs.org/rea-agents/-/rea-agents-$REA_VER.tgz" $tgz
        & tar.exe -xzf $tgz -C $rTmp package/bridge/cutter/rea_bridge.py
        if ($LASTEXITCODE -ne 0) { throw "could not extract rea_bridge.py from rea-agents $REA_VER (exit $LASTEXITCODE)" }
        New-Item -ItemType Directory -Force $plugDir | Out-Null
        Copy-Item (Join-Path $rTmp 'package\bridge\cutter\rea_bridge.py') $plugFile -Force
        Ok "REA Cutter bridge -> $plugFile (rea-agents $REA_VER)"
    } else { Ok "REA Cutter bridge present (skip; -Force to refresh after a REA update)" }
}

# ---- IDA config scaffold ------------------------------------------------
if (-not $SkipIda) {
    $idaJson = Join-Path $Root 'ida-mcp.json'
    if (-not (Test-Path $idaJson)) {
        @'
{
  "command": "idalib-mcp",
  "args": ["--stdio", "--max-workers", "1"],
  "mode": "headless",
  "env": { "IDADIR": "C:\\Program Files\\IDA Professional 9.3" }
}
'@ | Set-Content -Path $idaJson -Encoding UTF8
        Ok "scaffolded $idaJson (edit IDADIR / install ida-pro-mcp separately)"
    } else { Ok "ida-mcp.json present (skip)" }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---- emit the dsh-rea config block --------------------------------------
$ghName = Split-Path $ghDir -Leaf
$cfg = @"
- id: dsh-rea
  config:
    exposure: lazy
    toolCallTimeoutMs: 600000
    env:
      REA_ANALYSIS_PROVIDER: ghidra
      JAVA_HOME: '$jdkDir'
      GHIDRA_INSTALL_DIR: '$Root\$ghName'
      REA_OBJDUMP_COMMAND: '$Root\binutils\bin\objdump.exe'
      REA_RIZIN_COMMAND: '$rizinExe'
      REA_WABT_BIN_DIRECTORY: '$Root\wabt\bin'

"@
if (-not $SkipAndroid) { $cfg += "      REA_JADX_MCP_JAR: '$Root\jadx\jadx-headless-mcp-$JADX_VER-all.jar'`n" }
if (-not $SkipIda)     { $cfg += "      REA_IDA_MCP_CONFIG: '$Root\ida-mcp.json'`n" }
$pathParts = @("$jdkDir\bin")
if (-not $SkipAndroid) { $pathParts += @("$Root\platform-tools", "$Root\apktool") }
$pathParts += @("$Root\wabt\bin", 'C:\Windows\System32', 'C:\Windows')
$cfg += "      PATH: '$($pathParts -join ';')'`n"

$cfgFile = Join-Path $Root 'dsh-rea.config.yml'
$cfg | Set-Content -Path $cfgFile -Encoding UTF8

# ---- optional REA CLI for doctor ---------------------------------------
if ($InstallReaCli) {
    Say "npm i -g $REA_PKG"
    & npm install --global $REA_PKG
    $env:JAVA_HOME          = $jdkDir
    $env:GHIDRA_INSTALL_DIR = "$Root\$ghName"
    $env:REA_ANALYSIS_PROVIDER = 'ghidra'
    Say 'rea doctor --json'
    & rea doctor --json
}

Write-Host ""
Say "done. Tools under $Root"
Say "Paste this block into your dsh-rea plugin config (also saved to $cfgFile):"
Write-Host ""
Write-Host $cfg
Warn "Not handled here (by design): IDA Pro itself + ida-pro-mcp (licensed, separate install); JEB (set REA_JEB_MCP_URL); Chrome (uses existing install); Kuna (caller-supplied, set REA_KUNA_COMMAND)."
if (-not $SkipCutter) { Warn "Cutter: REA attaches to a RUNNING Cutter with the rea_bridge plugin loaded - start $cutterExe before using the cutter tools." }
Warn "If rea doctor reports adb/apktool/wabt missing under DSH, the bridge didn't forward PATH — add those three dirs to your user PATH as a fallback."
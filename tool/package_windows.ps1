# Packages the built Windows app into a single self-extracting .exe (7-Zip SFX).
# The user downloads ONE file, double-clicks it, and the app launches (it
# extracts to a temp folder and runs media_canvas.exe — no install, no unzip).
#
# Prereqs:
#   - 7-Zip installed (provides 7z.exe + 7z.sfx).
#   - The app already built:  flutter build windows --release
#     (run tool/fetch_ytdlp.ps1 first so yt-dlp.exe gets bundled).
#
# Usage:
#   pwsh tool/package_windows.ps1                 # version read from pubspec.yaml
#   pwsh tool/package_windows.ps1 -Version 1.0.3  # or pass it explicitly
#
# Output: release_assets/MediaCanvas-v<version>.exe
param(
  [string]$Version
)
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$releaseDir = Join-Path $root 'build\windows\x64\runner\Release'
$outDir = Join-Path $root 'release_assets'

# --- Resolve the version from pubspec.yaml when not supplied -----------------
if (-not $Version) {
  $line = Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)'
  if (-not $line) { throw 'Could not read version from pubspec.yaml; pass -Version.' }
  $Version = $line.Matches[0].Groups[1].Value
}
Write-Host "Packaging Media Canvas v$Version"

# --- Locate 7-Zip ------------------------------------------------------------
$sevenZip = @(
  'C:\Program Files\7-Zip\7z.exe',
  'C:\Program Files (x86)\7-Zip\7z.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $sevenZip) {
  $cmd = Get-Command 7z -ErrorAction SilentlyContinue
  if ($cmd) { $sevenZip = $cmd.Source }
}
if (-not $sevenZip) { throw '7-Zip (7z.exe) not found. Install 7-Zip to package the single exe.' }
$sfx = Join-Path (Split-Path $sevenZip) '7z.sfx'
if (-not (Test-Path $sfx)) { throw "7z.sfx not found next to 7z.exe ($sfx)." }

# --- Sanity-check the build output -------------------------------------------
$appExe = Join-Path $releaseDir 'media_canvas.exe'
if (-not (Test-Path $appExe)) {
  throw "Build not found at $releaseDir. Run: flutter build windows --release"
}
$bundledYtDlp = Join-Path $releaseDir 'data\flutter_assets\assets\bin\yt-dlp.exe'
if (-not (Test-Path $bundledYtDlp)) {
  Write-Warning 'yt-dlp.exe is NOT bundled in this build — the yt-dlp fallback will be disabled.'
  Write-Warning 'Run tool/fetch_ytdlp.ps1 then rebuild to include it.'
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("mc_pkg_" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
  $archive = Join-Path $work 'app.7z'

  # --- Compress the Release folder CONTENTS at the archive root -------------
  Write-Host 'Compressing Release folder...'
  & $sevenZip a -t7z $archive (Join-Path $releaseDir '*') -mx=7 -bso0 -bsp0
  if ($LASTEXITCODE -ne 0) { throw "7z compression failed ($LASTEXITCODE)." }

  # --- SFX config: auto-extract to temp and run the app --------------------
  # Must be CRLF; RunProgram launches media_canvas.exe after extraction.
  $config = Join-Path $work 'config.txt'
  $cfg = ";!@Install@!UTF-8!`r`n" +
         "Title=`"Media Canvas v$Version`"`r`n" +
         "RunProgram=`"media_canvas.exe`"`r`n" +
         ";!@InstallEnd@!`r`n"
  [System.IO.File]::WriteAllText($config, $cfg, (New-Object System.Text.UTF8Encoding($false)))

  # --- Concatenate: 7z.sfx + config + archive = single exe -----------------
  $outExe = Join-Path $outDir "MediaCanvas-v$Version.exe"
  Write-Host "Building $outExe"
  $fs = [System.IO.File]::Open($outExe, [System.IO.FileMode]::Create)
  try {
    foreach ($part in @($sfx, $config, $archive)) {
      $bytes = [System.IO.File]::ReadAllBytes($part)
      $fs.Write($bytes, 0, $bytes.Length)
    }
  } finally { $fs.Close() }

  # --- Verify: integrity + media_canvas.exe at the archive root ------------
  & $sevenZip t $outExe -bso0 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Self-extracting exe failed its integrity test.' }
  $listing = & $sevenZip l $outExe
  if (-not ($listing | Select-String -SimpleMatch 'media_canvas.exe')) {
    throw 'media_canvas.exe not found at the archive root — extraction would not launch the app.'
  }

  $sizeMB = [math]::Round((Get-Item $outExe).Length / 1MB, 1)
  Write-Host "OK: $outExe ($sizeMB MB)"
  Write-Host 'Single-file build complete!'
}
finally {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

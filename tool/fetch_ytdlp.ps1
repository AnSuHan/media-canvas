# Downloads the latest yt-dlp.exe into assets/bin/ so it gets bundled with the
# app. Run once before `flutter build windows` (the binary is gitignored).
#
#   pwsh tool/fetch_ytdlp.ps1
$ErrorActionPreference = 'Stop'
$dest = Join-Path $PSScriptRoot '..\assets\bin'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$out = Join-Path $dest 'yt-dlp.exe'
$url = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
Write-Host "Downloading yt-dlp → $out"
Invoke-WebRequest -Uri $url -OutFile $out
& $out --version
Write-Host 'yt-dlp ready.'

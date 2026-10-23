param([string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist'))
$ErrorActionPreference = 'Stop'
$buildDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) '.build/windows-tray'
[void][IO.Directory]::CreateDirectory($OutputDirectory)
& (Join-Path $PSScriptRoot 'build.ps1') -OutputDirectory $buildDirectory
$archive = Join-Path $OutputDirectory 'DNS-Switcher-Windows-Tray.zip'
Compress-Archive -LiteralPath (Join-Path $buildDirectory 'DNS-Switcher.exe') -DestinationPath $archive -Force
Write-Output "Ready: $archive"

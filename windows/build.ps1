param([string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist/windows'))
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe' }
[void][IO.Directory]::CreateDirectory($OutputDirectory)
& $compiler /nologo /target:winexe /optimize+ /reference:System.Windows.Forms.dll /reference:System.Drawing.dll "/win32icon:$PSScriptRoot/AppIcon.ico" "/resource:$PSScriptRoot/AppIcon.ico,AppIcon.ico" "/resource:$PSScriptRoot/DohProbe.cs,DohProbe.cs" "/resource:$PSScriptRoot/TrayCore.ps1,TrayCore.ps1" "/resource:$PSScriptRoot/TrayBackend.ps1,TrayBackend.ps1" "/out:$OutputDirectory/DNS-Switcher.exe" (Join-Path $PSScriptRoot 'TrayApp.cs')
if ($LASTEXITCODE -ne 0) { throw 'Не удалось собрать приложение в трее.' }
Write-Output "Ready: $OutputDirectory/DNS-Switcher.exe"

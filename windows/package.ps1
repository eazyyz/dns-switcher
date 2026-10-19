param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Management,Microsoft.PowerShell.Utility,Microsoft.PowerShell.Archive
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'DNS-Switcher.bat'),[Text.Encoding]::UTF8)
$defaults = [IO.File]::ReadAllText((Join-Path $root 'lists/dns-defaults.txt'),[Text.Encoding]::UTF8).TrimEnd("`r","`n")
if ($defaults -match "(?m)^'@") { throw 'The default list cannot contain a PowerShell here-string terminator.' }
$replacement = "# DEFAULT_DNS_LIST_START`n`$defaultListText = @'`n$defaults`n'@`n# DEFAULT_DNS_LIST_END"
$pattern = '(?s)# DEFAULT_DNS_LIST_START\r?\n.*?# DEFAULT_DNS_LIST_END'
if ([regex]::Matches($source,$pattern).Count -ne 1) { throw 'Default list markers not found.' }
$source = [regex]::Replace($source,$pattern,[Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement })
$body = ($source -split '(?m)^# POWERSHELL_START\r?$',2)[1]
. ([scriptblock]::Create($body)) -LibraryOnly
Read-DnsListText $defaultListText | Out-Null
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$staging = Join-Path ([IO.Path]::GetTempPath()) ('dns-switcher-package-' + [guid]::NewGuid().ToString())
try {
    [void][IO.Directory]::CreateDirectory($staging)
    $source = $source -replace '\r?\n',"`r`n"
    [IO.File]::WriteAllText((Join-Path $staging 'DNS-Switcher.bat'),$source,[Text.UTF8Encoding]::new($false))
    $archive = Join-Path $OutputDirectory 'DNS-Switcher-Windows.zip'
    Compress-Archive -LiteralPath (Join-Path $staging 'DNS-Switcher.bat') -DestinationPath $archive -Force
    Write-Output "Ready: $archive (Windows 11, no additional downloads)"
} finally { if ([IO.Directory]::Exists($staging)) { Remove-Item -LiteralPath $staging -Recurse -Force } }

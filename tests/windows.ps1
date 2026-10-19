$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Management,Microsoft.PowerShell.Utility
$root = Split-Path $PSScriptRoot -Parent
$source = [IO.File]::ReadAllText((Join-Path $root 'windows/DNS-Switcher.bat'), [Text.Encoding]::UTF8)
$body = ($source -split '(?m)^# POWERSHELL_START\r?$',2)[1]
. ([scriptblock]::Create($body)) -LibraryOnly

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$fixtures = Get-Content -LiteralPath (Join-Path $root 'tests/dns-lists.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$count = 0
foreach ($case in $fixtures) {
    $parseError = $null
    try { $actual = @(Read-DnsListText $case.text) } catch { $parseError = $_ }
    if ($case.valid) {
        if ($parseError) { throw "$($case.name): $parseError" }
        Assert-Test ($actual.Count -eq $case.names.Count) "$($case.name): profile count"
        for ($i=0; $i -lt $actual.Count; $i++) {
            Assert-Test ($actual[$i].Name -ceq $case.names[$i]) "$($case.name): name/order"
            Assert-Test ($actual[$i].Key -eq [string]($i+2)) "$($case.name): menu numbering"
        }
    } else { Assert-Test ($null -ne $parseError) "$($case.name): invalid list was accepted" }
    $count++
}
Write-Output "PASS $count shared TXT parser fixtures (PowerShell)"

$directory = Join-Path ([IO.Path]::GetTempPath()) ('dns-switcher-tests-' + [guid]::NewGuid().ToString())
$path = Join-Path $directory 'lists/dns-user.txt'
try {
    # The BAT launcher invokes the body in a child scope, rather than dot-sourcing it.
    & {
        param($Body, $Path)
        $launchBody = $Body.Replace('if ($LibraryOnly) { return }', 'if ($LibraryOnly) { Initialize-DnsList $args[0]; return }')
        & ([scriptblock]::Create($launchBody)) -LibraryOnly $Path
    } $body $path
    Assert-Test (@(Read-DnsListFile $path).Count -eq 4) 'BAT launcher scope did not seed the default list'
    Remove-Item -LiteralPath $path
    Initialize-DnsList $path
    Assert-Test (@(Read-DnsListFile $path).Count -eq 4) 'Default list was not seeded'
    $custom = "[Custom]`nipv4=192.168.1.2`ndoh=https://dns.example/query`n"
    [IO.File]::WriteAllText($path,$custom,[Text.UTF8Encoding]::new($false))
    Initialize-DnsList $path
    Assert-Test ([IO.File]::ReadAllText($path) -ceq $custom) 'Initialization overwrote an existing user list'
    Assert-Test (@(Read-DnsListFile $path)[0].Name -ceq 'Custom') 'Custom DNS is not loaded'
    [IO.File]::WriteAllText($path,'',[Text.UTF8Encoding]::new($false))
    Initialize-DnsList $path
    Assert-Test (@(Read-DnsListFile $path).Count -eq 0) 'Empty list was replaced with defaults'
    $broken = '[invalid'
    [IO.File]::WriteAllText($path,$broken,[Text.UTF8Encoding]::new($false))
    Initialize-DnsList $path
    Assert-Test ([IO.File]::ReadAllText($path) -ceq $broken) 'Invalid list was overwritten'
    [IO.File]::WriteAllBytes($path,[byte[]]@(255,254,91,0))
    $rejected = $false
    try { Read-DnsListFile $path | Out-Null } catch { $rejected = $true }
    Assert-Test $rejected 'Invalid UTF-8 was accepted'
    $canonical = @(Read-DnsListFile (Join-Path $root 'lists/dns-defaults.txt'))
    $embedded = @(Read-DnsListText $defaultListText)
    Assert-Test (($canonical | ConvertTo-Json -Depth 5 -Compress) -ceq ($embedded | ConvertTo-Json -Depth 5 -Compress)) 'Embedded defaults do not match the shared template'
    Write-Output 'PASS defaults, editing, preservation, empty lists, invalid-list preservation, UTF-8 and template parity'
} finally {
    if ([IO.Directory]::Exists($directory)) { Remove-Item -LiteralPath $directory -Recurse -Force }
}

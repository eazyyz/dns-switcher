$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'windows/TrayCore.ps1')

# Exercise the shared transaction without touching the machine's DNS.
function Get-NetAdapter { [pscustomobject]@{ InterfaceType=6; Status='Up'; ifIndex=9; Name='Test' } }
function Get-DnsBackup { 'backup' }
function Set-DnsClientServerAddress { $script:reset = $true }
function Clear-DnsClientCache { }
function Get-DnsClientServerAddress { }
function Get-DnsClientDohServerAddress { }
function Test-ConnectionAfterSwitch { if ($script:failCheck) { throw 'Simulated connection failure' } }
function Restore-DnsBackup { param($backup,$dohBackup); if ($backup[0] -ne 'backup') { throw 'Wrong backup' }; $script:restored = $true }
$script:reset = $false
$script:restored = $false
$script:failCheck = $false
Invoke-DnsSelection '1' ([ordered]@{})
if (-not $reset -or $restored) { throw 'Automatic DNS success path failed' }
$script:failCheck = $true
$thrown = $false
try { Invoke-DnsSelection '1' ([ordered]@{}) } catch { $thrown = $true }
if (-not $thrown -or -not $restored) { throw 'Failure must restore DNS and reach the tray helper' }
Write-Output 'PASS shared automatic DNS transaction and rollback/error propagation'

$testList = Join-Path ([IO.Path]::GetTempPath()) ('dns-tray-' + [guid]::NewGuid() + '/dns-user.txt')
try {
    $names = @(& (Join-Path $root 'windows/TrayBackend.ps1') -Action list -ListPath $testList)
    if ($names.Count -ne 4) { throw 'Backend did not return four defaults' }
    foreach ($name in $names) { [void][Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($name)) }
    Write-Output 'PASS tray backend defaults and encoded profile names'
} finally {
    if (Test-Path -LiteralPath $testList) { Remove-Item -LiteralPath $testList }
    $testDirectory = Split-Path $testList -Parent
    if (Test-Path -LiteralPath $testDirectory) { Remove-Item -LiteralPath $testDirectory }
}

$profiles = @(Read-DnsListFile (Join-Path $root 'lists/dns-defaults.txt'))
$script:testAdapters = @([pscustomobject]@{ InterfaceType=6; Status='Up'; ifIndex=9 })
$script:testManual = ''
$script:testV4 = @('192.168.1.1')
$script:testV6 = @()
function Get-NetAdapter { $script:testAdapters }
function Get-DnsBackup { param($adapters); [pscustomobject]@{Manual=$script:testManual} }
function Get-DnsClientServerAddress {
    param($InterfaceIndex,$AddressFamily)
    $addresses = if ($AddressFamily -eq 'IPv4') { $script:testV4 } else { $script:testV6 }
    [pscustomobject]@{ServerAddresses=@($addresses)}
}
if ((Get-ActiveDnsName $profiles) -ne '#auto') { throw 'DHCP DNS must be automatic, regardless of router address' }
$script:testManual = '83.220.169.155,212.109.195.93'
$script:testV4 = @('83.220.169.155','212.109.195.93')
if ((Get-ActiveDnsName $profiles) -ne 'Comss.one DNS') { throw 'Active Comss profile not detected' }
$script:testV6 = @('2001:db8::1')
if ((Get-ActiveDnsName $profiles) -ne '#other') { throw 'Unexpected IPv6 must not claim profile is active' }
$script:testV4 = @($profiles[1].V4)
$script:testV6 = @($profiles[1].V6 | ForEach-Object { ([Net.IPAddress]::Parse($_)).ToString() })
if ((Get-ActiveDnsName $profiles) -ne 'DNS-AI') { throw 'Equivalent IPv6 notation must match' }
$script:testAdapters = @()
if ((Get-ActiveDnsName $profiles) -ne '#offline') { throw 'Offline detection failed' }
$script:testAdapters = @([pscustomobject]@{ InterfaceType=6; Status='Up'; ifIndex=9 },[pscustomobject]@{ InterfaceType=71; Status='Up'; ifIndex=10 })
function Get-DnsBackup { param($adapters); [pscustomobject]@{Manual=$(if($adapters[0].ifIndex -eq 9){''}else{'1.1.1.1'})} }
if ((Get-ActiveDnsName $profiles) -ne '#mixed') { throw 'Different adapter DNS must not display a shared checkmark' }
Write-Output 'PASS active profile, DHCP, IPv6 mismatch/normalization, offline and mixed adapters'

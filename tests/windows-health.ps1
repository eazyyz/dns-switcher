$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'windows/TrayCore.ps1')
$profile = [pscustomobject]@{Key='2'; Name='Test'; V4=@('192.0.2.1','192.0.2.2'); V6=@('2001:db8::1'); Doh='https://dns.example/query'}
$script:healthy = @('192.0.2.2')
$script:discovered = @('192.0.2.3')
$script:lookups = 0
function Test-DohServerAddress { param($Endpoint,$Address); return $Address -in $script:healthy }
function Get-DohHostAddresses { $script:lookups++; $script:discovered }
$selected = Select-HealthyDnsProfile $profile
if ($selected.V4.Count -ne 1 -or $selected.V4[0] -ne '192.0.2.2' -or $selected.V6.Count -ne 0) { throw 'Failed to omit dead IPv4 and unreachable IPv6' }
if ($lookups -ne 0) { throw 'Unnecessary hostname fallback' }
if ($profile.V4.Count -ne 2 -or $profile.V6.Count -ne 1) { throw 'Selection mutated the saved profile' }
$script:healthy = @('192.0.2.3')
$selected = Select-HealthyDnsProfile $profile
if ($selected.V4[0] -ne '192.0.2.3' -or $lookups -ne 1) { throw 'Verified hostname fallback failed' }
$script:healthy = @()
$script:changed = $false
function Get-NetAdapter { [pscustomobject]@{InterfaceType=6; Status='Up'; ifIndex=9} }
function Get-DnsBackup { @() }
function Set-DnsClientServerAddress { $script:changed = $true }
function Get-DnsClientDohServerAddress { $script:changed = $true }
function Restore-DnsBackup { $script:changed = $true }
$failed = $false
try { Invoke-DnsSelection '2' @{ '2'=$profile } } catch { $failed = $true }
if (-not $failed -or $changed) { throw 'Unreachable provider must fail before network/DoH changes' }
Write-Output 'PASS healthy subset, IPv6 omission, verified hostname fallback, preservation and failure before mutation'

# A filtered profile must still have a correct tray checkmark after restart.
function Get-DnsBackup { [pscustomobject]@{Manual='192.0.2.2'} }
function Get-DnsClientServerAddress { param($InterfaceIndex,$AddressFamily); [pscustomobject]@{ServerAddresses=$(if($AddressFamily -eq 'IPv4'){@('192.0.2.2')}else{@()})} }
function Get-DnsClientDohServerAddress { [pscustomobject]@{AutoUpgrade=$true;AllowFallbackToUdp=$false;DohTemplate='https://dns.example/query'} }
if ((Get-ActiveDnsName @($profile)) -ne 'Test') { throw 'Healthy subset lost its profile checkmark' }
function Get-DnsClientDohServerAddress { [pscustomobject]@{AutoUpgrade=$true;AllowFallbackToUdp=$false;DohTemplate='https://other.example/query'} }
if ((Get-ActiveDnsName @($profile)) -ne '#other') { throw 'Different provider must not match' }
Write-Output 'PASS filtered profile recognition and rejection of unrelated DoH providers'

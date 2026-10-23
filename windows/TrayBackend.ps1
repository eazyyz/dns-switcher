param([ValidateSet('list','menu','status','apply')][string]$Action, [string]$ListPath, [string]$ProfileName)
$ErrorActionPreference = 'Stop'
try {
    if (-not (Get-Command Invoke-DnsSelection -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'TrayCore.ps1')
    }
    if ($Action -eq 'apply' -and [Environment]::OSVersion.Version.Build -lt 22000) { throw 'Требуется Windows 11.' }
    Initialize-DnsList $ListPath
    if ($Action -eq 'list' -or $Action -eq 'menu') {
        $items = @(Read-DnsListFile $ListPath)
        if ($Action -eq 'menu') {
            $active = Get-ActiveDnsName $items
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($active))
        }
        foreach ($item in $items) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($item.Name)) }
    } elseif ($Action -eq 'status') {
        $adapters = @(Get-NetAdapter -Physical | Where-Object { $_.InterfaceType -in @(6,71) })
        if (-not $adapters.Count) { 'Ethernet/Wi-Fi адаптеры не найдены.' }
        foreach ($adapter in $adapters) {
            "$($adapter.Name) ($($adapter.Status))"
            foreach ($family in @('IPv4','IPv6')) {
                $servers = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily $family).ServerAddresses
                $service = if ($family -eq 'IPv4') { 'Tcpip' } else { 'Tcpip6' }
                $manual = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$service\Parameters\Interfaces\$($adapter.InterfaceGuid)").NameServer
                $mode = if ([string]::IsNullOrWhiteSpace(($manual -join ','))) { 'автоматически' } else { 'вручную' }
                "  ${family}: $mode — $($servers -join ', ')"
            }
        }
    } else {
        $profiles = [ordered]@{}
        $selection = '1'
        if ($ProfileName) {
            foreach ($item in @(Read-DnsListFile $ListPath)) {
                $profiles[$item.Key] = $item
                if ($item.Name -ceq $ProfileName) { $selection = $item.Key }
            }
            if ($selection -eq '1') { throw 'Профиль изменён или удалён. Обновите список.' }
        }
        Invoke-DnsSelection $selection $profiles
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}

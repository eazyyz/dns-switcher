@echo off
setlocal
set "DNS_SWITCHER_FILE=%~f0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:DNS_SWITCHER_FILE,[Text.Encoding]::UTF8); & ([scriptblock]::Create(($s -split '(?m)^# POWERSHELL_START\r?$',2)[1]))"
exit /b %errorlevel%
# POWERSHELL_START
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = 'DNS Switcher - Windows 11'

# Official sources, checked 2026-10-17:
# https://bezmezhau.com/ru
# https://dns-ai.ru/
# https://dns.geohide.ru:8443/ (RU region)
# https://www.comss.ru/page.php?id=7315
$profiles = @{
    '2' = @{ Name='Bezmezhau DNS'; V4=@('143.20.64.55','31.58.216.201'); V6=@(); Doh='https://dns.bezmezhau.com/dns-query' }
    '3' = @{ Name='DNS-AI'; V4=@('194.87.196.13','186.246.49.127'); V6=@('2a00:b700:5::3:62','2a0a:2b41:0:500d::53'); Doh='https://dns.dns-ai.ru/dns-query' }
    '4' = @{ Name='GeoHide (Россия)'; V4=@('193.233.112.67','193.233.112.68'); V6=@(); Doh='https://geohide.ru/dns-query' }
    '5' = @{ Name='Comss.one DNS'; V4=@('83.220.169.155','212.109.195.93'); V6=@(); Doh='https://dns.comss.one/dns-query' }
}

function Get-DnsBackup($adapters) {
    foreach ($adapter in $adapters) {
        foreach ($family in @('IPv4','IPv6')) {
            $service = if ($family -eq 'IPv4') { 'Tcpip' } else { 'Tcpip6' }
            $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$service\Parameters\Interfaces\$($adapter.InterfaceGuid)"
            $manual = [string]((Get-ItemProperty -LiteralPath $key).NameServer -join ',')
            [pscustomobject]@{ Index=$adapter.ifIndex; Family=$family; Manual=$manual }
        }
    }
}

function Restore-DnsBackup($backup, $dohBackup) {
    $failures = @()
    foreach ($entry in $dohBackup) {
        try {
            if ($null -eq $entry.Previous) {
                if (Get-DnsClientDohServerAddress -ServerAddress $entry.IP -ErrorAction SilentlyContinue) {
                    Remove-DnsClientDohServerAddress -ServerAddress $entry.IP -ErrorAction Stop
                }
            } else {
                $old = $entry.Previous
                Set-DnsClientDohServerAddress -ServerAddress $entry.IP -DohTemplate $old.DohTemplate -AutoUpgrade $old.AutoUpgrade -AllowFallbackToUdp $old.AllowFallbackToUdp
            }
        } catch { $failures += $_.Exception.Message }
    }
    foreach ($entry in $backup) {
        try {
            $inputObject = Get-DnsClientServerAddress -InterfaceIndex $entry.Index -AddressFamily $entry.Family
            if ([string]::IsNullOrWhiteSpace($entry.Manual)) {
                $inputObject | Set-DnsClientServerAddress -ResetServerAddresses
            } else {
                $addresses = @($entry.Manual -split '[,;\s]+' | Where-Object { $_ })
                $inputObject | Set-DnsClientServerAddress -ServerAddresses $addresses
            }
        } catch { $failures += "Адаптер $($entry.Index), $($entry.Family): $($_.Exception.Message)" }
    }
    Clear-DnsClientCache
    if ($failures.Count) { throw ($failures -join '; ') }
}

function Test-DohResponse([byte[]]$bytes) {
    # DNS wire response: ID 0x1234, QR=1, TC=0, RCODE=0, at least one answer.
    if ($bytes.Length -lt 12 -or $bytes[0] -ne 0x12 -or $bytes[1] -ne 0x34) { return $false }
    if (($bytes[2] -band 0x80) -eq 0 -or ($bytes[2] -band 2) -ne 0 -or ($bytes[3] -band 15) -ne 0) { return $false }
    if (($bytes[6] * 256 + $bytes[7]) -eq 0 -or $bytes[4] -ne 0 -or $bytes[5] -ne 1) { return $false }
    # Verify the echoed question instead of accepting an arbitrary HTTP 200 body.
    [byte[]]$question = @(7,101,120,97,109,112,108,101,3,99,111,109,0,0,1,0,1)
    if ($bytes.Length -lt (12 + $question.Length + 12)) { return $false }
    for ($i=0; $i -lt $question.Length; $i++) {
        if ($bytes[12+$i] -ne $question[$i]) { return $false }
    }
    return $true
}

function Test-ConnectionAfterSwitch($profile) {
    Write-Host 'Проверка DNS и подключения…' -ForegroundColor Cyan
    if ($null -ne $profile) {
        # Pin each IPv4 resolver separately: DNS bootstrap/cache cannot hide a broken server.
        $uri = [uri]$profile.Doh
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.dns')
        $queryFile = $temporary + '.query'
        try {
            [byte[]]$query = @(0x12,0x34,1,0,0,1,0,0,0,0,0,0,7,101,120,97,109,112,108,101,3,99,111,109,0,0,1,0,1)
            [IO.File]::WriteAllBytes($queryFile,$query)
            foreach ($ip in $profile.V4) {
                $result = & "$env:SystemRoot\System32\curl.exe" --silent --show-error --noproxy '*' --ssl-revoke-best-effort --connect-timeout 5 --max-time 12 --resolve "$($uri.DnsSafeHost):$($uri.Port):$ip" --header 'Content-Type: application/dns-message' --header 'Accept: application/dns-message' --data-binary "@$queryFile" --output $temporary --write-out '%{http_code}|%{content_type}' $profile.Doh 2>&1
                $code = $LASTEXITCODE
                if ($code -ne 0 -or ($result -join '') -notmatch '^200\|application/dns-message(?:;.*)?$') {
                    throw "DoH $ip не отвечает корректно: $($result -join ' ')"
                }
                if (-not (Test-DohResponse ([IO.File]::ReadAllBytes($temporary)))) { throw "DoH $ip вернул некорректный DNS-ответ." }
                Write-Host "  DoH $ip : HTTPS-запрос DNS успешен" -ForegroundColor Green
            }
        } finally {
            Remove-Item -LiteralPath $temporary,$queryFile -Force -ErrorAction SilentlyContinue
        }
    }
    $resolved = $false
    foreach ($domain in @('example.com','www.microsoft.com')) {
        try {
            $answer = @(Resolve-DnsName -Name $domain -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Where-Object { $_.IPAddress })
            if ($answer.Count -gt 0) {
                Write-Host "  Системный DNS: $domain разрешается" -ForegroundColor Green
                $resolved = $true
                break
            }
        } catch { Write-Host "  Не удалось разрешить $domain" -ForegroundColor Yellow }
    }
    if (-not $resolved) { throw 'Системный DNS не разрешил ни один проверочный домен.' }
    foreach ($url in @('https://example.com/','https://www.microsoft.com/')) {
        $response = & "$env:SystemRoot\System32\curl.exe" --silent --noproxy '*' --ssl-revoke-best-effort --head --connect-timeout 5 --max-time 10 --output NUL --write-out '%{http_code}' $url 2>&1
        if ($LASTEXITCODE -eq 0 -and ($response -join '') -match '^[234]\d\d$') {
            Write-Host '  Интернет: HTTPS-соединение успешно' -ForegroundColor Green
            return
        }
    }
    throw 'Не удалось установить HTTPS-соединение с проверочными сайтами.'
}

function Show-CurrentDns {
    Write-Host 'Текущие настройки DNS:' -ForegroundColor Cyan
    try {
        $currentAdapters = @(Get-NetAdapter -Physical | Where-Object { $_.InterfaceType -in @(6,71) })
        if ($currentAdapters.Count -eq 0) { Write-Host '  Ethernet/Wi-Fi адаптеры не найдены.' }
        foreach ($adapter in $currentAdapters) {
            $connection = if ($adapter.Status -eq 'Up') { 'подключён' } else { 'не подключён' }
            Write-Host ("  {0} ({1})" -f $adapter.Name, $connection)
            foreach ($family in @('IPv4','IPv6')) {
                $servers = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily $family).ServerAddresses)
                # Effective addresses alone cannot distinguish DHCP from manual DNS.
                $service = if ($family -eq 'IPv4') { 'Tcpip' } else { 'Tcpip6' }
                $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$service\Parameters\Interfaces\$($adapter.InterfaceGuid)"
                $settings = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
                $manual = [string]($settings.NameServer -join ',')
                $label = 'Автоматический DNS'
                if (-not [string]::IsNullOrWhiteSpace($manual)) {
                    $label = 'Другой DNS (вручную)'
                    foreach ($profileKey in @('2','3','4','5')) {
                        $expected = if ($family -eq 'IPv4') { @($profiles[$profileKey].V4) } else { @($profiles[$profileKey].V6) }
                        if ($expected.Count -gt 0 -and ($servers -join ',') -eq ($expected -join ',')) {
                            $label = $profiles[$profileKey].Name
                            break
                        }
                    }
                }
                $addresses = if ($servers.Count -gt 0) { $servers -join ', ' } else { 'серверы не назначены' }
                $encrypted = 0
                foreach ($ip in $servers) {
                    $doh = Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue
                    if ($doh -and $doh.AutoUpgrade -and $doh.DohTemplate) { $encrypted++ }
                }
                $encryption = if ($servers.Count -eq 0) { 'DNS не назначен' }
                    elseif ($encrypted -eq $servers.Count) { 'DoH включён' }
                    elseif ($encrypted -gt 0) { 'DoH включён частично' }
                    else { 'DoH не настроен' }
                if ($servers.Count -eq 0) { $label = 'Нет DNS-серверов' }
                Write-Host ("    {0}: {1} • {2}" -f $family, $label, $encryption)
                if ($servers.Count -gt 0) { Write-Host "      $addresses" }
            }
        }
    } catch {
        Write-Host ("  Не удалось прочитать настройки DNS: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
    Write-Host ''
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $admin = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) {
        # Pass the path as Base64 so spaces, apostrophes and CMD metacharacters are safe.
        $encodedPath = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($env:DNS_SWITCHER_FILE))
        $bootstrap = '$env:DNS_SWITCHER_FILE=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String("' + $encodedPath + '")); $s=[IO.File]::ReadAllText($env:DNS_SWITCHER_FILE,[Text.Encoding]::UTF8); & ([scriptblock]::Create(($s -split ''(?m)^# POWERSHELL_START\r?$'',2)[1]))'
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
        $child = Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encodedCommand) -Wait -PassThru
        exit $child.ExitCode
    }
    if ([Environment]::OSVersion.Version.Build -lt 22000) { throw 'Для этого файла требуется Windows 11.' }

    while ($true) {
        Clear-Host
        Show-CurrentDns
        Write-Host 'Выберите DNS:' -ForegroundColor Cyan
        Write-Host '  1 — Автоматический DNS (IPv4 и IPv6)'
        Write-Host '  2 — Bezmezhau DNS'
        Write-Host '  3 — DNS-AI'
        Write-Host '  4 — GeoHide (Россия)'
        Write-Host '  5 — Comss.one DNS     0 — Выход'
        Write-Host ''
        Write-Host 'Применяется ко всем физическим Ethernet/Wi-Fi адаптерам, включая отключённые.'
        Write-Host 'DoH выше — настройка Windows; доступность проверяется после смены.'
        $selection = Read-Host 'Выбор (0–5)'
        if ($selection -eq '0') { exit 0 }
        if ($selection -notin @('1','2','3','4','5')) { continue }

        $backup = @()
        $dohBackup = @()
        $changed = $false
        try {
            $adapters = @(Get-NetAdapter -Physical | Where-Object { $_.InterfaceType -in @(6,71) })
            if ($adapters.Count -eq 0) { throw 'Не найдены физические Ethernet/Wi-Fi адаптеры.' }
            if (@($adapters | Where-Object { $_.Status -eq 'Up' }).Count -eq 0) { throw 'Нет подключённого Ethernet/Wi-Fi адаптера для проверки. Настройки не изменены.' }
            $backup = @(Get-DnsBackup $adapters)
            $profile = $null
            if ($selection -ne '1') {
                $profile = $profiles[$selection]
                # Register encrypted DNS before changing adapters. No plaintext fallback.
                foreach ($ip in @($profile.V4) + @($profile.V6)) {
                    $existing = Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue
                    $dohBackup += [pscustomobject]@{ IP=$ip; Previous=$existing }
                    $changed = $true
                    $params = @{ ServerAddress=$ip; DohTemplate=$profile.Doh; AllowFallbackToUdp=$false; AutoUpgrade=$true; ErrorAction='Stop' }
                    if ($existing) { Set-DnsClientDohServerAddress @params }
                    else { Add-DnsClientDohServerAddress @params }
                }
            }
            foreach ($adapter in $adapters) {
                $changed = $true
                Write-Host ("Настройка: {0}" -f $adapter.Name)
                if ($selection -eq '1') {
                    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses
                } else {
                    Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 |
                        Set-DnsClientServerAddress -ServerAddresses $profile.V4
                    if ($profile.V6.Count -gt 0) {
                        Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv6 |
                            Set-DnsClientServerAddress -ServerAddresses $profile.V6
                    } else {
                        # No published IPv6 DNS: clear its DNS list without disabling IPv6.
                        $result = & "$env:SystemRoot\System32\netsh.exe" interface ipv6 set dnsservers "name=$($adapter.ifIndex)" source=static address=none validate=no 2>&1
                        if ($LASTEXITCODE -ne 0) { throw ($result -join [Environment]::NewLine) }
                    }
                }
            }
            Clear-DnsClientCache
            Test-ConnectionAfterSwitch $profile
            if ($selection -eq '1') { Write-Host 'Готово: DNS получается автоматически из настроек сети.' -ForegroundColor Green }
            else { Write-Host ("Готово: {0}. DNS через HTTPS, без перехода на открытый DNS." -f $profile.Name) -ForegroundColor Green }
            Get-DnsClientServerAddress -InterfaceIndex $adapters.ifIndex |
                Format-Table InterfaceAlias,AddressFamily,ServerAddresses -AutoSize | Out-Host
            Write-Host 'Если браузер использует собственный защищённый DNS или включён VPN, он может обходить эти настройки.'
        } catch {
            Write-Host ("Ошибка: {0}" -f $_.Exception.Message) -ForegroundColor Red
            if ($changed) {
                try {
                    Restore-DnsBackup $backup $dohBackup
                    Write-Host 'Откат выполнен: восстановлены предыдущие DNS и настройки DoH.' -ForegroundColor Yellow
                } catch {
                    Write-Host ("Не удалось полностью выполнить откат: {0}" -f $_.Exception.Message) -ForegroundColor Red
                    Write-Host 'Выберите 1 для возврата автоматического DNS.'
                }
            }
        }
        [void](Read-Host 'Нажмите Enter, чтобы вернуться в меню')
    }
} catch {
    Write-Host ("Ошибка запуска: {0}" -f $_.Exception.Message) -ForegroundColor Red
    [void](Read-Host 'Нажмите Enter для выхода')
    exit 1
}


param([switch]$LibraryOnly)

function Get-ActiveDnsName($Profiles) {
    $adapters = @(Get-NetAdapter -Physical | Where-Object { $_.InterfaceType -in @(6,71) -and $_.Status -eq 'Up' })
    if (-not $adapters.Count) { return '#offline' }
    $states = foreach ($adapter in $adapters) {
        $backup = @(Get-DnsBackup @($adapter))
        if (@($backup | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Manual) }).Count -eq 0) { '#auto'; continue }
        $v4 = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses)
        $v6 = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv6).ServerAddresses)
        $match = '#other'
        foreach ($profile in $Profiles) {
            $actual = @($v4 + $v6 | ForEach-Object { ([Net.IPAddress]::Parse($_)).ToString() }) -join ','
            $expected = @(@($profile.V4) + @($profile.V6) | ForEach-Object { ([Net.IPAddress]::Parse($_)).ToString() }) -join ','
            if ($actual -ceq $expected) { $match = $profile.Name; break }
            # A healthy subset or a verified replacement from the same DoH host
            # is still this provider. Every configured address must use its DoH.
            if ($v4.Count -gt 0) {
                $sameProvider = $true
                foreach ($address in @($v4) + @($v6)) {
                    $doh = Get-DnsClientDohServerAddress -ServerAddress $address -ErrorAction SilentlyContinue
                    if (-not $doh -or -not $doh.AutoUpgrade -or $doh.AllowFallbackToUdp -or $doh.DohTemplate -cne $profile.Doh) { $sameProvider = $false; break }
                }
                if ($sameProvider) { $match = $profile.Name; break }
            }
        }
        $match
    }
    $unique = @($states | Select-Object -Unique)
    if ($unique.Count -eq 1) { return $unique[0] }
    return '#mixed'
}
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# DEFAULT_DNS_LIST_START
$defaultListText = @'
# Каждая секция [Название] — отдельный DNS; адреса разделяются запятыми.
# ipv4 и doh обязательны, ipv6 можно оставить пустым. Любую секцию можно изменить или удалить.

[Bezmezhau DNS]
ipv4=181.215.40.49,31.58.216.201
ipv6=
doh=https://dns.bezmezhau.com/dns-query

[DNS-AI]
ipv4=194.87.196.13,45.151.102.219
ipv6=2a00:b700:5::3:62,2a12:5940:d4ef::219
doh=https://dns.dns-ai.ru/dns-query

[GeoHide (Россия)]
ipv4=37.230.192.51
ipv6=
doh=https://geohide.ru/dns-query

[Comss.one DNS]
ipv4=83.220.169.155,212.109.195.93
ipv6=
doh=https://dns.comss.one/dns-query
'@
# DEFAULT_DNS_LIST_END

function ConvertTo-DnsAddresses([string]$Value, [int]$Family) {
    if ([string]::IsNullOrEmpty($Value)) { return }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($part in $Value.Split(',')) {
        $address = $part.Trim()
        $parsed = $null
        if (-not $address -or $address.Contains('%') -or -not [Net.IPAddress]::TryParse($address, [ref]$parsed)) {
            throw 'Неверный IP-адрес в списке DNS.'
        }
        if ($Family -eq 4) {
            if ($address -notmatch '\A(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\z' -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Неверный IPv4-адрес.' }
        } elseif ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetworkV6) { throw 'Неверный IPv6-адрес.' }
        if (-not $seen.Add([Convert]::ToBase64String($parsed.GetAddressBytes()))) { throw 'Повторяющийся IP-адрес.' }
        $address
    }
}

function New-DnsListProfile([string]$Name, [hashtable]$Fields, [string]$Key) {
    if (-not $Name -or [Text.Encoding]::UTF8.GetByteCount($Name) -gt 240 -or $Name -match '[\p{Cc}\[\]]') { throw 'Некорректное название DNS (до 240 байт UTF-8).' }
    $v4 = [string[]]@(ConvertTo-DnsAddresses $Fields['ipv4'] 4)
    $v6 = [string[]]@(ConvertTo-DnsAddresses $Fields['ipv6'] 6)
    if ($v4.Count -lt 1 -or $v4.Count -gt 8 -or $v6.Count -gt 8) { throw 'Нужен хотя бы один IPv4; не более 8 адресов каждого семейства.' }
    $endpoint = [string]$Fields['doh']
    $dnsUri = $null
    if ([Text.Encoding]::UTF8.GetByteCount($endpoint) -gt 2048 -or $endpoint -match '[\s\p{Cc}\\]' -or
        -not [Uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$dnsUri) -or
        $dnsUri.Scheme -ne 'https' -or -not $dnsUri.Host -or $dnsUri.UserInfo -or $dnsUri.Fragment -or $dnsUri.Port -lt 1 -or $dnsUri.Port -gt 65535) {
        throw 'doh должен содержать HTTPS URL без пробелов, логина, пароля или фрагмента #.'
    }
    [pscustomobject]@{ Key=$Key; Name=$Name; V4=$v4; V6=$v6; Doh=$endpoint }
}

function Read-DnsListText([AllowEmptyString()][string]$Text) {
    if ([Text.Encoding]::UTF8.GetByteCount($Text) -gt 262144) { throw 'Список DNS превышает 256 КБ.' }
    $result = [Collections.Generic.List[object]]::new()
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $name = $null
    $fields = @{}
    $sectionLine = 0
    $lines = $Text.TrimStart([char]0xfeff) -split '\r\n|\n|\r'
    # Flush the last section with a sentinel.
    for ($index=0; $index -le $lines.Length; $index++) {
        $line = if ($index -eq $lines.Length) { '[END]' } else { $lines[$index].Trim() }
        if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        if ($line.StartsWith('[')) {
            if (-not $line.EndsWith(']')) { throw "Строка $($index+1): незакрытое название [DNS]." }
            if ($null -ne $name) {
                try {
                    if ($result.Count -ge 1000) { throw 'Допускается не более 1000 DNS.' }
                    $profile = New-DnsListProfile $name $fields ([string]($result.Count+2))
                    if (-not $names.Add($name)) { throw 'Название DNS повторяется.' }
                    $result.Add($profile)
                } catch { throw "Строка ${sectionLine}: $($_.Exception.Message)" }
            }
            $name = $line.Substring(1,$line.Length-2).Trim()
            $fields = @{}
            $sectionLine = $index+1
        } else {
            $separator = $line.IndexOf('=')
            if ($null -eq $name -or $separator -lt 0) { throw "Строка $($index+1): ожидается [Название] или поле=значение." }
            $key = $line.Substring(0,$separator).Trim().ToLowerInvariant()
            if ($key -notin @('ipv4','ipv6','doh') -or $fields.ContainsKey($key)) { throw "Строка $($index+1): неизвестное или повторяющееся поле; допустимы ipv4, ipv6, doh." }
            $fields[$key] = $line.Substring($separator+1).Trim()
        }
    }
    $result.ToArray()
}

function Read-DnsListFile([string]$Path) {
    if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 262144) { throw 'Список DNS превышает 256 КБ.' }
    $encoding = [Text.UTF8Encoding]::new($false,$true)
    try { $text = $encoding.GetString([IO.File]::ReadAllBytes($Path)) }
    catch [Text.DecoderFallbackException] { throw 'Сохраните TXT в кодировке UTF-8.' }
    Read-DnsListText $text
}

function Initialize-DnsList([string]$Path) {
    if ([IO.File]::Exists($Path)) { return }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $bytes = [Text.Encoding]::UTF8.GetBytes($defaultListText)
    try {
        $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    } catch [IO.IOException] { if (-not [IO.File]::Exists($Path)) { throw } }
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
    [byte[]]$question = @(7,101,120,97,109,112,108,101,3,99,111,109,0,0,1,0,1)
    if ($bytes.Length -lt (12 + $question.Length + 12)) { return $false }
    for ($i=0; $i -lt $question.Length; $i++) {
        if ($bytes[12+$i] -ne $question[$i]) { return $false }
    }
    return $true
}

function Test-DohServerAddress([string]$Endpoint, [string]$Address) {
    if (-not ('DohProbe' -as [type])) {
        if ($script:DohProbeSource) { Add-Type -TypeDefinition $script:DohProbeSource }
        else { Add-Type -Path (Join-Path $PSScriptRoot 'DohProbe.cs') }
    }
    try {
        $bytes = [DohProbe]::Query($Endpoint, $Address)
        return (Test-DohResponse $bytes)
    } catch {
        Write-Host "  Пропущен ${Address}: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function Get-DohHostAddresses([string]$Endpoint) {
    $uri = [uri]$Endpoint
    @(Resolve-DnsName -Name $uri.DnsSafeHost -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop |
        Where-Object { $_.IPAddress -and $_.Type -eq 'A' } | Select-Object -ExpandProperty IPAddress -Unique | Select-Object -First 8)
}

function Select-HealthyDnsProfile($Profile) {
    if ($null -eq $Profile) { throw 'DNS-профиль не найден.' }
    $v4 = @($Profile.V4 | Where-Object { Test-DohServerAddress $Profile.Doh $_ })
    if (-not $v4.Count) {
        # Host resolution only supplies candidates; authenticated TLS and a DNS
        # wire response must pass before any replacement enters adapter settings.
        try { $candidates = @(Get-DohHostAddresses $Profile.Doh) } catch { $candidates = @() }
        $v4 = @($candidates | Where-Object { $_ -notin $Profile.V4 } | Where-Object { Test-DohServerAddress $Profile.Doh $_ })
    }
    if (-not $v4.Count) { throw "Нет доступных DoH-серверов $($Profile.Name). Настройки сети не изменены." }
    $v6 = @($Profile.V6 | Where-Object { Test-DohServerAddress $Profile.Doh $_ })
    [pscustomobject]@{ Key=$Profile.Key; Name=$Profile.Name; V4=[string[]]$v4; V6=[string[]]$v6; Doh=$Profile.Doh }
}

function Test-ConnectionAfterSwitch($profile) {
    Write-Host 'Проверка DNS и подключения…' -ForegroundColor Cyan
    if ($null -ne $profile) {
        foreach ($ip in @($profile.V4) + @($profile.V6)) {
            if (-not (Test-DohServerAddress $profile.Doh $ip)) { throw "DoH $ip не отвечает корректно." }
            Write-Host "  DoH $ip : HTTPS-запрос DNS успешен" -ForegroundColor Green
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
                # Effective addresses cannot distinguish DHCP from manual DNS.
                $service = if ($family -eq 'IPv4') { 'Tcpip' } else { 'Tcpip6' }
                $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$service\Parameters\Interfaces\$($adapter.InterfaceGuid)"
                $settings = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
                $manual = [string]($settings.NameServer -join ',')
                $label = 'Автоматический DNS'
                if (-not [string]::IsNullOrWhiteSpace($manual)) {
                    $label = 'Другой DNS (вручную)'
                    foreach ($profileKey in $profiles.Keys) {
                        $expected = if ($family -eq 'IPv4') { @($profiles[$profileKey].V4) } else { @($profiles[$profileKey].V6) }
                        if ($expected.Count -gt 0 -and ($servers -join ',') -eq ($expected -join ',')) {
                            $label = $profiles[$profileKey].Name
                            break
                        }
                    }
                }
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
                if ($servers.Count -gt 0) { Write-Host ('      ' + ($servers -join ', ')) }
            }
        }
    } catch {
        Write-Host ("  Не удалось прочитать настройки DNS: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
    Write-Host ''
}

function Invoke-DnsSelection($selection, $profiles) {
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
                $profile = Select-HealthyDnsProfile $profiles[$selection]
                # Register DoH before changing adapter settings.
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
                        # Clear IPv6 DNS without disabling IPv6.
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
            $switchError = $_
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
            throw $switchError
        }
}


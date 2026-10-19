import Foundation
import Darwin

private struct Recovery: Codable {
    let services: [ServiceSnapshot]
    let profile: Profile?
}

public final class Controller {
    private static let label = "com.eazyyz.dns-switcher"
    private let directory = URL(fileURLWithPath: "/Library/Application Support/DNS Switcher", isDirectory: true)
    private let daemon = URL(fileURLWithPath: "/Library/LaunchDaemons/com.eazyyz.dns-switcher.plist")
    private let fm = FileManager.default
    private var executable: URL { directory.appendingPathComponent("dns-switcher") }
    private var profileFile: URL { directory.appendingPathComponent("profile.json") }
    private var pendingFile: URL { directory.appendingPathComponent("pending.json") }
    private var readyFile: URL { directory.appendingPathComponent("ready.pid") }

    public init() {}

    private func read<T: Decodable>(_ type: T.Type, _ file: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }

    private func save<T: Encodable>(_ value: T, _ file: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else { throw SwitcherError("Не удалось защитить файл \(file.lastPathComponent).") }
    }

    private func currentProfile() throws -> Profile? {
        guard fm.fileExists(atPath: profileFile.path) else { return nil }
        let profile = try read(Profile.self, profileFile)
        try DNSList.validate(profile)
        return profile
    }

    private func prepareDirectory() throws {
        if fm.fileExists(atPath: directory.path) {
            let attrs = try fm.attributesOfItem(atPath: directory.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  attrs[.ownerAccountID] as? Int == 0,
                  (attrs[.posixPermissions] as? Int ?? 0) & 0o022 == 0 else {
                throw SwitcherError("Папка сервиса должна принадлежать root и быть защищена от записи другими пользователями.")
            }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        }
    }

    private func stopDaemon() throws {
        let result = try run("/bin/launchctl", ["bootout", "system/\(Self.label)"])
        if result.status != 0 {
            let remaining = try run("/bin/launchctl", ["print", "system/\(Self.label)"])
            guard remaining.status != 0 else { throw SwitcherError("Не удалось остановить DNS-сервис.") }
        }
    }

    private func startDaemon(_ profile: Profile) throws {
        if fm.fileExists(atPath: readyFile.path) { try fm.removeItem(at: readyFile) }
        try save(profile, profileFile)
        guard chmod(profileFile.path, 0o644) == 0 else { throw SwitcherError("Не удалось сохранить профиль сервиса.") }
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executable.path, "--proxy", profileFile.path],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 3,
            "ProcessType": "Background", "UserName": "root",
            "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: daemon, options: .atomic)
        guard chmod(daemon.path, 0o644) == 0 else { throw SwitcherError("Не удалось защитить конфигурацию сервиса.") }
        let result = try run("/bin/launchctl", ["bootstrap", "system", daemon.path])
        guard result.status == 0 else { throw SwitcherError("Не удалось запустить DNS-сервис через launchd.") }
        // Match the ready PID to launchd before probing localhost.
        for _ in 0..<6 {
            let status = try run("/bin/launchctl", ["print", "system/\(Self.label)"])
            let job = String(decoding: status.output, as: UTF8.self)
            if let ready = try? String(contentsOf: readyFile, encoding: .utf8),
               let pid = Int32(ready), pid > 0,
               job.contains("state = running"), job.contains("pid = \(pid)\n"), localProbe() { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw SwitcherError("DNS-сервис не отвечает. Возможно, локальный порт 53 уже занят.")
    }

    private func removeDaemonFiles() throws {
        for file in [daemon, profileFile, readyFile] where fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
    }

    private func installExecutable() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        guard source != executable else { return }
        let staging = directory.appendingPathComponent(UUID().uuidString)
        try fm.copyItem(at: source, to: staging)
        defer { try? fm.removeItem(at: staging) }
        guard chown(staging.path, 0, 0) == 0, chmod(staging.path, 0o755) == 0,
              rename(staging.path, executable.path) == 0 else { throw SwitcherError("Не удалось установить DNS-сервис.") }
    }

    private func localProbe() -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(53).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return false }
        let query = DNSMessage.probe
        let sent = query.withUnsafeBytes { send(fd, $0.baseAddress, query.count, 0) }
        guard sent == query.count else { return false }
        var bytes = [UInt8](repeating: 0, count: 65535)
        let count = recv(fd, &bytes, bytes.count, 0)
        return count > 0 && DNSMessage.validate(Data(bytes.prefix(max(0, count))), for: query, requireAnswer: true)
    }

    private func flush() throws {
        guard try run("/usr/bin/dscacheutil", ["-flushcache"]).status == 0,
              try run("/usr/bin/killall", ["-HUP", "mDNSResponder"]).status == 0 else {
            throw SwitcherError("Не удалось очистить системный DNS-кеш.")
        }
    }

    private func checkInternet() throws {
        var resolved = false
        for domain in ["example.com", "www.apple.com"] {
            let result = try run("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", domain], timeout: 10)
            let answer = String(decoding: result.output, as: UTF8.self)
            if result.status == 0 && (answer.contains("ip_address:") || answer.contains("ipv6_address:")) {
                resolved = true
                print("  Системный DNS: \(domain) разрешается")
                break
            }
        }
        guard resolved else { throw SwitcherError("Системный DNS не разрешил проверочные домены.") }
        for url in ["https://example.com/", "https://www.apple.com/"] {
            let result = try run("/usr/bin/curl", ["--disable", "--silent", "--noproxy", "*", "--head", "--connect-timeout", "5", "--max-time", "10", "--output", "/dev/null", "--write-out", "%{http_code}", url])
            let code = Int(String(decoding: result.output, as: UTF8.self)) ?? 0
            if result.status == 0 && (200..<500).contains(code) {
                print("  Интернет: HTTPS-соединение работает")
                return
            }
        }
        throw SwitcherError("Не удалось установить HTTPS-соединение с проверочными сайтами.")
    }

    private func withLock(_ action: () throws -> Void) throws {
        guard geteuid() == 0 else { throw SwitcherError("Для изменения DNS нужны права администратора (sudo).") }
        try prepareDirectory()
        let fd = open(directory.appendingPathComponent("operation.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SwitcherError("Не удалось открыть блокировку настроек.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw SwitcherError("DNS уже переключается в другом окне.") }
        defer { flock(fd, LOCK_UN) }
        try action()
    }

    private func recoverUnlocked() throws {
        guard fm.fileExists(atPath: pendingFile.path) else { return }
        print("Восстановление настроек после незавершённого переключения…")
        let recovery = try read(Recovery.self, pendingFile)
        // Restore network settings even if restarting the proxy fails.
        var failures: [String] = []
        func attempt(_ action: () throws -> Void) {
            do { try action() } catch { failures.append(error.localizedDescription) }
        }
        attempt { try stopDaemon() }
        if let profile = recovery.profile { attempt { try startDaemon(profile) } }
        else { attempt { try removeDaemonFiles() } }
        attempt { try NetworkSettings().restore(recovery.services) }
        attempt { try flush() }
        guard failures.isEmpty else { throw SwitcherError(failures.joined(separator: "; ")) }
        try fm.removeItem(at: pendingFile)
        print("Предыдущие DNS и настройки DoH восстановлены.")
    }

    public func apply(profile: Profile?) throws {
        if let profile = profile { try DNSList.validate(profile) }
        try withLock {
            try recoverUnlocked()
            let services = try NetworkSettings().snapshot()
            guard !services.isEmpty else { throw SwitcherError("Физические Ethernet/Wi-Fi подключения не найдены.") }
            guard services.contains(where: { $0.connected }) else { throw SwitcherError("Нет подключённого Ethernet/Wi-Fi для проверки. Настройки не изменены.") }
            if let profile = profile {
                print("Проверка каждого DoH-сервера перед переключением…")
                try DoHClient(profile: profile).check()
            }
            let previous = try currentProfile()
            // Persist rollback state before changing DNS.
            try save(Recovery(services: services, profile: previous), pendingFile)
            do {
                try stopDaemon()
                if let profile = profile {
                    try installExecutable()
                    try startDaemon(profile)
                }
                try NetworkSettings().apply(services, servers: profile == nil ? nil : ["127.0.0.1"])
                try flush()
                print("Проверка DNS и подключения…")
                if let profile = profile { try DoHClient(profile: profile).check() }
                try checkInternet()
                if profile == nil { try removeDaemonFiles() }
                try fm.removeItem(at: pendingFile)
                print(profile.map { "Готово: \($0.name). DNS через HTTPS без перехода на открытый DNS." } ?? "Готово: автоматический DNS для IPv4 и IPv6.")
            } catch {
                let failure = error
                do { try recoverUnlocked() }
                catch { throw SwitcherError("\(failure.localizedDescription) Откат не завершён: \(error.localizedDescription). Повторите выбор DNS, чтобы программа повторила автоматический откат.") }
                throw failure
            }
        }
    }

    public func status(profiles: [Profile] = []) throws {
        print("Текущие настройки DNS:")
        let services = try NetworkSettings().snapshot()
        if services.isEmpty { print("  Физические Ethernet/Wi-Fi подключения не найдены.") }
        let daemonStatus = try run("/bin/launchctl", ["print", "system/\(Self.label)"])
        let running = daemonStatus.status == 0 && String(decoding: daemonStatus.output, as: UTF8.self).contains("state = running")
        let profile = try currentProfile()
        for service in services {
            let label: String
            if service.servers.isEmpty { label = "Автоматический DNS (IPv4 и IPv6)" }
            else if service.servers == ["127.0.0.1"], let profile = profile { label = running ? "\(profile.name) • DoH-сервис работает" : "\(profile.name) • DoH-сервис не запущен" }
            else { label = profiles.first { $0.ipv4 + $0.ipv6 == service.servers }?.name ?? "Другой DNS (вручную)" }
            print("  \(service.name) [\(service.device), \(service.connected ? "подключён" : "не подключён")]")
            print("    \(label)")
            if !service.servers.isEmpty { print("    \(service.servers.joined(separator: ", "))") }
        }
        let effective = try run("/usr/sbin/scutil", ["--dns"])
        let addresses = String(decoding: effective.output, as: UTF8.self).split(separator: "\n").filter { $0.contains("nameserver[") }
        if !addresses.isEmpty {
            print("  DNS системных и дополнительных резолверов:")
            for line in Set(addresses.map { $0.trimmingCharacters(in: .whitespaces) }).sorted() { print("    \(line)") }
        }
        if fm.fileExists(atPath: pendingFile.path) { print("  Есть незавершённое переключение. При следующем выборе DNS программа сначала повторит автоматический откат.") }
        print("  VPN, профили macOS и защищённый DNS браузера могут обходить эти настройки.\n")
    }
}

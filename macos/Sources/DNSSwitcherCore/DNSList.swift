import Foundation
import Darwin

public enum DNSList {
    public static let maximumBytes = 262144

    public static func validate(_ profile: Profile) throws {
        let name = profile.name
        guard !name.isEmpty, name.utf8.count <= 240,
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              !name.contains("["), !name.contains("]") else { throw SwitcherError("Некорректное название DNS (до 240 байт UTF-8, без скобок и управляющих символов).") }
        guard (1...8).contains(profile.ipv4.count), profile.ipv6.count <= 8 else {
            throw SwitcherError("«\(name)»: нужен хотя бы один IPv4, не более 8 адресов каждого семейства.")
        }
        for (addresses, family) in [(profile.ipv4, AF_INET), (profile.ipv6, AF_INET6)] {
            var unique = Set<Data>()
            for address in addresses {
                if family == AF_INET {
                    let parts = address.split(separator: ".", omittingEmptySubsequences: false)
                    guard parts.count == 4, parts.allSatisfy({
                        !$0.isEmpty && ($0.count == 1 || !$0.hasPrefix("0")) &&
                        $0.utf8.allSatisfy { (48...57).contains($0) } && (Int($0) ?? 256) <= 255
                    }) else { throw SwitcherError("«\(name)»: неверный IPv4-адрес.") }
                }
                var storage = [UInt8](repeating: 0, count: family == AF_INET ? 4 : 16)
                let valid = address.withCString { inet_pton(family, $0, &storage) }
                guard valid == 1, !address.contains("%") else { throw SwitcherError("«\(name)»: неверный IP-адрес «\(address)».") }
                guard unique.insert(Data(storage)).inserted else { throw SwitcherError("«\(name)»: повторяющийся IP-адрес.") }
            }
        }
        let endpoint = profile.endpoint
        guard endpoint.utf8.count <= 2048,
              endpoint.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !endpoint.contains("\\"),
              let url = URLComponents(string: endpoint), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil, url.port.map({ (1...65535).contains($0) }) ?? true else {
            throw SwitcherError("«\(name)»: doh должен содержать HTTPS URL без пробелов, логина, пароля или фрагмента #.")
        }
    }

    public static func parse(_ text: String) throws -> [Profile] {
        guard text.utf8.count <= maximumBytes else { throw SwitcherError("Список DNS превышает 256 КБ.") }
        var profiles: [Profile] = []
        var names = Set<String>()
        var name: String?
        var fields: [String: String] = [:]
        var sectionLine = 0
        func finish() throws {
            guard let current = name else { return }
            guard profiles.count < 1000 else { throw SwitcherError("В списке допускается не более 1000 DNS.") }
            func addresses(_ key: String) throws -> [String] {
                guard let raw = fields[key], !raw.isEmpty else { return [] }
                let values = raw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard !values.contains("") else { throw SwitcherError("Пустой адрес в \(key).") }
                return values
            }
            do {
                let profile = Profile(key: String(profiles.count + 2), name: current,
                                      ipv4: try addresses("ipv4"), ipv6: try addresses("ipv6"),
                                      endpoint: fields["doh"] ?? "")
                try validate(profile)
                guard names.insert(current.lowercased()).inserted else { throw SwitcherError("Название DNS повторяется.") }
                profiles.append(profile)
            } catch { throw SwitcherError("Строка \(sectionLine): \(error.localizedDescription)") }
        }
        let normalized = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        for (index, raw) in normalized.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw SwitcherError("Строка \(index + 1): незакрытое название [DNS].") }
                try finish()
                name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                sectionLine = index + 1
                fields = [:]
            } else {
                guard name != nil, let separator = line.firstIndex(of: "=") else { throw SwitcherError("Строка \(index + 1): ожидается [Название] или поле=значение.") }
                let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
                guard ["ipv4", "ipv6", "doh"].contains(key), fields[key] == nil else {
                    throw SwitcherError("Строка \(index + 1): неизвестное или повторяющееся поле; допустимы ipv4, ipv6, doh.")
                }
                fields[key] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            }
        }
        try finish()
        return profiles
    }

    public static func read(_ file: URL) throws -> [Profile] {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? (maximumBytes + 1)) <= maximumBytes else {
            throw SwitcherError("Список DNS превышает 256 КБ.")
        }
        let data = try Data(contentsOf: file)
        guard let text = String(data: data, encoding: .utf8) else { throw SwitcherError("Сохраните TXT в кодировке UTF-8.") }
        return try parse(text)
    }
}

public final class DNSListStore {
    public let file: URL
    public init(file: URL? = nil) {
        self.file = file ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DNS Switcher/lists/dns-user.txt")
    }

    public func ensureExists() throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: file.path) else { return }
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try Data(DefaultDNSList.text.utf8).write(to: file, options: .withoutOverwriting) }
        catch CocoaError.fileWriteFileExists { return }
    }

    public func load() throws -> [Profile] {
        try ensureExists()
        return try DNSList.read(file)
    }
}

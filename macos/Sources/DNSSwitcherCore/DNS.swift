import Foundation

public struct SwitcherError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Profile: Codable, Equatable {
    public let key: String
    public let name: String
    public let ipv4: [String]
    public let ipv6: [String]
    public let endpoint: String
}

public enum DNSMessage {
    public static let probe = Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
                                  7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0, 0, 1, 0, 1])

    private static func word(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    // Bound compression pointers and name length to reject malformed packets.
    private static func name(_ bytes: [UInt8], _ offset: inout Int) -> [UInt8]? {
        var cursor = offset
        var result: [UInt8] = []
        var jumped = false
        var visited = Set<Int>()
        while cursor < bytes.count, visited.insert(cursor).inserted {
            let length = Int(bytes[cursor])
            if length & 0xc0 == 0xc0 {
                guard cursor + 1 < bytes.count else { return nil }
                if !jumped { offset = cursor + 2 }
                cursor = (length & 0x3f) << 8 | Int(bytes[cursor + 1])
                jumped = true
            } else {
                guard length <= 63, cursor + 1 + length <= bytes.count else { return nil }
                result.append(UInt8(length))
                if length == 0 {
                    if !jumped { offset = cursor + 1 }
                    return result
                }
                result += bytes[(cursor + 1)..<(cursor + 1 + length)].map {
                    (65...90).contains($0) ? $0 + 32 : $0
                }
                guard result.count <= 254 else { return nil }
                cursor += length + 1
                if !jumped { offset = cursor }
            }
        }
        return nil
    }

    private static func question(_ bytes: [UInt8], _ offset: inout Int) -> [UInt8]? {
        guard let labels = name(bytes, &offset), offset + 4 <= bytes.count else { return nil }
        let result = labels + bytes[offset..<(offset + 4)]
        offset += 4
        return result
    }

    public static func isQuery(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[2] & 0xf8 == 0, word(bytes, 4) == 1 else { return false }
        var offset = 12
        return question(bytes, &offset) != nil
    }

    public static func validate(_ response: Data, for query: Data, requireAnswer: Bool = false) -> Bool {
        let q = [UInt8](query), r = [UInt8](response)
        guard isQuery(query), r.count >= 12, q[0...1] == r[0...1],
              r[2] & 0x80 != 0, r[2] & 0x7a == 0, word(r, 4) == 1 else { return false }
        if requireAnswer && (r[3] & 15 != 0 || word(r, 6) == 0) { return false }
        var qi = 12, ri = 12
        guard let qq = question(q, &qi), let rq = question(r, &ri), qq == rq else { return false }
        for _ in 0..<(word(r, 6) + word(r, 8) + word(r, 10)) {
            guard name(r, &ri) != nil, ri + 10 <= r.count else { return false }
            let length = word(r, ri + 8)
            ri += 10
            guard ri + length <= r.count else { return false }
            ri += length
        }
        return ri == r.count
    }

    public static func failure(for query: Data) -> Data {
        var bytes = [UInt8](query)
        guard bytes.count >= 12 else { return Data() }
        var end = 12
        guard question(bytes, &end) != nil else { return Data() }
        bytes = Array(bytes.prefix(end))
        bytes[2] = 0x80 | (bytes[2] & 1)
        bytes[3] = 0x82 // RA, SERVFAIL
        for index in 6..<12 { bytes[index] = 0 }
        return Data(bytes)
    }

    public static func udpResponse(_ response: Data, for query: Data) -> Data {
        let q = [UInt8](query)
        guard isQuery(query) else { return Data() }
        var offset = 12
        guard question(q, &offset) != nil else { return Data() }
        let endOfQuestion = offset
        var limit = 512
        for _ in 0..<(word(q, 6) + word(q, 8) + word(q, 10)) {
            guard name(q, &offset) != nil, offset + 10 <= q.count else { break }
            let length = word(q, offset + 8)
            if word(q, offset) == 41 { limit = max(512, min(4096, word(q, offset + 2))) }
            offset += 10
            guard offset + length <= q.count else { break }
            offset += length
        }
        guard response.count > limit else { return response }
        var truncated = [UInt8](response.prefix(12))
        guard truncated.count == 12 else { return Data() }
        truncated[2] |= 2
        for index in 6..<12 { truncated[index] = 0 }
        return Data(truncated) + Data(q[12..<endOfQuestion])
    }
}

public struct CommandResult {
    public let status: Int32
    public let output: Data
}

public func run(_ executable: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval = 20) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let source = Pipe()
    process.standardInput = source
    try process.run()
    let deadline = DispatchWorkItem {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
    defer { deadline.cancel() }
    if let input = input { source.fileHandleForWriting.write(input) }
    source.fileHandleForWriting.closeFile()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus, output: data)
}

public struct DoHClient {
    public let profile: Profile
    public init(profile: Profile) { self.profile = profile }

    public func query(_ data: Data, server: String) throws -> Data {
        guard let url = URL(string: profile.endpoint), url.scheme?.lowercased() == "https", let host = url.host,
              profile.ipv4.contains(server) else { throw SwitcherError("Некорректный DoH-профиль.") }
        let response = try run("/usr/bin/curl", [
            "--disable", "--silent", "--noproxy", "*", "--proto", "=https", "--connect-timeout", "3", "--max-time", "4",
            "--resolve", "\(host):\(url.port ?? 443):\(server)", "--max-filesize", "65535",
            "--header", "Content-Type: application/dns-message", "--header", "Accept: application/dns-message",
            "--data-binary", "@-", "--write-out", "\n%{http_code}|%{content_type}", profile.endpoint
        ], input: data)
        guard response.status == 0, let split = response.output.lastIndex(of: 10) else {
            throw SwitcherError("DoH \(server): HTTPS-запрос не выполнен.")
        }
        let metadata = String(decoding: response.output[(split + 1)...], as: UTF8.self)
        let parts = metadata.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, parts[0] == "200",
              parts[1].split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/dns-message" else {
            throw SwitcherError("DoH \(server): неверный HTTP-ответ.")
        }
        let body = Data(response.output[..<split])
        guard DNSMessage.validate(body, for: data) else { throw SwitcherError("DoH \(server): некорректный DNS-ответ.") }
        return body
    }

    public func resolve(_ data: Data) -> Data {
        let servers = Bool.random() ? profile.ipv4 : profile.ipv4.reversed()
        for server in servers {
            if let result = try? query(data, server: server) { return result }
        }
        return DNSMessage.failure(for: data)
    }

    public func check() throws {
        for server in profile.ipv4 {
            let result = try query(DNSMessage.probe, server: server)
            guard DNSMessage.validate(result, for: DNSMessage.probe, requireAnswer: true) else {
                throw SwitcherError("DoH \(server): нет ответа на проверочный запрос.")
            }
            print("  DoH \(server): DNS через HTTPS работает")
        }
    }
}

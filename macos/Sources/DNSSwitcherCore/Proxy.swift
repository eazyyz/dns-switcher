import Foundation
import Darwin

public final class DNSProxy {
    private let resolve: (Data) -> Data
    public private(set) var port: UInt16
    private let capacity = DispatchSemaphore(value: 24)
    private let workers = DispatchQueue(label: "dns-switcher.requests", attributes: .concurrent)

    public init(profile: Profile, port: UInt16 = 53, resolver: ((Data) -> Data)? = nil) {
        let client = DoHClient(profile: profile)
        resolve = resolver ?? { client.resolve($0) }
        self.port = port
    }

    private func listener(_ type: Int32) throws -> Int32 {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { throw SwitcherError("Не удалось создать DNS-сокет.") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var yes: Int32 = 1
        // UDP exclusivity prevents queries reaching another local resolver.
        if type == SOCK_STREAM { setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            close(fd)
            throw SwitcherError("Порт 127.0.0.1:\(port) занят или недоступен.")
        }
        return fd
    }

    public func start() throws {
        signal(SIGPIPE, SIG_IGN)
        let udp = try listener(SOCK_DGRAM)
        var listeners = [udp]
        do {
            if port == 0 {
                var address = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let result = withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(udp, $0, &length) }
                }
                guard result == 0 else { throw SwitcherError("Не удалось определить тестовый порт.") }
                port = UInt16(bigEndian: address.sin_port)
            }
            let tcp = try listener(SOCK_STREAM)
            listeners.append(tcp)
            guard listen(tcp, 32) == 0 else { throw SwitcherError("Не удалось запустить TCP DNS.") }
            DispatchQueue.global().async { self.udpLoop(udp) }
            DispatchQueue.global().async { self.tcpLoop(tcp) }
        } catch {
            listeners.forEach { close($0) }
            throw error
        }
    }

    private func udpLoop(_ fd: Int32) {
        while true {
            var bytes = [UInt8](repeating: 0, count: 65535)
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &bytes, bytes.count, 0, $0, &length) }
            }
            if count < 0 { if errno == EINTR { continue }; return }
            let query = Data(bytes.prefix(count))
            guard DNSMessage.isQuery(query) else { continue }
            guard capacity.wait(timeout: .now()) == .success else {
                sendUDP(DNSMessage.failure(for: query), fd, peer)
                continue
            }
            let target = peer
            workers.async {
                defer { self.capacity.signal() }
                self.sendUDP(DNSMessage.udpResponse(self.resolve(query), for: query), fd, target)
            }
        }
    }

    private func sendUDP(_ data: Data, _ fd: Int32, _ target: sockaddr_in) {
        var peer = target
        data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func tcpLoop(_ fd: Int32) {
        while true {
            let connection = accept(fd, nil, nil)
            if connection < 0 { if errno == EINTR { continue }; return }
            guard capacity.wait(timeout: .now()) == .success else { close(connection); continue }
            workers.async {
                defer { close(connection); self.capacity.signal() }
                var timeout = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                for _ in 0..<100 {
                    guard let header = Self.read(connection, count: 2) else { return }
                    let length = Int(header[0]) << 8 | Int(header[1])
                    guard length >= 12, let query = Self.read(connection, count: length), DNSMessage.isQuery(query) else { return }
                    let response = self.resolve(query)
                    let frame = Data([UInt8(response.count >> 8), UInt8(response.count & 255)]) + response
                    guard Self.write(connection, data: frame) else { return }
                }
            }
        }
    }

    private static func read(_ fd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        let success = data.withUnsafeMutableBytes { bytes -> Bool in
            var offset = 0
            while offset < count {
                let n = recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
        return success ? data : nil
    }

    private static func write(_ fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let n = send(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }
}

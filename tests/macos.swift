import Foundation
import Darwin
import SystemConfiguration
@testable import DNSSwitcherCore

let defaultProfiles = try DNSList.parse(DefaultDNSList.text)

func sameSnapshot(_ lhs: ServiceSnapshot, _ rhs: ServiceSnapshot) -> Bool {
    guard lhs.id == rhs.id, lhs.name == rhs.name, lhs.device == rhs.device,
          lhs.connected == rhs.connected, lhs.hadDNS == rhs.hadDNS, lhs.dnsEnabled == rhs.dnsEnabled else { return false }
    if lhs.configuration == rhs.configuration { return true }
    guard let left = lhs.configuration, let right = rhs.configuration,
          let a = try? PropertyListSerialization.propertyList(from: left, format: nil) as? NSDictionary,
          let b = try? PropertyListSerialization.propertyList(from: right, format: nil) as? NSDictionary else { return false }
    // Binary plist key ordering can change after serialization.
    return a.isEqual(b)
}

var passed = 0
var failed = 0
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw SwitcherError(message) }
}
func test(_ name: String, _ body: () throws -> Void) {
    do { try body(); passed += 1; print("PASS \(name)") }
    catch { failed += 1; print("FAIL \(name): \(error.localizedDescription)") }
}
func answer(_ query: Data = DNSMessage.probe) -> Data {
    var bytes = [UInt8](query)
    bytes[2] = 0x81; bytes[3] = 0x80; bytes[7] = 1
    return Data(bytes + [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34])
}

test("shared TXT parser fixtures, editing, removal and dynamic numbering") {
    struct Fixture: Decodable {
        let name: String
        let text: String
        let valid: Bool
        let names: [String]?
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: "tests/dns-lists.json"))
    let cases = try JSONDecoder().decode([Fixture].self, from: data)
    for fixture in cases {
        let result: Result<[Profile], Error> = Result { try DNSList.parse(fixture.text) }
        switch result {
        case .success(let profiles):
            try expect(fixture.valid, "\(fixture.name): invalid list was accepted")
            try expect(profiles.map { $0.name } == fixture.names, "\(fixture.name): name/order")
            try expect(profiles.map { $0.key } == profiles.indices.map { String($0 + 2) }, "menu numbering")
        case .failure(let error):
            try expect(!fixture.valid, "\(fixture.name): \(error.localizedDescription)")
        }
    }
    try expect(try DNSList.read(URL(fileURLWithPath: "lists/dns-defaults.txt")) == defaultProfiles, "embedded template mismatch")
}

test("user list initialization never overwrites edits or an intentionally empty list") {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = DNSListStore(file: folder.appendingPathComponent("lists/dns-user.txt"))
    try expect(try store.load() == defaultProfiles, "initial defaults")
    let custom = "[Мой DNS]\nipv4=192.168.1.2\ndoh=https://dns.example/query\n"
    try Data(custom.utf8).write(to: store.file)
    try expect(try store.load().map { $0.name } == ["Мой DNS"], "edits were lost")
    try store.ensureExists()
    try expect(try String(contentsOf: store.file, encoding: .utf8) == custom, "update overwrote edits")
    try Data().write(to: store.file)
    try expect(try store.load().isEmpty, "empty list was reseeded")
    try Data("[broken".utf8).write(to: store.file)
    try store.ensureExists()
    try expect(try String(contentsOf: store.file, encoding: .utf8) == "[broken", "invalid list was overwritten")
    try Data([255, 254, 91, 0]).write(to: store.file)
    do { _ = try store.load(); throw SwitcherError("invalid UTF8 accepted") }
    catch let error as SwitcherError where error.message == "invalid UTF8 accepted" { throw error }
    catch {}
}

test("all four Windows profiles and IPv6 addresses are preserved") {
    try expect(defaultProfiles.map { $0.key } == ["2", "3", "4", "5"], "profile keys")
    try expect(defaultProfiles.allSatisfy { $0.ipv4.count == 2 && $0.endpoint.hasPrefix("https://") }, "endpoints")
    try expect(defaultProfiles[1].ipv6 == ["2a00:b700:5::3:62", "2a0a:2b41:0:500d::53"], "IPv6")
    let data = try JSONEncoder().encode(defaultProfiles)
    let decoded = try JSONDecoder().decode([Profile].self, from: data)
    try expect(decoded == defaultProfiles, "profile round trip")
}
test("valid DNS response and compressed answer names") {
    try expect(DNSMessage.isQuery(DNSMessage.probe), "query rejected")
    try expect(DNSMessage.validate(answer(), for: DNSMessage.probe, requireAnswer: true), "answer rejected")
}
test("NXDOMAIN is forwarded but fails the connectivity probe") {
    var bytes = [UInt8](DNSMessage.probe)
    bytes[2] = 0x81; bytes[3] = 0x83
    try expect(DNSMessage.validate(Data(bytes), for: DNSMessage.probe), "NXDOMAIN rejected")
    try expect(!DNSMessage.validate(Data(bytes), for: DNSMessage.probe, requireAnswer: true), "false probe success")
}
test("HTML, mismatched IDs, questions, truncation and corrupt records are rejected") {
    try expect(!DNSMessage.validate(Data("<html>200 OK</html>".utf8), for: DNSMessage.probe), "HTML accepted")
    for index in [0, 1, 4, 5, 13, 25, 27] {
        var changed = answer(); changed[index] ^= 1
        try expect(!DNSMessage.validate(changed, for: DNSMessage.probe), "mutation accepted at \(index)")
    }
    var truncated = answer(); truncated[2] |= 2
    try expect(!DNSMessage.validate(truncated, for: DNSMessage.probe), "TC accepted")
    for count in 0..<answer().count {
        try expect(!DNSMessage.validate(answer().prefix(count), for: DNSMessage.probe), "short message accepted")
    }
    var invalidLength = answer(); invalidLength[40] = 255
    try expect(!DNSMessage.validate(invalidLength, for: DNSMessage.probe), "bad RDLENGTH")
    try expect(!DNSMessage.validate(answer() + Data([0]), for: DNSMessage.probe), "trailing junk")
}
test("compression loops and malformed query labels are rejected") {
    var bytes = [UInt8](DNSMessage.probe)
    bytes[12] = 0xc0; bytes[13] = 0x0c
    try expect(!DNSMessage.isQuery(Data(bytes)), "compression loop")
    bytes[12] = 64
    try expect(!DNSMessage.isQuery(Data(bytes)), "oversized label")
    bytes[12] = 0xff; bytes[13] = 0xff
    try expect(!DNSMessage.isQuery(Data(bytes)), "out of bounds pointer")
    try expect(!DNSMessage.isQuery(answer()), "response treated as query")
}
test("failed upstream returns a valid SERVFAIL with the original question") {
    let failure = DNSMessage.failure(for: DNSMessage.probe)
    try expect(DNSMessage.validate(failure, for: DNSMessage.probe), "invalid SERVFAIL")
    try expect(failure[3] & 15 == 2, "wrong rcode")
    try expect(DNSMessage.failure(for: Data([1, 2])).isEmpty, "short query")
}
test("large UDP answers request TCP retry and respect EDNS buffer size") {
    var bytes = [UInt8](DNSMessage.probe)
    bytes[2] = 0x81; bytes[3] = 0x80; bytes[7] = 1
    let large = Data(bytes + [0xc0, 0x0c, 0, 16, 0, 1, 0, 0, 0, 60, 2, 88] + [UInt8](repeating: 0, count: 600))
    try expect(DNSMessage.validate(large, for: DNSMessage.probe), "large fixture")
    let truncated = DNSMessage.udpResponse(large, for: DNSMessage.probe)
    try expect(truncated.count == DNSMessage.probe.count && truncated[2] & 2 != 0, "missing TCP retry flag")
    var edns = [UInt8](DNSMessage.probe)
    edns[11] = 1
    edns += [0, 0, 41, 4, 208, 0, 0, 0, 0, 0, 0] // OPT, UDP payload size 1232.
    try expect(DNSMessage.udpResponse(large, for: Data(edns)) == large, "EDNS size not respected")
}
test("malformed packet fuzzing stays bounded") {
    var state: UInt64 = 42
    for length in 0..<512 {
        var bytes: [UInt8] = []
        for _ in 0..<length {
            state = state &* 6364136223846793005 &+ 1
            bytes.append(UInt8(truncatingIfNeeded: state >> 32))
        }
        _ = DNSMessage.isQuery(Data(bytes))
        _ = DNSMessage.validate(Data(bytes), for: DNSMessage.probe)
    }
}
test("child process deadline prevents hung system DNS checks") {
    let start = Date()
    let result = try run("/bin/sleep", ["5"], timeout: 0.1)
    try expect(result.status != 0 && Date().timeIntervalSince(start) < 3, "timeout did not terminate process")
}
test("interactive child keeps the foreground process group and reports its exit code") {
    let pgid = getpgrp()
    let script = "child_group=$(/bin/ps -o pgid= -p $$); [ \"$child_group\" -eq \(pgid) ] || exit 99; exit 7"
    let status = try runInteractive("/bin/sh", ["-c", script])
    try expect(status == 7, "interactive child changed its process group or lost the exit code")
    do { _ = try runInteractive("/nonexistent/dns-switcher", []); throw SwitcherError("spawn error ignored") }
    catch let error as SwitcherError where error.message == "spawn error ignored" { throw error }
    catch {}
}

test("menu selection follows connected services, daemon health and pending recovery") {
    func service(_ servers: [String], connected: Bool = true, enabled: Bool = true) throws -> ServiceSnapshot {
        let data = try PropertyListSerialization.data(fromPropertyList: ["ServerAddresses": servers], format: .binary, options: 0)
        return ServiceSnapshot(id: UUID().uuidString, name: "Wi-Fi", device: "en0", connected: connected,
                               hadDNS: true, dnsEnabled: enabled, configuration: data)
    }
    let proxy = try service(["127.0.0.1"])
    let automatic = try service([])
    let manual = try service(["9.9.9.9"])
    let profile = defaultProfiles[0]
    let active = MenuStatus(services: [proxy, try service([], connected: false)], profile: profile, running: true, pending: false)
    try expect(active.isSelected(profile) && !active.isAutomatic && !active.needsAttention, "connected profile selection")
    let renumbered = Profile(key: "99", name: profile.name, ipv4: profile.ipv4, ipv6: profile.ipv6, endpoint: profile.endpoint)
    try expect(active.isSelected(renumbered), "renumbered profile lost selection")
    let edited = Profile(key: profile.key, name: profile.name, ipv4: profile.ipv4, ipv6: profile.ipv6, endpoint: "https://example.com/new")
    try expect(!active.isSelected(edited), "unapplied edit appears selected")
    for running in [false, true] {
        let mixed = MenuStatus(services: [proxy, manual], profile: profile, running: running, pending: false)
        try expect(mixed.activeProfile == nil && !mixed.isAutomatic, "mixed settings selected a profile")
    }
    let stopped = MenuStatus(services: [proxy], profile: profile, running: false, pending: false)
    try expect(stopped.activeProfile == nil && stopped.needsAttention, "stopped daemon appears healthy")
    let missing = MenuStatus(services: [proxy], profile: nil, running: true, pending: false)
    try expect(missing.needsAttention && missing.activeProfile == nil, "missing daemon configuration appears healthy")
    let pending = MenuStatus(services: [proxy], profile: profile, running: true, pending: true)
    try expect(pending.needsAttention && pending.activeProfile == nil && !pending.isAutomatic, "pending recovery appears applied")
    let auto = MenuStatus(services: [automatic], profile: profile, running: true, pending: false)
    try expect(auto.isAutomatic && auto.activeProfile == nil, "stale daemon profile overrides actual network settings")
    let disabled = MenuStatus(services: [try service(["127.0.0.1"], enabled: false)], profile: profile, running: true, pending: false)
    try expect(disabled.isAutomatic && disabled.activeProfile == nil, "disabled DNS protocol appears active")
    let offline = MenuStatus(services: [try service([], connected: false)], profile: nil, running: false, pending: false)
    try expect(offline.isAutomatic, "offline configuration cannot be read")
    let empty = MenuStatus(services: [], profile: nil, running: false, pending: false)
    try expect(!empty.isAutomatic && empty.needsAttention, "missing services appear automatic")
}

// Use isolated preferences without activating system network changes.
test("automatic/manual DNS and full rollback in isolated macOS preferences") {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("preferences.plist").path
    guard let prefs = SCPreferencesCreate(nil, "DNS Switcher Tests" as CFString, path as CFString) else { throw SwitcherError("test preferences") }
    let services: [String: Any] = [
        "wifi": ["UserDefinedName": "Wi-Fi test", "Interface": ["DeviceName": "en0", "Hardware": "AirPort", "Type": "Ethernet"],
                 "DNS": ["ServerAddresses": ["9.9.9.9", "2620:fe::fe"], "SearchDomains": ["test.invalid"]]],
        "ethernet": ["UserDefinedName": "Ethernet test", "Interface": ["DeviceName": "en99", "Hardware": "Ethernet", "Type": "Ethernet"], "DNS": [:]],
        "missing": ["UserDefinedName": "No DNS protocol", "Interface": ["DeviceName": "en98", "Hardware": "Ethernet", "Type": "Ethernet"]],
        "vpn": ["UserDefinedName": "VPN test", "Interface": ["DeviceName": "utun99", "Type": "PPP", "SubType": "L2TP"], "DNS": ["ServerAddresses": ["10.0.0.1"]]]
    ]
    try expect(SCPreferencesSetValue(prefs, "NetworkServices" as CFString, services as CFDictionary), "seed preferences")
    // Commit the test file directly: SCPreferencesCommitChanges requires authorization.
    let persist: (SCPreferences) -> Bool = { value in
        do {
            var dictionary: [String: Any] = [:]
            for key in SCPreferencesCopyKeyList(value) as? [String] ?? [] {
                dictionary[key] = SCPreferencesGetValue(value, key as CFString)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch { return false }
    }
    try expect(persist(prefs), "persist test preferences")
    let disabledService = SCNetworkServiceCopy(prefs, "ethernet" as CFString)!
    let disabledDNS = SCNetworkServiceCopyProtocol(disabledService, kSCNetworkProtocolTypeDNS)!
    try expect(SCNetworkProtocolSetEnabled(disabledDNS, false), "disable fixture DNS")
    var activations = 0
    let settings = NetworkSettings(preferences: prefs, commit: persist,
                                   activate: { _ in activations += 1; return true }, lock: { _ in true }, unlock: { _ in })
    let original = try settings.snapshot()
    try expect(original.count == 3, "physical filtering: \(original.map { $0.name })")
    try expect(original.first { $0.id == "ethernet" }?.dnsEnabled == false, "disabled DNS state not captured")
    try expect(original.first { $0.id == "missing" }?.hadDNS == false, "missing DNS protocol not captured")
    try expect(original.first { $0.id == "wifi" }?.servers == ["9.9.9.9", "2620:fe::fe"], "manual IPv4/IPv6 snapshot")
    try settings.apply(original, servers: ["127.0.0.1"])
    try expect(try settings.snapshot().allSatisfy { $0.servers == ["127.0.0.1"] }, "proxy DNS assignment")
    try settings.restore(original)
    let restored = try settings.snapshot()
    try expect(restored.elementsEqual(original, by: sameSnapshot), "full original configuration not restored")
    try settings.apply(restored, servers: nil)
    let automatic = try settings.snapshot()
    try expect(automatic.allSatisfy { $0.servers.isEmpty }, "automatic DNS not restored")
    let wifi = SCNetworkServiceCopy(prefs, "wifi" as CFString)!
    let dns = SCNetworkServiceCopyProtocol(wifi, kSCNetworkProtocolTypeDNS)!
    let config = SCNetworkProtocolGetConfiguration(dns) as? [String: Any]
    try expect(config?["SearchDomains"] as? [String] == ["test.invalid"], "search domains lost")
    let raw = SCPreferencesGetValue(prefs, "NetworkServices" as CFString) as? [String: Any]
    let vpn = raw?["vpn"] as? [String: Any]
    let vpnDNS = vpn?["DNS"] as? [String: Any]
    try expect(vpnDNS?["ServerAddresses"] as? [String] == ["10.0.0.1"], "VPN modified")
    try expect(activations == 3 && FileManager.default.fileExists(atPath: path), "isolated commits")
    // Activation can fail after the preferences have been committed.
    let broken = NetworkSettings(preferences: prefs, commit: persist, activate: { _ in false }, lock: { _ in true }, unlock: { _ in })
    do { try broken.apply(automatic, servers: ["127.0.0.1"]); throw SwitcherError("activation error ignored") }
    catch let error as SwitcherError where error.message == "activation error ignored" { throw error }
    catch {}
    try settings.restore(original)
    try expect(try settings.snapshot().elementsEqual(original, by: sameSnapshot), "rollback after failed activation")
}

func connectSocket(_ type: Int32, port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, type, 0)
    guard fd >= 0 else { throw SwitcherError("socket") }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0 else { close(fd); throw SwitcherError("connect") }
    return fd
}
func sendData(_ fd: Int32, _ data: Data) throws {
    let count = data.withUnsafeBytes { send(fd, $0.baseAddress, data.count, 0) }
    try expect(count == data.count, "short write")
}
func readData(_ fd: Int32, _ count: Int) throws -> Data {
    var data = Data()
    while data.count < count {
        var bytes = [UInt8](repeating: 0, count: count - data.count)
        let n = recv(fd, &bytes, bytes.count, 0)
        guard n > 0 else { throw SwitcherError("short read") }
        data.append(contentsOf: bytes.prefix(n))
    }
    return data
}

test("real loopback UDP and TCP proxy, split frames and persistent connections") {
    let proxy = DNSProxy(profile: defaultProfiles[0], port: 0, resolver: { answer($0) })
    try proxy.start()
    try expect(proxy.port >= 1024, "test listener uses a privileged port")
    let udp = try connectSocket(SOCK_DGRAM, port: proxy.port)
    defer { close(udp) }
    try sendData(udp, DNSMessage.probe)
    var bytes = [UInt8](repeating: 0, count: 4096)
    let count = recv(udp, &bytes, bytes.count, 0)
    try expect(count > 0 && DNSMessage.validate(Data(bytes.prefix(max(0, count))), for: DNSMessage.probe, requireAnswer: true), "UDP response")
    let tcp = try connectSocket(SOCK_STREAM, port: proxy.port)
    defer { close(tcp) }
    for id: UInt8 in [1, 2] {
        var query = DNSMessage.probe; query[1] = id
        try sendData(tcp, Data([0]))
        try sendData(tcp, Data([UInt8(query.count)]) + query)
        let header = try readData(tcp, 2)
        let length = Int(header[0]) << 8 | Int(header[1])
        let response = try readData(tcp, length)
        try expect(DNSMessage.validate(response, for: query, requireAnswer: true), "TCP response")
    }
    let conflict = DNSProxy(profile: defaultProfiles[1], port: proxy.port)
    do { try conflict.start(); throw SwitcherError("port conflict ignored") }
    catch let error as SwitcherError where error.message == "port conflict ignored" { throw error }
    catch {}
}

print("\n\(passed) passed, \(failed) failed. System DNS was not changed.")
exit(failed == 0 ? 0 : 1)

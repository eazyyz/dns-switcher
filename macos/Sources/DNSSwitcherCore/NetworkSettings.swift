import Foundation
import SystemConfiguration

public struct ServiceSnapshot: Codable {
    public let id: String
    public let name: String
    public let device: String
    public let connected: Bool
    public let hadDNS: Bool
    public let dnsEnabled: Bool
    public let configuration: Data?

    public var servers: [String] {
        guard let data = configuration,
              let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        return config[kSCPropNetDNSServerAddresses as String] as? [String] ?? []
    }
}

public final class NetworkSettings {
    private let preferences: SCPreferences
    private let activate: (SCPreferences) -> Bool
    private let commit: (SCPreferences) -> Bool
    private let lock: (SCPreferences) -> Bool
    private let unlock: (SCPreferences) -> Void
    public convenience init() throws {
        guard let value = SCPreferencesCreate(nil, "DNS Switcher" as CFString, nil) else {
            throw SwitcherError("Не удалось открыть настройки сети.")
        }
        self.init(preferences: value)
    }

    init(preferences: SCPreferences,
         commit: @escaping (SCPreferences) -> Bool = SCPreferencesCommitChanges,
         activate: @escaping (SCPreferences) -> Bool = SCPreferencesApplyChanges,
         lock: @escaping (SCPreferences) -> Bool = { SCPreferencesLock($0, false) },
         unlock: @escaping (SCPreferences) -> Void = { _ = SCPreferencesUnlock($0) }) {
        self.preferences = preferences
        self.activate = activate
        self.commit = commit
        self.lock = lock
        self.unlock = unlock
    }

    private func physicalDevice(_ interface: SCNetworkInterface) -> String? {
        guard let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { return nil }
        // Only physical Ethernet and Wi-Fi services.
        guard type == (kSCNetworkInterfaceTypeEthernet as String) || type == (kSCNetworkInterfaceTypeIEEE80211 as String),
              let device = SCNetworkInterfaceGetBSDName(interface) as String? else { return nil }
        return device
    }

    private func connected(_ device: String) -> Bool {
        guard let store = SCDynamicStoreCreate(nil, "DNS Switcher" as CFString, nil, nil),
              let link = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(device)/Link" as CFString) as? [String: Any],
              link["Active"] as? Bool == true else { return false }
        return ["IPv4", "IPv6"].contains { family in
            guard let state = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(device)/\(family)" as CFString) as? [String: Any] else { return false }
            return !(state["Addresses"] as? [String] ?? []).isEmpty
        }
    }

    public func snapshot() throws -> [ServiceSnapshot] {
        guard let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            throw SwitcherError("Не удалось прочитать сетевые службы.")
        }
        return try services.compactMap { service in
            guard let interface = SCNetworkServiceGetInterface(service), let device = physicalDevice(interface),
                  let id = SCNetworkServiceGetServiceID(service) as String? else { return nil }
            let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS)
            let configuration = dns.flatMap { SCNetworkProtocolGetConfiguration($0) }
            let data = try configuration.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
            return ServiceSnapshot(
                id: id,
                name: SCNetworkServiceGetName(service) as String? ?? device,
                device: device, connected: SCNetworkServiceGetEnabled(service) && connected(device),
                hadDNS: dns != nil, dnsEnabled: dns.map { SCNetworkProtocolGetEnabled($0) } ?? false,
                configuration: data
            )
        }.sorted { $0.name < $1.name }
    }

    public func apply(_ snapshots: [ServiceSnapshot], servers: [String]?) throws {
        try change(snapshots, restore: false, servers: servers)
    }

    public func restore(_ snapshots: [ServiceSnapshot]) throws {
        try change(snapshots, restore: true, servers: nil)
    }

    private func change(_ snapshots: [ServiceSnapshot], restore: Bool, servers: [String]?) throws {
        guard lock(preferences) else { throw SwitcherError("Настройки сети заняты другим приложением.") }
        defer { unlock(preferences) }
        for snapshot in snapshots {
            guard let service = SCNetworkServiceCopy(preferences, snapshot.id as CFString) else {
                throw SwitcherError("Сетевая служба «\(snapshot.name)» больше не существует.")
            }
            if restore && !snapshot.hadDNS {
                if SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) != nil {
                    guard SCNetworkServiceRemoveProtocolType(service, kSCNetworkProtocolTypeDNS) else { throw settingsError(snapshot.name) }
                }
                continue
            }
            if SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) == nil {
                guard SCNetworkServiceAddProtocolType(service, kSCNetworkProtocolTypeDNS) else { throw settingsError(snapshot.name) }
            }
            guard let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else { throw settingsError(snapshot.name) }
            var configuration: [String: Any]
            if restore {
                configuration = try snapshot.configuration.map {
                    try PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] ?? [:]
                } ?? [:]
            } else {
                configuration = SCNetworkProtocolGetConfiguration(dns) as? [String: Any] ?? [:]
                if let servers = servers {
                    configuration[kSCPropNetDNSServerAddresses as String] = servers
                } else {
                    configuration.removeValue(forKey: kSCPropNetDNSServerAddresses as String)
                }
            }
            guard SCNetworkProtocolSetConfiguration(dns, configuration as CFDictionary),
                  SCNetworkProtocolSetEnabled(dns, restore ? snapshot.dnsEnabled : true) else { throw settingsError(snapshot.name) }
        }
        guard commit(preferences), activate(preferences) else {
            throw SwitcherError("Не удалось применить настройки сети: \(String(cString: SCErrorString(SCError()))).")
        }
    }

    private func settingsError(_ name: String) -> SwitcherError {
        SwitcherError("Не удалось изменить DNS службы «\(name)».")
    }
}

import Foundation

/// Summarizes connected physical services, or all services when offline.
public struct MenuStatus {
    public let summary: String
    public let activeProfile: Profile?
    public let isAutomatic: Bool
    public let needsAttention: Bool

    init(services: [ServiceSnapshot], profile: Profile?, running: Bool, pending: Bool) {
        let connected = services.filter { $0.connected }
        let relevant = connected.isEmpty ? services : connected
        activeProfile = !pending && running && !relevant.isEmpty && relevant.allSatisfy {
            $0.dnsEnabled && $0.servers == ["127.0.0.1"]
        } ? profile : nil
        isAutomatic = !pending && !relevant.isEmpty && relevant.allSatisfy {
            !$0.dnsEnabled || $0.servers.isEmpty
        }
        if pending {
            summary = "Требуется восстановление DNS — выберите профиль"
            needsAttention = true
        } else if relevant.isEmpty {
            summary = "Подключения Wi-Fi / Ethernet не найдены"
            needsAttention = true
        } else if let activeProfile = activeProfile {
            summary = "\(activeProfile.name) · DoH"
            needsAttention = false
        } else if isAutomatic {
            summary = "Автоматический DNS"
            needsAttention = false
        } else if relevant.contains(where: { $0.dnsEnabled && $0.servers == ["127.0.0.1"] }) && (!running || profile == nil) {
            summary = "Локальный DNS-сервис недоступен"
            needsAttention = true
        } else {
            summary = "Другой DNS / разные настройки подключений"
            needsAttention = false
        }
    }

    public func isSelected(_ profile: Profile) -> Bool {
        guard let active = activeProfile else { return false }
        // Numbering can change after editing; a changed endpoint must not appear applied.
        return active.name == profile.name && active.ipv4 == profile.ipv4 &&
            active.ipv6 == profile.ipv6 && active.endpoint == profile.endpoint
    }
}

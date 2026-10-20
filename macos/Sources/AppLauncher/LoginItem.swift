import AppKit
import ServiceManagement

enum LoginItem {
    private static var legacyFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.eazyyz.dns-switcher.menu.plist")
    }

    static var enabled: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return FileManager.default.fileExists(atPath: legacyFile.path)
    }

    static var needsApproval: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .requiresApproval }
        return false
    }

    static func toggle() throws {
        if #available(macOS 13, *) {
            if needsApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else if enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if needsApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } else {
            // Monterey reads this user agent at next login.
            let fm = FileManager.default
            if enabled {
                try fm.removeItem(at: legacyFile)
            } else {
                try fm.createDirectory(at: legacyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                let plist: [String: Any] = [
                    "Label": "com.eazyyz.dns-switcher.menu",
                    "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundlePath],
                    "RunAtLoad": true
                ]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: legacyFile, options: .atomic)
            }
        }
    }
}

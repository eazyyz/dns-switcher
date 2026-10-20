import AppKit
import DNSSwitcherCore

final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = DNSListStore()
    private let queue = DispatchQueue(label: "com.eazyyz.dns-switcher.menu")
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var profiles: [Profile] = []
    private var status: MenuStatus?
    private var listError: String?
    private var statusError: String?
    private var feedback: String?
    private var busy = false
    private var refreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: {
               $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
           }) {
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        render()
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        busy ? .terminateCancel : .terminateNow
    }

    private func item(_ title: String, action: Selector? = nil, enabled: Bool = true) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
        result.target = self
        result.isEnabled = enabled && action != nil
        return result
    }

    private func render() {
        let image: NSImage?
        if busy {
            image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Переключение DNS")
        } else if statusError != nil || status?.needsAttention == true {
            image = NSImage(systemSymbolName: "exclamationmark.shield", accessibilityDescription: "Проверьте DNS")
        } else {
            image = BrandIcon.menuBar
        }
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = image == nil ? "DNS" : ""
        statusItem.button?.toolTip = "DNS Switcher — \(busy ? "Переключение DNS…" : statusError ?? status?.summary ?? "Чтение настроек…")"
        menu.removeAllItems()
        menu.addItem(item("DNS Switcher"))
        menu.addItem(item(busy ? "Переключение DNS…" : statusError ?? status?.summary ?? "Чтение настроек…"))
        if let feedback = feedback { menu.addItem(item(feedback)) }
        menu.addItem(.separator())
        let automatic = item("Автоматический DNS", action: #selector(selectDNS(_:)), enabled: !busy)
        automatic.state = status?.isAutomatic == true ? .on : .off
        menu.addItem(automatic)
        for profile in profiles {
            let entry = item(profile.name, action: #selector(selectDNS(_:)), enabled: !busy)
            entry.representedObject = profile
            entry.state = status?.isSelected(profile) == true ? .on : .off
            menu.addItem(entry)
        }
        if let listError = listError {
            let error = item("Ошибка списка — откройте и исправьте файл")
            error.toolTip = listError
            menu.addItem(error)
        } else if profiles.isEmpty {
            menu.addItem(item("В списке нет DNS-профилей"))
        }
        menu.addItem(.separator())
        menu.addItem(item("Изменить список DNS…", action: #selector(editList), enabled: !busy))
        let login = item(LoginItem.needsApproval ? "Разрешить запуск при входе…" : "Запускать при входе",
                         action: #selector(toggleLogin), enabled: !busy)
        login.state = LoginItem.enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("После выхода выбранный DNS продолжит работать"))
        let quit = item("Выход", action: #selector(quit), enabled: !busy)
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func refresh() {
        guard !refreshing, !busy else { return }
        refreshing = true
        queue.async {
            let list = Result { try self.store.load() }
            let state = Result { try Controller().menuStatus() }
            DispatchQueue.main.async {
                self.refreshing = false
                switch list {
                case .success(let profiles): self.profiles = profiles; self.listError = nil
                case .failure(let error): self.profiles = []; self.listError = error.localizedDescription
                }
                switch state {
                case .success(let status): self.status = status; self.statusError = nil
                case .failure: self.status = nil; self.statusError = "Не удалось прочитать настройки DNS"
                }
                self.render()
            }
        }
    }

    @objc private func selectDNS(_ sender: NSMenuItem) {
        guard !busy, let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("dns-switcher") else { return }
        let profile = sender.representedObject as? Profile
        busy = true
        feedback = nil
        render()
        queue.async {
            let result = Result { try PrivilegedCommand.apply(profile, executable: executable) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let applied):
                    self.feedback = applied ? "Готово: \(profile?.name ?? "автоматический DNS")" : nil
                case .failure(let error):
                    self.feedback = "Переключение не завершено"
                    self.showError("Не удалось переключить DNS", error.localizedDescription)
                }
                self.refresh()
                self.render()
            }
        }
    }

    @objc private func editList() {
        do {
            try store.ensureExists()
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([store.file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                    configuration: configuration) { _, error in
                if let error = error {
                    DispatchQueue.main.async { self.showError("Не удалось открыть список DNS", error.localizedDescription) }
                }
            }
        } catch { showError("Не удалось открыть список DNS", error.localizedDescription) }
    }

    @objc private func toggleLogin() {
        do { try LoginItem.toggle(); render() }
        catch { showError("Не удалось настроить запуск при входе", error.localizedDescription) }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

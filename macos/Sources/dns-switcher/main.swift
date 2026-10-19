import Foundation
import Darwin
import DNSSwitcherCore

func elevated(_ arguments: [String]) throws {
    print("Для изменения DNS нужны права администратора.")
    print("Если появится Password:, введите пароль Mac и нажмите Enter. Символы пароля не отображаются.")
    fflush(stdout)
    let code = try runInteractive("/usr/bin/sudo",
        [URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path] + arguments)
    if code != 0 { throw SwitcherError("Операция не завершена (код \(code)).") }
}

func apply(_ profile: Profile?, _ controller: Controller) throws {
    if let profile = profile { try DNSList.validate(profile) }
    if geteuid() == 0 { try controller.apply(profile: profile) }
    else if let profile = profile {
        // Pass the displayed profile through sudo instead of a menu index.
        let encoded = try JSONEncoder().encode(profile).base64EncodedString()
        try elevated(["--apply-profile", encoded])
    } else { try elevated(["--apply", "1"]) }
}

func requireUser() throws {
    guard geteuid() != 0 else { throw SwitcherError("Запускайте меню и команды списка без sudo. Пароль запрашивается только при смене DNS.") }
}

func openList(_ store: DNSListStore) throws {
    try requireUser()
    try store.ensureExists()
    let result = try run("/usr/bin/open", ["-a", "TextEdit", store.file.path])
    guard result.status == 0 else { throw SwitcherError("Не удалось открыть список: \(store.file.path)") }
    print("Сохраните файл в UTF-8 и вернитесь в это окно. Список обновится при возврате в меню.")
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    let controller = Controller()
    let store = DNSListStore()
    switch args.first {
    case "--menu" where args.count == 1:
        try requireUser()
        while true {
            print("\nDNS Switcher — macOS\n")
            var profiles: [Profile] = []
            do { profiles = try store.load() }
            catch { print("Ошибка списка: \(error.localizedDescription)\nФайл: \(store.file.path)\nИсправьте файл через E. Автоматический DNS доступен.") }
            do { try controller.status(profiles: profiles) }
            catch { print("Ошибка чтения настроек: \(error.localizedDescription)") }
            print("Выберите DNS:\n  1 — Автоматический DNS (IPv4 и IPv6)")
            for profile in profiles { print("  \(profile.key) — \(profile.name)") }
            if profiles.isEmpty { print("  В списке нет DNS-профилей.") }
            print("""

              E — Изменить список DNS
              0 — Выход

            Применяется ко всем физическим Ethernet/Wi-Fi подключениям.
            Редактирование списка не меняет DNS сети до выбора профиля.
            Сервис DoH продолжает работать после закрытия окна и перезагрузки.
            """)
            print("Введите номер или букву и нажмите Enter: ", terminator: "")
            fflush(stdout)
            guard let input = readLine() else { break }
            let selection = input.trimmingCharacters(in: .whitespaces).uppercased()
            if selection == "0" { break }
            if selection.isEmpty { continue }
            do {
                if selection == "1" { try apply(nil, controller) }
                else if let profile = profiles.first(where: { $0.key == selection }) { try apply(profile, controller) }
                else if selection == "E" { try openList(store) }
                else { print("Такого пункта нет."); continue }
            } catch { print("Ошибка: \(error.localizedDescription)") }
            print("Нажмите Enter, чтобы вернуться в меню…", terminator: "")
            fflush(stdout)
            _ = readLine()
        }
    case "--list" where args.count == 1:
        try requireUser()
        for profile in try store.load() { print("\(profile.key) — \(profile.name)") }
    case "--list-path" where args.count == 1:
        try requireUser()
        try store.ensureExists()
        print(store.file.path)
    case "--edit-list" where args.count == 1:
        try openList(store)
    case "--validate-list" where args.count == 2:
        let profiles = try DNSList.read(URL(fileURLWithPath: args[1]))
        print(String(decoding: try JSONEncoder().encode(profiles), as: UTF8.self))
    case "--status" where args.count == 1:
        try controller.status()
    case "--apply" where args.count == 2:
        if args[1] == "1" { try apply(nil, controller) }
        else {
            try requireUser()
            guard let profile = try store.load().first(where: { $0.key == args[1] }) else { throw SwitcherError("Неизвестный пункт списка DNS.") }
            try apply(profile, controller)
        }
    case "--apply-profile" where args.count == 2:
        guard args[1].utf8.count <= 16384, let data = Data(base64Encoded: args[1]) else { throw SwitcherError("Некорректные данные DNS.") }
        let profile = try JSONDecoder().decode(Profile.self, from: data)
        try apply(profile, controller)
    case "--check" where args.count == 2:
        try requireUser()
        guard let profile = try store.load().first(where: { $0.key == args[1] }) else { throw SwitcherError("Неизвестный пункт списка DNS.") }
        try DoHClient(profile: profile).check()
    case "--proxy" where args.count == 2 || args.count == 3:
        let profile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        try DNSList.validate(profile)
        let port: UInt16
        if args.count == 3 {
            guard let value = UInt16(args[2]), value >= 1024 else { throw SwitcherError("Для теста выберите порт 1024–65535.") }
            port = value
        } else { port = 53 }
        let proxy = DNSProxy(profile: profile, port: port)
        try proxy.start()
        if args.count == 2 {
            let ready = URL(fileURLWithPath: args[1]).deletingLastPathComponent().appendingPathComponent("ready.pid")
            try Data(String(getpid()).utf8).write(to: ready, options: .atomic)
            guard chmod(ready.path, 0o600) == 0 else { throw SwitcherError("Не удалось записать состояние сервиса.") }
        }
        withExtendedLifetime(proxy) { dispatchMain() }
    default:
        print("""
        DNS Switcher для macOS 12+
        --menu              Интерактивное меню
        --list              DNS из вашего TXT-файла
        --list-path         Путь к вашему TXT-файлу
        --edit-list         Открыть список в TextEdit
        --validate-list TXT Проверить формат файла (без изменения настроек)
        --status            Показать настройки сети
        --check N           Проверить DoH из вашего списка
        --apply N           Применить DNS; 1 — автоматический (пароль при необходимости)
        """)
        if !args.isEmpty { exit(1) }
    }
} catch {
    fputs("Ошибка: \(error.localizedDescription)\n", stderr)
    exit(1)
}

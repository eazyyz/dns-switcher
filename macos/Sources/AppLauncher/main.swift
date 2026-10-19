import Foundation
import Darwin

do {
    guard let resources = Bundle.main.resourceURL else {
        throw NSError(domain: "DNSSwitcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не найдены файлы DNS Switcher."])
    }
    let command = resources.appendingPathComponent("run.command")
    guard FileManager.default.isExecutableFile(atPath: command.path) else {
        throw NSError(domain: "DNSSwitcher", code: 2, userInfo: [NSLocalizedDescriptionKey: "Приложение повреждено. Распакуйте архив повторно."])
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", "Terminal", command.path]
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}

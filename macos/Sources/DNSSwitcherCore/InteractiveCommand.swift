import Foundation
import Darwin

// Keep sudo in the foreground process group to avoid SIGTTIN.
public func runInteractive(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let strings = ([executable] + arguments).map { strdup($0) }
    defer { strings.forEach { free($0) } }
    guard strings.allSatisfy({ $0 != nil }) else { throw SwitcherError("Недостаточно памяти для запуска команды.") }
    var argv = strings + [nil]
    var pid: pid_t = 0
    let result = argv.withUnsafeMutableBufferPointer {
        posix_spawn(&pid, executable, nil, nil, $0.baseAddress!, environ)
    }
    guard result == 0 else { throw SwitcherError("Не удалось запустить команду: \(String(cString: strerror(result))).") }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 {
        if errno != EINTR { throw SwitcherError("Не удалось дождаться завершения команды.") }
    }
    if status & 0x7f == 0 { return (status >> 8) & 0xff }
    return 128 + (status & 0x7f)
}

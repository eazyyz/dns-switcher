import Foundation
import DNSSwitcherCore

// Exercise the real AppleScript bridge without requesting privileges or changing DNS.
do {
    let unprivileged = PrivilegedCommand.script.replacingOccurrences(of: " with administrator privileges", with: "")
    let payload = "Кавычки ' \"; $(echo injected) `echo injected` \\ пробелы"
    let output = try PrivilegedCommand.execute(arguments: ["/usr/bin/printf", "%s", payload], script: unprivileged)
    guard output == payload else { throw SwitcherError("Arguments were not preserved: \(output)") }
    print("PASS AppleScript preserves Unicode, spaces, quotes and shell metacharacters")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DNS ' test \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("print args")
    try Data("#!/bin/sh\nexec /usr/bin/printf \"$@\"\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let pathOutput = try PrivilegedCommand.execute(arguments: [executable.path, "%s", payload], script: unprivileged)
    guard pathOutput == payload else { throw SwitcherError("Application path was not quoted") }
    print("PASS executable paths with spaces and apostrophes")

    let cancelledScript = PrivilegedCommand.script.replacingOccurrences(
        of: "return do shell script commandText with administrator privileges", with: "error number -128")
    let cancelled = try PrivilegedCommand.execute(arguments: [], script: cancelledScript)
    guard cancelled == "DNS_SWITCHER_CANCELLED" else { throw SwitcherError("Cancellation was not recognized") }
    print("PASS system authentication cancellation")

    do {
        _ = try PrivilegedCommand.execute(arguments: ["/usr/bin/false"], script: unprivileged)
        throw SwitcherError("Command failure was ignored")
    } catch let error as SwitcherError where error.message == "Command failure was ignored" { throw error }
    catch {}
    print("PASS failed commands report an error")
} catch {
    fputs("FAIL \(error.localizedDescription)\n", stderr)
    exit(1)
}
